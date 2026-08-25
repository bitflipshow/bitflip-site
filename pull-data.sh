#!/usr/bin/env bash
# Fetches episode data from Outline and R2 (or FileBrowser), creating the
# episode markdown file and downloading the audio file ready for publishing.
#
# Finds the Outline doc by episode number, extracts frontmatter and show
# notes, writes episodes/NNNN.md, then downloads the matching audio file
# and speaker tracks into the local audio directory.
#
# Usage:
#   ./pull-data.sh <episode-number> [--skip-audio]
#   ./pull-data.sh <episode-number> --skip-notes
#   ./pull-data.sh 3
#   ./pull-data.sh 42 --skip-audio
#   ./pull-data.sh 42 --skip-notes
#
# Requirements:
#   curl, python3, rclone (for AUDIO_SOURCE=r2)

set -Eeuo pipefail

########################################
# Configuration
########################################

OUTLINE_URL="https://outline.komodo-gecko.ts.net"
OUTLINE_API_KEY_FILE="~/.config/bitflip/outline_api_key"

EPISODES_DIR="episodes"

# Audio source — "filebrowser" or "r2"
AUDIO_SOURCE="r2"

# FileBrowser — audio file source
FB_HOST="http://100.104.240.5:8080"
FB_USER="production"
FB_PASS_FILE="~/.config/bitflip/fb_password"
FB_REMOTE_DIR="audio-production"
FB_RAW_DIR="audio-transcript"
AUDIO_DIR="audio"

# R2 (via rclone) — audio source
R2_REMOTE="production-audio"  # rclone remote name (from rclone config)
R2_BUCKET="recorded-files"    # R2 bucket name
R2_BASE_DIR="PodBooth"        # Folder inside the bucket containing "Episode N" subfolders
R2_FULL_DIR="production/full"         # Subfolder holding the full episode audio
R2_SPEAKERS_DIR="production/speakers" # Subfolder holding per-speaker tracks

########################################
# Globals
########################################

EPISODE_NUM=""
EPISODE_NUM_PADDED=""
OUTLINE_API_KEY=""
FB_PASS=""
FB_TOKEN=""
SKIP_AUDIO=false
SKIP_NOTES=false

########################################
# Utility
########################################

log()    { echo "  $*" >&2; }
header() { echo >&2; echo ">> $*" >&2; }
fatal()  { echo "Error: $*" >&2; exit 1; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fatal "Required command missing: $1"
  fi
}

########################################
# Argument Parsing
########################################

usage() {
  echo "Usage: $0 <episode-number> [--skip-audio] [--skip-notes]"
  echo "Example: $0 3"
  echo "         $0 42 --skip-audio"
  echo "         $0 42 --skip-notes"
  exit 1
}

parse_args() {
  if [[ $# -eq 0 ]]; then usage; fi

  if [[ ! "$1" =~ ^[0-9]+$ ]]; then
    echo "Error: episode number must be numeric" >&2; exit 1
  fi

  EPISODE_NUM=$(( 10#$1 ))
  EPISODE_NUM_PADDED=$(printf "%04d" "$EPISODE_NUM")
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-audio) SKIP_AUDIO=true ;;
      --skip-notes) SKIP_NOTES=true ;;
      *) usage ;;
    esac
    shift
  done

  if [[ "$SKIP_AUDIO" == true && "$SKIP_NOTES" == true ]]; then
    fatal "--skip-audio and --skip-notes together would do nothing."
  fi
}

########################################
# Load Outline API Key
########################################

load_api_key() {
  local key_file="${OUTLINE_API_KEY_FILE/#\~/$HOME}"
  if [[ -f "$key_file" ]]; then
    OUTLINE_API_KEY=$(tr -d '[:space:]' < "$key_file")
  else
    OUTLINE_API_KEY="${OUTLINE_API_KEY:-}"
  fi
  if [[ -z "$OUTLINE_API_KEY" ]]; then
    fatal "No Outline API key found at $key_file."
  fi
}

########################################
# Load FileBrowser Password
########################################

load_fb_password() {
  local pass_file="${FB_PASS_FILE/#\~/$HOME}"
  if [[ -f "$pass_file" ]]; then
    FB_PASS=$(tr -d '[:space:]' < "$pass_file")
  else
    FB_PASS="${FB_PASS:-}"
  fi
  if [[ -z "$FB_PASS" ]]; then
    fatal "No FileBrowser password found at $pass_file."
  fi
}

########################################
# FileBrowser Auth (shared token)
########################################

fb_login() {
  local auth_tmp
  auth_tmp=$(mktemp /tmp/fb-auth.XXXXXX.json)
  python3 - "$FB_USER" "$FB_PASS" "$auth_tmp" <<'PYEOF'
import json, sys
user, password, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(out, "w") as f:
    json.dump({"username": user, "password": password}, f)
PYEOF

  FB_TOKEN=$(curl -sf -X POST "${FB_HOST}/api/login" \
    -H "Content-Type: application/json" \
    -d @"$auth_tmp")
  rm -f "$auth_tmp"

  if [[ -z "$FB_TOKEN" ]]; then
    fatal "FileBrowser authentication failed."
  fi
}

########################################
# Outline API
########################################

outline_post() {
  local endpoint="$1" payload_file="$2"
  local http_status response_file
  response_file=$(mktemp /tmp/outline-response.XXXXXX.json)

  http_status=$(curl -s -o "$response_file" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${OUTLINE_API_KEY}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d @"$payload_file" \
    "${OUTLINE_URL}/api/${endpoint}")

  if [[ "$http_status" != "200" ]]; then
    echo "Error: Outline API ${endpoint} returned HTTP ${http_status}" >&2
    echo "  Body: $(cat "$response_file")" >&2
    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

########################################
# Find the Episode Doc and Fetch Clean Markdown
########################################

find_episode_doc() {
  header "Searching Outline for episode ${EPISODE_NUM}"

  local payload_tmp response_tmp
  payload_tmp=$(mktemp /tmp/outline-payload.XXXXXX.json)

  python3 - "$EPISODE_NUM" "$payload_tmp" <<'PYEOF'
import json, sys
num, out = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    json.dump({"query": f"Episode {num}", "limit": 10}, f)
PYEOF

  local response
  response=$(outline_post "documents.search" "$payload_tmp")
  rm -f "$payload_tmp"
  [[ -n "$response" ]] || fatal "Outline search API call failed."

  response_tmp=$(mktemp /tmp/outline-search.XXXXXX.json)
  echo "$response" > "$response_tmp"

  local doc_id
  doc_id=$(python3 - "$EPISODE_NUM" "$response_tmp" <<'PYEOF'
import json, sys, re

num       = sys.argv[1]
resp_file = sys.argv[2]

with open(resp_file) as f:
    raw = f.read()

if not raw.strip():
    sys.stderr.write("Empty response from Outline search\n")
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    sys.stderr.write(f"Failed to parse search response: {e}\nRaw: {raw[:500]}\n")
    sys.exit(1)

for item in data.get("data", []):
    doc = item.get("document", item)
    title = doc.get("title", "")
    if re.match(rf"^Episode\s+0*{re.escape(num)}\b", title, re.IGNORECASE):
        sys.stderr.write(f"Found: {title}\n")
        print(doc.get("id", ""))
        sys.exit(0)

sys.stderr.write(f"No doc found matching 'Episode {num}'\n")
sys.exit(1)
PYEOF
  )
  rm -f "$response_tmp"

  if [[ -z "$doc_id" ]]; then
    fatal "No Outline doc found matching 'Episode ${EPISODE_NUM}'."
  fi

  log "Doc ID: ${doc_id}"
  echo "$doc_id"
}

fetch_doc() {
  local doc_id="$1"
  header "Fetching doc content"

  local payload_tmp
  payload_tmp=$(mktemp /tmp/outline-payload.XXXXXX.json)

  python3 - "$doc_id" "$payload_tmp" <<'PYEOF'
import json, sys
doc_id, out = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    json.dump({"id": doc_id}, f)
PYEOF

  local response
  response=$(outline_post "documents.info" "$payload_tmp")
  rm -f "$payload_tmp"
  [[ -n "$response" ]] || fatal "Outline documents.info call failed."

  python3 - <(echo "$response") <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
content = data.get("data", {}).get("text", "")
if not content:
    sys.stderr.write("Empty text field in documents.info response\n")
    sys.exit(1)
print(content, end="")
PYEOF
}

########################################
# Parse Doc Content
########################################

extract_section() {
  local content="$1" heading="$2"
  local tmp
  tmp=$(mktemp /tmp/outline-content.XXXXXX.txt)
  echo "$content" > "$tmp"
  python3 - "$heading" "$tmp" <<'PYEOF'
import sys, re
heading = sys.argv[1]
with open(sys.argv[2]) as f:
    content = f.read()
lines = content.splitlines()
in_section = False
result = []
for line in lines:
    if re.match(rf"^##\s+{re.escape(heading)}\s*$", line, re.IGNORECASE):
        in_section = True
        continue
    if in_section:
        if re.match(r"^##\s+", line):
            break
        result.append(line)
print("\n".join(result).strip())
PYEOF
  rm -f "$tmp"
}

extract_show_notes_section() {
  local content="$1"
  local tmp
  tmp=$(mktemp /tmp/outline-content.XXXXXX.txt)
  echo "$content" > "$tmp"
  python3 - "$tmp" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
lines = content.splitlines()
in_show_notes = False
result = []
for line in lines:
    if re.match(r"^#\s+\*{0,2}Show Notes\*{0,2}\s*$", line, re.IGNORECASE):
        in_show_notes = True
        continue
    if in_show_notes:
        if re.match(r"^#\s+\S", line):
            break
        result.append(line)
print("\n".join(result).strip())
PYEOF
  rm -f "$tmp"
}

extract_code_block() {
  local content="$1"
  local tmp
  tmp=$(mktemp /tmp/outline-content.XXXXXX.txt)
  echo "$content" > "$tmp"
  python3 - "$tmp" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
match = re.search(r"```[^\n]*\n(.*?)```", content, re.DOTALL)
if match:
    print(match.group(1).strip())
else:
    sys.exit(1)
PYEOF
  rm -f "$tmp"
}

parse_yaml_to_json() {
  local content="$1"
  local tmp
  tmp=$(mktemp /tmp/outline-yaml.XXXXXX.txt)
  echo "$content" > "$tmp"
  python3 - "$tmp" <<'PYEOF'
import sys, json, re

with open(sys.argv[1]) as f:
    content = f.read()

result = {}
current_key = None
current_list = None

for line in content.splitlines():
    if not line.strip():
        continue
    if current_key is not None and current_list is not None:
        sub = re.match(r"^\s{4,}(\w+):\s*(.*)", line)
        if sub:
            if not current_list or not isinstance(current_list[-1], dict):
                current_list.append({})
            current_list[-1][sub.group(1)] = sub.group(2).strip().strip('"')
            continue
    if re.match(r"^\s{2,}-\s*", line) and current_key is not None:
        item = re.sub(r"^\s*-\s*", "", line).strip()
        if current_list is None:
            current_list = []
        if not item:
            current_list.append({})
        else:
            sub = re.match(r"(\w+):\s*(.*)", item)
            if sub:
                current_list.append({sub.group(1): sub.group(2).strip().strip('"')})
            else:
                val = item.strip('"')
                if val:
                    current_list.append(val)
        continue
    m = re.match(r"^(\w+):\s*(.*)", line)
    if m:
        if current_key is not None and current_list is not None:
            result[current_key] = current_list if current_list else None
        current_key = m.group(1)
        val = m.group(2).strip().strip('"')
        if val == "" or val.lower() == "null":
            current_list = []
        elif val.lower() == "true":
            result[current_key] = True; current_key = None; current_list = None
        elif val.lower() == "false":
            result[current_key] = False; current_key = None; current_list = None
        else:
            try:
                result[current_key] = int(val)
            except ValueError:
                result[current_key] = val
            current_key = None; current_list = None

if current_key is not None and current_list is not None:
    result[current_key] = current_list if current_list else None

print(json.dumps(result))
PYEOF
  rm -f "$tmp"
}

########################################
# Build Episode Markdown
########################################

build_episode_md() {
  local fm_json="$1" what_we_cover="$2" links_text="$3" transcript="$4"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local episodes_dir="${script_dir}/${EPISODES_DIR}"

  local cover_tmp links_tmp transcript_tmp
  cover_tmp=$(mktemp /tmp/outline-cover.XXXXXX.txt)
  links_tmp=$(mktemp /tmp/outline-links.XXXXXX.txt)
  transcript_tmp=$(mktemp /tmp/outline-transcript.XXXXXX.txt)
  echo "$what_we_cover" > "$cover_tmp"
  echo "$links_text"    > "$links_tmp"
  echo "$transcript"    > "$transcript_tmp"

  python3 - "$fm_json" "$cover_tmp" "$links_tmp" "$transcript_tmp" "$episodes_dir" "$EPISODE_NUM_PADDED" <<'PYEOF'
import json, sys, re, os

fm_json        = sys.argv[1]
cover_tmp      = sys.argv[2]
links_tmp      = sys.argv[3]
transcript_tmp = sys.argv[4]
episodes_dir   = sys.argv[5]
ep_padded      = sys.argv[6]

try:
    fm = json.loads(fm_json)
except json.JSONDecodeError as e:
    sys.stderr.write(f"Failed to parse frontmatter JSON: {e}\nRaw: {fm_json[:200]}\n")
    sys.exit(1)

with open(cover_tmp) as f:
    cover_text = f.read()
with open(links_tmp) as f:
    links_raw = f.read()
with open(transcript_tmp) as f:
    transcript_text = f.read()

ep_num      = fm.get("episodeNumber", 0)
title       = fm.get("title", "")
ep_date     = fm.get("date", "")
draft       = fm.get("draft", True)
summary     = fm.get("summary", "")
audio_url   = fm.get("audioUrl", "")
audio_size  = fm.get("audioSize", "")
duration    = fm.get("duration", "00:00:00")
explicit    = fm.get("explicit", False)
youtube_url = fm.get("youtubeUrl", "")
tags        = fm.get("tags") or []
hosts       = fm.get("hosts") or []
guests      = fm.get("guests") or []
sponsors    = fm.get("sponsors") or []
chapters    = fm.get("chapters") or [{"time": "00:00:00", "title": "Intro"}]

filename = f"{ep_padded}.md"
filepath = os.path.join(episodes_dir, filename)

if os.path.exists(filepath):
    print(f"ERROR: {filepath} already exists — delete it first.", file=sys.stderr)
    sys.exit(1)

chapters_yaml = ""
for ch in chapters:
    if isinstance(ch, dict):
        chapters_yaml += f'  - time: "{ch.get("time", "00:00:00")}"\n'
        chapters_yaml += f'    title: "{ch.get("title", "")}"\n'
    else:
        chapters_yaml += f'  - time: "00:00:00"\n    title: "{ch}"\n'

def yaml_list(items):
    return ("\n" + "".join(f"  - {i}\n" for i in items)) if items else " []\n"

frontmatter = f"""---
episodeNumber: {ep_num}
title: "{title}"
date: "{ep_date}"
draft: {"true" if draft else "false"}
summary: "{summary}"
audioUrl: "{audio_url}"
audioSize: {audio_size if audio_size != "" else ""}
duration: "{duration}"
explicit: {"true" if explicit else "false"}
youtubeUrl: "{youtube_url}"
chapters:
{chapters_yaml}tags:{yaml_list(tags)}hosts:{yaml_list(hosts)}"""

if guests:
    guest_yaml = ""
    for g in guests:
        if isinstance(g, dict):
            guest_yaml += f'  - name: "{g.get("name", "")}"\n'
            if g.get("role"):
                guest_yaml += f'    role: "{g["role"]}"\n'
            if g.get("link"):
                guest_yaml += f'    link: "{g["link"]}"\n'
        else:
            guest_yaml += f'  - name: "{g}"\n'
    frontmatter += f"guests:\n{guest_yaml}"

if sponsors:
    sponsor_yaml = ""
    for s in sponsors:
        if isinstance(s, dict):
            sponsor_yaml += f'  - name: "{s.get("name", "")}"\n'
            if s.get("url"):
                sponsor_yaml += f'    url: "{s["url"]}"\n'
            if s.get("blurb"):
                sponsor_yaml += f'    blurb: "{s["blurb"]}"\n'
        else:
            sponsor_yaml += f'  - name: "{s}"\n'
    frontmatter += f"sponsors:\n{sponsor_yaml}"

frontmatter += "---\n"

body_parts = []

if cover_text.strip():
    body_parts.append("## What we cover\n\n" + cover_text.strip())

if links_raw.strip():
    link_lines = []
    for line in links_raw.splitlines():
        line = line.strip()
        if not line or line in ("\\", "*", "-"):
            continue
        line = re.sub(r"^[\*\-]\s*", "", line)
        line = re.sub(r"^<(.+)>$", r"\1", line)
        if line:
            link_lines.append(f"- {line}")
    if link_lines:
        body_parts.append("## Links\n\n" + "\n".join(link_lines))

if transcript_text.strip():
    body_parts.append("## Transcript\n\n" + transcript_text.strip())
else:
    body_parts.append("## Transcript\n\n<!-- transcript will be added by publish.sh -->")

body = "\n\n".join(body_parts) + "\n"

os.makedirs(episodes_dir, exist_ok=True)
with open(filepath, "w") as f:
    f.write(frontmatter)
    f.write("\n")
    f.write(body)

print(filepath)
PYEOF
  local status=$?
  rm -f "$cover_tmp" "$links_tmp" "$transcript_tmp"
  return $status
}

########################################
# FileBrowser Audio Fetch
########################################

fetch_audio_filebrowser() {
  header "Fetching production audio from FileBrowser"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local local_audio_dir="${script_dir}/${AUDIO_DIR}"

  local listing listing_tmp match
  listing=$(curl -sf "${FB_HOST}/api/resources/${FB_REMOTE_DIR}/" \
    -H "X-Auth: ${FB_TOKEN}") \
    || fatal "Could not list FileBrowser folder '${FB_REMOTE_DIR}'."

  listing_tmp=$(mktemp /tmp/fb-listing.XXXXXX.json)
  echo "$listing" > "$listing_tmp"

  match=$(python3 - "$EPISODE_NUM" "$listing_tmp" <<'PYEOF'
import json, sys, re

num       = sys.argv[1]
list_file = sys.argv[2]

with open(list_file) as f:
    data = json.load(f)

pattern = re.compile(rf"^bitflip-e0*{re.escape(num)}\.(wav|mp3)$", re.IGNORECASE)

for item in data.get("items", []):
    if not item.get("isDir", True) and pattern.match(item.get("name", "")):
        print(item["name"])
        sys.exit(0)

sys.stderr.write(f"No file matching bitflip-e*{num}.wav/mp3 found\n")
sys.exit(1)
PYEOF
  )
  rm -f "$listing_tmp"

  if [[ -z "$match" ]]; then
    fatal "No file matching 'bitflip-e*${EPISODE_NUM}.wav/mp3' found in '${FB_REMOTE_DIR}'."
  fi

  mkdir -p "$local_audio_dir"
  local local_file="${local_audio_dir}/${match}"

  log "Downloading: ${match} → ${local_file}"
  curl -sf "${FB_HOST}/api/raw/${FB_REMOTE_DIR}/${match}" \
    -H "X-Auth: ${FB_TOKEN}" \
    -o "$local_file" \
    || fatal "Failed to download '${match}' from FileBrowser."

  log "Production audio saved: ${local_file}"
  echo "$local_file"
}

########################################
# FileBrowser Raw Tracks Fetch
########################################

fetch_raw_tracks_filebrowser() {
  header "Fetching raw speaker tracks from FileBrowser"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local local_tracks_dir="${script_dir}/${AUDIO_DIR}/${EPISODE_NUM_PADDED}"

  local dir_listing dir_tmp raw_ep_dir
  dir_listing=$(curl -sf "${FB_HOST}/api/resources/${FB_RAW_DIR}/" \
    -H "X-Auth: ${FB_TOKEN}" 2>/dev/null) || {
    log "WARNING: could not list '${FB_RAW_DIR}/' on FileBrowser — skipping raw tracks."
    return 0
  }

  dir_tmp=$(mktemp /tmp/fb-rawdir.XXXXXX.json)
  echo "$dir_listing" > "$dir_tmp"

  raw_ep_dir=$(python3 - "$EPISODE_NUM" "$dir_tmp" <<'PYEOF'
import json, sys

num       = int(sys.argv[1])
list_file = sys.argv[2]

with open(list_file) as f:
    data = json.load(f)

for item in data.get("items", []):
    if item.get("isDir", False):
        try:
            if int(item["name"]) == num:
                print(item["name"])
                sys.exit(0)
        except (ValueError, KeyError):
            continue

sys.exit(1)
PYEOF
  ) || true
  rm -f "$dir_tmp"

  if [[ -z "$raw_ep_dir" ]]; then
    log "WARNING: no raw-files directory found for episode ${EPISODE_NUM} — skipping raw tracks."
    return 0
  fi

  log "Found raw-files directory: ${FB_RAW_DIR}/${raw_ep_dir}/"

  local track_listing track_tmp track_files
  track_listing=$(curl -sf "${FB_HOST}/api/resources/${FB_RAW_DIR}/${raw_ep_dir}/" \
    -H "X-Auth: ${FB_TOKEN}") \
    || { log "WARNING: could not list raw tracks directory — skipping."; return 0; }

  track_tmp=$(mktemp /tmp/fb-tracks.XXXXXX.json)
  echo "$track_listing" > "$track_tmp"

  track_files=$(python3 - "$track_tmp" <<'PYEOF'
import json, sys, re

list_file = sys.argv[1]

with open(list_file) as f:
    data = json.load(f)

pattern = re.compile(r"^\d+-\w+\.(wav|mp3)$", re.IGNORECASE)

for item in data.get("items", []):
    if not item.get("isDir", True) and pattern.match(item.get("name", "")):
        print(item["name"])
PYEOF
  )
  rm -f "$track_tmp"

  if [[ -z "$track_files" ]]; then
    log "WARNING: no track files found in ${FB_RAW_DIR}/${raw_ep_dir}/ — skipping raw tracks."
    return 0
  fi

  mkdir -p "$local_tracks_dir"

  local downloaded=0
  while IFS= read -r track_file; do
    local local_track="${local_tracks_dir}/${track_file}"
    log "Downloading track: ${track_file}"
    curl -sf "${FB_HOST}/api/raw/${FB_RAW_DIR}/${raw_ep_dir}/${track_file}" \
      -H "X-Auth: ${FB_TOKEN}" \
      -o "$local_track" \
      || { log "WARNING: failed to download '${track_file}' — skipping."; continue; }
    (( downloaded++ )) || true
  done <<< "$track_files"

  log "${downloaded} track(s) saved to: ${local_tracks_dir}/"
}

########################################
# R2 Audio Fetch (via rclone)
########################################

# List entries in a bucket path; one name per line, dirs and files.
# Prints nothing on failure (caller handles warnings).
r2_list_dir() {
  local path="$1"
  rclone lsjson "${R2_REMOTE}:${R2_BUCKET}/${path}" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    items = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)
for item in items:
    print(item.get('Name', ''))
" || true
}

# Find the episode subdirectory inside R2_BASE_DIR.
# Matches 'Episode 10', 'Episode 010', 'Episode 0010', etc.
r2_find_episode_dir() {
  local entries
  entries=$(r2_list_dir "$R2_BASE_DIR")

  if [[ -z "$entries" ]]; then
    echo ""
    return 0
  fi

  local entries_tmp
  entries_tmp=$(mktemp /tmp/r2-episodes.XXXXXX.txt)
  echo "$entries" > "$entries_tmp"

  python3 - "$EPISODE_NUM" "$entries_tmp" <<'PYEOF' || true
import sys, re

num = int(sys.argv[1])
with open(sys.argv[2]) as f:
    for line in f:
        name = line.strip()
        m = re.match(r"^Episode\s+(\d{1,4})$", name, re.IGNORECASE)
        if m and int(m.group(1)) == num:
            print(name)
            sys.exit(0)

sys.exit(1)
PYEOF

  rm -f "$entries_tmp"
}

fetch_audio_r2() {
  header "Fetching audio from R2"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local local_audio_dir="${script_dir}/${AUDIO_DIR}"
  local local_tracks_dir="${script_dir}/${AUDIO_DIR}/${EPISODE_NUM_PADDED}"

  # Find the episode subdirectory
  local ep_dir
  ep_dir=$(r2_find_episode_dir)

  if [[ -z "$ep_dir" ]]; then
    fatal "No episode directory found in '${R2_BASE_DIR}/' matching episode ${EPISODE_NUM}."
  fi

  log "Found episode directory: ${R2_BASE_DIR}/${ep_dir}"

  # Download main audio file — pick whatever audio file is in the full/ subfolder
  header "Fetching main audio from R2"

  local full_remote="${R2_BASE_DIR}/${ep_dir}/${R2_FULL_DIR}"
  local full_entries
  full_entries=$(r2_list_dir "$full_remote")

  if [[ -z "$full_entries" ]]; then
    fatal "No files found in '${full_remote}/' on R2."
  fi

  local entries_tmp audio_file_tmp
  entries_tmp=$(mktemp /tmp/r2-audio-entries.XXXXXX.txt)
  audio_file_tmp=$(mktemp /tmp/r2-audio-pick.XXXXXX.txt)
  echo "$full_entries" > "$entries_tmp"

  python3 - "$entries_tmp" "$audio_file_tmp" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    names = [l.strip() for l in f if l.strip()]
audio = [n for n in names if re.search(r'\.(wav|mp3)$', n, re.IGNORECASE)]
if not audio:
    sys.stderr.write("No .wav or .mp3 file found in full/ subfolder\n")
    sys.exit(1)
if len(audio) > 1:
    sys.stderr.write(f"WARNING: {len(audio)} audio files found — using '{audio[0]}'.\n")
with open(sys.argv[2], 'w') as f:
    f.write(audio[0])
PYEOF

  local audio_file
  audio_file=$(cat "$audio_file_tmp")
  rm -f "$entries_tmp" "$audio_file_tmp"

  if [[ -z "$audio_file" ]]; then
    fatal "No audio file (.wav or .mp3) found in '${full_remote}/'."
  fi

  local audio_ext
  audio_ext=$(python3 -c "import sys; print(sys.argv[1].rsplit('.', 1)[-1].lower())" "$audio_file")
  local audio_local="${local_audio_dir}/bitflip-e${EPISODE_NUM_PADDED}.${audio_ext}"

  mkdir -p "$local_audio_dir"

  log "Downloading: ${audio_file} → $(basename "$audio_local")"
  rclone copyto "${R2_REMOTE}:${R2_BUCKET}/${full_remote}/${audio_file}" "$audio_local" \
    || fatal "Failed to download '${audio_file}' from R2."

  log "Audio saved: ${audio_local}"

  # Download speaker tracks from the speakers/ subdirectory
  header "Fetching speaker tracks from R2"

  local tracks_remote="${R2_BASE_DIR}/${ep_dir}/${R2_SPEAKERS_DIR}"
  local track_files
  track_files=$(r2_list_dir "$tracks_remote")

  if [[ -z "$track_files" ]]; then
    log "WARNING: no files found in '${tracks_remote}/' — skipping speaker tracks."
  else
    mkdir -p "$local_tracks_dir"
    local downloaded=0
    local ep_prefix
    ep_prefix=$(printf "%03d" "$EPISODE_NUM")

    while IFS= read -r track_file; do
      [[ -z "$track_file" ]] && continue
      [[ "$track_file" =~ \.(wav|mp3|WAV|MP3)$ ]] || continue

      # Rename geoff.wav → 010-geoff.wav to match FileBrowser convention.
      # R2 filenames are sometimes just the speaker name ("Alex.wav") and
      # sometimes the full episode title ("Bitflip Ep 13 - Alex.wav") — in
      # the latter case, only the bit after the last " - " is the speaker.
      local renamed
      renamed=$(python3 -c "
import sys
name = sys.argv[1]
stem, ext = name.rsplit('.', 1)
speaker = stem.rsplit(' - ', 1)[-1].strip()
speaker = speaker.replace(' ', '')
print(sys.argv[2] + '-' + speaker.lower() + '.' + ext.lower())
" "$track_file" "$ep_prefix")

      log "Downloading track: ${track_file} → ${renamed}"
      rclone copyto "${R2_REMOTE}:${R2_BUCKET}/${tracks_remote}/${track_file}" \
        "${local_tracks_dir}/${renamed}" \
        || { log "WARNING: failed to download '${track_file}' — skipping."; continue; }
      (( downloaded++ )) || true
    done <<< "$track_files"

    log "${downloaded} track(s) saved to: ${local_tracks_dir}/"
  fi

  echo "$audio_local"
}

########################################
# Audio Source Dispatcher
########################################

fetch_audio() {
  case "$AUDIO_SOURCE" in
    filebrowser)
      fetch_audio_filebrowser
      fetch_raw_tracks_filebrowser
      ;;
    r2)
      fetch_audio_r2
      ;;
    *)
      fatal "Unknown AUDIO_SOURCE '${AUDIO_SOURCE}' — must be 'filebrowser' or 'r2'."
      ;;
  esac
}

########################################
# Main
########################################

main() {
  parse_args "$@"
  require curl
  require python3
  require git

  local branch="ep${EPISODE_NUM}"
  header "Switching to branch: ${branch}"
  if git show-ref --quiet "refs/heads/${branch}"; then
    log "Branch already exists — checking out"
    git checkout "$branch"
  else
    git checkout -b "$branch"
    log "Branch created"
  fi

  if [[ "$SKIP_AUDIO" == false ]]; then
    if [[ "$AUDIO_SOURCE" == "filebrowser" ]]; then
      load_fb_password
      fb_login
    elif [[ "$AUDIO_SOURCE" == "r2" ]]; then
      require rclone
      rclone listremotes 2>/dev/null | grep -qx "${R2_REMOTE}:" \
        || fatal "rclone remote '${R2_REMOTE}' not configured — run 'rclone config'."
    fi
  fi

  local episode_path=""
  if [[ "$SKIP_NOTES" == false ]]; then
    load_api_key

    local doc_id
    doc_id=$(find_episode_doc) \
      || fatal "No Outline doc found matching 'Episode ${EPISODE_NUM}'."

    local doc_content
    doc_content=$(fetch_doc "$doc_id")

    header "Parsing doc"

    local show_notes
    show_notes=$(extract_show_notes_section "$doc_content")
    if [[ -z "$show_notes" ]]; then
      fatal "No '# Show Notes' section found in the Outline doc."
    fi

    local fm_section fm_block fm_json
    fm_section=$(extract_section "$show_notes" "Episode Frontmatter")
    fm_block=$(extract_code_block "$fm_section") \
      || fatal "No fenced code block found under '## Episode Frontmatter'."
    fm_json=$(parse_yaml_to_json "$fm_block")
    log "Frontmatter parsed OK"

    local what_we_cover links transcript
    what_we_cover=$(extract_section "$show_notes" "What We Cover")
    links=$(extract_section "$show_notes" "Links")
    transcript=$(extract_section "$show_notes" "Transcript")

    header "Writing episode file"
    episode_path=$(build_episode_md "$fm_json" "$what_we_cover" "$links" "$transcript")
  fi

  local audio_path=""
  if [[ "$SKIP_AUDIO" == false ]]; then
    audio_path=$(fetch_audio)
  fi

  echo
  echo "Done."
  if [[ -n "$episode_path" ]]; then
    echo "Episode file: ${episode_path}"
  fi
  if [[ -n "$audio_path" ]]; then
    echo "Audio file:   ${audio_path}"
  fi
}

main "$@"