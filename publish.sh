#!/usr/bin/env bash
# Encodes a distribution-ready MP3, embeds chapters, optionally transcribes
# with faster-whisper, uploads to R2, and patches the episode frontmatter.
#
# Usage:
#   ./publish-episode.sh <episode.md> <source-audio> [options]
#
# Options:
#   --dry-run        Show what would happen without making any changes
#   --cover <file>   Cover art image (default: public/images/podcast-cover.png)
#   --skip-encode    Use source audio as-is (must already be an MP3)
#   --skip-upload    Skip R2 upload
#   --transcribe     Transcribe with faster-whisper and embed in episode markdown
#
# Requirements:
#   ffmpeg, ffprobe, rclone
#   --transcribe local:  python3
#   --transcribe remote: ssh, scp, python3 on remote host

set -euo pipefail

########################################
# Configuration
########################################

R2_REMOTE="r2"
R2_BUCKET="audio.bitflip.show"
PUBLIC_AUDIO_URL="https://audio.bitflip.show"

DEFAULT_COVER="public/images/podcast-cover.png"
MP3_BITRATE="128k"
MP3_CHANNELS="2"

WHISPER_MODE="local"   # local | remote
WHISPER_VENV="~/.local/share/bitflip/venv"
WHISPER_MODEL="large-v3-turbo"   # tiny / base / small / medium / large-v2 / large-v3
WHISPER_LANG="en"   # Language code (e.g. "en") or "auto" to detect.
WHISPER_BEAM=10
WHISPER_DIARIZE=true   # true to label speakers as Speaker_00, Speaker_01, etc.  Requires a Hugging Face token. Accept model licenses at: https://huggingface.co/pyannote/speaker-diarization-community-1
WHISPER_HF_TOKEN_FILE="~/.config/bitflip/hf_token"   # Local path to a file containing your HF token (one line).
# Optional prompt to improve accuracy — provide context like show name, host names,
# and common technical terms. Leave empty to disable.
WHISPER_PROMPT="BitFlip Show podcast. Hosts: Alex, Adam, Geoff, Stephen. Topics: self-hosting, Linux, Proxmox, Docker, LXC, Ansible, Jellyfin, Home Assistant, Tailscale, Unraid, open source infrastructure."

# Remote transcription (WHISPER_MODE="remote")
WHISPER_SSH_HOST="user@homeserver.local"  # user@host or SSH config alias
WHISPER_SSH_PORT="22"
WHISPER_REMOTE_VENV="~/.local/share/bitflip/venv"  # venv path on remote host
WHISPER_REMOTE_WORKDIR="/tmp/bitflip-transcribe"    # scratch dir on remote host

########################################
# Globals
########################################

MD_FILE=""
SOURCE_AUDIO=""
COVER_ART=""

DRY_RUN=false
SKIP_ENCODE=false
SKIP_UPLOAD=false
DO_TRANSCRIBE=false
OUTPUT_FILE=""

EPISODE_NUM=""
EPISODE_TITLE=""
EPISODE_DATE=""
EPISODE_NUM_PADDED=""

MP3_TEMP=""
MP3_FILENAME=""

AUDIO_SIZE=""
AUDIO_URL=""
DURATION=""

HF_TOKEN=""

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

########################################
# Argument Parsing
########################################

usage() {
  echo "Usage: $0 <episode.md> <source-audio> [options]"
  echo "Options:"
  echo "  --dry-run          Show what would happen without making changes"
  echo "  --cover <file>     Cover art image (default: $DEFAULT_COVER)"
  echo "  --skip-encode      Use source audio as-is (must already be MP3)"
  echo "  --skip-upload      Skip R2 upload"
  echo "  --output <file>    Save final MP3 to this path (implied by --skip-upload)"
  echo "  --transcribe       Transcribe and embed in episode markdown"
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --skip-encode) SKIP_ENCODE=true ;;
      --skip-upload) SKIP_UPLOAD=true ;;
      --transcribe) DO_TRANSCRIBE=true ;;
      --cover) COVER_ART="$2"; shift ;;
      --output) OUTPUT_FILE="$2"; shift ;;
      -*) usage ;;
      *)
        if [[ -z "$MD_FILE" ]]; then
          MD_FILE="$1"
        elif [[ -z "$SOURCE_AUDIO" ]]; then
          SOURCE_AUDIO="$1"
        else
          usage
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$MD_FILE" || -z "$SOURCE_AUDIO" ]]; then
    usage
  fi

  if [[ ! -f "$MD_FILE" ]]; then
    echo "Error: episode file not found: $MD_FILE" >&2; exit 1
  fi

  if [[ ! -f "$SOURCE_AUDIO" ]]; then
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

  if [[ "$DO_TRANSCRIBE" == true ]]; then
    if [[ "$WHISPER_MODE" == "remote" ]]; then
      require ssh
      require scp
    else
      require python3
    fi
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
# Markdown Frontmatter Helpers
########################################

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

fm_set() {
  local key="$1" value="$2"

  if grep -q "^${key}:" "$MD_FILE"; then
    sed -i.bak "s|^${key}:.*|${key}: ${value}|" "$MD_FILE"
  else
    sed -i.bak "0,/^---$/!{/^---$/i\\${key}: ${value}
}" "$MD_FILE"
  fi

  rm -f "${MD_FILE}.bak"
}

########################################
# Metadata
########################################

read_metadata() {
  header "Reading metadata"

  EPISODE_NUM=$(fm_get "episodeNumber")
  EPISODE_TITLE=$(fm_get "title")
  EPISODE_DATE=$(fm_get "date")

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
  header "Encoding MP3"

  MP3_TEMP=$(mktemp /tmp/bitflip-encoded.XXXXXX.mp3)
  CLEANUP_FILES+=("$MP3_TEMP")

  if [[ "$SKIP_ENCODE" == true ]]; then
    log "Skipping encode"

    if [[ "$DRY_RUN" == false ]]; then cp "$SOURCE_AUDIO" "$MP3_TEMP"; fi
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
# Chapters
########################################

# Convert HH:MM:SS or MM:SS timestamp to milliseconds
ts_to_ms() {
  local ts="$1"
  local h=0 m=0 s=0
  IFS=: read -r -a parts <<< "$ts"
  case "${#parts[@]}" in
    3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
    2) m="${parts[0]}"; s="${parts[1]}" ;;
    *) fatal "Unrecognised chapter timestamp: $ts" ;;
  esac
  # Strip leading zeros to avoid bash treating values as octal (e.g. 09 -> 9)
  h=$(( 10#$h ))
  m=$(( 10#$m ))
  s=$(( 10#$s ))
  echo $(( (h * 3600 + m * 60 + s) * 1000 ))
}

embed_chapters() {
  header "Embedding chapters"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] chapter embedding"
    return
  fi

  # Parse chapters block from frontmatter into parallel time/title arrays
  local chapter_times=()
  local chapter_titles=()
  local in_chapters=0 current_time="" current_title=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^chapters: ]]; then
      in_chapters=1
      continue
    fi
    # Stop at next top-level frontmatter key
    if [[ $in_chapters -eq 1 && "$line" =~ ^[a-zA-Z] ]]; then
      break
    fi
    if [[ $in_chapters -eq 1 ]]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*time:[[:space:]]*\"?([0-9:]+)\"? ]]; then
        current_time="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+title:[[:space:]]*\"?(.+)\"?$ ]]; then
        current_title="${BASH_REMATCH[1]}"
        current_title="${current_title%\"}"  # strip trailing quote if any
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
    log "No chapters found"
    return
  fi

  log "${#chapter_times[@]} chapters found"

  # Get total duration in ms for the final chapter's end time
  local total_ms
  total_ms=$(ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$MP3_TEMP" | \
    awk '{printf "%d", $1 * 1000}')

  # Write ffmpeg metadata file
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

  # Remux MP3 with chapter metadata (audio stream copy, no re-encode)
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
  # chaptered now points to a deleted path, remove from cleanup to avoid rm error
  CLEANUP_FILES=("${CLEANUP_FILES[@]/$chaptered}")

  log "Chapters embedded"
}

########################################
# Transcription
########################################

# Environment variables passed to transcribe.py (both local and remote)
# transcribe.py reads: WHISPER_DIARIZE, HF_TOKEN, WHISPER_PROMPT

run_transcription() {
  if [[ "$DO_TRANSCRIBE" == false ]]; then return; fi

  if [[ "$WHISPER_MODE" == "remote" ]]; then
    run_transcription_remote
  else
    run_transcription_local
  fi
}

run_transcription_local() {
  header "Transcribing (local, model: ${WHISPER_MODEL})"

  local transcript
  transcript=$(mktemp /tmp/transcript.XXXXXX.md)
  CLEANUP_FILES+=("$transcript")

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] whisper transcription"
    return
  fi

  local venv
  venv="${WHISPER_VENV/#\~/$HOME}"

  if [[ ! -f "$venv/bin/python" ]]; then
    log "Creating venv: $venv"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q faster-whisper
    if [[ "$WHISPER_DIARIZE" == true ]]; then
      "$venv/bin/pip" install -q pyannote.audio
    fi
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  WHISPER_DIARIZE="$WHISPER_DIARIZE" \
  HF_TOKEN="$HF_TOKEN" \
  WHISPER_PROMPT="$WHISPER_PROMPT" \
    "$venv/bin/python" "$script_dir/scripts/transcribe.py" \
      "$MP3_TEMP" \
      "$transcript" \
      "$WHISPER_MODEL" \
      "$WHISPER_LANG" \
      "$WHISPER_BEAM"

  append_transcript "$transcript"
}

run_transcription_remote() {
  header "Transcribing (remote: ${WHISPER_SSH_HOST}, model: ${WHISPER_MODEL})"

  local transcript
  transcript=$(mktemp /tmp/transcript.XXXXXX.md)
  CLEANUP_FILES+=("$transcript")

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] remote whisper transcription"
    return
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local remote_workdir="$WHISPER_REMOTE_WORKDIR"
  local remote_audio="${remote_workdir}/audio.mp3"
  local remote_script="${remote_workdir}/transcribe.py"
  local remote_out="${remote_workdir}/transcript.md"
  local remote_venv="${WHISPER_REMOTE_VENV}"

  local ssh_opts=(-p "$WHISPER_SSH_PORT" -o BatchMode=yes)

  # Prepare remote working directory
  log "Preparing remote workdir: ${WHISPER_SSH_HOST}:${remote_workdir}"
  ssh "${ssh_opts[@]}" "$WHISPER_SSH_HOST" "mkdir -p '$remote_workdir'"

  # Upload audio and transcribe.py
  log "Uploading audio..."
  scp -P "$WHISPER_SSH_PORT" -q "$MP3_TEMP" "${WHISPER_SSH_HOST}:${remote_audio}"

  log "Uploading transcribe.py..."
  scp -P "$WHISPER_SSH_PORT" -q "$script_dir/scripts/transcribe.py" "${WHISPER_SSH_HOST}:${remote_script}"

  # Bootstrap venv on remote if needed
  ssh "${ssh_opts[@]}" "$WHISPER_SSH_HOST" bash <<REMOTE_SETUP
set -euo pipefail
venv="${remote_venv/#\~/\$HOME}"
if [[ ! -f "\$venv/bin/python" ]]; then
  echo "  Creating remote venv: \$venv"
  python3 -m venv "\$venv"
  "\$venv/bin/pip" install -q faster-whisper
  $( [[ "$WHISPER_DIARIZE" == true ]] && echo '"\$venv/bin/pip" install -q pyannote.audio' )
fi
REMOTE_SETUP

  # Run transcription on remote
  log "Running transcription on remote..."
  ssh "${ssh_opts[@]}" "$WHISPER_SSH_HOST" \
    WHISPER_DIARIZE="$WHISPER_DIARIZE" \
    HF_TOKEN="$HF_TOKEN" \
    WHISPER_PROMPT="$WHISPER_PROMPT" \
    "${remote_venv/#\~/\$HOME}/bin/python" \
      "$remote_script" \
      "$remote_audio" \
      "$remote_out" \
      "$WHISPER_MODEL" \
      "$WHISPER_LANG" \
      "$WHISPER_BEAM"

  # Retrieve transcript
  log "Retrieving transcript..."
  scp -P "$WHISPER_SSH_PORT" -q "${WHISPER_SSH_HOST}:${remote_out}" "$transcript"

  # Clean up remote scratch files
  ssh "${ssh_opts[@]}" "$WHISPER_SSH_HOST" "rm -f '$remote_audio' '$remote_script' '$remote_out'"

  append_transcript "$transcript"
}

append_transcript() {

  local src="$1"
  local tmp

  tmp=$(mktemp)

  awk '/^## [Tt]ranscript/{exit} {print}' "$MD_FILE" > "$tmp"

  echo >> "$tmp"
  echo "## Transcript" >> "$tmp"
  echo >> "$tmp"

  cat "$src" >> "$tmp"

  mv "$tmp" "$MD_FILE"
}

########################################
# Metadata Extraction
########################################

extract_audio_metadata() {

  header "Reading duration and file size"

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
    # Save the file locally instead — default to MP3_FILENAME in current dir
    local dest="${OUTPUT_FILE:-$MP3_FILENAME}"
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

  rclone copyto "$MP3_TEMP" \
    "${R2_REMOTE}:${R2_BUCKET}/${MP3_FILENAME}" \
    --s3-acl public-read

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
# Main Pipeline
########################################

main() {

  parse_args "$@"

  COVER_ART="${COVER_ART:-$DEFAULT_COVER}"

  check_dependencies
  if [[ "$DO_TRANSCRIBE" == true ]]; then
    load_hf_token
  fi

  read_metadata

  encode_audio

  embed_chapters

  run_transcription

  extract_audio_metadata

  upload_audio

  patch_frontmatter

  echo

  if [[ "$DRY_RUN" == true ]]; then
    echo "Done (dry run)"
  else
    echo "Done."
    echo "Episode URL: ${PUBLIC_AUDIO_URL}/${MP3_FILENAME}"
  fi
}

main "$@"