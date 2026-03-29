#!/usr/bin/env python3
"""
Transcription script using WhisperX.

WhisperX handles transcription, word-level alignment, and speaker diarization
in a single integrated pipeline, replacing the previous faster-whisper +
pyannote.audio combination which required extensive version pinning and patching.

Usage (called from publish.sh):
  python3 transcribe.py <audio> <output.md> <model> <language> [beam_size]

Environment variables:
  WHISPER_DIARIZE   - "true" to enable speaker diarization
  HF_TOKEN          - HuggingFace token for pyannote diarization models
  WHISPER_SPEAKERS  - number of speakers (count of hosts + guests from frontmatter)
"""

import sys
import os
import warnings
import torch

# Suppress noisy warnings from pyannote/lightning
warnings.filterwarnings("ignore")
os.environ["TOKENIZERS_PARALLELISM"] = "false"

# --------------------------------------------------
# Arguments
# --------------------------------------------------

audio_path = sys.argv[1]
out_path   = sys.argv[2]
model_size = sys.argv[3]
language   = sys.argv[4] if sys.argv[4] != "auto" else None
diarize        = os.environ.get("WHISPER_DIARIZE", "false") == "true"
hf_token       = os.environ.get("HF_TOKEN", "")
_spk           = os.environ.get("WHISPER_SPEAKERS", "")
num_speakers   = int(_spk) if _spk.isdigit() else None

# --------------------------------------------------
# Utility
# --------------------------------------------------

def fmt_ts(s):
    h   = int(s // 3600)
    m   = int((s % 3600) // 60)
    sec = int(s % 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


# --------------------------------------------------
# Device
# --------------------------------------------------

device       = "cuda" if torch.cuda.is_available() else "cpu"
compute_type = "float16" if device == "cuda" else "int8"

print(f"Device: {device} ({compute_type})")

# --------------------------------------------------
# Load model and transcribe
# --------------------------------------------------

import whisperx

print(f"Loading model: {model_size}")

model = whisperx.load_model(
    model_size,
    device,
    compute_type=compute_type,
    language=language,
)

print("Loading audio...")
audio = whisperx.load_audio(audio_path)

print("Transcribing...")

result = model.transcribe(
    audio,
    batch_size=16,
    language=language,
)

detected_lang = result.get("language", language or "unknown")
print(f"Language: {detected_lang}")
print(f"Segments: {len(result['segments'])}")

# Free GPU memory before alignment
del model
if device == "cuda":
    torch.cuda.empty_cache()

# --------------------------------------------------
# Word-level alignment
# --------------------------------------------------

print("Aligning word timestamps...")

try:
    align_model, align_metadata = whisperx.load_align_model(
        language_code=detected_lang,
        device=device,
    )

    result = whisperx.align(
        result["segments"],
        align_model,
        align_metadata,
        audio,
        device,
        return_char_alignments=False,
    )

    del align_model
    if device == "cuda":
        torch.cuda.empty_cache()

except Exception as e:
    print(f"WARNING: alignment failed ({e}), using segment-level timestamps")

# --------------------------------------------------
# Speaker diarization
# --------------------------------------------------

if diarize and hf_token:
    print("Running speaker diarization...")

    try:
        # Use pyannote directly (not via WhisperX wrapper) so we can access
        # exclusive_speaker_diarization — a feature backported from precision-2
        # that returns non-overlapping speaker turns, making word-speaker
        # reconciliation much cleaner than regular diarization.
        from pyannote.audio import Pipeline
        from pyannote.audio.pipelines.utils.hook import ProgressHook
        from whisperx.diarize import assign_word_speakers
        import pandas as pd

        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-community-1",
            token=hf_token,
        ).to(torch.device(device))

        if num_speakers:
            print(f"  Hint: {num_speakers} speakers (from frontmatter)")
            kwargs = dict(min_speakers=num_speakers, max_speakers=num_speakers)
        else:
            kwargs = {}

        audio_input = {
            "waveform": torch.from_numpy(audio[None, :]),
            "sample_rate": 16000,
        }

        with ProgressHook() as hook:
            output = pipeline(audio_input, hook=hook, **kwargs)

        # Use exclusive_speaker_diarization — one speaker active at a time,
        # dramatically simplifying word-to-speaker reconciliation.
        rows = []
        for turn, spk in output.exclusive_speaker_diarization:
            # spk is a string label like "SPEAKER_0" or "A", "B" etc.
            rows.append({"start": turn.start, "end": turn.end, "speaker": spk})
        diarize_df = pd.DataFrame(rows)

        result = assign_word_speakers(diarize_df, result, fill_nearest=True)

        speakers = {
            w.get("speaker")
            for seg in result["segments"]
            for w in seg.get("words", [])
            if w.get("speaker")
        }
        print(f"{len(speakers)} speakers detected")

    except Exception as e:
        print(f"WARNING: diarization failed ({e})")

# --------------------------------------------------
# Build transcript lines grouped by speaker
# --------------------------------------------------

def get_speaker(seg, word=None):
    """Get speaker label from word or segment, normalised."""
    raw = None
    if word:
        raw = word.get("speaker")
    if not raw:
        raw = seg.get("speaker")
    if not raw:
        return "Speaker"
    return raw.replace("SPEAKER_", "Speaker_")


lines = []  # list of (start, speaker, text)

for seg in result["segments"]:
    words = seg.get("words", [])

    if not words:
        # No word-level data — use segment as a single line
        text = seg.get("text", "").strip()
        if text:
            spk   = get_speaker(seg)
            start = seg.get("start", 0)
            end   = seg.get("end", start)
            lines.append((start, spk, text, end))
        continue

    # Group consecutive words by speaker into lines
    cur_spk   = get_speaker(seg, words[0])
    cur_start = words[0].get("start", seg.get("start", 0))
    cur_end   = cur_start
    cur_words = []

    for w in words:
        spk  = get_speaker(seg, w)
        text = w.get("word", "").strip()
        wend = w.get("end", cur_end)

        if spk != cur_spk:
            joined = " ".join(cur_words).strip()
            if joined:
                lines.append((cur_start, cur_spk, joined, cur_end))
            cur_spk   = spk
            cur_start = w.get("start", cur_end)
            cur_end   = cur_start
            cur_words = []

        if text:
            cur_words.append(text)
        cur_end = wend

    joined = " ".join(cur_words).strip()
    if joined:
        lines.append((cur_start, cur_spk, joined, cur_end))

# --------------------------------------------------
# Merge consecutive same-speaker lines into paragraphs
# --------------------------------------------------

MERGE_GAP        = 5.0  # max gap (seconds) between same-speaker lines to merge
MERGE_MIN_WORDS  = 4    # only merge if the existing line has at least this many words
                        # — keeps short utterances ("Bye!", "Yeah.") as discrete lines

merged = []
for start, spk, text, _end in lines:
    if merged and merged[-1][1] == spk:
        prev_start, prev_spk, prev_text, prev_end = merged[-1]
        gap = start - prev_end
        prev_word_count = len(prev_text.split())
        if gap < MERGE_GAP and prev_word_count >= MERGE_MIN_WORDS:
            merged[-1] = (prev_start, prev_spk, prev_text + " " + text, start)
            continue
    merged.append((start, spk, text, _end))

# --------------------------------------------------
# Write markdown transcript
# --------------------------------------------------

with open(out_path, "w") as f:
    for start, spk, text, _ in merged:
        f.write(f"**{spk}**: {text}\n")
        f.write(f"*{fmt_ts(start)}*\n\n")

print(f"Transcript written: {out_path}")