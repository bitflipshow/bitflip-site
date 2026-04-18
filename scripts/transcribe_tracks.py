#!/usr/bin/env python3
"""
Per-track transcription script for multi-speaker podcast recordings.

Each speaker is recorded on a separate MP3 track, all starting simultaneously
with identical duration. This script transcribes each track independently
(no diarization needed — each file = one speaker), aligns word timestamps,
then interleaves all tracks into a single chronological transcript.

Usage:
    python3 transcribe_tracks.py <audio_dir> <output.md>

Audio files are discovered by matching the pattern: {number}-{name}.mp3
e.g. 003-alex.mp3, 003-adam.mp3, 003-geoff.mp3

Files in the directory that don't match the pattern are skipped with a warning.

Environment variables:
    WHISPER_MODEL   - model size (default: large-v3-turbo)
    WHISPER_LANG    - language code (default: en)
"""

import sys
import os
import re
import warnings
import torch

# Suppress noisy warnings from pyannote/lightning
warnings.filterwarnings("ignore")
os.environ["TOKENIZERS_PARALLELISM"] = "false"

# --------------------------------------------------
# Arguments
# --------------------------------------------------

if len(sys.argv) < 3:
    print(f"Usage: {sys.argv[0]} <audio_dir> <output.md>")
    sys.exit(1)

audio_dir  = sys.argv[1]
out_path   = sys.argv[2]
model_size = os.environ.get("WHISPER_MODEL", "large-v3-turbo")
language   = os.environ.get("WHISPER_LANG", "en")
if language == "auto":
    language = None

# --------------------------------------------------
# Discover track files
# --------------------------------------------------

TRACK_PATTERN = re.compile(r"^\d+-(\w+)\.mp3$", re.IGNORECASE)

tracks = []  # list of (speaker_name, filepath)

try:
    entries = sorted(os.listdir(audio_dir))
except FileNotFoundError:
    print(f"ERROR: directory not found: {audio_dir}")
    sys.exit(1)

for entry in entries:
    m = TRACK_PATTERN.match(entry)
    if m:
        speaker = m.group(1).capitalize()
        tracks.append((speaker, os.path.join(audio_dir, entry)))
    else:
        # Warn about non-matching files (skip directories silently)
        full = os.path.join(audio_dir, entry)
        if os.path.isfile(full):
            print(f"WARNING: skipping unrecognised file: {entry}")

if not tracks:
    print(f"ERROR: no matching track files found in {audio_dir}")
    print(f"  Expected pattern: {{number}}-{{name}}.mp3 (e.g. 003-alex.mp3)")
    sys.exit(1)

print(f"Found {len(tracks)} track(s):")
for speaker, path in tracks:
    print(f"  {speaker}: {os.path.basename(path)}")

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

print(f"\nDevice: {device} ({compute_type})")

# --------------------------------------------------
# Load WhisperX model once, reuse for all tracks
# --------------------------------------------------

import whisperx

print(f"Loading model: {model_size}")
model = whisperx.load_model(
    model_size,
    device,
    compute_type=compute_type,
    language=language,
)

# --------------------------------------------------
# Transcribe each track
# --------------------------------------------------

# all_words: list of (start, end, speaker, text)
all_words = []

for speaker, filepath in tracks:
    print(f"\nTranscribing: {speaker} ({os.path.basename(filepath)})")

    audio = whisperx.load_audio(filepath)

    result = model.transcribe(
        audio,
        batch_size=16,
        language=language,
    )

    detected_lang = result.get("language", language or "unknown")
    print(f"  Language: {detected_lang}, Segments: {len(result['segments'])}")

    # Align for word-level timestamps
    print(f"  Aligning word timestamps...")
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
        print(f"  WARNING: alignment failed ({e}), using segment-level timestamps")

    # Extract words with timestamps
    word_count = 0
    for seg in result["segments"]:
        words = seg.get("words", [])
        if words:
            for w in words:
                if "start" not in w:
                    continue
                text = w.get("word", "").strip()
                if text:
                    all_words.append((
                        w["start"],
                        w.get("end", w["start"]),
                        speaker,
                        text,
                    ))
                    word_count += 1
        else:
            # No word-level data — use segment as a single entry
            text = seg.get("text", "").strip()
            if text:
                all_words.append((
                    seg.get("start", 0),
                    seg.get("end", 0),
                    speaker,
                    text,
                ))
                word_count += 1

    print(f"  Words extracted: {word_count}")

# Free model memory
del model
if device == "cuda":
    torch.cuda.empty_cache()

# --------------------------------------------------
# Sort all words chronologically
# --------------------------------------------------

all_words.sort(key=lambda x: x[0])

print(f"\nTotal words across all tracks: {len(all_words)}")

# --------------------------------------------------
# Group words into speaker lines
# Consecutive words from the same speaker are grouped together.
# When the speaker changes (or a gap > SPLIT_GAP occurs), a new line starts.
# --------------------------------------------------

SPLIT_GAP       = 4.0  # start a new line if same speaker pauses this long (seconds)
                       # higher value keeps short interjections on one line
MERGE_GAP       = 8.0  # merge consecutive same-speaker lines if gap is less than this
MERGE_MIN_WORDS = 5    # only merge if existing line has at least this many words

lines = []  # (start, end, speaker, text)

if all_words:
    cur_start, cur_end, cur_spk, cur_text = all_words[0][0], all_words[0][1], all_words[0][2], all_words[0][3]
    cur_words = [cur_text]

    for start, end, spk, text in all_words[1:]:
        gap = start - cur_end

        if spk == cur_spk and gap < SPLIT_GAP:
            # Same speaker, small gap — continue current line
            cur_words.append(text)
            cur_end = end
        else:
            # Speaker changed or long pause — emit current line
            lines.append((cur_start, cur_end, cur_spk, " ".join(cur_words)))
            cur_start, cur_end, cur_spk, cur_words = start, end, spk, [text]

    # Emit final line
    lines.append((cur_start, cur_end, cur_spk, " ".join(cur_words)))

# --------------------------------------------------
# Fold short lines into previous same-speaker line, then merge
# --------------------------------------------------

# Merge consecutive same-speaker lines (with min-words guard on the
# existing line to prevent short utterances absorbing the next line)
merged = []
for start, end, spk, text in lines:
    if merged and merged[-1][2] == spk:
        prev_start, prev_end, prev_spk, prev_text = merged[-1]
        gap = start - prev_end
        if gap < MERGE_GAP and len(prev_text.split()) >= MERGE_MIN_WORDS:
            merged[-1] = (prev_start, end, prev_spk, prev_text + " " + text)
            continue
    merged.append((start, end, spk, text))

# --------------------------------------------------
# Write markdown transcript
# --------------------------------------------------

print(f"Writing transcript: {out_path}")

with open(out_path, "w") as f:
    for start, end, spk, text in merged:
        f.write(f"**{spk}**: {text}\n")
        f.write(f"*{fmt_ts(start)}*\n\n")

print(f"Done — {len(merged)} lines written.")