#!/usr/bin/env bash
# Encodes a distribution-ready MP3, embeds chapters, optionally transcribes
# with faster-whisper, uploads to R2, and patches the episode frontmatter.
#
# Usage:
#   ./publish.sh <episode-number> [options]          ← auto-resolves files
#   ./publish.sh <episode.md> <source-audio> [options]
#   ./publish.sh <episode.md> --generate-chapters [--force-chapters] [--dry-run]
#
# Options:
#   --dry-run             Show what would happen without making any changes
#   --cover <file>        Cover art image (default: public/images/podcast-cover-small.png)
#   --skip-encode         Use source audio as-is (must already be an MP3)
#   --skip-upload         Skip R2 upload; save MP3 locally instead
#   --output <file>       Local path for saved MP3 (used with --skip-upload)
#   --transcribe          Transcribe with faster-whisper and generate chapters via Claude
#   --no-chapters         Transcribe but skip Claude chapter generation
#   --generate-chapters   Generate chapters from existing ## Transcript in the episode file
#   --force-chapters      Overwrite existing frontmatter chapters without prompting
#   --open-pr             Commit episode file, push branch, and open a GitHub PR
#
# Pipeline (full run):
#   encode → transcribe → append transcript → generate chapters → embed chapters → upload → patch frontmatter
#
# Requirements:
#   ffmpeg, ffprobe, rclone, curl, python3

set -Eeuo pipefail

########################################
# Configuration
########################################

R2_REMOTE="r2"
R2_BUCKET="bitflip-audio"
PUBLIC_AUDIO_URL="https://audio.bitflip.show"

DEFAULT_COVER="public/images/podcast-cover-small.png"
MP3_BITRATE="128k"
MP3_CHANNELS="2"

WHISPER_VENV="~/.local/share/bitflip/venv"
WHISPER_MODEL="large-v3-turbo"
WHISPER_LANG="en"
WHISPER_DIARIZE=true
WHISPER_HF_TOKEN_FILE="~/.config/bitflip/hf_token"

ANTHROPIC_API_KEY_FILE="~/.config/bitflip/anthropic_api_key"
CLAUDE_MODEL="claude-sonnet-4-6"

# Directories used for auto-resolution when an episode number is given
EPISODES_DIR="episodes"
AUDIO_DIR="audio"

# GitHub — used for opening pull requests with --open-pr
GITHUB_TOKEN_FILE="~/.config/bitflip/github_token"   # One line: a token with repo scope
GITHUB_REPO="bitflipshow/bitflip-site"              # owner/repo

########################################
# Globals
########################################

MD_FILE=""
SOURCE_AUDIO=""
COVER_ART=""

DRY_RUN=false
SKIP_ENCODE=false
SKIP_UPLOAD=false
SKIP_CHAPTERS=false
DO_TRANSCRIBE=false
DO_GENERATE_CHAPTERS=false
FORCE_CHAPTERS=false
OPEN_PR=false
OUTPUT_FILE=""

EPISODE_NUM=""
EPISODE_TITLE=""
EPISODE_DATE=""
EPISODE_NUM_PADDED=""
EPISODE_SPEAKERS=""

MP3_TEMP=""
MP3_FILENAME=""

AUDIO_SIZE=""
AUDIO_URL=""
DURATION=""

HF_TOKEN=""
ANTHROPIC_API_KEY=""
GITHUB_TOKEN=""
TRANSCRIPT_FILE=""

CLEANUP_FILES=()

########################################
# Utility
########################################

cleanup() {
  [[ "${#CLEANUP_FILES[@]}" -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT

log() { echo "  $*"; }
header() { echo; echo ">> $*"; }
fatal() { echo "Error: $*" >&2; exit 1; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fatal "Required command missing: $1"
  fi
}

retry() {
  local attempts="$1" delay="$2"
  shift 2
  local i
  for (( i = 1; i <= attempts; i++ )); do
    "$@" && return 0
    if (( i < attempts )); then
      log "Attempt ${i}/${attempts} failed — retrying in ${delay}s..."
      sleep "$delay"
    fi
  done
  return 1
}

########################################
# Episode File Resolution
########################################

# Called when a bare episode number is given instead of explicit file paths.
# Searches EPISODES_DIR and AUDIO_DIR and sets MD_FILE and SOURCE_AUDIO.
resolve_episode_files() {
  local num="$1"
  local padded
  padded=$(printf "%04d" "$(( 10#$num ))")

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Find episode markdown: episodes/0003.md
  local md="${script_dir}/${EPISODES_DIR}/${padded}.md"
  if [[ ! -f "$md" ]]; then
    fatal "Episode file not found: ${md}"
  fi
  MD_FILE="$md"

  # Find audio: audio/bitflip-e*3.mp3 — accepts any zero-padding
  local audio_match=""
  local pattern
  # Build a glob pattern: bitflip-e*<num>.mp3 — then confirm with regex
  while IFS= read -r -d '' candidate; do
    local basename
    basename=$(basename "$candidate")
    if [[ "$basename" =~ ^bitflip-e0*${num}\.mp3$ ]]; then
      audio_match="$candidate"
      break
    fi
  done < <(find "${script_dir}/${AUDIO_DIR}" -maxdepth 1 -name "bitflip-e*.mp3" -print0 2>/dev/null | sort -z)

  if [[ -z "$audio_match" ]]; then
    fatal "Audio file not found in ${AUDIO_DIR}/ matching bitflip-e*${num}.mp3"
  fi
  SOURCE_AUDIO="$audio_match"

  log "Resolved episode: ${MD_FILE}"
  log "Resolved audio:   ${SOURCE_AUDIO}"
}

########################################
# Argument Parsing
########################################

usage() {
  echo "Usage: $0 <episode-number> [options]"
  echo "       $0 <episode.md> <source-audio> [options]"
  echo "       $0 <episode.md> --generate-chapters [--force-chapters] [--dry-run]"
  echo "Options:"
  echo "  --dry-run             Show what would happen without making changes"
  echo "  --cover <file>        Cover art image (default: $DEFAULT_COVER)"
  echo "  --skip-encode         Use source audio as-is (must already be MP3)"
  echo "  --skip-upload         Skip R2 upload"
  echo "  --output <file>       Save final MP3 to this path (implied by --skip-upload)"
  echo "  --transcribe          Transcribe and embed in episode markdown; generates chapters via Claude"
  echo "  --no-chapters         Transcribe but skip Claude chapter generation"
  echo "  --generate-chapters   Generate chapters from existing transcript in the episode markdown"
  echo "  --force-chapters      Overwrite existing frontmatter chapters without prompting"
  echo "  --open-pr             Commit episode file, push branch, and open a GitHub PR"
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --skip-encode) SKIP_ENCODE=true ;;
      --skip-upload) SKIP_UPLOAD=true ;;
      --transcribe) DO_TRANSCRIBE=true ;;
      --no-chapters) SKIP_CHAPTERS=true ;;
      --generate-chapters) DO_GENERATE_CHAPTERS=true ;;
      --force-chapters) FORCE_CHAPTERS=true ;;
      --open-pr) OPEN_PR=true ;;
      --cover) COVER_ART="$2"; shift ;;
      --output) OUTPUT_FILE="$2"; shift ;;
      -*) usage ;;
      *)
        if [[ -z "$MD_FILE" ]]; then
          # Bare integer → auto-resolve episode files
          if [[ "$1" =~ ^[0-9]+$ ]]; then
            resolve_episode_files "$1"
          else
            MD_FILE="$1"
          fi
        elif [[ -z "$SOURCE_AUDIO" ]]; then
          SOURCE_AUDIO="$1"
        else
          usage
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$MD_FILE" ]]; then
    usage
  fi

  if [[ ! -f "$MD_FILE" ]]; then
    echo "Error: episode file not found: $MD_FILE" >&2; exit 1
  fi

  # SOURCE_AUDIO is not required when only generating chapters from an existing transcript
  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false && -z "$SOURCE_AUDIO" ]]; then
    SKIP_ENCODE=true
    SKIP_UPLOAD=true
    SOURCE_AUDIO="/dev/null"
  fi

  if [[ -z "$SOURCE_AUDIO" ]]; then
    usage
  fi

  if [[ "$SOURCE_AUDIO" != "/dev/null" && ! -f "$SOURCE_AUDIO" ]]; then
    echo "Error: audio file not found: $SOURCE_AUDIO" >&2; exit 1
  fi
}

########################################
# Dependency Checks
########################################

check_dependencies() {
  require ffmpeg
  require ffprobe

  if [[ "$SKIP_UPLOAD" == false ]]; then
    require rclone
  fi

  if [[ "$DO_TRANSCRIBE" == true || "$DO_GENERATE_CHAPTERS" == true ]]; then
    require python3
    require curl
  fi

  if [[ "$OPEN_PR" == true ]]; then
    require curl
    require git
  fi
}

########################################
# HF Token
########################################

load_hf_token() {
  local token_file="${WHISPER_HF_TOKEN_FILE/#\~/$HOME}"

  if [[ -f "$token_file" ]]; then
    HF_TOKEN=$(tr -d '[:space:]' < "$token_file")
  fi

  if [[ "$WHISPER_DIARIZE" == true && -z "$HF_TOKEN" ]]; then
    log "WARNING: WHISPER_DIARIZE=true but no HF token found at $token_file"
    log "         Diarization will be skipped."
  fi
}

########################################
# Anthropic API Key
########################################

load_anthropic_api_key() {
  local key_file="${ANTHROPIC_API_KEY_FILE/#\~/$HOME}"

  if [[ -f "$key_file" ]]; then
    ANTHROPIC_API_KEY=$(tr -d '[:space:]' < "$key_file")
  else
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
  fi

  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log "WARNING: No Anthropic API key found at $key_file and ANTHROPIC_API_KEY is not set."
    log "         Chapter generation will be skipped."
  fi
}

########################################
# Markdown Frontmatter Helpers
########################################

sed_inplace() {
  sed -i.bak -e "$1" "$2"
  rm -f "$2.bak"
}

fm_get() {
  local key="$1"
  awk -v key="$key" '
    /^---$/ {delim++; next}
    delim==2 {exit}
    delim==1 && $0 ~ "^"key":" {
      sub("^"key":[[:space:]]*",""); gsub(/^"|"$/,""); print; exit
    }
  ' "$MD_FILE"
}

fm_count_array() {
  local key="$1"
  awk -v key="$key" '
    /^---$/ { delim++; next }
    delim==2 { exit }
    delim==1 {
      if ($0 ~ "^"key":") { in_block=1; next }
      if (in_block && $0 ~ /^[[:space:]]*-/) { count++ }
      if (in_block && $0 ~ /^[^[:space:]-]/) { in_block=0 }
    }
    END { print count+0 }
  ' "$MD_FILE"
}

fm_set() {
  local key="$1" value="$2"

  if grep -q "^${key}:" "$MD_FILE"; then
    sed_inplace "s|^${key}:.*|${key}: ${value}|" "$MD_FILE"
  else
    local tmp
    tmp=$(mktemp)
    awk -v key="$key" -v value="$value" '
      /^---$/ && NR > 1 && !inserted {
        print key ": " value
        inserted = 1
      }
      { print }
    ' "$MD_FILE" > "$tmp"
    mv "$tmp" "$MD_FILE"
  fi
}

fm_has_chapters() {
  awk '
    /^---$/ {delim++; next}
    delim==2 {exit}
    delim==1 && /^chapters:/ {found=1; exit}
    END {exit !found}
  ' "$MD_FILE"
}

fm_set_chapters() {
  local chapters_file="$1"
  local tmp block
  tmp=$(mktemp)
  block=$(cat "$chapters_file")

  awk -v block="$block" '
    /^---$/ { delim++ }
    delim == 1 && !done {
      if (/^chapters:/) {
        in_chapters = 1
        print block
        next
      }
      if (in_chapters) {
        if (/^[a-zA-Z]/) {
          in_chapters = 0
          done = 1
        } else {
          next
        }
      }
    }
    { print }
  ' "$MD_FILE" > "$tmp"

  if ! grep -q "^chapters:" "$tmp"; then
    awk -v block="$block" '
      /^---$/ && NR > 1 && !inserted {
        print block
        inserted = 1
      }
      { print }
    ' "$tmp" > "${tmp}.2"
    mv "${tmp}.2" "$tmp"
  fi

  mv "$tmp" "$MD_FILE"
}

########################################
# Metadata
########################################

read_metadata() {
  header "Reading metadata"

  EPISODE_NUM=$(fm_get "episodeNumber")
  EPISODE_TITLE=$(fm_get "title")
  EPISODE_DATE=$(fm_get "date")

  local host_count guest_count
  host_count=$(fm_count_array "hosts")
  guest_count=$(fm_count_array "guests")
  EPISODE_SPEAKERS=$(( host_count + guest_count ))
  if [[ "$EPISODE_SPEAKERS" -eq 0 ]]; then
    EPISODE_SPEAKERS=""
  fi

  if [[ -z "$EPISODE_NUM" ]]; then fatal "episodeNumber missing"; fi
  if [[ ! "$EPISODE_NUM" =~ ^[0-9]+$ ]]; then fatal "episodeNumber must be numeric"; fi
  if [[ -z "$EPISODE_DATE" ]]; then fatal "date missing from frontmatter"; fi

  EPISODE_NUM_PADDED=$(printf "%04d" "$EPISODE_NUM")
  MP3_FILENAME="${EPISODE_DATE}-bitflip-e${EPISODE_NUM_PADDED}.mp3"

  log "Episode: #${EPISODE_NUM} - ${EPISODE_TITLE}"
}

########################################
# Encoding
########################################

encode_audio() {
  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    return
  fi

  header "Encoding MP3"

  MP3_TEMP=$(mktemp /tmp/bitflip-encoded.XXXXXX.mp3)
  CLEANUP_FILES+=("$MP3_TEMP")

  if [[ "$SKIP_ENCODE" == true ]]; then
    log "Skipping encode"
    if [[ "$DRY_RUN" == false ]]; then
      ffprobe -v error "$SOURCE_AUDIO" >/dev/null 2>&1 \
        || fatal "Source audio is not a valid media file: $SOURCE_AUDIO"
      cp "$SOURCE_AUDIO" "$MP3_TEMP"
    fi
    return
  fi

  local cover_args=()
  if [[ -f "$COVER_ART" ]]; then
    cover_args=(-i "$COVER_ART" -map 0:a -map 1:v -c:v mjpeg -pix_fmt yuvj420p)
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] ffmpeg encode"
    return
  fi

  ffmpeg -y -loglevel warning -hide_banner \
    -i "$SOURCE_AUDIO" "${cover_args[@]}" \
    -c:a libmp3lame \
    -b:a "$MP3_BITRATE" \
    -ac "$MP3_CHANNELS" \
    -id3v2_version 3 \
    -metadata title="$EPISODE_TITLE" \
    "$MP3_TEMP" 2>&1 | grep -v "^\[swscaler\|Last message repeated" || true

  log "Encoding complete"
}

########################################
# Transcription
########################################

run_transcription() {
  if [[ "$DO_TRANSCRIBE" == false ]]; then return; fi

  header "Transcribing (local, model: ${WHISPER_MODEL})"

  TRANSCRIPT_FILE=$(mktemp /tmp/transcript.XXXXXX.md)
  CLEANUP_FILES+=("$TRANSCRIPT_FILE")

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] whisper transcription"
    return
  fi

  local venv
  venv="${WHISPER_VENV/#\~/$HOME}"

  if [[ ! -f "$venv/bin/python" ]]; then
    log "Creating venv: $venv"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q whisperx
    "$venv/bin/pip" uninstall -q -y torchcodec 2>/dev/null || true
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  WHISPER_DIARIZE="$WHISPER_DIARIZE" \
  HF_TOKEN="$HF_TOKEN" \
  WHISPER_SPEAKERS="$EPISODE_SPEAKERS" \
    "$venv/bin/python" "$script_dir/scripts/transcribe.py" \
      "$MP3_TEMP" \
      "$TRANSCRIPT_FILE" \
      "$WHISPER_MODEL" \
      "$WHISPER_LANG"
}

append_transcript() {
  if [[ "$DO_TRANSCRIBE" == false || -z "$TRANSCRIPT_FILE" ]]; then return; fi
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] append transcript to ${MD_FILE}"
    return
  fi

  header "Appending transcript"

  local tmp
  tmp=$(mktemp)
  awk '/^## [Tt]ranscript/{exit} {print}' "$MD_FILE" > "$tmp"
  echo >> "$tmp"
  echo "## Transcript" >> "$tmp"
  echo >> "$tmp"
  cat "$TRANSCRIPT_FILE" >> "$tmp"
  mv "$tmp" "$MD_FILE"

  log "Transcript appended"
}

extract_transcript_from_md() {
  header "Extracting transcript from episode file"

  local tmp
  tmp=$(mktemp /tmp/transcript.XXXXXX.md)
  CLEANUP_FILES+=("$tmp")

  awk '/^## [Tt]ranscript/{found=1; next} found{print}' "$MD_FILE" > "$tmp"

  if [[ ! -s "$tmp" ]]; then
    fatal "No ## Transcript section found in ${MD_FILE} — cannot generate chapters."
  fi

  local line_count
  line_count=$(wc -l < "$tmp")
  log "Transcript extracted (${line_count} lines)"

  TRANSCRIPT_FILE="$tmp"
}

########################################
# Chapter Generation (Claude)
########################################

generate_chapters_from_transcript() {
  if [[ "$DO_TRANSCRIBE" == false && "$DO_GENERATE_CHAPTERS" == false ]]; then return; fi
  if [[ "$SKIP_CHAPTERS" == true ]]; then return; fi

  header "Generating chapters with Claude"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Claude chapter generation"
    return
  fi

  if fm_has_chapters; then
    if [[ "$FORCE_CHAPTERS" == true ]]; then
      log "Overwriting existing chapters (--force-chapters)"
    else
      echo
      echo "  WARNING: frontmatter already contains a chapters: block."
      printf "  Overwrite with Claude-generated chapters? [y/N] "
      local answer
      read -r answer
      if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log "Skipping chapter generation."
        return
      fi
    fi
  fi

  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log "WARNING: Anthropic API key not available — skipping chapter generation."
    log "         Add your key to ${ANTHROPIC_API_KEY_FILE} or set ANTHROPIC_API_KEY in the environment."
    return
  fi

  if [[ -z "$TRANSCRIPT_FILE" || ! -f "$TRANSCRIPT_FILE" ]]; then
    log "WARNING: transcript file not found — skipping chapter generation."
    return
  fi

  local MAX_TRANSCRIPT_CHARS=120000
  local transcript_size
  transcript_size=$(wc -c < "$TRANSCRIPT_FILE")

  local transcript_content
  if (( transcript_size > MAX_TRANSCRIPT_CHARS )); then
    log "WARNING: transcript is ${transcript_size} chars — truncating to ${MAX_TRANSCRIPT_CHARS} for Claude."
    transcript_content=$(head -c "$MAX_TRANSCRIPT_CHARS" "$TRANSCRIPT_FILE")
  else
    transcript_content=$(cat "$TRANSCRIPT_FILE")
  fi

  local prompt
  prompt="You are a podcast editor. Given the transcript below, identify 8–16 meaningful chapter
break points. For each chapter, output a YAML list item in exactly this format (no extra text,
no markdown fences, no commentary — raw YAML only):

  - time: \"HH:MM:SS\"
    title: \"Chapter title\"

Rules:
- Times MUST use exactly three colon-separated components: hours, minutes, seconds — all zero-padded to two digits.
  CORRECT:   00:00:00  00:03:45  01:02:33
  INCORRECT: 0:00  3:45  1:02:33  (two-component MM:SS format is not allowed)
- The first chapter must always start at 00:00:00.
- Titles should be concise (3–7 words), sentence-case, no trailing punctuation.
- Base break points on genuine topic shifts, not arbitrary intervals.
- Output ONLY the YAML list items — nothing before or after.

Transcript:
${transcript_content}"

  log "Calling Claude API (${CLAUDE_MODEL})..."

  local payload_file response_file
  payload_file=$(mktemp /tmp/bitflip-claude-payload.XXXXXX.json)
  response_file=$(mktemp /tmp/bitflip-claude-response.XXXXXX.json)
  CLEANUP_FILES+=("$payload_file" "$response_file")

  python3 - "$CLAUDE_MODEL" "$prompt" "$payload_file" <<'PYEOF'
import json, sys
model, prompt, out = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "model": model,
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": prompt}],
}
with open(out, "w") as f:
    json.dump(payload, f)
PYEOF

  local http_status
  http_status=$(retry 3 5 curl -s -o "$response_file" -w "%{http_code}" \
    https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d @"$payload_file")

  if [[ "$http_status" != "200" ]]; then
    log "WARNING: Claude API returned HTTP ${http_status} — skipping chapter generation."
    log "         Response: $(cat "$response_file")"
    return
  fi

  if ! grep -q '"content"' "$response_file"; then
    log "WARNING: Claude response missing 'content' field — skipping chapter generation."
    log "         Response: $(cat "$response_file")"
    return
  fi

  local raw_yaml
  raw_yaml=$(python3 -c "
import json, sys
with open('${response_file}') as f:
    data = json.load(f)
text = data.get('content', [{}])[0].get('text', '')
print(text, end='')
")

  if [[ -z "$raw_yaml" ]]; then
    log "WARNING: Claude returned an empty response — skipping chapter generation."
    return
  fi

  local invalid_lines
  invalid_lines=$(echo "$raw_yaml" | grep -v '^\s*$' \
    | grep -v '^\s*-\s*$' \
    | grep -v '^\s*- time:' \
    | grep -v '^\s*title:' \
    | grep -v '^\s*time:' \
    || true)

  if [[ -n "$invalid_lines" ]]; then
    log "WARNING: Claude response contains unexpected lines — skipping to avoid corrupting frontmatter."
    log "         Unexpected: ${invalid_lines}"
    return
  fi

  local chapters_block_file
  chapters_block_file=$(mktemp /tmp/bitflip-chapters-yaml.XXXXXX.txt)
  CLEANUP_FILES+=("$chapters_block_file")

  {
    echo "chapters:"
    echo "$raw_yaml"
  } > "$chapters_block_file"

  fm_set_chapters "$chapters_block_file"

  local chapter_count
  chapter_count=$(echo "$raw_yaml" | grep -c '^\s*- time:' || true)
  log "${chapter_count} chapters written to frontmatter"
}

########################################
# Chapters (embed into MP3)
########################################

ts_to_ms() {
  local ts="$1"
  local h=0 m=0 s=0
  IFS=: read -r -a parts <<< "$ts"
  case "${#parts[@]}" in
    3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
    2) m="${parts[0]}"; s="${parts[1]}" ;;
    *) fatal "Unrecognised chapter timestamp: $ts" ;;
  esac
  h=$(( 10#$h ))
  m=$(( 10#$m ))
  s=$(( 10#$s ))
  if (( m > 59 || s > 59 )); then
    fatal "Chapter timestamp out of range: $ts (parsed as h=${h} m=${m} s=${s})"
  fi
  echo $(( (h * 3600 + m * 60 + s) * 1000 ))
}

embed_chapters() {
  header "Embedding chapters"

  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    log "Skipping chapter embedding (no audio file — chapters written to frontmatter only)"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] chapter embedding"
    return
  fi

  local chapter_times=()
  local chapter_titles=()
  local in_chapters=0 current_time="" current_title=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^chapters: ]]; then
      in_chapters=1
      continue
    fi
    if [[ $in_chapters -eq 1 && "$line" =~ ^[a-zA-Z] ]]; then
      break
    fi
    if [[ $in_chapters -eq 1 ]]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*time:[[:space:]]*\"?([0-9:]+)\"? ]]; then
        current_time="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+title:[[:space:]]*\"?(.+)\"?$ ]]; then
        current_title="${BASH_REMATCH[1]}"
        current_title="${current_title%\"}"
      fi
      if [[ -n "$current_time" && -n "$current_title" ]]; then
        chapter_times+=("$current_time")
        chapter_titles+=("$current_title")
        current_time=""
        current_title=""
      fi
    fi
  done < <(awk '/^---$/{d++; next} d==1{print} d==2{exit}' "$MD_FILE")

  if [[ "${#chapter_times[@]}" -eq 0 ]]; then
    log "No chapters found in frontmatter — skipping chapter embedding"
    return
  fi

  log "${#chapter_times[@]} chapters found"

  local total_ms
  total_ms=$(ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$MP3_TEMP" | \
    awk '{printf "%d", $1 * 1000}')

  local meta_file
  meta_file=$(mktemp /tmp/bitflip-chapters.XXXXXX.txt)
  CLEANUP_FILES+=("$meta_file")

  echo ";FFMETADATA1" > "$meta_file"

  local i
  for i in "${!chapter_times[@]}"; do
    local start_ms end_ms
    start_ms=$(ts_to_ms "${chapter_times[$i]}")
    if [[ $(( i + 1 )) -lt "${#chapter_times[@]}" ]]; then
      end_ms=$(ts_to_ms "${chapter_times[$(( i + 1 ))]}")
    else
      end_ms="$total_ms"
    fi
    printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%d\nEND=%d\ntitle=%s\n\n' \
      "$start_ms" "$end_ms" "${chapter_titles[$i]}" >> "$meta_file"
  done

  local chaptered
  chaptered=$(mktemp /tmp/bitflip-chaptered.XXXXXX.mp3)
  CLEANUP_FILES+=("$chaptered")

  ffmpeg -y -loglevel warning \
    -i "$MP3_TEMP" \
    -i "$meta_file" \
    -map_metadata 1 \
    -map 0 \
    -c copy \
    "$chaptered"

  mv "$chaptered" "$MP3_TEMP"
  for i in "${!CLEANUP_FILES[@]}"; do
    [[ "${CLEANUP_FILES[$i]}" == "$chaptered" ]] && unset 'CLEANUP_FILES[$i]'
  done

  log "Chapters embedded"
}

########################################
# Metadata Extraction
########################################

extract_audio_metadata() {
  header "Reading duration and file size"

  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    log "Skipping (no audio file)"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] ffprobe"
    return
  fi

  DURATION=$(ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$MP3_TEMP" |
    awk '{h=int($1/3600);m=int(($1%3600)/60);s=int($1%60); if(h>0) printf "%d:%02d:%02d",h,m,s; else printf "%d:%02d",m,s}')

  if stat --version >/dev/null 2>&1; then
    AUDIO_SIZE=$(stat -c%s "$MP3_TEMP")
  else
    AUDIO_SIZE=$(stat -f%z "$MP3_TEMP")
  fi

  AUDIO_URL="${PUBLIC_AUDIO_URL}/${MP3_FILENAME}"

  log "Duration: $DURATION"
  log "Size: $AUDIO_SIZE"
}

########################################
# Upload
########################################

upload_audio() {
  header "Uploading to R2"

  if [[ "$SKIP_UPLOAD" == true ]]; then
    local dest="${OUTPUT_FILE:-${AUDIO_DIR}/${MP3_FILENAME}}"
    if [[ "$DRY_RUN" == false ]]; then
      cp "$MP3_TEMP" "$dest"
      log "Saved to: $dest"
    else
      log "[dry-run] would save to: $dest"
    fi
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] rclone upload"
    return
  fi

  retry 3 5 rclone copyto "$MP3_TEMP" \
    "${R2_REMOTE}:${R2_BUCKET}/${MP3_FILENAME}"

  log "Upload complete"
}

########################################
# Frontmatter Patch
########################################

patch_frontmatter() {
  header "Updating frontmatter"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] patch frontmatter"
    return
  fi

  if [[ -z "$AUDIO_URL" || -z "$AUDIO_SIZE" || -z "$DURATION" ]]; then
    log "Skipping frontmatter patch (audio metadata not available)"
    return
  fi

  fm_set "audioUrl" "\"${AUDIO_URL}\""
  fm_set "audioSize" "$AUDIO_SIZE"
  fm_set "duration" "\"${DURATION}\""
}

########################################
# GitHub PR
########################################

load_github_token() {
  local token_file="${GITHUB_TOKEN_FILE/#\~/$HOME}"

  if [[ -f "$token_file" ]]; then
    GITHUB_TOKEN=$(tr -d '[:space:]' < "$token_file")
  else
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"
  fi

  if [[ -z "$GITHUB_TOKEN" ]]; then
    fatal "No GitHub token found at $token_file. Create a fine-grained token with Contents and Pull Requests permissions (read/write) at https://github.com/settings/tokens"
  fi
}

open_pull_request() {
  if [[ "$OPEN_PR" == false ]]; then return; fi

  header "Opening GitHub PR"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] git commit + push + open PR"
    return
  fi

  # Determine the current branch — this should be the episode branch (e.g. ep3)
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)

  if [[ "$branch" == "main" || "$branch" == "master" ]]; then
    log "WARNING: currently on ${branch} — skipping PR (run from an episode branch)"
    return
  fi

  # Stage and commit only the episode markdown file
  git add "$MD_FILE"

  # Check if there's anything to commit
  if git diff --cached --quiet; then
    log "No changes to commit in ${MD_FILE}"
  else
    git commit -m "publish episode ${EPISODE_NUM}"
    log "Committed: ${MD_FILE}"
  fi

  # Push the branch
  git push -u origin "$branch"
  log "Pushed branch: ${branch}"

  # Build PR body from episode metadata
  local pr_body
  pr_body="## Episode ${EPISODE_NUM} — ${EPISODE_TITLE}

**Air Date:** ${EPISODE_DATE}

---
_Opened automatically via publication script_"

  # Call GitHub API to open the PR
  local payload_file response_file
  payload_file=$(mktemp /tmp/bitflip-github-payload.XXXXXX.json)
  response_file=$(mktemp /tmp/bitflip-github-response.XXXXXX.json)
  CLEANUP_FILES+=("$payload_file" "$response_file")

  python3 - "$branch" "$EPISODE_NUM" "$pr_body" "$payload_file" <<'PYEOF'
import json, sys
branch, num, body, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = {
    "title": f"Episode {num} Release",
    "head": branch,
    "base": "main",
    "body": body,
}
with open(out, "w") as f:
    json.dump(payload, f)
PYEOF

  local http_status
  http_status=$(curl -s -o "$response_file" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d @"$payload_file" \
    "https://api.github.com/repos/${GITHUB_REPO}/pulls")

  if [[ "$http_status" != "201" ]]; then
    log "WARNING: GitHub API returned HTTP ${http_status} — PR not opened."
    log "         Response: $(cat "$response_file")"
    return
  fi

  local pr_url
  pr_url=$(python3 -c "
import json, sys
with open('${response_file}') as f:
    data = json.load(f)
print(data.get('html_url', ''))
")

  log "PR opened: ${pr_url}"
  echo "  PR:        ${pr_url}"
}

########################################
# Main Pipeline
########################################

main() {
  parse_args "$@"

  COVER_ART="${COVER_ART:-$DEFAULT_COVER}"

  check_dependencies
  if [[ "$DO_TRANSCRIBE" == true ]]; then
    load_hf_token
  fi
  if [[ ("$DO_TRANSCRIBE" == true && "$SKIP_CHAPTERS" == false) || "$DO_GENERATE_CHAPTERS" == true ]]; then
    load_anthropic_api_key
  fi
  if [[ "$OPEN_PR" == true ]]; then
    load_github_token
  fi

  read_metadata

  encode_audio
  run_transcription
  append_transcript

  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    extract_transcript_from_md
  fi

  generate_chapters_from_transcript
  embed_chapters
  extract_audio_metadata
  upload_audio
  patch_frontmatter
  open_pull_request

  echo

  if [[ "$DRY_RUN" == true ]]; then
    echo "Done (dry run)"
  elif [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    echo "Done."
    echo "Chapters written to: ${MD_FILE}"
  elif [[ "$SKIP_UPLOAD" == true ]]; then
    local dest="${OUTPUT_FILE:-${AUDIO_DIR}/${MP3_FILENAME}}"
    echo "Done."
    echo "Saved to: ${dest}"
  else
    echo "Done."
    echo "Episode URL: ${PUBLIC_AUDIO_URL}/${MP3_FILENAME}"
  fi
}

main "$@"