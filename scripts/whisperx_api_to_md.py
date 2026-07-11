#!/usr/bin/env python3
"""
Convert a WhisperX API verbose_json response (single-file, diarized) to the
BitFlip transcript markdown format.

Usage:
    python3 whisperx_api_to_md.py <response.json> <output.md>

Input: verbose_json from POST /v1/audio/transcriptions with diarize=true, align=true
Output: markdown in the format used by transcribe.py:
    **Speaker_0**: text
    *00:01:23*

"""

import json
import sys


def fmt_ts(s):
    h   = int(s // 3600)
    m   = int((s % 3600) // 60)
    sec = int(s % 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


def get_speaker(seg, word=None):
    """Get speaker label from word or segment, normalised to Speaker_N style."""
    raw = None
    if word:
        raw = word.get("speaker")
    if not raw:
        raw = seg.get("speaker")
    if not raw:
        return "Speaker"
    return raw.replace("SPEAKER_", "Speaker_")


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <response.json> <output.md>")
        sys.exit(1)

    response_file = sys.argv[1]
    out_path      = sys.argv[2]

    with open(response_file) as f:
        data = json.load(f)

    segments = data.get("segments", [])
    if not segments:
        print("WARNING: no segments in response", file=sys.stderr)
        open(out_path, "w").close()
        sys.exit(0)

    # --------------------------------------------------
    # Build (start, speaker, text, end) lines from word-level data,
    # grouping consecutive words by speaker — mirrors transcribe.py exactly.
    # --------------------------------------------------

    MERGE_GAP       = 5.0
    MERGE_MIN_WORDS = 4

    lines = []  # (start, speaker, text, end)

    for seg in segments:
        words = seg.get("words", [])

        if not words:
            text = seg.get("text", "").strip()
            if text:
                spk   = get_speaker(seg)
                start = seg.get("start", 0)
                end   = seg.get("end", start)
                lines.append((start, spk, text, end))
            continue

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

    merged = []
    for start, spk, text, end in lines:
        if merged and merged[-1][1] == spk:
            prev_start, prev_spk, prev_text, prev_end = merged[-1]
            gap = start - prev_end
            if gap < MERGE_GAP and len(prev_text.split()) >= MERGE_MIN_WORDS:
                merged[-1] = (prev_start, prev_spk, prev_text + " " + text, end)
                continue
        merged.append((start, spk, text, end))

    # --------------------------------------------------
    # Filter ASR hallucinations (short filler phrases Whisper inserts in silence)
    # --------------------------------------------------

    FILLER_PHRASES = {
        "thank you", "thanks", "thank you so much", "thanks so much",
        "thank you very much", "thanks very much",
        "bye", "goodbye", "bye bye", "see you", "see ya",
        "you're welcome", "youre welcome",
    }

    def is_filler(text):
        normalised = text.lower().strip().rstrip(".,!?")
        return normalised in FILLER_PHRASES

    merged = [(s, spk, t, e) for s, spk, t, e in merged if not is_filler(t)]

    # --------------------------------------------------
    # Write markdown
    # --------------------------------------------------

    with open(out_path, "w") as f:
        for start, spk, text, _ in merged:
            f.write(f"**{spk}**: {text}\n")
            f.write(f"*{fmt_ts(start)}*\n\n")

    print(f"Transcript written: {out_path} ({len(merged)} lines)")


if __name__ == "__main__":
    main()
