"""Private BitFlip download analytics service."""

import base64
from contextlib import closing
import csv
import hashlib
import hmac
import html
import json
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


DB_PATH = os.getenv("DB_PATH", "/data/analytics.sqlite3")
BOT = re.compile(r"bot|spider|crawler|preview|facebookexternalhit|google|bing|curl/|wget/|python-requests|headless|monitor|atc/.*watchos|\(null\)/\(null\).*watchos", re.I)
DAY = 86400
SERVICE_STARTED = time.time()


def connect():
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB_PATH, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS episodes (
            number INTEGER PRIMARY KEY, title TEXT NOT NULL, published TEXT NOT NULL,
            filename TEXT NOT NULL UNIQUE, audio_url TEXT NOT NULL, size INTEGER NOT NULL,
            duration_seconds INTEGER NOT NULL, header_bytes INTEGER, minute_bytes INTEGER,
            youtube_id TEXT
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY, episode INTEGER NOT NULL, fingerprint TEXT NOT NULL,
            ip_hash TEXT NOT NULL, opened INTEGER NOT NULL, ranges TEXT NOT NULL,
            UNIQUE(episode, fingerprint, opened)
        );
        CREATE INDEX IF NOT EXISTS sessions_lookup ON sessions(episode, fingerprint, opened);
        CREATE TABLE IF NOT EXISTS downloads (
            id INTEGER PRIMARY KEY, episode INTEGER NOT NULL, counted_at INTEGER NOT NULL,
            fingerprint TEXT, ip_hash TEXT
        );
        CREATE INDEX IF NOT EXISTS downloads_time ON downloads(counted_at);
        CREATE INDEX IF NOT EXISTS downloads_dedupe ON downloads(episode, fingerprint, counted_at);
        CREATE TABLE IF NOT EXISTS platform_daily (
            platform TEXT NOT NULL, metric TEXT NOT NULL, day TEXT NOT NULL,
            episode INTEGER NOT NULL, value REAL NOT NULL,
            PRIMARY KEY(platform, metric, day, episode)
        );
        CREATE TABLE IF NOT EXISTS processed_events (
            key TEXT PRIMARY KEY, processed_at INTEGER NOT NULL,
            event_timestamp INTEGER
        );
        CREATE TABLE IF NOT EXISTS sync_state (
            source TEXT PRIMARY KEY, succeeded_at INTEGER, error TEXT
        );
    """)
    columns = {row[1] for row in db.execute("PRAGMA table_info(processed_events)")}
    if "event_timestamp" not in columns:
        db.execute("ALTER TABLE processed_events ADD COLUMN event_timestamp INTEGER")
    return db


def secret_hash(value):
    return hmac.new(os.environ["HASH_SECRET"].encode(), value.encode(), hashlib.sha256).hexdigest()


def duration_seconds(value):
    parts = [int(x) for x in str(value).split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    raise ValueError("invalid duration")


def youtube_id(url):
    if not url:
        return None
    parsed = urllib.parse.urlparse(url)
    if parsed.hostname == "youtu.be":
        return parsed.path.lstrip("/") or None
    if parsed.hostname in ("youtube.com", "www.youtube.com"):
        return urllib.parse.parse_qs(parsed.query).get("v", [None])[0]
    return None


def header_size(url):
    """Measure MP3 ID3v2 header using a ten-byte range read."""
    if not url.lower().split("?")[0].endswith(".mp3"):
        return 0
    request = urllib.request.Request(url, headers={"Range": "bytes=0-9", "User-Agent": "BitFlipAnalyticsManifest/1.0"})
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status != 206:
            raise ValueError("audio origin did not honor range request")
        data = response.read(10)
    if len(data) != 10:
        raise ValueError("short ID3 header read")
    if data[:3] != b"ID3":
        return 0
    if any(byte & 0x80 for byte in data[6:10]):
        raise ValueError("invalid ID3 syncsafe size")
    return 10 + (data[6] << 21) + (data[7] << 14) + (data[8] << 7) + data[9]


def live_size(url):
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "BitFlipAnalyticsManifest/1.0"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return int(response.headers["Content-Length"])


def sync_manifest(db, source=None):
    source = source or os.environ["MANIFEST_URL"]
    with urllib.request.urlopen(source, timeout=20) as response:
        episodes = json.load(response)
    for episode in episodes:
        url = episode["audioUrl"]
        filename = urllib.parse.unquote(urllib.parse.urlparse(url).path.rsplit("/", 1)[-1])
        declared_size = int(episode["audioSize"])
        seconds = duration_seconds(episode["duration"])
        try:
            size = live_size(url)
            if size != declared_size:
                print(f"Audio size mismatch for episode {episode['number']}: feed={declared_size}, live={size}",
                      file=sys.stderr, flush=True)
            header = header_size(url)
            minute = min(size - header, (size - header) * 60 // seconds) if seconds > 0 and url.lower().endswith(".mp3") else None
        except (ValueError, urllib.error.URLError, TimeoutError):
            size, header, minute = declared_size, None, None
        db.execute("""INSERT INTO episodes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(number) DO UPDATE SET title=excluded.title, published=excluded.published,
            filename=excluded.filename, audio_url=excluded.audio_url, size=excluded.size,
            duration_seconds=excluded.duration_seconds, header_bytes=excluded.header_bytes,
            minute_bytes=excluded.minute_bytes, youtube_id=excluded.youtube_id""",
            (int(episode["number"]), episode["title"], str(episode["published"]),
             filename, url, size, seconds, header, minute, youtube_id(episode.get("youtubeUrl"))))
    db.commit()
    return len(episodes)


def merge_ranges(ranges):
    merged = []
    for start, end in sorted(ranges):
        if merged and start <= merged[-1][1] + 1:
            merged[-1][1] = max(end, merged[-1][1])
        else:
            merged.append([start, end])
    return merged


def covered_bytes(ranges, start, end):
    return sum(max(0, min(right, end) - max(left, start) + 1) for left, right in ranges)


def qualifies(ranges, episode):
    size = episode["size"]
    header = episode["header_bytes"]
    minute = episode["minute_bytes"]
    if header is None or minute is None or minute < 1 or header >= size:
        return covered_bytes(ranges, 0, size - 1) == size
    return (covered_bytes(ranges, 0, header - 1) == header and
            covered_bytes(ranges, header, size - 1) >= minute)


def ingest(db, event, now=None):
    """Serialize writers so concurrent imports cannot count the same listener twice."""
    with db:
        db.execute("BEGIN IMMEDIATE")
        return _ingest(db, event, now)


def _ingest(db, event, now=None):
    now = int(now if now is not None else time.time())
    if event.get("method") != "GET" or event.get("status") not in (200, 206):
        return "ignored"
    ua = str(event.get("userAgent") or "")[:512]
    ip = str(event.get("ip") or "")[:100]
    if not ua or not ip or BOT.search(ua):
        return "filtered"
    episode = db.execute("SELECT * FROM episodes WHERE filename=?", (event.get("filename"),)).fetchone()
    if episode is None:
        return "unknown_episode"
    try:
        size = int(event["size"])
        start, end = int(event["start"]), int(event["end"])
    except (KeyError, TypeError, ValueError):
        return "invalid"
    if size != episode["size"] or start < 0 or end < start or end >= size or (start == 0 and end == 1):
        return "invalid"
    if event["status"] == 200 and start != 0:
        return "invalid"
    fingerprint = secret_hash(ip + "\x00" + ua)
    ip_hash = secret_hash(ip)
    duplicate = db.execute("""SELECT 1 FROM downloads WHERE episode=? AND fingerprint=?
        AND counted_at>? LIMIT 1""", (episode["number"], fingerprint, now - DAY)).fetchone()
    if duplicate:
        return "duplicate"
    session = db.execute("""SELECT * FROM sessions WHERE episode=? AND fingerprint=?
        AND opened>? ORDER BY opened DESC LIMIT 1""", (episode["number"], fingerprint, now - DAY)).fetchone()
    ranges = merge_ranges((json.loads(session["ranges"]) if session else []) + [[start, end]])
    if session:
        db.execute("UPDATE sessions SET ranges=? WHERE id=?", (json.dumps(ranges), session["id"]))
    else:
        db.execute("INSERT INTO sessions(episode,fingerprint,ip_hash,opened,ranges) VALUES(?,?,?,?,?)",
                   (episode["number"], fingerprint, ip_hash, now, json.dumps(ranges)))
    if not qualifies(ranges, episode):
        return "pending"
    db.execute("INSERT INTO downloads(episode,counted_at,fingerprint,ip_hash) VALUES(?,?,?,?)",
               (episode["number"], now, fingerprint, ip_hash))
    return "counted"


def cleanup(db, now=None):
    now = int(now if now is not None else time.time())
    with db:
        db.execute("DELETE FROM sessions WHERE opened < ?", (now - 2 * DAY,))
        db.execute("UPDATE downloads SET fingerprint=NULL, ip_hash=NULL WHERE counted_at < ?", (now - 2 * DAY,))


def mark_sync(db, source, error=None):
    with db:
        if error is None:
            db.execute("""INSERT INTO sync_state(source,succeeded_at,error) VALUES(?,?,NULL)
                ON CONFLICT(source) DO UPDATE SET succeeded_at=excluded.succeeded_at,error=NULL""",
                (source, int(time.time())))
        else:
            db.execute("""INSERT INTO sync_state(source,succeeded_at,error) VALUES(?,NULL,?)
                ON CONFLICT(source) DO UPDATE SET error=excluded.error""", (source, str(error)[:500]))


def summary(db, now=None):
    now = int(now if now is not None else time.time())
    windows = {"24h": DAY, "7d": 7 * DAY, "30d": 30 * DAY}
    first_event = db.execute("SELECT min(event_timestamp) FROM processed_events WHERE event_timestamp IS NOT NULL").fetchone()[0]
    episodes = []
    for row in db.execute("SELECT number,title,published FROM episodes ORDER BY published DESC,number DESC"):
        published = datetime.fromisoformat(row["published"].replace("Z", "+00:00"))
        if published.tzinfo is None:
            published = published.replace(tzinfo=timezone.utc)
        start = int(published.timestamp())
        counts, states = {}, {}
        for name, seconds in windows.items():
            end = start + seconds
            counts[name] = db.execute("""SELECT count(*) FROM downloads WHERE episode=?
                AND counted_at>=? AND counted_at<? AND counted_at<=?""",
                (row["number"], start, end, now)).fetchone()[0]
            if first_event is None or first_event >= end or now < start:
                states[name] = "unavailable"
            elif first_event > start:
                states[name] = "partial history"
            else:
                states[name] = "complete" if now >= end else "collecting"
        counts["lifetime"] = db.execute("SELECT count(*) FROM downloads WHERE episode=? AND counted_at<=?",
                                       (row["number"], now)).fetchone()[0]
        external = {f"{platform}_{metric}": value for platform, metric, value in db.execute("""
            SELECT platform,metric,sum(value) FROM platform_daily WHERE episode=?
            AND day<=date(?,'unixepoch') GROUP BY platform,metric""", (row["number"], now))}
        episodes.append({**dict(row), **counts, **external, "window_status": states})
    return {"episodes": episodes, "coverage_start": first_event}


def import_spotify(db, path, metric, date_column, value_column, episode_column=None):
    if metric not in ("plays", "streams", "followers"):
        raise ValueError("metric must be plays, streams or followers")
    count = 0
    with open(path, newline="", encoding="utf-8-sig") as file, db:
        for row in csv.DictReader(file):
            day = datetime.fromisoformat(row[date_column]).date().isoformat()
            episode = int(row[episode_column]) if episode_column and row[episode_column] else -1
            value = float(row[value_column].replace(",", ""))
            db.execute("""INSERT INTO platform_daily VALUES('spotify',?,?,?,?) ON CONFLICT DO UPDATE
                SET value=excluded.value""", (metric, day, episode, value))
            count += 1
    return count


def process_event(db, key, event):
    """Commit the event marker and its counting effects in one transaction."""
    timestamp = int(event["timestamp"])
    with db:
        db.execute("BEGIN IMMEDIATE")
        if db.execute("SELECT 1 FROM processed_events WHERE key=?", (key,)).fetchone():
            return "already_processed"
        result = _ingest(db, event, timestamp)
        if result == "unknown_episode":
            return result
        db.execute("INSERT INTO processed_events(key,processed_at,event_timestamp) VALUES(?,?,?)",
                   (key, int(time.time()), timestamp))
        return result


def pull_r2(db, client=None):
    """Move private R2 events into SQLite; delete only after a committed import."""
    if client is None:
        import boto3
        client = boto3.client("s3", endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
            aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
            aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"], region_name="auto")
    bucket = os.environ.get("R2_EVENTS_BUCKET", "bitflip-analytics-events")
    imported = 0
    for page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="events/"):
        for item in page.get("Contents", []):
            key = item["Key"]
            if db.execute("SELECT 1 FROM processed_events WHERE key=?", (key,)).fetchone():
                client.delete_object(Bucket=bucket, Key=key)
                continue
            body = client.get_object(Bucket=bucket, Key=key)["Body"].read()
            event = json.loads(body)
            result = process_event(db, key, event)
            if result == "unknown_episode":
                continue
            client.delete_object(Bucket=bucket, Key=key)
            imported += 1
    return imported


def import_events(db, path):
    """Backfill chronologically sorted Worker-format JSONL from retained logs."""
    imported = 0
    previous_time = 0
    with open(path, encoding="utf-8") as file:
        for line_number, line in enumerate(file, 1):
            if not line.strip():
                continue
            event = json.loads(line)
            timestamp = int(event["timestamp"])
            if timestamp < previous_time:
                raise ValueError(f"line {line_number}: events must be sorted by timestamp")
            previous_time = timestamp
            canonical = json.dumps(event, sort_keys=True, separators=(",", ":"))
            key = "history/" + hashlib.sha256(canonical.encode()).hexdigest()
            if db.execute("SELECT 1 FROM processed_events WHERE key=?", (key,)).fetchone():
                continue
            result = process_event(db, key, event)
            if result == "unknown_episode":
                raise ValueError(f"line {line_number}: episode filename missing from manifest")
            imported += 1
    return imported


def sync_youtube(db):
    data = urllib.parse.urlencode({"client_id": os.environ["YOUTUBE_CLIENT_ID"],
        "client_secret": os.environ["YOUTUBE_CLIENT_SECRET"], "refresh_token": os.environ["YOUTUBE_REFRESH_TOKEN"],
        "grant_type": "refresh_token"}).encode()
    request = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    with urllib.request.urlopen(request, timeout=20) as response:
        token = json.load(response)["access_token"]
    start = db.execute("SELECT min(published) FROM episodes").fetchone()[0]
    if not start:
        return 0
    videos = {row["youtube_id"]: row["number"] for row in db.execute("SELECT youtube_id,number FROM episodes WHERE youtube_id IS NOT NULL")}
    count = 0
    index = 1
    while True:
        params = urllib.parse.urlencode({"ids": "channel==MINE", "startDate": start,
            "endDate": datetime.now(timezone.utc).date().isoformat(), "dimensions": "day,video",
            "metrics": "views,estimatedMinutesWatched", "maxResults": "200", "startIndex": str(index)})
        request = urllib.request.Request("https://youtubeanalytics.googleapis.com/v2/reports?" + params,
                                         headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(request, timeout=30) as response:
            rows = json.load(response).get("rows", [])
        with db:
            for day, video, views, minutes in rows:
                if video not in videos:
                    continue
                for metric, value in (("views", views), ("watch_minutes", minutes)):
                    db.execute("""INSERT INTO platform_daily VALUES('youtube',?,?,?,?) ON CONFLICT DO UPDATE
                        SET value=excluded.value""", (metric, day, videos[video], float(value)))
                count += 1
        if len(rows) < 200:
            break
        index += 200
    return count


def episode_chart(episodes):
    peak = max([episode["30d"] for episode in episodes] + [1])
    bars = []
    for index, episode in enumerate(episodes):
        y = 8 + index * 30
        label = f'#{episode["number"]} {episode["title"]}'
        status = episode["window_status"]["30d"]
        value = "—" if status == "unavailable" else f'{episode["30d"]:,}'
        if status not in ("complete", "unavailable"):
            value += " (" + status + ")"
        bars.append(f'<text x="0" y="{y + 16}">{html.escape(label[:42])}</text>'
                    f'<rect x="310" y="{y}" width="{(0 if status == "unavailable" else episode["30d"]) / peak * 330:.1f}" height="20"><title>{html.escape(label)}: {episode["30d"]} downloads in first 30 days; {status}</title></rect>'
                    f'<text x="650" y="{y + 16}">{value}</text>')
    height = 16 + len(episodes) * 30
    return f'<svg viewBox="0 0 880 {height}" role="img" aria-label="First 30 days of downloads by episode">{"".join(bars)}</svg>'


def dashboard(data):
    def metric(episode, key):
        value = episode.get(key)
        return f"{value:,.0f}" if value is not None else "—"
    def downloads(episode, key):
        if data["coverage_start"] is None:
            return "—"
        status = episode["window_status"].get(key, "complete")
        if status == "unavailable":
            return "—"
        suffix = f" <small>({status})</small>" if status != "complete" else ""
        return f'{episode[key]:,}' + suffix
    rows = "".join(f'<tr><td>#{e["number"]} {html.escape(e["title"])}</td><td>{downloads(e,"24h")}</td><td>{downloads(e,"7d")}</td><td>{downloads(e,"30d")}</td><td>{downloads(e,"lifetime")}</td><td>{metric(e,"spotify_plays")}</td><td>{metric(e,"spotify_streams")}</td><td>{metric(e,"youtube_views")}</td><td>{metric(e,"youtube_watch_minutes")}</td></tr>'
                   for e in data["episodes"])
    coverage = ("Earliest recorded audio event: " + datetime.fromtimestamp(data["coverage_start"], timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
                if data["coverage_start"] is not None else "No audio events recorded yet")
    return f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>BitFlip analytics</title><style>body{{font:16px system-ui;max-width:1100px;margin:auto;padding:2rem;background:#10171d;color:#e9f2f5}}
h1,h2{{color:#fff}}small{{color:#afc4cd}}svg{{width:100%;height:auto;background:#1d2d36;border-radius:.6rem}}svg rect{{fill:#69d5b0}}svg text{{fill:#d4e4e9;font:13px system-ui}}
table{{border-collapse:collapse;width:100%}}th,td{{padding:.6rem;border-bottom:1px solid #38505c;text-align:right}}th:first-child,td:first-child{{text-align:left}}
.scroll{{overflow-x:auto}}</style><h1>BitFlip analytics</h1><p>Qualified RSS audio downloads by episode. First 24 hours, 7 days, and 30 days after release (UTC).</p>
<p>{html.escape(coverage)}. Lifetime download counts start at collection, unless older qualified logs are imported.</p>
{f'<h2>First 30 days by episode</h2>{episode_chart(data["episodes"])}' if data["coverage_start"] is not None else ''}
<h2>Episode metrics</h2><div class="scroll"><table><thead><tr><th>Episode</th><th>First 24h</th><th>First 7d</th><th>First 30d</th><th>Recorded lifetime downloads</th><th>Imported lifetime Spotify plays</th><th>Imported lifetime Spotify streams</th><th>Imported lifetime YouTube views</th><th>Imported lifetime YouTube watch minutes</th></tr></thead><tbody>{rows}</tbody></table></div>
<small>Spotify and YouTube metrics have platform definitions. A dash means unavailable data. Partial history means collection started after release. Collecting means the release window is still open. Source interruptions can leave gaps; check collector health before comparing episodes.</small></html>'''


class Handler(BaseHTTPRequestHandler):
    def send(self, status, body, content_type="text/plain; charset=utf-8"):
        body = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authorized_admin(self):
        expected = base64.b64encode((os.environ["ADMIN_USER"] + ":" + os.environ["ADMIN_PASSWORD"]).encode()).decode()
        if hmac.compare_digest(self.headers.get("Authorization", ""), "Basic " + expected):
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="BitFlip analytics"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def do_GET(self):
        if self.path == "/health":
            try:
                with closing(connect()) as db:
                    db.execute("SELECT 1")
                    episode_count = db.execute("SELECT count(*) FROM episodes").fetchone()[0]
                    poll = db.execute("SELECT succeeded_at,error FROM sync_state WHERE source='r2'").fetchone()
                fresh = bool(poll and poll["succeeded_at"] and time.time() - poll["succeeded_at"] < 900)
                ready = episode_count > 0 and fresh
                status = 200 if ready or time.time() - SERVICE_STARTED < 900 else 503
                body = {"episodes": episode_count, "r2_poll_fresh": fresh,
                        "last_r2_poll": poll["succeeded_at"] if poll else None,
                        "last_error": poll["error"] if poll else None}
                self.send(status, json.dumps(body), "application/json; charset=utf-8")
            except sqlite3.Error:
                self.send(503, "database unavailable")
            return
        if self.path not in ("/", "/api/summary"):
            self.send(404, "not found")
            return
        if not self.authorized_admin():
            return
        with closing(connect()) as db:
            data = summary(db)
        if self.path == "/api/summary":
            self.send(200, json.dumps(data), "application/json; charset=utf-8")
        else:
            self.send(200, dashboard(data), "text/html; charset=utf-8")



def background_sync():
    last_manifest = 0
    last_youtube = 0
    while True:
        try:
            with closing(connect()) as db:
                cleanup(db)
                if time.time() - last_manifest > 6 * 3600:
                    try:
                        sync_manifest(db)
                        mark_sync(db, "manifest")
                        last_manifest = time.time()
                    except Exception as error:
                        mark_sync(db, "manifest", error)
                        print(f"Manifest sync failed: {error}", file=sys.stderr, flush=True)
                try:
                    pull_r2(db)
                    mark_sync(db, "r2")
                except Exception as error:
                    mark_sync(db, "r2", error)
                    print(f"R2 poll failed: {error}", file=sys.stderr, flush=True)
                if os.getenv("YOUTUBE_REFRESH_TOKEN") and time.time() - last_youtube > DAY:
                    try:
                        sync_youtube(db)
                        mark_sync(db, "youtube")
                        last_youtube = time.time()
                    except Exception as error:
                        mark_sync(db, "youtube", error)
                        print(f"YouTube sync failed: {error}", file=sys.stderr, flush=True)
        except Exception as error:
            print(f"Analytics background loop failed: {error}", file=sys.stderr, flush=True)
        time.sleep(300)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "serve"
    with closing(connect()) as db:
        if command == "sync-manifest":
            print(f"Synced {sync_manifest(db)} episodes")
        elif command == "sync-youtube":
            print(f"Synced {sync_youtube(db)} YouTube daily rows")
        elif command == "pull-r2":
            print(f"Imported {pull_r2(db)} R2 events")
        elif command == "import-spotify":
            print(f"Imported {import_spotify(db, *sys.argv[2:])} Spotify rows")
        elif command == "import-events":
            print(f"Imported {import_events(db, sys.argv[2])} historical events")
        elif command == "serve":
            for key in ("ADMIN_USER", "ADMIN_PASSWORD", "HASH_SECRET", "R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"):
                if not os.getenv(key) or os.environ[key].startswith("replace-with"):
                    raise SystemExit(f"Set {key} before serving")
            threading.Thread(target=background_sync, daemon=True).start()
            ThreadingHTTPServer(("0.0.0.0", 8787), Handler).serve_forever()
        else:
            raise SystemExit(f"Unknown command: {command}")


if __name__ == "__main__":
    main()
