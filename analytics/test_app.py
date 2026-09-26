import os
import tempfile
import json
import io
import threading
import time
from datetime import datetime, timezone
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
        self.db.execute("DELETE FROM youtube_public")
        self.db.execute("DELETE FROM sessions")
        self.db.execute("DELETE FROM downloads")
        self.db.execute("DELETE FROM episodes")
        self.db.execute("DELETE FROM settings")
        self.db.execute("DELETE FROM sync_state")
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
        self.assertEqual(app.ingest(self.db, self.event(ua="BitFlipAnalyticsManifest/1.0"), self.now), "filtered")
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
        self.assertEqual(app.ingest(self.db, bad, self.now), "size_mismatch")
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

    def r2_client(self, objects):
        class Client:
            def __init__(self):
                self.objects, self.deleted, self.copied = dict(objects), [], []
            def get_paginator(self, _name):
                return self
            def paginate(self, **_kwargs):
                return [{"Contents": [{"Key": key} for key in sorted(self.objects)]}]
            def get_object(self, Key, **_kwargs):
                return {"Body": io.BytesIO(self.objects[Key])}
            def copy_object(self, Key, CopySource, **_kwargs):
                self.copied.append((CopySource["Key"], Key))
            def delete_object(self, Key, **_kwargs):
                self.deleted.append(Key)
                del self.objects[Key]
        return Client()

    def test_malformed_r2_event_is_set_aside_without_blocking_later_events(self):
        good = json.dumps({**self.event(), "timestamp": self.now}).encode()
        client = self.r2_client({"events/a.json": b"{not json", "events/b.json": b"[]",
                                 "events/c.json": b'{"method":"GET"}', "events/d.json": good})
        self.assertEqual(app.pull_r2(self.db, client), 1)
        self.assertEqual(client.copied, [("events/a.json", "rejected/a.json"), ("events/b.json", "rejected/b.json"),
                                         ("events/c.json", "rejected/c.json")])
        self.assertEqual(client.objects, {})
        self.assertEqual(self.db.execute("SELECT count(*) FROM downloads").fetchone()[0], 1)

    def test_size_mismatch_waits_in_r2_until_manifest_matches(self):
        event = {**self.event(), "size": 2100000, "end": 2099999, "timestamp": self.now}
        client = self.r2_client({"events/a.json": json.dumps(event).encode()})
        self.assertEqual(app.pull_r2(self.db, client), 0)
        self.assertIn("events/a.json", client.objects)
        self.assertIsNone(self.db.execute("SELECT 1 FROM processed_events").fetchone())
        self.db.execute("UPDATE episodes SET size=2100000")
        self.db.commit()
        self.assertEqual(app.pull_r2(self.db, client), 1)
        self.assertEqual(client.objects, {})

    def test_failed_audio_probe_keeps_last_measured_values(self):
        manifest = [{"number": 15, "title": "Episode 15", "published": "2023-11-14T22:13:20Z",
                     "audioUrl": "https://audio.example/episode.mp3", "audioSize": 52,
                     "duration": "2:00", "youtubeUrl": "https://youtu.be/video15"}]
        with patch.object(app.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(manifest).encode())), \
             patch.object(app, "live_size", side_effect=app.urllib.error.URLError("down")):
            app.sync_manifest(self.db, "https://bitflip.show/analytics-manifest.json")
        row = self.db.execute("SELECT size,header_bytes,minute_bytes FROM episodes").fetchone()
        self.assertEqual(tuple(row), (2000000, 10000, 995000))
        self.assertEqual(app.ingest(self.db, self.event(), self.now), "counted")

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

    def test_date_only_release_windows_start_at_first_download(self):
        self.db.execute("UPDATE episodes SET published='2023-11-15'")
        self.db.commit()
        release_day = 1_700_024_400  # 2023-11-15 00:00 America/New_York
        self.assertEqual(app.release_floor("2023-11-15"), release_day)
        first = release_day + 10 * 3600
        for index, timestamp in enumerate((self.now, first, first + 20 * 3600, first + 30 * 3600)):
            app.process_event(self.db, f"events/{index}",
                              {**self.event(ip=f"198.51.100.{index + 1}"), "timestamp": timestamp})
        episode = app.summary(self.db, first + 3 * app.DAY)["episodes"][0]
        self.assertEqual(episode["window_start"], first)
        self.assertEqual([episode[x] for x in ("24h", "7d", "30d", "lifetime")], [2, 3, 3, 4])
        self.assertEqual(episode["window_status"], {"24h": "complete", "7d": "collecting", "30d": "collecting"})

    def test_release_without_downloads_is_collecting(self):
        self.db.execute("UPDATE episodes SET published='2023-11-15'")
        self.db.commit()
        app.process_event(self.db, "events/other", {**self.event(), "filename": "other.mp3", "timestamp": self.now})
        app.process_event(self.db, "events/probe", {**self.event(0, 1, 206), "timestamp": self.now})
        episode = app.summary(self.db, self.now + 2 * app.DAY)["episodes"][0]
        self.assertIsNone(episode["window_start"])
        self.assertEqual(episode["24h"], 0)
        self.assertEqual(set(episode["window_status"].values()), {"collecting"})

    def test_late_collection_does_not_claim_missing_history_is_zero(self):
        app.process_event(self.db, "events/late", {**self.event(), "timestamp": self.now + 2 * app.DAY})
        data = app.summary(self.db, self.now + 3 * app.DAY)
        self.assertEqual(data["episodes"][0]["window_status"],
                         {"24h": "unavailable", "7d": "partial history", "30d": "partial history"})
        self.assertIn("partial history", app.dashboard(data))

    def test_public_snapshot_is_separate_and_newest_wins(self):
        app.save_youtube_public(self.db, "video15", 100, self.now)
        app.save_youtube_public(self.db, "video15", 120, self.now + 10)
        app.save_youtube_public(self.db, "video15", 90, self.now - 10)
        episode = app.summary(self.db)["episodes"][0]
        self.assertEqual(episode["youtube_public_views"], 120)
        self.assertEqual(episode["lifetime"], 0)
        self.assertNotIn("youtube_views", episode)
        with self.assertRaises(ValueError):
            app.save_youtube_public(self.db, "unknown", 100, self.now)
        with self.assertRaises(ValueError):
            app.save_youtube_public(self.db, "video15", -1, self.now)
        self.db.execute("UPDATE episodes SET youtube_id='replacement' WHERE number=15")
        self.assertIsNone(app.summary(self.db)["episodes"][0]["youtube_public_views"])

    def test_public_refresh_retains_data_on_failure(self):
        app.save_youtube_public(self.db, "video15", 100, self.now)
        with patch("app.subprocess.run", side_effect=app.subprocess.TimeoutExpired("yt-dlp", 60)):
            with self.assertRaises(ValueError):
                app.sync_youtube_public(self.db)
        self.assertEqual(app.summary(self.db)["episodes"][0]["youtube_public_views"], 100)
        result = type("Result", (), {"stdout": json.dumps({"id": "video15", "view_count": 130})})()
        with patch("app.subprocess.run", return_value=result) as run:
            self.assertEqual(app.sync_youtube_public(self.db), 1)
            self.assertEqual(app.sync_youtube_public(self.db), 0)
            self.assertEqual(run.call_count, 1)
        self.assertEqual(app.summary(self.db)["episodes"][0]["youtube_public_views"], 130)

    def populate_archive(self):
        for number in range(60):
            if number == 15:
                continue
            published = datetime.fromtimestamp(self.now + number * app.DAY, timezone.utc).isoformat()
            self.db.execute("INSERT INTO episodes VALUES(?,?,?,?,?,?,?,?,?,?)",
                            (number, f"Episode {number}", published, f"episode-{number}.mp3",
                             f"https://audio.example/{number}.mp3", 2000000, 120, 10000, 995000, None))
        self.db.commit()

    def test_archive_queries_preserve_old_totals_and_bound_work(self):
        self.populate_archive()
        app.process_event(self.db, "events/old", {**self.event(), "timestamp": self.now})
        statements = []
        self.db.set_trace_callback(statements.append)
        recent = app.summary(self.db, self.now + 100 * app.DAY, limit=10)
        self.db.set_trace_callback(None)
        self.assertEqual([e["number"] for e in recent["episodes"]], list(range(59, 49, -1)))
        self.assertEqual(recent["total"], 60)
        self.assertLessEqual(len(statements), 6)
        pages = [app.summary(self.db, limit=25, offset=offset)["episodes"] for offset in (0, 25, 50)]
        self.assertEqual([len(page) for page in pages], [25, 25, 10])
        self.assertEqual(len({e["number"] for page in pages for e in page}), 60)
        old = app.summary(self.db, number=15, limit=1)["episodes"][0]
        self.assertEqual(old["lifetime"], 1)
        self.assertEqual(app.summary(self.db, query="#15", limit=25)["total"], 1)
        for query in ("#05", "05"):
            self.assertEqual([e["number"] for e in app.summary(self.db, query=query, limit=25)["episodes"]], [5])

    def test_http_recent_archive_detail_and_invalid_navigation(self):
        self.populate_archive()
        server = app.ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            def fetch(path):
                with app.urllib.request.urlopen(base + path) as response:
                    return response.read().decode()
            self.assertEqual(len(json.loads(fetch("/api/summary"))["episodes"]), 10)
            self.assertEqual(len(json.loads(fetch("/api/episodes?page=3"))["episodes"]), 10)
            home = fetch("/")
            self.assertEqual(home.count('data-episode="'), 10)
            self.assertNotIn('data-episode="0"', home)
            self.assertIn('Download milestones', fetch("/episodes/0"))
            self.assertIn('data-episode="0"', fetch("/episodes?q=%230"))
            self.assertIn('No episodes found', fetch("/episodes?q=%3Cscript%3E"))
            self.assertIn('value="&lt;script&gt;"', fetch("/episodes?q=%3Cscript%3E"))
            self.assertEqual(home.count('data-episode="'), fetch("/?page=x").count('data-episode="'))
            self.assertEqual(len(json.loads(fetch("/api/summary?page=x"))["episodes"]), 10)
            with app.urllib.request.urlopen(base + "/podcast-logo.png?v=2") as response:
                self.assertEqual(response.headers["Content-Type"], "image/png")
            for path, code in (("/episodes?page=-1", 400), ("/episodes?page=no", 400),
                               ("/episodes?page=100", 404), ("/episodes/999", 404)):
                with self.assertRaises(app.urllib.error.HTTPError) as failure:
                    fetch(path)
                self.assertEqual(failure.exception.code, code)
                failure.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_privacy_cleanup_removes_old_identifiers(self):
        self.assertEqual(app.ingest(self.db, self.event(), self.now), "counted")
        app.cleanup(self.db, self.now + 2 * app.DAY + 1)
        row = self.db.execute("SELECT fingerprint,ip_hash FROM downloads").fetchone()
        self.assertEqual(tuple(row), (None, None))
        self.assertEqual(self.db.execute("SELECT count(*) FROM sessions").fetchone()[0], 0)

    def test_cleanup_skips_cleared_rows_and_prunes_live_markers(self):
        app.process_event(self.db, "events/one", {**self.event(), "timestamp": self.now})
        app.process_event(self.db, "history/old", {**self.event(ip="198.51.100.2"), "timestamp": self.now - 5})
        self.db.execute("UPDATE processed_events SET processed_at=?", (self.now,))
        self.db.commit()
        app.cleanup(self.db, self.now + 3 * app.DAY)
        before = self.db.total_changes
        app.cleanup(self.db, self.now + 3 * app.DAY + 300)
        self.assertEqual(self.db.total_changes - before, 1)  # only the coverage_start upsert
        app.cleanup(self.db, self.now + 31 * app.DAY)
        keys = [row[0] for row in self.db.execute("SELECT key FROM processed_events")]
        self.assertEqual(keys, ["history/old"])
        self.db.execute("DELETE FROM processed_events")
        self.db.commit()
        self.assertEqual(app.summary(self.db, self.now + 31 * app.DAY)["coverage_start"], self.now - 5)

    def test_backfill_pauses_cleanup(self):
        path = Path(tempfile.mktemp(suffix=".jsonl"))
        events = [{**self.event(0, 600000, 206), "timestamp": self.now},
                  {**self.event(600001, 1010000, 206), "timestamp": self.now + 60}]
        path.write_text("".join(json.dumps(e) + "\n" for e in events))
        original = app._ingest
        def ingest_then_cleanup(db, event, now=None):
            result = original(db, event, now)
            app.cleanup(self.db)  # the live service cleaning up mid-import
            return result
        try:
            with patch.object(app, "_ingest", side_effect=ingest_then_cleanup):
                self.assertEqual(app.import_events(self.db, path), 2)
        finally:
            path.unlink()
        self.assertEqual(self.db.execute("SELECT count(*) FROM downloads").fetchone()[0], 1)
        self.assertIsNone(self.db.execute("SELECT 1 FROM sync_state WHERE source='backfill'").fetchone())

    def test_alert_once_when_polling_fails_and_once_on_recovery(self):
        sent = []
        with patch.dict(os.environ, {"ALERT_WEBHOOK_URL": "https://hooks.example/test"}):
            app.mark_sync(self.db, "r2")
            self.assertFalse(app.check_alert(self.db, False, time.time(), sent.append))
            app.mark_sync(self.db, "r2", "R2 unavailable")
            self.assertFalse(app.check_alert(self.db, False, time.time() + 60, sent.append))
            self.assertTrue(app.check_alert(self.db, False, time.time() + app.ALERT_AFTER + 60, sent.append))
            self.assertTrue(app.check_alert(self.db, True, time.time() + app.ALERT_AFTER + 360, sent.append))
            def broken(_message):
                raise OSError("webhook down")
            app.mark_sync(self.db, "r2")
            self.assertTrue(app.check_alert(self.db, True, time.time(), broken))
            self.assertFalse(app.check_alert(self.db, True, time.time(), sent.append))
        self.assertEqual(len(sent), 2)
        self.assertIn("R2 unavailable", sent[0])
        self.assertIn("recovered", sent[1])
        self.assertFalse(app.check_alert(self.db, False, time.time() + app.ALERT_AFTER * 10, sent.append))

    def add_second_video(self):
        self.db.execute("""INSERT INTO episodes VALUES(16,'Episode 16','2023-11-20','episode-16.mp3',
            'https://audio.example/16.mp3',2000000,120,10000,995000,'video16')""")
        self.db.commit()

    def test_one_broken_video_does_not_fail_public_refresh(self):
        self.add_second_video()
        def run(args, **_kwargs):
            video = args[-1].rsplit("=", 1)[-1]
            views = None if video == "video16" else 130
            return type("Result", (), {"stdout": json.dumps({"id": video, "view_count": views})})()
        with patch("app.subprocess.run", side_effect=run):
            self.assertEqual(app.sync_youtube_public(self.db), 1)
        views = {e["number"]: e["youtube_public_views"] for e in app.summary(self.db)["episodes"]}
        self.assertEqual(views, {15: 130, 16: None})
        with patch("app.subprocess.run", side_effect=app.subprocess.TimeoutExpired("yt-dlp", 60)):
            with self.assertRaises(ValueError):
                app.sync_youtube_public(self.db)  # only video16 is due, and it fails

    def test_public_import_rejects_bad_timestamps_atomically(self):
        self.add_second_video()
        now = int(time.time())
        for bad in (now + 3600, now * 1000, 0, "1700000000", True, 1.5):
            with self.assertRaises(ValueError):
                app.save_youtube_public(self.db, "video15", 100, bad)
        with self.assertRaises(ValueError) as failure:
            app.import_youtube_public(self.db, [{"video_id": "video15", "views": 100, "observed_at": now},
                                                {"video_id": "video16", "views": 5, "observed_at": now * 1000}])
        self.assertIn("row 2", str(failure.exception))
        self.assertIsNone(self.db.execute("SELECT 1 FROM youtube_public").fetchone())
        self.assertEqual(app.import_youtube_public(self.db, [{"video_id": "video15", "views": 100, "observed_at": now},
                                                             {"video_id": "video16", "views": 5, "observed_at": now}]), 2)
        self.assertEqual(self.db.execute("SELECT count(*) FROM youtube_public").fetchone()[0], 2)


if __name__ == "__main__":
    unittest.main()
