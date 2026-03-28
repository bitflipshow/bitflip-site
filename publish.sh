#!/usr/bin/env bash
# Encodes a distribution-ready MP3, embeds chapters, optionally transcribes
# with faster-whisper, uploads to R2, and patches the episode frontmatter.
#
# Usage:
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
WHISPER_MODEL="large-v3-turbo"   # tiny / base / small / medium / large-v2 / large-v3
WHISPER_LANG="en"   # Language code (e.g. "en") or "auto" to detect.
WHISPER_BEAM=10
WHISPER_DIARIZE=true   # true to label speakers as Speaker_00, Speaker_01, etc.  Requires a Hugging Face token. Accept model licenses at: https://huggingface.co/pyannote/speaker-diarization-community-1
WHISPER_HF_TOKEN_FILE="~/.config/bitflip/hf_token"   # Local path to a file containing your HF token (one line).
# Optional prompt to improve accuracy — provide context like show name, host names,
# and common technical terms. Leave empty to disable.
WHISPER_PROMPT="BitFlip Show podcast. Hosts: Alex, Adam, Geoff, Stephen. Topics: self-hosting, Linux, Proxmox, Docker, LXC, Ansible, Jellyfin, Home Assistant, Tailscale, Unraid, open source infrastructure."

# Claude API — used for chapter generation from transcript
ANTHROPIC_API_KEY_FILE="~/.config/bitflip/anthropic_api_key"   # Local path to a file containing your Anthropic API key (one line).
CLAUDE_MODEL="claude-sonnet-4-6"

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
ANTHROPIC_API_KEY=""
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

# retry <attempts> <delay_seconds> <command> [args...]
# Retries a command up to <attempts> times, waiting <delay_seconds> between tries.
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
# Argument Parsing
########################################

usage() {
  echo "Usage: $0 <episode.md> <source-audio> [options]"
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

  if [[ -z "$MD_FILE" ]]; then
    usage
  fi

  if [[ ! -f "$MD_FILE" ]]; then
    echo "Error: episode file not found: $MD_FILE" >&2; exit 1
  fi

  # SOURCE_AUDIO is not required when only generating chapters from an existing transcript
  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false && -z "$SOURCE_AUDIO" ]]; then
    # Set flags so the pipeline skips all audio steps cleanly
    SKIP_ENCODE=true
    SKIP_UPLOAD=true
    # Provide a dummy value so later guards don't trip on an empty variable
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

  # python3 needed for whisper venv bootstrap and for JSON payload/response handling
  if [[ "$DO_TRANSCRIBE" == true || "$DO_GENERATE_CHAPTERS" == true ]]; then
    require python3
    require curl
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
    # Fall back to environment variable if file is absent
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

# sed_inplace: portable in-place sed for both GNU (Linux) and BSD (macOS).
# Usage: sed_inplace 's/old/new/' file
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

fm_set() {
  local key="$1" value="$2"

  if grep -q "^${key}:" "$MD_FILE"; then
    sed_inplace "s|^${key}:.*|${key}: ${value}|" "$MD_FILE"
  else
    # Insert before the closing --- of the frontmatter
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

# fm_has_chapters: returns 0 (true) if a chapters: block exists in frontmatter
fm_has_chapters() {
  awk '
    /^---$/ {delim++; next}
    delim==2 {exit}
    delim==1 && /^chapters:/ {found=1; exit}
    END {exit !found}
  ' "$MD_FILE"
}

# fm_set_chapters: replace or insert the entire chapters: block in frontmatter.
# Argument: path to a file whose contents are the YAML block to insert,
# starting with "chapters:" and including all indented list items.
fm_set_chapters() {
  local chapters_file="$1"
  local tmp block
  tmp=$(mktemp)

  # Slurp the replacement block once — reused in both awk passes below
  block=$(cat "$chapters_file")

  awk -v block="$block" '
    /^---$/ { delim++ }
    # Inside frontmatter: replace the existing chapters block
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
          next  # skip indented chapter lines
        }
      }
    }
    { print }
  ' "$MD_FILE" > "$tmp"

  # If chapters: was never found, insert it before the closing --- of the frontmatter
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
  # Nothing to encode when only generating chapters from an existing transcript
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

# Environment variables passed to transcribe.py
# transcribe.py reads: WHISPER_DIARIZE, HF_TOKEN, WHISPER_PROMPT

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

    # ----------------------------------------------------------------
    # Package version rationale
    # ----------------------------------------------------------------
    # torch/torchaudio pinned to 2.8.0:
    #   - ctranslate2 (faster-whisper) requires libcublas.so.12 (CUDA 12).
    #     torch 2.11+ ships CUDA 13 wheels from PyPI by default, causing a
    #     runtime library mismatch. torch 2.8.0 ships CUDA 12 libraries.
    #   - torchaudio must match torch exactly per its dependency requirements.
    #
    # pyannote.audio pinned to 4.0.1:
    #   - 4.0.2+ hard-pins torch==2.8.0 (exact), conflicting with other
    #     packages. 4.0.1 uses the flexible torch>=2.0 requirement.
    #   - 4.0.x depends on torchcodec for audio I/O, which requires CUDA 13.
    #     We patch it out (see patch_pyannote_io.py).
    #
    # Patches applied after install (see scripts/patch_pyannote_io.py):
    #   1. torchcodec uninstalled — requires libnvrtc.so.13 (CUDA 13),
    #      incompatible with the CUDA 12 stack needed by ctranslate2.
    #   2. pyannote/audio/core/io.py patched to replace all AudioDecoder
    #      (torchcodec) calls with torchaudio.load/torchaudio.info.
    #   3. use_auth_token renamed to token throughout pyannote source —
    #      pyannote 4.x uses the updated HuggingFace Hub API parameter name.
    #
    # Reference: https://github.com/bobsummerwill/strato-transcripts/blob/main/WORKAROUNDS.md
    # ----------------------------------------------------------------

    "$venv/bin/pip" install -q "torch==2.8.0" "torchaudio==2.8.0"
    "$venv/bin/pip" install -q faster-whisper

    if [[ "$WHISPER_DIARIZE" == true ]]; then
      "$venv/bin/pip" install -q "pyannote.audio==4.0.1" matplotlib

      # Patch 1: remove torchcodec (requires CUDA 13)
      "$venv/bin/pip" uninstall -q -y torchcodec 2>/dev/null || true

      # Patch 2: replace torchcodec AudioDecoder calls with torchaudio equivalents
      local io_py="${venv}/lib/python3.12/site-packages/pyannote/audio/core/io.py"
      python3 "${script_dir}/scripts/patch_pyannote_io.py" "$io_py"

      # Patch 3: rename use_auth_token → token throughout pyannote source
      find "${venv}/lib/python3.12/site-packages/pyannote" -name "*.py"         -exec grep -l "use_auth_token" {} \;         | xargs --no-run-if-empty sed -i "s/use_auth_token/token/g"
      log "Applied use_auth_token→token patch to pyannote"
    fi
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  WHISPER_DIARIZE="$WHISPER_DIARIZE" \
  HF_TOKEN="$HF_TOKEN" \
  WHISPER_PROMPT="$WHISPER_PROMPT" \
    "$venv/bin/python" "$script_dir/scripts/transcribe.py" \
      "$MP3_TEMP" \
      "$TRANSCRIPT_FILE" \
      "$WHISPER_MODEL" \
      "$WHISPER_LANG" \
      "$WHISPER_BEAM"
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

# Extract the ## Transcript section from the episode markdown into a temp file,
# setting TRANSCRIPT_FILE. Calls fatal if no transcript section is found.
extract_transcript_from_md() {
  header "Extracting transcript from episode file"

  local tmp
  tmp=$(mktemp /tmp/transcript.XXXXXX.md)
  CLEANUP_FILES+=("$tmp")

  # Grab everything after the first ## Transcript heading
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

  # Guard: existing chapters in frontmatter
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

  # Truncate transcript if it would exceed safe Claude input limits.
  # ~120k chars leaves comfortable headroom below the 200k token context window
  # when combined with the prompt and expected output.
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

  # Build the prompt
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

  # Build JSON payload via python3 (already a dependency) to handle escaping safely
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

  # A 200 can still carry an application-level error (e.g. overloaded, invalid request)
  if ! grep -q '"content"' "$response_file"; then
    log "WARNING: Claude response missing 'content' field — skipping chapter generation."
    log "         Response: $(cat "$response_file")"
    return
  fi

  # Extract the text content from the API response
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

  # Validate: every line should be blank, a list item, or an indented time/title key
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

  # Build the full chapters block to splice into frontmatter
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

# Convert HH:MM:SS or MM:SS timestamp to milliseconds.
# HH:MM:SS is required from Claude, but MM:SS is accepted as a fallback
# to avoid a fatal error if the model slips up.
ts_to_ms() {
  local ts="$1"
  local h=0 m=0 s=0
  IFS=: read -r -a parts <<< "$ts"
  case "${#parts[@]}" in
    3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
    2) m="${parts[0]}"; s="${parts[1]}" ;;   # MM:SS fallback
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

  # No audio to process when running chapter generation only
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

  read_metadata

  # Step 1: encode source audio to MP3
  encode_audio

  # Step 2: transcribe (sets TRANSCRIPT_FILE); skipped when only --generate-chapters is set
  run_transcription

  # Step 3: append transcript text to episode markdown
  append_transcript

  # Step 4a: if --generate-chapters without --transcribe, pull transcript from the episode file
  if [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    extract_transcript_from_md
  fi

  # Step 4b: generate chapter markers from transcript via Claude, write into frontmatter
  generate_chapters_from_transcript

  # Step 5: embed chapters from frontmatter into the MP3
  embed_chapters

  # Step 6: read duration + size from the final MP3
  extract_audio_metadata

  # Step 7: upload to R2 (or save locally)
  upload_audio

  # Step 8: patch audioUrl / audioSize / duration into frontmatter
  patch_frontmatter

  echo

  if [[ "$DRY_RUN" == true ]]; then
    echo "Done (dry run)"
  elif [[ "$DO_GENERATE_CHAPTERS" == true && "$DO_TRANSCRIBE" == false ]]; then
    echo "Done."
    echo "Chapters written to: ${MD_FILE}"
  elif [[ "$SKIP_UPLOAD" == true ]]; then
    local dest="${OUTPUT_FILE:-$MP3_FILENAME}"
    echo "Done."
    echo "Saved to: ${dest}"
  else
    echo "Done."
    echo "Episode URL: ${PUBLIC_AUDIO_URL}/${MP3_FILENAME}"
  fi
}

main "$@"