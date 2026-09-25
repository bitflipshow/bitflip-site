import os
import tempfile
import json
import io
from pathlib import Path
import unittest
from unittest.mock import patch

os.environ["HASH_SECRET"] = "test-secret"
os.environ["DB_PATH"] = os.path.join(tempfile.mkdtemp(), "test.sqlite3")

import app


class AnalyticsTests(unittest.TestCase):
    def setUp(self):
        self.db = app.connect()
        self.db.execute("DELETE FROM processed_events")
        self.db.execute("DELETE FROM platform_daily")
        self.db.execute("DELETE FROM sessions")
        self.db.execute("DELETE FROM downloads")
        self.db.execute("DELETE FROM episodes")
        self.db.execute("""INSERT INTO episodes VALUES
            (15,'Episode 15','2023-11-14T22:13:20+00:00','episode.mp3','https://audio.example/episode.mp3',
             2000000,120,10000,995000,'video15')""")
        self.db.commit()
        self.now = 1_700_000_000

    def tearDown(self):
        self.db.close()

    def event(self, start=0, end=1999999, status=200, ua="PodcastApp/1.0", ip="198.51.100.1", method="GET"):
        return dict(method=method, status=status, filename="episode.mp3", size=2000000,
                    start=start, end=end, userAgent=ua, ip=ip)

    def test_full_get_counts_once_per_rolling_day(self):
        self.assertEqual(app.ingest(self.db, self.event(), self.now), "counted")
        self.assertEqual(app.ingest(self.db, self.event(), self.now + 10), "duplicate")
        self.assertEqual(app.ingest(self.db, self.event(), self.now + app.DAY + 1), "counted")
        self.assertEqual(app.summary(self.db, self.now + app.DAY + 2)["episodes"][0]["lifetime"], 2)

    def test_head_bot_and_probe_do_not_count(self):
        self.assertEqual(app.ingest(self.db, self.event(method="HEAD"), self.now), "ignored")
        self.assertEqual(app.ingest(self.db, self.event(ua="Googlebot/2.1"), self.now), "filtered")
        self.assertEqual(app.ingest(self.db, self.event(0, 1, 206), self.now), "invalid")
        self.assertEqual(app.summary(self.db, self.now)["episodes"][0]["lifetime"], 0)

    def test_partial_ranges_reassemble_without_duplicate_bytes(self):
        self.assertEqual(app.ingest(self.db, self.event(0, 600000, 206), self.now), "pending")
        self.assertEqual(app.ingest(self.db, self.event(0, 600000, 206), self.now + 1), "pending")
        self.assertEqual(app.ingest(self.db, self.event(600001, 1010000, 206), self.now + 2), "counted")
        self.assertEqual(app.ingest(self.db, self.event(1010001, 1999999, 206), self.now + 3), "duplicate")

    def test_full_response_stopped_early_needs_threshold(self):
        self.assertEqual(app.ingest(self.db, self.event(0, 600000, 200), self.now), "pending")
        self.assertEqual(app.ingest(self.db, self.event(600001, 1010000, 206), self.now + 1), "counted")

    def test_header_and_one_minute_content_required(self):
        self.assertEqual(app.ingest(self.db, self.event(10000, 1999999, 206), self.now), "pending")
        self.assertEqual(app.ingest(self.db, self.event(0, 9999, 206), self.now + 1), "counted")

    def test_invalid_size_unknown_episode_and_separate_listener(self):
        bad = self.event()
        bad["size"] = 1
        self.assertEqual(app.ingest(self.db, bad, self.now), "invalid")
        bad = self.event()
        bad["filename"] = "other.mp3"
        self.assertEqual(app.ingest(self.db, bad, self.now), "unknown_episode")
        self.assertEqual(app.ingest(self.db, self.event(), self.now), "counted")
        self.assertEqual(app.ingest(self.db, self.event(ip="198.51.100.2"), self.now), "counted")

    def test_complete_file_fallback_when_header_unknown(self):
        self.db.execute("UPDATE episodes SET header_bytes=NULL, minute_bytes=NULL")
        self.db.commit()
        self.assertEqual(app.ingest(self.db, self.event(0, 1000000, 206), self.now), "pending")
        self.assertEqual(app.ingest(self.db, self.event(1000001, 1999999, 206), self.now + 1), "counted")

    def test_historical_import_is_idempotent(self):
        path = Path(tempfile.mktemp(suffix=".jsonl"))
        event = self.event()
        event["timestamp"] = self.now
        path.write_text(json.dumps(event) + "\n")
        try:
            self.assertEqual(app.import_events(self.db, path), 1)
            self.assertEqual(app.import_events(self.db, path), 0)
            self.assertEqual(app.summary(self.db, self.now)["episodes"][0]["lifetime"], 1)
        finally:
            path.unlink()

    def test_r2_event_deleted_only_after_import(self):
        event = self.event()
        event["timestamp"] = self.now

        class Client:
            deleted = []
            def get_paginator(self, _name):
                return self
            def paginate(self, **_kwargs):
                return [{"Contents": [{"Key": "events/2023-11-14/one.json"}]}]
            def get_object(self, **_kwargs):
                return {"Body": io.BytesIO(json.dumps(event).encode())}
            def delete_object(self, **kwargs):
                self.deleted.append(kwargs["Key"])

        client = Client()
        self.assertEqual(app.pull_r2(self.db, client), 1)
        self.assertEqual(app.pull_r2(self.db, client), 0)
        self.assertEqual(self.db.execute("SELECT count(*) FROM downloads").fetchone()[0], 1)
        self.assertEqual(len(client.deleted), 2)

    def test_manifest_identifies_collector_and_preserves_publication_time(self):
        manifest = [{"number": 15, "title": "Episode 15", "published": "2023-11-14T22:13:20Z",
                     "audioUrl": "https://audio.example/episode.mp3", "audioSize": 2000000,
                     "duration": "2:00", "youtubeUrl": "https://youtu.be/video15"}]
        def fetch(request, **kwargs):
            self.assertEqual(request.get_header("User-agent"), "BitFlipAnalyticsManifest/1.0")
            return io.BytesIO(json.dumps(manifest).encode())
        with patch.object(app.urllib.request, "urlopen", side_effect=fetch), patch.object(app, "live_size", return_value=2000000), patch.object(app, "header_size", return_value=10000):
            self.assertEqual(app.sync_manifest(self.db, "https://bitflip.show/analytics-manifest.json"), 1)
        self.assertEqual(self.db.execute("SELECT published FROM episodes").fetchone()[0], "2023-11-14T22:13:20Z")

    def test_ipv6_rotation_and_mapped_ipv4_dedupe(self):
        self.assertEqual(app.ingest(self.db, self.event(ip="2001:db8:abcd:12::1"), self.now), "counted")
        self.assertEqual(app.ingest(self.db, self.event(ip="2001:0db8:abcd:0012::2"), self.now + 1), "duplicate")
        self.assertEqual(app.ingest(self.db, self.event(ip="2001:db8:abcd:13::1"), self.now + 1), "counted")
        self.assertEqual(app.ingest(self.db, self.event(ip="::ffff:198.51.100.9"), self.now), "counted")
        self.assertEqual(app.ingest(self.db, self.event(ip="198.51.100.9"), self.now + 1), "duplicate")
        for ip in ("invalid", "127.0.0.1", "::", "ff02::1", "fe80::1"):
            self.assertEqual(app.ingest(self.db, self.event(ip=ip), self.now), "filtered")

    def test_youtube_query_and_idempotent_episode_mapping(self):
        requests = []
        def fetch(request, **kwargs):
            requests.append(request)
            if request.full_url == "https://oauth2.googleapis.com/token":
                return io.BytesIO(b'{"access_token":"test-token"}')
            params = app.urllib.parse.parse_qs(app.urllib.parse.urlparse(request.full_url).query)
            self.assertEqual(params["filters"], ["video==video15"])
            self.assertEqual(params["startDate"], ["2023-11-14"])
            self.assertEqual(params["sort"], ["day,video"])
            return io.BytesIO(json.dumps({"rows": [["2023-11-15", "video15", 12, 40.5]]}).encode())
        with patch.dict(os.environ, {"YOUTUBE_CLIENT_ID": "test", "YOUTUBE_CLIENT_SECRET": "test", "YOUTUBE_REFRESH_TOKEN": "test"}), patch.object(app.urllib.request, "urlopen", side_effect=fetch):
            self.assertEqual(app.sync_youtube(self.db), 1)
            self.assertEqual(app.sync_youtube(self.db), 1)
        episode = app.summary(self.db, self.now + 2 * app.DAY)["episodes"][0]
        self.assertEqual(episode["youtube_views"], 12)
        self.assertEqual(episode["youtube_watch_minutes"], 40.5)
        self.assertEqual(episode["lifetime"], 0)

    def test_event_and_count_roll_back_together(self):
        self.db.execute("""CREATE TEMP TRIGGER fail_marker BEFORE INSERT ON processed_events
            BEGIN SELECT RAISE(ABORT, 'simulated failure'); END""")
        event = {**self.event(), "timestamp": self.now}
        with self.assertRaises(app.sqlite3.IntegrityError):
            app.process_event(self.db, "events/one", event)
        self.assertEqual(self.db.execute("SELECT count(*) FROM downloads").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT count(*) FROM sessions").fetchone()[0], 0)
        self.db.execute("DROP TRIGGER fail_marker")
        self.assertEqual(app.process_event(self.db, "events/one", event), "counted")
        app.cleanup(self.db, self.now + 3 * app.DAY)
        self.assertEqual(app.process_event(self.db, "events/one", event), "already_processed")
        self.assertEqual(self.db.execute("SELECT count(*) FROM downloads").fetchone()[0], 1)

    def test_windows_are_since_release_and_keep_completed_totals(self):
        for days in (0, 1, 7, 30):
            app.process_event(self.db, f"events/{days}",
                              {**self.event(ip=f"198.51.100.{days + 1}"), "timestamp": self.now + days * app.DAY})
        episode = app.summary(self.db, self.now + 60 * app.DAY)["episodes"][0]
        self.assertEqual([episode[x] for x in ("24h", "7d", "30d", "lifetime")], [1, 2, 3, 4])
        self.assertEqual(episode["window_status"]["30d"], "complete")

    def test_late_collection_does_not_claim_missing_history_is_zero(self):
        app.process_event(self.db, "events/late", {**self.event(), "timestamp": self.now + 2 * app.DAY})
        data = app.summary(self.db, self.now + 3 * app.DAY)
        self.assertEqual(data["episodes"][0]["window_status"],
                         {"24h": "unavailable", "7d": "partial history", "30d": "partial history"})
        self.assertIn("partial history", app.dashboard(data))

    def test_privacy_cleanup_removes_old_identifiers(self):
        self.assertEqual(app.ingest(self.db, self.event(), self.now), "counted")
        app.cleanup(self.db, self.now + 2 * app.DAY + 1)
        row = self.db.execute("SELECT fingerprint,ip_hash FROM downloads").fetchone()
        self.assertEqual(tuple(row), (None, None))
        self.assertEqual(self.db.execute("SELECT count(*) FROM sessions").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
