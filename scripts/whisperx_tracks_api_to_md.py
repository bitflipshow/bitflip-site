#!/usr/bin/env python3
"""
Convert per-track WhisperX API verbose_json responses to the BitFlip transcript
markdown format.

Each track was transcribed independently (diarize=false) — the speaker name
is derived from the JSON filename, which is set by the calling script to the
capitalised speaker name (e.g. Geoff.json, Alex.json).

Usage:
    python3 whisperx_tracks_api_to_md.py <json_dir> <output.md>

Input:  directory of verbose_json files named <Speaker>.json
Output: interleaved chronological markdown in the format used by transcribe_tracks.py:
    **Geoff**: text
    *00:01:23*

"""

import json
import os
import sys


def fmt_ts(s):
    h   = int(s // 3600)
    m   = int((s % 3600) // 60)
    sec = int(s % 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <json_dir> <output.md>")
        sys.exit(1)

    json_dir = sys.argv[1]
    out_path = sys.argv[2]

    SPLIT_GAP       = 4.0
    MERGE_GAP       = 8.0
    MERGE_MIN_WORDS = 5

    # --------------------------------------------------
    # Load each per-speaker JSON, extract words with timestamps
    # --------------------------------------------------

    all_words = []  # (start, end, speaker, word_text)

    json_files = sorted(
        f for f in os.listdir(json_dir) if f.endswith(".json")
    )

    if not json_files:
        print(f"ERROR: no JSON files found in {json_dir}", file=sys.stderr)
        sys.exit(1)

    for fname in json_files:
        speaker = os.path.splitext(fname)[0]  # filename is already capitalised speaker name
        fpath   = os.path.join(json_dir, fname)

        with open(fpath) as f:
            data = json.load(f)

        segments  = data.get("segments", [])
        word_count = 0

        for seg in segments:
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

        print(f"  {speaker}: {word_count} words")

    if not all_words:
        print("WARNING: no words extracted from any track", file=sys.stderr)
        open(out_path, "w").close()
        sys.exit(0)

    # --------------------------------------------------
    # Sort all words chronologically across all tracks
    # --------------------------------------------------

    all_words.sort(key=lambda x: x[0])
    print(f"Total words across all tracks: {len(all_words)}")

    # --------------------------------------------------
    # Group words into speaker lines — mirrors transcribe_tracks.py exactly
    # --------------------------------------------------

    lines = []  # (start, end, speaker, text)

    cur_start, cur_end, cur_spk, cur_text = (
        all_words[0][0], all_words[0][1], all_words[0][2], all_words[0][3]
    )
    cur_words = [cur_text]

    for start, end, spk, text in all_words[1:]:
        gap = start - cur_end

        if spk == cur_spk and gap < SPLIT_GAP:
            cur_words.append(text)
            cur_end = end
        else:
            lines.append((cur_start, cur_end, cur_spk, " ".join(cur_words)))
            cur_start, cur_end, cur_spk, cur_words = start, end, spk, [text]

    lines.append((cur_start, cur_end, cur_spk, " ".join(cur_words)))

    # --------------------------------------------------
    # Merge consecutive same-speaker lines
    # --------------------------------------------------

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

    merged = [(s, e, spk, t) for s, e, spk, t in merged if not is_filler(t)]

    # --------------------------------------------------
    # Write markdown
    # --------------------------------------------------

    with open(out_path, "w") as f:
        for start, end, spk, text in merged:
            f.write(f"**{spk}**: {text}\n")
            f.write(f"*{fmt_ts(start)}*\n\n")

    print(f"Transcript written: {out_path} ({len(merged)} lines)")


if __name__ == "__main__":
    main()
