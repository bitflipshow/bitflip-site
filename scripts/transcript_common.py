#!/usr/bin/env python3
"""Shared validation, formatting, and conservative hallucination filtering."""

from __future__ import annotations

import math
import re
from typing import Any

FILLER_PHRASES = {
    "thank you", "thanks", "thank you so much", "thanks so much",
    "thank you very much", "thanks very much", "bye", "goodbye",
    "bye bye", "see you", "see ya", "you're welcome", "youre welcome",
}

# Suppress a standalone stock phrase only when the ASR itself strongly indicates
# non-speech. These deliberately conservative defaults should be calibrated on
# real BitFlip responses; missing metadata always means keep the phrase.
NO_SPEECH_THRESHOLD = 0.90
LOW_LOGPROB_THRESHOLD = -1.0


def fmt_ts(seconds: float) -> str:
    if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0:
        raise ValueError(f"invalid timestamp: {seconds!r}")
    total = int(seconds)
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes:02d}:{secs:02d}"


def normalize_phrase(text: str) -> str:
    text = text.lower().replace("’", "'").strip()
    text = re.sub(r"^[\W_]+|[\W_]+$", "", text)
    text = re.sub(r"[.!?,;:]+", "", text)
    return " ".join(text.split())


def is_filler_phrase(text: str) -> bool:
    return normalize_phrase(text) in FILLER_PHRASES


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def likely_silence_hallucination(segment: dict[str, Any]) -> bool:
    """Require both high no-speech probability and poor log probability."""
    no_speech = _number(segment.get("no_speech_prob"))
    avg_logprob = _number(segment.get("avg_logprob"))
    return (
        no_speech is not None
        and avg_logprob is not None
        and no_speech >= NO_SPEECH_THRESHOLD
        and avg_logprob <= LOW_LOGPROB_THRESHOLD
    )


def validate_segments(data: Any, source: str) -> list[dict[str, Any]]:
    if not isinstance(data, dict):
        raise ValueError(f"{source}: response must be a JSON object")
    segments = data.get("segments")
    if not isinstance(segments, list) or not segments:
        raise ValueError(f"{source}: response has no transcript segments")
    valid = []
    for index, segment in enumerate(segments):
        if not isinstance(segment, dict):
            raise ValueError(f"{source}: segment {index} is not an object")
        text = segment.get("text", "")
        words = segment.get("words", [])
        if not isinstance(text, str) or not isinstance(words, list):
            raise ValueError(f"{source}: segment {index} has invalid text/words")
        if text.strip() or words:
            valid.append(segment)
    if not valid:
        raise ValueError(f"{source}: response contains no usable transcript text")
    return valid


def segment_bounds(segment: dict[str, Any]) -> tuple[float, float]:
    start = _number(segment.get("start"))
    end = _number(segment.get("end"))
    if start is None or start < 0:
        raise ValueError(f"invalid or missing segment start: {segment.get('start')!r}")
    if end is None:
        end = start
    if end < start:
        raise ValueError(f"segment end precedes start: {start} > {end}")
    return start, end


def valid_word_bounds(word: dict[str, Any], fallback: float) -> tuple[float, float]:
    start = _number(word.get("start"))
    end = _number(word.get("end"))
    if start is None or start < 0:
        start = fallback
    if end is None or end < start:
        end = start
    return start, end


def speaker_name(raw: Any, fallback: str = "Speaker") -> str:
    if not isinstance(raw, str) or not raw.strip():
        return fallback
    raw = raw.strip()
    if raw.startswith("SPEAKER_"):
        return "Speaker_" + raw[len("SPEAKER_"):]
    return raw


def segment_is_suppressible_filler(segment: dict[str, Any]) -> bool:
    """Only drop a whole standalone phrase with strong non-speech evidence."""
    text = segment.get("text", "")
    if not isinstance(text, str) or not is_filler_phrase(text):
        return False
    return likely_silence_hallucination(segment)
