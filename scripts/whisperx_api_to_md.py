#!/usr/bin/env python3
"""Convert a WhisperX verbose_json response to BitFlip transcript Markdown."""

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
        speaker_name,
        validate_segments,
        valid_word_bounds,
    )
except ImportError:  # direct execution as `python scripts/whisperx_api_to_md.py`
    from transcript_common import (
        fmt_ts,
        is_filler_phrase,
        segment_bounds,
        segment_is_suppressible_filler,
        speaker_name,
        validate_segments,
        valid_word_bounds,
    )

MERGE_GAP = 5.0
MERGE_MIN_WORDS = 4


def convert(data: Any, source: str = "response") -> tuple[str, int, int]:
    segments = validate_segments(data, source)
    lines: list[tuple[float, str, str, float]] = []
    dropped_fillers = 0
    kept_filler_candidates = 0

    for index, segment in enumerate(segments):
        seg_start, seg_end = segment_bounds(segment)
        text = segment.get("text", "").strip()
        if segment_is_suppressible_filler(segment):
            dropped_fillers += 1
            continue
        if text and is_filler_phrase(text):
            kept_filler_candidates += 1

        words = segment.get("words", [])
        if not words:
            if text:
                lines.append((seg_start, speaker_name(segment.get("speaker")), text, seg_end))
            continue

        current_speaker: str | None = None
        current_start = seg_start
        current_end = seg_start
        current_words: list[str] = []

        def flush() -> None:
            if current_words and current_speaker is not None:
                lines.append((current_start, current_speaker, " ".join(current_words), current_end))

        for word in words:
            if not isinstance(word, dict):
                raise ValueError(f"{source}: segment {index} contains a non-object word")
            word_text = word.get("word", "")
            if not isinstance(word_text, str):
                raise ValueError(f"{source}: segment {index} contains invalid word text")
            word_text = word_text.strip()
            word_start, word_end = valid_word_bounds(word, seg_start)
            word_speaker = speaker_name(word.get("speaker"), speaker_name(segment.get("speaker")))

            if current_speaker is None:
                current_speaker = word_speaker
                current_start = word_start
                current_end = word_start
            elif word_speaker != current_speaker:
                flush()
                current_speaker = word_speaker
                current_start = word_start
                current_end = word_start
                current_words = []

            if word_text:
                current_words.append(word_text)
            current_end = max(current_end, word_end)

        flush()

    lines.sort(key=lambda row: row[0])
    merged: list[tuple[float, str, str, float]] = []
    for start, speaker, text, end in lines:
        if merged and merged[-1][1] == speaker:
            prev_start, prev_speaker, prev_text, prev_end = merged[-1]
            if start - prev_end < MERGE_GAP and len(prev_text.split()) >= MERGE_MIN_WORDS:
                merged[-1] = (prev_start, prev_speaker, f"{prev_text} {text}", max(end, prev_end))
                continue
        merged.append((start, speaker, text, end))

    if not merged:
        raise ValueError(f"{source}: no transcript lines remain after parsing")

    output = "".join(
        f"**{speaker}**: {text}\n*{fmt_ts(start)}*\n\n"
        for start, speaker, text, _ in merged
    )
    return output, dropped_fillers, kept_filler_candidates


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
        print(f"Usage: {sys.argv[0]} <response.json> <output.md>", file=sys.stderr)
        return 2
    response_path, output_path = sys.argv[1:]
    try:
        with open(response_path, encoding="utf-8") as source:
            data = json.load(source)
        content, dropped, kept = convert(data, response_path)
        write_atomic(output_path, content)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    line_count = sum(1 for line in content.splitlines() if line.startswith("**"))
    print(f"Transcript written: {output_path} ({line_count} lines)")
    if dropped:
        print(f"Suppressed {dropped} standalone filler phrase(s) with strong non-speech evidence")
    if kept:
        print(f"Kept {kept} standalone filler candidate(s): not enough evidence to suppress")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
