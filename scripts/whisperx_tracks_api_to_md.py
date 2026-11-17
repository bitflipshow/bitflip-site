#!/usr/bin/env python3
"""Interleave per-speaker WhisperX responses into BitFlip transcript Markdown."""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    from .transcript_common import (
        fmt_ts,
        is_filler_phrase,
        segment_bounds,
        segment_is_suppressible_filler,
        validate_segments,
        valid_word_bounds,
    )
except ImportError:  # direct execution as `python scripts/whisperx_tracks_api_to_md.py`
    from transcript_common import (
        fmt_ts,
        is_filler_phrase,
        segment_bounds,
        segment_is_suppressible_filler,
        validate_segments,
        valid_word_bounds,
    )

SPLIT_GAP = 4.0
MERGE_GAP = 8.0
MERGE_MIN_WORDS = 5


def convert_directory(json_dir: str) -> tuple[str, int, int, dict[str, int]]:
    directory = Path(json_dir)
    if not directory.is_dir():
        raise ValueError(f"JSON directory does not exist: {json_dir}")
    json_files = sorted(path for path in directory.iterdir() if path.is_file() and path.suffix == ".json")
    if not json_files:
        raise ValueError(f"no JSON files found in {json_dir}")

    all_words: list[tuple[float, float, str, str]] = []
    word_counts: dict[str, int] = {}
    dropped_fillers = 0
    kept_filler_candidates = 0

    for path in json_files:
        speaker = path.stem
        with path.open(encoding="utf-8") as source:
            data: Any = json.load(source)
        segments = validate_segments(data, str(path))
        word_count = 0

        for index, segment in enumerate(segments):
            seg_start, seg_end = segment_bounds(segment)
            text = segment.get("text", "").strip()
            if segment_is_suppressible_filler(segment):
                dropped_fillers += 1
                continue
            if text and is_filler_phrase(text):
                kept_filler_candidates += 1

            words = segment.get("words", [])
            if words:
                for word in words:
                    if not isinstance(word, dict):
                        raise ValueError(f"{path}: segment {index} contains a non-object word")
                    word_text = word.get("word", "")
                    if not isinstance(word_text, str):
                        raise ValueError(f"{path}: segment {index} contains invalid word text")
                    word_text = word_text.strip()
                    if not word_text:
                        continue
                    start, end = valid_word_bounds(word, seg_start)
                    all_words.append((start, end, speaker, word_text))
                    word_count += 1
            elif text:
                all_words.append((seg_start, seg_end, speaker, text))
                word_count += len(text.split())

        word_counts[speaker] = word_count
        print(f"  {speaker}: {word_count} words")

    if not all_words:
        raise ValueError("no usable words extracted from any track")

    all_words.sort(key=lambda item: item[0])
    lines: list[tuple[float, float, str, str]] = []
    current_start, current_end, current_speaker, current_text = all_words[0]
    current_words = [current_text]

    for start, end, speaker, text in all_words[1:]:
        gap = start - current_end
        if speaker == current_speaker and gap < SPLIT_GAP:
            current_words.append(text)
            current_end = max(current_end, end)
        else:
            lines.append((current_start, current_end, current_speaker, " ".join(current_words)))
            current_start, current_end, current_speaker = start, end, speaker
            current_words = [text]
    lines.append((current_start, current_end, current_speaker, " ".join(current_words)))

    merged: list[tuple[float, float, str, str]] = []
    for start, end, speaker, text in lines:
        if merged and merged[-1][2] == speaker:
            prev_start, prev_end, prev_speaker, prev_text = merged[-1]
            if start - prev_end < MERGE_GAP and len(prev_text.split()) >= MERGE_MIN_WORDS:
                merged[-1] = (prev_start, max(prev_end, end), prev_speaker, f"{prev_text} {text}")
                continue
        merged.append((start, end, speaker, text))

    if not merged:
        raise ValueError("no transcript lines remain after grouping")
    output = "".join(
        f"**{speaker}**: {text}\n*{fmt_ts(start)}*\n\n"
        for start, _, speaker, text in merged
    )
    return output, dropped_fillers, kept_filler_candidates, word_counts


def write_atomic(path: str, content: str) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(content)
        os.replace(temp_name, destination)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <json_dir> <output.md>", file=sys.stderr)
        return 2
    json_dir, output_path = sys.argv[1:]
    try:
        content, dropped, kept, counts = convert_directory(json_dir)
        write_atomic(output_path, content)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    line_count = sum(1 for line in content.splitlines() if line.startswith("**"))
    print(f"Total words across tracks: {sum(counts.values())}")
    print(f"Transcript written: {output_path} ({line_count} lines)")
    if dropped:
        print(f"Suppressed {dropped} standalone filler phrase(s) with strong non-speech evidence")
    if kept:
        print(f"Kept {kept} standalone filler candidate(s): not enough evidence to suppress")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
