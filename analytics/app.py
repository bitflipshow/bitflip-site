"""Private BitFlip download analytics service."""

from contextlib import closing
import csv
import hashlib
import hmac
import json
import ipaddress
import os
import re
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from views import dashboard


DB_PATH = os.getenv("DB_PATH", "/data/analytics.sqlite3")
BOT = re.compile(r"bitflipanalytics|bot|spider|crawler|preview|facebookexternalhit|google|bing|curl/|wget/|python-requests|headless|monitor|atc/.*watchos|\(null\)/\(null\).*watchos", re.I)
DAY = 86400
SERVICE_STARTED = time.time()
RELEASE_TZ = ZoneInfo(os.getenv("RELEASE_TZ", "America/New_York"))


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
        CREATE INDEX IF NOT EXISTS downloads_episode_time ON downloads(episode, counted_at);
        CREATE INDEX IF NOT EXISTS downloads_dedupe ON downloads(episode, fingerprint, counted_at);
        CREATE TABLE IF NOT EXISTS platform_daily (
            platform TEXT NOT NULL, metric TEXT NOT NULL, day TEXT NOT NULL,
            episode INTEGER NOT NULL, value REAL NOT NULL,
            PRIMARY KEY(platform, metric, day, episode)
        );
        CREATE TABLE IF NOT EXISTS youtube_public (
            episode INTEGER PRIMARY KEY, video_id TEXT NOT NULL,
            views INTEGER NOT NULL CHECK(views>=0), observed_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS processed_events (
            key TEXT PRIMARY KEY, processed_at INTEGER NOT NULL,
            event_timestamp INTEGER
        );
        CREATE INDEX IF NOT EXISTS platform_episode_day ON platform_daily(episode, day);
        CREATE TABLE IF NOT EXISTS sync_state (
            source TEXT PRIMARY KEY, succeeded_at INTEGER, error TEXT
        );
    """)
    columns = {row[1] for row in db.execute("PRAGMA table_info(processed_events)")}
    if "event_timestamp" not in columns:
        db.execute("ALTER TABLE processed_events ADD COLUMN event_timestamp INTEGER")
    db.execute("CREATE INDEX IF NOT EXISTS processed_event_time ON processed_events(event_timestamp)")
    return db


def secret_hash(value):
    return hmac.new(os.environ["HASH_SECRET"].encode(), value.encode(), hashlib.sha256).hexdigest()


def listener_ip(value):
    """Canonicalize IPv4 and truncate IPv6 to /64 before hashing (IAB v2.2)."""
    address = ipaddress.ip_address(value)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    if address.is_unspecified or address.is_loopback or address.is_multicast or address.is_link_local:
        raise ValueError("not a listener address")
    if isinstance(address, ipaddress.IPv6Address):
        return str(ipaddress.ip_network(f"{address}/64", strict=False).network_address)
    return str(address)


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


def is_mp3(url):
    return urllib.parse.urlparse(url).path.lower().endswith(".mp3")


def header_size(url):
    """Measure MP3 ID3v2 header using a ten-byte range read."""
    if not is_mp3(url):
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
    request = urllib.request.Request(source, headers={"User-Agent": "BitFlipAnalyticsManifest/1.0"})
    with urllib.request.urlopen(request, timeout=20) as response:
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
            minute = min(size - header, (size - header) * 60 // seconds) if seconds > 0 and is_mp3(url) else None
        except (ValueError, urllib.error.URLError, TimeoutError) as error:
            # Keep the last measured values; the feed size may be stale and would reject every event.
            known = db.execute("SELECT size,header_bytes,minute_bytes FROM episodes WHERE number=? AND audio_url=?",
                               (int(episode["number"]), url)).fetchone()
            size, header, minute = tuple(known) if known else (declared_size, None, None)
            print(f"Audio probe failed for episode {episode['number']}: {error}; "
                  f"{'keeping last measured size' if known else 'using feed size'}", file=sys.stderr, flush=True)
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
    try:
        ip = listener_ip(ip)
    except ValueError:
        return "filtered"
    episode = db.execute("SELECT * FROM episodes WHERE filename=?", (event.get("filename"),)).fetchone()
    if episode is None:
        return "unknown_episode"
    try:
        size = int(event["size"])
        start, end = int(event["start"]), int(event["end"])
    except (KeyError, TypeError, ValueError):
        return "invalid"
    if size != episode["size"]:
        return "size_mismatch"
    if start < 0 or end < start or end >= size or (start == 0 and end == 1):
        return "invalid"
    if event["status"] == 200 and start != 0:
        return "invalid"
    fingerprint = secret_hash(ip + "\x00" + ua)
    ip_hash = secret_hash(ip)
    duplicate = db.execute("""SELECT 1 FROM downloads WHERE episode=? AND fingerprint=?
        AND counted_at>? AND counted_at<=? LIMIT 1""", (episode["number"], fingerprint, now - DAY, now)).fetchone()
    if duplicate:
        return "duplicate"
    session = db.execute("""SELECT * FROM sessions WHERE episode=? AND fingerprint=?
        AND opened>? AND opened<=? ORDER BY opened DESC LIMIT 1""", (episode["number"], fingerprint, now - DAY, now)).fetchone()
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


def release_floor(published):
    """Earliest time a release window may start; date-only values mean the release day in RELEASE_TZ."""
    if len(published) == 10:
        return int(datetime.fromisoformat(published).replace(tzinfo=RELEASE_TZ).timestamp())
    moment = datetime.fromisoformat(published.replace("Z", "+00:00"))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return int(moment.timestamp())


def summary(db, now=None, limit=None, offset=0, query="", number=None):
    """Read a bounded episode selection with constant query count as the archive grows."""
    now = int(now if now is not None else time.time())
    windows = {"24h": DAY, "7d": 7 * DAY, "30d": 30 * DAY}
    first_event = db.execute("SELECT min(event_timestamp) FROM processed_events WHERE event_timestamp IS NOT NULL").fetchone()[0]
    where, parameters = "1=1", []
    if number is not None:
        where, parameters = "number=?", [number]
    elif query:
        where = "(instr(lower(title), lower(?))>0 OR CAST(number AS TEXT)=?)"
        parameters = [query, query.lstrip("#")]
    total = db.execute(f"SELECT count(*) FROM episodes WHERE {where}", parameters).fetchone()[0]
    rows = db.execute(f"""SELECT e.number,e.title,e.published,e.duration_seconds,p.views AS youtube_public_views,
        p.observed_at AS youtube_public_observed_at FROM episodes e
        LEFT JOIN youtube_public p ON p.episode=e.number AND p.video_id=e.youtube_id WHERE {where}
        ORDER BY julianday(published) DESC,number DESC LIMIT ? OFFSET ?""",
        [*parameters, limit if limit is not None else -1, offset]).fetchall()
    ids = [row["number"] for row in rows]
    # Episodes released after collection began start their windows at the first counted download
    # on or after release day; older episodes fall back to release day with partial-history labels.
    floors = {row["number"]: release_floor(row["published"]) for row in rows}
    covered = {number: first_event is not None and first_event <= floor for number, floor in floors.items()}
    counts_by_episode, external_by_episode = {}, {}
    if ids:
        placeholders = ",".join("?" for _ in ids)
        values = ",".join("(?,?,?)" for _ in ids)
        for row in db.execute(f"""WITH floors(episode,floor,covered) AS (VALUES {values}),
            starts AS (SELECT episode, CASE WHEN covered THEN (SELECT min(counted_at) FROM downloads d
                WHERE d.episode=f.episode AND d.counted_at>=f.floor AND d.counted_at<=?) ELSE floor END AS start
                FROM floors f)
            SELECT d.episode, s.start, count(*) AS lifetime,
            coalesce(sum(d.counted_at>=s.start AND d.counted_at<s.start+86400), 0) AS '24h',
            coalesce(sum(d.counted_at>=s.start AND d.counted_at<s.start+604800), 0) AS '7d',
            coalesce(sum(d.counted_at>=s.start AND d.counted_at<s.start+2592000), 0) AS '30d'
            FROM downloads d JOIN starts s ON s.episode=d.episode
            WHERE d.counted_at<=? GROUP BY d.episode, s.start""",
            [*(v for n in ids for v in (n, floors[n], covered[n])), now, now]):
            counts_by_episode[row["episode"]] = dict(row)
        for episode, platform, metric, value in db.execute(f"""SELECT episode,platform,metric,sum(value)
            FROM platform_daily WHERE episode IN ({placeholders}) AND day<=date(?,'unixepoch')
            GROUP BY episode,platform,metric""", [*ids, now]):
            external_by_episode.setdefault(episode, {})[f"{platform}_{metric}"] = value
    episodes = []
    for row in rows:
        floor = floors[row["number"]]
        counts = counts_by_episode.get(row["number"], dict.fromkeys([*windows, "lifetime", "start"], 0))
        start = (counts["start"] or None) if covered[row["number"]] else floor
        states = {}
        for name, seconds in windows.items():
            if first_event is None or now < floor:
                states[name] = "unavailable"
            elif covered[row["number"]]:
                states[name] = "complete" if start is not None and now >= start + seconds else "collecting"
            elif first_event >= floor + seconds:
                states[name] = "unavailable"
            else:
                states[name] = "partial history"
        episodes.append({**dict(row), **{key: counts[key] for key in [*windows, "lifetime"]},
                         **external_by_episode.get(row["number"], {}), "window_start": start,
                         "window_status": states})
    return {"episodes": episodes, "coverage_start": first_event, "total": total, "offset": offset,
            "page_size": limit, "query": query}


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


# Leave these in R2 so a later manifest sync can resolve them before the lifecycle rule expires them.
RETRYABLE = ("unknown_episode", "size_mismatch")


def process_event(db, key, event):
    """Commit the event marker and its counting effects in one transaction."""
    timestamp = int(event["timestamp"])
    with db:
        db.execute("BEGIN IMMEDIATE")
        if db.execute("SELECT 1 FROM processed_events WHERE key=?", (key,)).fetchone():
            return "already_processed"
        result = _ingest(db, event, timestamp)
        if result in RETRYABLE:
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
    waiting = dict.fromkeys(RETRYABLE, 0)
    for page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="events/"):
        for item in page.get("Contents", []):
            key = item["Key"]
            if db.execute("SELECT 1 FROM processed_events WHERE key=?", (key,)).fetchone():
                client.delete_object(Bucket=bucket, Key=key)
                continue
            body = client.get_object(Bucket=bucket, Key=key)["Body"].read()
            try:
                event = json.loads(body)
                if not isinstance(event, dict):
                    raise ValueError("event is not an object")
                result = process_event(db, key, event)
            except (ValueError, KeyError, TypeError) as error:
                # Move malformed events aside so they cannot block later events until they expire.
                client.copy_object(Bucket=bucket, Key="rejected/" + key.removeprefix("events/"),
                                   CopySource={"Bucket": bucket, "Key": key})
                client.delete_object(Bucket=bucket, Key=key)
                print(f"Rejected malformed R2 event {key}: {error!r}", file=sys.stderr, flush=True)
                continue
            if result in RETRYABLE:
                waiting[result] += 1
                continue
            client.delete_object(Bucket=bucket, Key=key)
            imported += 1
    if any(waiting.values()):
        print(f"R2 events awaiting manifest update: {waiting}", file=sys.stderr, flush=True)
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
            if result == "size_mismatch":
                raise ValueError(f"line {line_number}: file size differs from the manifest")
            imported += 1
    return imported


def save_youtube_public(db, video_id, views, observed_at):
    """Store a lifetime snapshot, never a daily increment or a download."""
    if not isinstance(views, int) or isinstance(views, bool) or views < 0:
        raise ValueError("public views must be a nonnegative integer")
    episode = db.execute("SELECT number FROM episodes WHERE youtube_id=?", (video_id,)).fetchone()
    if episode is None:
        raise ValueError("video is not in the episode manifest")
    with db:
        db.execute("""INSERT INTO youtube_public VALUES(?,?,?,?)
            ON CONFLICT(episode) DO UPDATE SET video_id=excluded.video_id,
            views=excluded.views,observed_at=excluded.observed_at
            WHERE excluded.observed_at>=youtube_public.observed_at""",
            (episode[0], video_id, views, observed_at))


def sync_youtube_public(db):
    """Refresh public counts without account credentials or media downloads."""
    now = int(time.time())
    videos = db.execute("""SELECT e.youtube_id FROM episodes e LEFT JOIN youtube_public p
        ON p.episode=e.number AND p.video_id=e.youtube_id WHERE e.youtube_id IS NOT NULL
        AND (p.observed_at IS NULL OR p.observed_at<?)""", (now - DAY,)).fetchall()
    count, failed = 0, 0
    for (video_id,) in videos:
        try:
            result = subprocess.run(["yt-dlp", "--skip-download", "--no-playlist", "--print",
                "%(.{id,view_count})j", "https://www.youtube.com/watch?v=" + video_id],
                capture_output=True, text=True, timeout=60, check=True)
            data = json.loads(result.stdout)
            if data["id"] != video_id:
                raise ValueError("video identity mismatch")
            save_youtube_public(db, video_id, data["view_count"], int(time.time()))
            count += 1
        except (subprocess.SubprocessError, ValueError, KeyError, OSError):
            failed += 1
    if failed:
        raise ValueError(f"Public YouTube refresh failed for {failed} videos; previous snapshots retained")
    return count


def public_youtube_loop():
    # A separate connection/thread keeps slow public pages from delaying R2 collection.
    while True:
        try:
            with closing(connect()) as db:
                if db.execute("SELECT count(*) FROM episodes").fetchone()[0] == 0:
                    time.sleep(30)
                    continue
                try:
                    sync_youtube_public(db)
                    mark_sync(db, "youtube_public")
                except Exception as error:
                    mark_sync(db, "youtube_public", error)
                    print(f"Public YouTube sync failed: {error}", file=sys.stderr, flush=True)
        except Exception as error:
            print(f"Public YouTube loop failed: {error}", file=sys.stderr, flush=True)
        time.sleep(6 * 3600)


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
    if not videos:
        return 0
    count = 0
    index = 1
    while True:
        params = urllib.parse.urlencode({"ids": "channel==MINE", "startDate": start[:10],
            "endDate": datetime.now(timezone.utc).date().isoformat(), "dimensions": "day,video",
            "filters": "video==" + ",".join(videos), "sort": "day,video",
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


class Handler(BaseHTTPRequestHandler):
    def send(self, status, body, content_type="text/plain; charset=utf-8"):
        body = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/podcast-logo.png":
            self.send(200, Path(__file__).with_name("podcast-logo.png").read_bytes(), "image/png")
            return
        if self.path == "/health":
            try:
                with closing(connect()) as db:
                    db.execute("SELECT 1")
                    episode_count = db.execute("SELECT count(*) FROM episodes").fetchone()[0]
                    poll = db.execute("SELECT succeeded_at,error FROM sync_state WHERE source='r2'").fetchone()
                fresh = bool(poll and poll["succeeded_at"] and time.time() - poll["succeeded_at"] < 900)
                ready = episode_count > 0 and fresh
                status = 200 if ready else 503
                body = {"episodes": episode_count, "r2_poll_fresh": fresh,
                        "last_r2_poll": poll["succeeded_at"] if poll else None,
                        "last_error": poll["error"] if poll else None}
                self.send(status, json.dumps(body), "application/json; charset=utf-8")
            except sqlite3.Error:
                self.send(503, "database unavailable")
            return
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.rstrip("/") or "/"
        params = urllib.parse.parse_qs(parsed.query)
        detail = re.fullmatch(r"/(?:api/)?episodes/(\d+)", path)
        archive = path in ("/episodes", "/api/episodes")
        if path not in ("/", "/api/summary") and not archive and not detail:
            self.send(404, "not found")
            return
        try:
            page = int(params.get("page", ["1"])[0])
            if page < 1 or page > 1_000_000:
                raise ValueError
        except ValueError:
            self.send(400, "invalid page")
            return
        query = params.get("q", [""])[0].strip()[:200] if archive else ""
        mode = "episode" if detail else "archive" if archive else "recent"
        size = 1 if detail else 25 if archive else 10
        with closing(connect()) as db:
            data = summary(db, limit=size, offset=(page - 1) * size if archive else 0,
                           query=query, number=int(detail[1]) if detail else None)
        if detail and not data["episodes"]:
            self.send(404, "episode not found")
            return
        if archive and page > 1 and not data["episodes"]:
            self.send(404, "page not found")
            return
        if path.startswith("/api/"):
            self.send(200, json.dumps(data), "application/json; charset=utf-8")
        else:
            metric = params.get("metric", ["lifetime"])[0]
            if metric not in ("24h", "7d", "30d", "lifetime"):
                metric = "lifetime"
            self.send(200, dashboard(data, mode=mode, metric=metric), "text/html; charset=utf-8")



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
        elif command == "sync-youtube-public":
            print(f"Synced {sync_youtube_public(db)} public YouTube snapshots")
        elif command == "import-youtube-public":
            for row in json.loads(Path(sys.argv[2]).read_text()):
                save_youtube_public(db, row["video_id"], row["views"], row["observed_at"])
        elif command == "sync-youtube":
            print(f"Synced {sync_youtube(db)} YouTube daily rows")
        elif command == "pull-r2":
            print(f"Imported {pull_r2(db)} R2 events")
        elif command == "import-spotify":
            print(f"Imported {import_spotify(db, *sys.argv[2:])} Spotify rows")
        elif command == "import-events":
            print(f"Imported {import_events(db, sys.argv[2])} historical events")
        elif command == "serve":
            for key in ("HASH_SECRET", "R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"):
                if not os.getenv(key) or os.environ[key].startswith("replace-with"):
                    raise SystemExit(f"Set {key} before serving")
            threading.Thread(target=background_sync, daemon=True).start()
            threading.Thread(target=public_youtube_loop, daemon=True).start()
            ThreadingHTTPServer(("0.0.0.0", 8787), Handler).serve_forever()
        else:
            raise SystemExit(f"Unknown command: {command}")


if __name__ == "__main__":
    main()
