#!/usr/bin/env python3

import sys
import os
import subprocess
import warnings
from faster_whisper import WhisperModel
import torch

# --------------------------------------------------
# Arguments
# --------------------------------------------------

audio_path = sys.argv[1]
out_path = sys.argv[2]
model_size = sys.argv[3]
language = sys.argv[4] if sys.argv[4] != "auto" else None
beam_size = int(sys.argv[5]) if len(sys.argv) > 5 else 5

diarize = os.environ.get("WHISPER_DIARIZE", "false") == "true"
hf_token = os.environ.get("HF_TOKEN", "")
initial_prompt = os.environ.get("WHISPER_PROMPT")

# --------------------------------------------------
# Utility
# --------------------------------------------------


def fmt_ts(s):
    h = int(s // 3600)
    m = int((s % 3600) // 60)
    sec = int(s % 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


def get_duration(path):
    try:
        r = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                path,
            ],
            capture_output=True,
            text=True,
        )
        return float(r.stdout.strip())
    except Exception:
        return 0.0


def draw_progress(current, total):
    if total <= 0:
        return

    pct = min(current / total, 1.0)

    try:
        width = os.get_terminal_size().columns
    except OSError:
        width = 80

    suffix = f"] {int(pct*100):3d}%  {fmt_ts(current)} / {fmt_ts(total)}"
    prefix = "  ["

    bar_w = max(10, width - len(prefix) - len(suffix) - 1)

    filled = int(bar_w * pct)
    bar = "█" * filled + "░" * (bar_w - filled)

    print(f"\r{prefix}{bar}{suffix}", end="", flush=True)


# --------------------------------------------------
# Model Setup
# --------------------------------------------------

device = "cuda" if torch.cuda.is_available() else "cpu"
compute_type = "float16" if device == "cuda" else "int8"

print(f"Device: {device} ({compute_type})")

total_dur = get_duration(audio_path)

print(f"Loading model: {model_size}")

model = WhisperModel(model_size, device=device, compute_type=compute_type)

# --------------------------------------------------
# Transcription
# --------------------------------------------------

print(f"Transcribing ({fmt_ts(total_dur)})...")
print()

segments_iter, info = model.transcribe(
    audio_path,
    language=language,
    beam_size=beam_size,
    initial_prompt=initial_prompt,
    word_timestamps=True,
    vad_filter=True,
    vad_parameters={"min_silence_duration_ms": 500},
)

print(f"Language: {info.language} ({info.language_probability:.2f})")
print()

segments = []
all_words = []

for seg in segments_iter:
    segments.append(seg)

    if seg.words:
        for w in seg.words:
            all_words.append((w.start, w.end, w.word))

    draw_progress(seg.end, total_dur)

draw_progress(total_dur, total_dur)

print()
print(f"Segments: {len(segments)}, Words: {len(all_words)}")

# --------------------------------------------------
# Speaker Diarization
# --------------------------------------------------

speaker_map = []

if diarize and hf_token:
    try:
        print("Running speaker diarization...")

        warnings.filterwarnings("ignore")

        from pyannote.audio import Pipeline
        import torchaudio

        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-community-1", use_auth_token=hf_token
        )

        pipeline.to(torch.device(device))

        waveform, sample_rate = torchaudio.load(audio_path)

        audio_input = {"waveform": waveform, "sample_rate": sample_rate}

        diar = pipeline(audio_input)

        for turn, speaker in diar.exclusive_speaker_diarization:
            speaker_map.append((turn.start, turn.end, str(speaker)))

        speakers = len({s[2] for s in speaker_map})

        print(f"{speakers} speakers detected")

    except Exception as e:
        print(f"WARNING: diarization failed ({e})")

# --------------------------------------------------
# Speaker helper
# --------------------------------------------------


def get_speaker_at(t):
    if not speaker_map:
        return "Speaker"

    for s, e, lbl in speaker_map:
        if s <= t < e:
            return lbl.replace("SPEAKER_", "Speaker_")

    best = min(speaker_map, key=lambda x: min(abs(t - x[0]), abs(t - x[1])))
    return best[2].replace("SPEAKER_", "Speaker_")


# --------------------------------------------------
# Build Transcript Lines
# --------------------------------------------------


def build_lines(words, fallback_segments):
    if not words:
        lines = []

        for seg in fallback_segments:
            text = seg.text.strip()
            if text:
                spk = get_speaker_at(seg.start)
                lines.append((seg.start, spk, text))

        return lines

    labeled = [(w_start, w_end, w_text, get_speaker_at(w_start)) for w_start, w_end, w_text in words]

    lines = []

    cur_spk = labeled[0][3]
    cur_start = labeled[0][0]
    cur_words = []

    for w_start, w_end, w_text, spk in labeled:

        if spk != cur_spk:

            lines.append((cur_start, cur_spk, "".join(cur_words).strip()))

            cur_spk = spk
            cur_start = w_start
            cur_words = []

        cur_words.append(w_text)

    if cur_words:
        lines.append((cur_start, cur_spk, "".join(cur_words).strip()))

    return [(s, spk, txt) for s, spk, txt in lines if txt]


lines = build_lines(all_words, segments)

# --------------------------------------------------
# Write Markdown Transcript
# --------------------------------------------------

with open(out_path, "w") as f:

    for start, spk, text in lines:

        f.write(f"**{spk}**: {text}\n")
        f.write(f"*{fmt_ts(start)}*\n\n")

print(f"Transcript written: {out_path}")