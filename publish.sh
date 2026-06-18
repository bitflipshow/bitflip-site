#!/usr/bin/env bash
# Encodes a distribution-ready MP3, embeds chapters, transcribes via WhisperX
# API, uploads to R2, and patches the episode frontmatter.
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
#   --transcribe          Transcribe via WhisperX API and generate chapters via Claude
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

WHISPER_API_URL="localhost:8200"
WHISPER_API_KEY="" # optional
WHISPER_MODEL="large-v3-turbo"
WHISPER_LANG="en"

ANTHROPIC_API_KEY_FILE="~/.config/bitflip/anthropic_api_key"
CLAUDE_MODEL="claude-sonnet-4-6"
SKIP_CLAUDE_FIX=false

# Directories used for auto-resolution when an episode number is given
EPISODES_DIR="episodes"
AUDIO_DIR="audio"

# GitHub — used for opening pull requests with --open-pr
GITHUB_TOKEN_FILE="~/.config/bitflip/github_token"   # One line: a token with repo scope
GITHUB_REPO="bitflipshow/bitflip-site"               # owner/repo

# FileBrowser
FB_HOST="http://100.104.240.5:8080"
FB_USER="production"
FB_PASS_FILE="~/.config/bitflip/fb_password"
FB_DEST_DIR="bitflip-episodes"

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

ANTHROPIC_API_KEY=""
GITHUB_TOKEN=""
TRANSCRIPT_FILE=""
FB_TOKEN=""

CLEANUP_FILES=()

########################################
# Utility
########################################

cleanup() {
  [[ "${#CLEANUP_FILES[@]}" -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}" 2>/dev/null || true
}
interrupted() {
  echo "" >&2
  echo "Interrupted." >&2
  exit 130
}
trap cleanup EXIT
trap interrupted INT TERM

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

resolve_episode_files() {
  local num="$1"
  local padded
  padded=$(printf "%04d" "$(( 10#$num ))")

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local md="${script_dir}/${EPISODES_DIR}/${padded}.md"
  if [[ ! -f "$md" ]]; then
    fatal "Episode file not found: ${md}"
  fi
  MD_FILE="$md"

  # Prefer MP3 over WAV when both exist
  local audio_match=""
  local wav_match=""
  while IFS= read -r -d '' candidate; do
    local bname ext corename epnum
    bname=$(basename "$candidate")
    ext="${bname##*.}"
    corename="${bname#*bitflip-e}"
    epnum="${corename%%.*}"
    if [[ "$epnum" =~ ^[0-9]+$ ]] && [[ "$((10#$epnum))" -eq "$((10#$num))" ]]; then
      if [[ "$ext" == "mp3" ]]; then
        audio_match="$candidate"
        break
      elif [[ "$ext" == "wav" && -z "$wav_match" ]]; then
        wav_match="$candidate"
      fi
    fi
  done < <(find "${script_dir}/${AUDIO_DIR}" -maxdepth 1 \( -name "*.wav" -o -name "*.mp3" \) -print0 2>/dev/null | sort -z)

  # Fall back to WAV if no MP3 found
  audio_match="${audio_match:-$wav_match}"

  if [[ -z "$audio_match" ]]; then
    fatal "Audio file not found in ${AUDIO_DIR}/ matching bitflip-e*${num}.wav/mp3"
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
  echo "  --transcribe          Transcribe via WhisperX API; generates chapters via Claude"
  echo "  --no-chapters         Transcribe but skip Claude chapter generation"
  echo "  --no-claude-fix       Skip Claude transcript correction step"
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
      --no-claude-fix) SKIP_CLAUDE_FIX=true ;;
      --open-pr) OPEN_PR=true ;;
      --cover) COVER_ART="$2"; shift ;;
      --output) OUTPUT_FILE="$2"; shift ;;
      -*) usage ;;
      *)
        if [[ -z "$MD_FILE" ]]; then
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

  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    SKIP_ENCODE=true
    SKIP_UPLOAD=true
    if [[ -z "$SOURCE_AUDIO" ]]; then
      SOURCE_AUDIO="/dev/null"
    fi
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
  require curl
  require python3

  if [[ "$SKIP_UPLOAD" == false ]]; then
    require rclone
  fi

  if [[ "$OPEN_PR" == true ]]; then
    require git
  fi

  if [[ "$DO_TRANSCRIBE" == true ]]; then
    if [[ -z "$WHISPER_API_URL" ]]; then
      fatal "WHISPER_API_URL is not set. Set it in the config block to point at your WhisperX API server."
    fi
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

  TRANSCRIPT_FILE=$(mktemp /tmp/transcript.XXXXXX.md)
  CLEANUP_FILES+=("$TRANSCRIPT_FILE")

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] whisper transcription"
    return
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Check for per-speaker tracks in audio/<episode_num_padded>/
  local tracks_dir="${script_dir}/${AUDIO_DIR}/${EPISODE_NUM_PADDED}"
  local track_count=0
  if [[ -d "$tracks_dir" ]]; then
    track_count=$(find "$tracks_dir" -maxdepth 1 \( -name "[0-9]*-*.wav" -o -name "[0-9]*-*.mp3" \) 2>/dev/null | wc -l)
  fi

  if [[ "$track_count" -gt 0 ]]; then
    header "Transcribing via API (per-track, model: ${WHISPER_MODEL})"
    log "Found ${track_count} speaker track(s) in ${AUDIO_DIR}/${EPISODE_NUM_PADDED}/"
    transcribe_tracks_api "$tracks_dir" "$script_dir"
  else
    header "Transcribing via API (single-file, model: ${WHISPER_MODEL})"
    transcribe_single_api "$script_dir"
  fi
}

transcribe_single_api() {
  local script_dir="$1"

  local speaker_args=()
  if [[ -n "$EPISODE_SPEAKERS" ]]; then
    speaker_args=(-F "min_speakers=${EPISODE_SPEAKERS}" -F "max_speakers=${EPISODE_SPEAKERS}")
  fi

  local auth_args=()
  if [[ -n "$WHISPER_API_KEY" ]]; then
    auth_args=(-H "Authorization: Bearer ${WHISPER_API_KEY}")
  fi

  local response_file
  response_file=$(mktemp /tmp/whisper-response.XXXXXX.json)
  CLEANUP_FILES+=("$response_file")

  log "POSTing to ${WHISPER_API_URL}..."

  local http_status
  http_status=$(curl -s -o "$response_file" -w "%{http_code}" \
    --max-time 1800 \
    "${auth_args[@]}" \
    -X POST "${WHISPER_API_URL}/v1/audio/transcriptions" \
    -F "file=@${MP3_TEMP}" \
    -F "model=${WHISPER_MODEL}" \
    -F "language=${WHISPER_LANG}" \
    -F "diarize=true" \
    -F "align=true" \
    -F "response_format=verbose_json" \
    "${speaker_args[@]}")

  if [[ "$http_status" != "200" ]]; then
    fatal "WhisperX API returned HTTP ${http_status}: $(cat "$response_file")"
  fi

  python3 "${script_dir}/scripts/whisperx_api_to_md.py" "$response_file" "$TRANSCRIPT_FILE"
}

transcribe_tracks_api() {
  local tracks_dir="$1"
  local script_dir="$2"

  local auth_args=()
  if [[ -n "$WHISPER_API_KEY" ]]; then
    auth_args=(-H "Authorization: Bearer ${WHISPER_API_KEY}")
  fi

  local json_dir
  json_dir=$(mktemp -d /tmp/whisper-tracks.XXXXXX)
  CLEANUP_FILES+=("$json_dir")

  local track
  while IFS= read -r -d '' track; do
    local bname speaker out_file http_status
    bname=$(basename "$track")
    speaker=$(echo "$bname" | sed 's/^[0-9]*-//;s/\.[^.]*$//' | \
              awk '{print toupper(substr($0,1,1)) substr($0,2)}')
    out_file="${json_dir}/${speaker}.json"

    log "  Transcribing track: ${speaker} (${bname})"

    http_status=$(curl -s -o "$out_file" -w "%{http_code}" \
      --max-time 1800 \
      "${auth_args[@]}" \
      -X POST "${WHISPER_API_URL}/v1/audio/transcriptions" \
      -F "file=@${track}" \
      -F "model=${WHISPER_MODEL}" \
      -F "language=${WHISPER_LANG}" \
      -F "diarize=false" \
      -F "align=true" \
      -F "response_format=verbose_json")

    if [[ "$http_status" != "200" ]]; then
      fatal "WhisperX API returned HTTP ${http_status} for track ${bname}: $(cat "$out_file")"
    fi
  done < <(find "$tracks_dir" -maxdepth 1 \( -name "[0-9]*-*.wav" -o -name "[0-9]*-*.mp3" \) -print0 | sort -z)

  python3 "${script_dir}/scripts/whisperx_tracks_api_to_md.py" "$json_dir" "$TRANSCRIPT_FILE"
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
# Transcript Correction (Claude)
########################################

fix_transcript_with_claude() {
  if [[ "$DO_TRANSCRIBE" == false || -z "$TRANSCRIPT_FILE" ]]; then return; fi
  if [[ "$SKIP_CLAUDE_FIX" == true ]]; then
    log "Skipping Claude transcript correction (--no-claude-fix)"
    return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Claude transcript correction"
    return
  fi
  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log "WARNING: Anthropic API key not available — skipping transcript correction."
    return
  fi

  header "Fixing transcript with Claude"

  local corrected_file
  corrected_file=$(mktemp /tmp/transcript-fixed.XXXXXX.md)
  CLEANUP_FILES+=("$corrected_file")

  python3 - "$CLAUDE_MODEL" "$ANTHROPIC_API_KEY" "$TRANSCRIPT_FILE" "$corrected_file" <<'PYEOF'
import json, sys, urllib.request, urllib.error, time

model, api_key, transcript_file, out_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

SYSTEM = """You are a transcript editor for a homelab/self-hosting technology podcast. \
Fix ONLY obvious ASR (automatic speech recognition) errors — misspelled product names, \
software names, and proper nouns that the ASR misheard. Do not rewrite or paraphrase. \
Preserve speaker labels, timestamps, and all conversational wording exactly.

Known corrections to apply (and similar patterns):
- Unrage / Un-rage → Unraid
- Limetep / Lymetech → LimeTech
- Navidrone → Navidrome
- Wolfin / wolfing / wolfing's → Wolphin / Wolphin's
- Senspin → Sendspin
- Plex Amp → PlexAmp
- Bamboo / bamboo (when referring to the 3D printer brand) → Bambu
- Vault Warden / vault warden → Vaultwarden
- Arcasm /Chasm → Kasm
- Orca Slicer → OrcaSlicer
- Bazite → Bazzite
- LXE → LXC
- SODAR → Sonarr
- radar → Radarr
- Proximox → Proxmox
- rustic → Restic

Return ONLY the corrected text — no commentary, no preamble, no explanation."""

CHUNK_CHARS = 25000
MAX_TOKENS = 8192
MAX_RETRIES = 3

def call_claude(chunk):
    payload = {
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": SYSTEM,
        "messages": [{"role": "user", "content": chunk}],
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    return data.get("content", [{}])[0].get("text", "")

with open(transcript_file) as f:
    content = f.read()

def make_chunks(text, max_chars):
    chunks, current, size = [], [], 0
    for line in text.splitlines(keepends=True):
        if size + len(line) > max_chars and current:
            chunks.append(''.join(current))
            current, size = [], 0
        current.append(line)
        size += len(line)
    if current:
        chunks.append(''.join(current))
    return chunks

chunks = make_chunks(content, CHUNK_CHARS)
total = len(chunks)
print(f"  {len(content)} chars, {total} chunk(s)", flush=True)

corrected_parts = []
for i, chunk in enumerate(chunks, 1):
    print(f"  Chunk {i}/{total}...", flush=True)
    last_err = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            text = call_claude(chunk)
            break
        except urllib.error.HTTPError as e:
            last_err = f"HTTP {e.code}: {e.read().decode()}"
        except Exception as e:
            last_err = str(e)
        if attempt < MAX_RETRIES:
            time.sleep(5)
    else:
        print(f"  WARNING: Claude API failed on chunk {i} after {MAX_RETRIES} attempts: {last_err}", flush=True)
        sys.exit(1)
    if not text:
        print(f"  WARNING: Claude returned empty text for chunk {i}", flush=True)
        sys.exit(1)
    corrected_parts.append(text)

with open(out_file, "w") as f:
    f.write(''.join(corrected_parts))
PYEOF

  local py_exit=$?
  if [[ $py_exit -ne 0 ]]; then
    log "WARNING: transcript correction failed — keeping original."
    return
  fi

  if [[ -s "$corrected_file" ]]; then
    cp "$corrected_file" "$TRANSCRIPT_FILE"
    log "Transcript correction applied"
  else
    log "WARNING: corrected transcript was empty — keeping original."
  fi
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
      log "WARNING: frontmatter already contains chapters — skipping generation (use --force-chapters to overwrite)"
      return
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
  prompt="You are a podcast editor. Given the transcript below, identify no more than 8 meaningful chapter
break points.  Less is acceptable. For each chapter, output a YAML list item in exactly this format (no extra text,
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

  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    log "Skipping (chapters-only mode)"
    return
  fi

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
  upload_to_filebrowser
}

########################################
# FileBrowser
########################################

load_filebrowser_creds() {
  local pass_file="${FB_PASS_FILE/#\~/$HOME}"
  local fb_pass
  fb_pass=$(tr -d '[:space:]' < "$pass_file" 2>/dev/null || true)

  if [[ -z "$fb_pass" ]]; then
    log "WARNING: FileBrowser password not found at $pass_file — skipping FileBrowser upload."
    return
  fi

  local auth_payload response_file
  auth_payload=$(python3 -c "
import json, sys
print(json.dumps({'username': sys.argv[1], 'password': sys.argv[2]}))
" "$FB_USER" "$fb_pass")

  response_file=$(mktemp /tmp/bitflip-fb-auth.XXXXXX.json)
  CLEANUP_FILES+=("$response_file")

  local http_status
  http_status=$(curl -s -o "$response_file" -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$auth_payload" \
    "${FB_HOST}/api/login")

  if [[ "$http_status" != "200" ]]; then
    log "WARNING: FileBrowser login failed (HTTP ${http_status}) — skipping FileBrowser upload."
    return
  fi

  FB_TOKEN=$(tr -d '"' < "$response_file")

  if [[ -z "$FB_TOKEN" ]]; then
    log "WARNING: FileBrowser returned empty token — skipping FileBrowser upload."
  fi
}

upload_to_filebrowser() {
  if [[ -z "$FB_TOKEN" ]]; then return; fi

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] FileBrowser upload to ${FB_DEST_DIR}/${MP3_FILENAME}"
    return
  fi

  log "Uploading to FileBrowser (${FB_DEST_DIR}/)..."

  local response_file
  response_file=$(mktemp /tmp/bitflip-fb-upload.XXXXXX.json)
  CLEANUP_FILES+=("$response_file")

  local http_status
  http_status=$(retry 3 5 curl -s -o "$response_file" -w "%{http_code}" \
    -X POST \
    -H "X-Auth: ${FB_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$MP3_TEMP" \
    "${FB_HOST}/api/resources/${FB_DEST_DIR}/${MP3_FILENAME}?override=true")

  if [[ "$http_status" == "200" || "$http_status" == "204" ]]; then
    log "FileBrowser upload complete"
  else
    log "WARNING: FileBrowser upload failed (HTTP ${http_status})"
    log "         Response: $(cat "$response_file")"
  fi
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

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)

  if [[ "$branch" == "main" || "$branch" == "master" ]]; then
    log "WARNING: currently on ${branch} — skipping PR (run from an episode branch)"
    return
  fi

  git add "$MD_FILE"

  if git diff --cached --quiet; then
    log "No changes to commit in ${MD_FILE}"
  else
    git commit -m "publish episode ${EPISODE_NUM}"
    log "Committed: ${MD_FILE}"
  fi

  git push -u origin "$branch"
  log "Pushed branch: ${branch}"

  local pr_body
  pr_body="## Episode ${EPISODE_NUM} — ${EPISODE_TITLE}

**Air Date:** ${EPISODE_DATE}

---
_Opened automatically via publication script_"

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

  if [[ "$DO_TRANSCRIBE" == true || "$DO_GENERATE_CHAPTERS" == true ]]; then
    load_anthropic_api_key
  fi
  if [[ "$OPEN_PR" == true ]]; then
    load_github_token
  fi

  load_filebrowser_creds

  read_metadata

  encode_audio
  run_transcription
  fix_transcript_with_claude
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
