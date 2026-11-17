"""Regression tests for WhisperX response-to-Markdown converters."""

import json
import tempfile
import unittest
from pathlib import Path

from scripts.whisperx_api_to_md import convert as convert_single
from scripts.whisperx_tracks_api_to_md import convert_directory


class SingleTrackConverterTests(unittest.TestCase):
    def test_drops_only_standalone_phrase_with_strong_non_speech_metadata(self):
        data = {
            "segments": [
                {
                    "start": 1.0,
                    "end": 1.5,
                    "text": "Thank you!",
                    "speaker": "SPEAKER_00",
                    "no_speech_prob": 0.98,
                    "avg_logprob": -1.4,
                },
                {
                    "start": 3.0,
                    "end": 3.8,
                    "text": "Thank you.",
                    "speaker": "SPEAKER_00",
                    "no_speech_prob": 0.05,
                    "avg_logprob": -0.2,
                },
            ]
        }
        output, dropped, kept = convert_single(data)
        self.assertEqual(dropped, 1)
        self.assertEqual(kept, 1)
        self.assertEqual(output, "**Speaker_00**: Thank you.\n*00:03*\n\n")

    def test_missing_confidence_preserves_candidate_phrase(self):
        output, dropped, kept = convert_single(
            {"segments": [{"start": 0, "end": 1, "text": "Thanks", "speaker": "Alex"}]}
        )
        self.assertEqual((dropped, kept), (0, 1))
        self.assertIn("Thanks", output)

    def test_aligned_response_without_no_speech_probability_keeps_phrase(self):
        output, dropped, kept = convert_single(
            {"segments": [{"start": 0, "end": 1, "text": "Thank you", "avg_logprob": -1.5}]}
        )
        self.assertEqual((dropped, kept), (0, 1))
        self.assertIn("Thank you", output)

    def test_converts_word_level_speaker_changes(self):
        data = {
            "segments": [
                {
                    "start": 1,
                    "end": 3,
                    "text": "Hello there",
                    "words": [
                        {"start": 1.1, "end": 1.5, "word": "Hello", "speaker": "SPEAKER_00"},
                        {"start": 1.6, "end": 2.0, "word": "there", "speaker": "SPEAKER_01"},
                    ],
                }
            ]
        }
        output, _, _ = convert_single(data)
        self.assertIn("**Speaker_00**: Hello", output)
        self.assertIn("**Speaker_01**: there", output)

    def test_empty_response_fails_instead_of_writing_empty_transcript(self):
        with self.assertRaises(ValueError):
            convert_single({"segments": []})


class PerTrackConverterTests(unittest.TestCase):
    def test_interleaves_tracks_and_keeps_real_thanks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "Geoff.json").write_text(
                json.dumps({"segments": [{"start": 1, "end": 2, "text": "Opening thought."}]}),
                encoding="utf-8",
            )
            (root / "Alex.json").write_text(
                json.dumps(
                    {
                        "segments": [
                            {
                                "start": 3,
                                "end": 4,
                                "text": "Thank you.",
                                "no_speech_prob": 0.1,
                                "avg_logprob": -0.2,
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            output, dropped, kept, counts = convert_directory(temp_dir)
        self.assertEqual(dropped, 0)
        self.assertEqual(kept, 1)
        self.assertEqual(counts, {"Alex": 2, "Geoff": 2})
        self.assertLess(output.index("Opening thought"), output.index("Thank you"))

    def test_suppresses_filler_in_track_with_strong_non_speech_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "Alex.json").write_text(
                json.dumps(
                    {
                        "segments": [
                            {
                                "start": 1,
                                "end": 2,
                                "text": "Thank you",
                                "no_speech_prob": 0.99,
                                "avg_logprob": -1.5,
                            },
                            {"start": 4, "end": 5, "text": "Real sentence."},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            output, dropped, kept, _ = convert_directory(temp_dir)
        self.assertEqual((dropped, kept), (1, 0))
        self.assertNotIn("Thank you", output)
        self.assertIn("Real sentence", output)

    def test_empty_track_response_fails(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            (Path(temp_dir) / "Alex.json").write_text("{\"segments\": []}", encoding="utf-8")
            with self.assertRaises(ValueError):
                convert_directory(temp_dir)


if __name__ == "__main__":
    unittest.main()
