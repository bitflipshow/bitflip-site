#!/bin/bash
# publish-episode.sh
#
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

# == Configuration =============================================================

R2_REMOTE="r2"
R2_BUCKET="audio.bitflip.show"
PUBLIC_AUDIO_URL="https://audio.bitflip.show"
DEFAULT_COVER="public/images/podcast-cover.png"
MP3_BITRATE="112k"
MP3_CHANNELS="1"  # mono

# == Transcription configuration ===============================================
#
# WHISPER_MODE:
#   "local"   -- runs faster-whisper in a Python venv on this machine.
#                The venv is created and packages installed automatically.
#   "remote"  -- SSH into another host and run faster-whisper there.
#                The remote venv is also managed automatically.
#
# WHISPER_VENV:          Path to the Python venv (expanded on local and remote).
# WHISPER_MODEL:         tiny / base / small / medium / large-v2 / large-v3
# WHISPER_LANG:          Language code (e.g. "en") or "auto" to detect.
# WHISPER_DIARIZE:       true to label speakers as Speaker_00, Speaker_01, etc.
#                        Requires a Hugging Face token. Accept model licenses at:
#                          https://huggingface.co/pyannote/speaker-diarization-community-1
# WHISPER_HF_TOKEN_FILE: Local path to a file containing your HF token (one line).
# WHISPER_SSH_HOST:      user@hostname or alias from ~/.ssh/config (remote only).
# WHISPER_SSH_PORT:      SSH port (default: 22, remote only).

WHISPER_MODE="local"
WHISPER_VENV="~/.local/share/bitflip/venv"
WHISPER_MODEL="large-v3-turbo"
WHISPER_BEAM=10                  # 1=fastest/least accurate, 5=default, 10=slower/more accurate
WHISPER_LANG="en"
# Optional prompt to improve accuracy — provide context like show name, host names,
# and common technical terms. Leave empty to disable.
WHISPER_PROMPT="BitFlip Show podcast. Hosts: Alex, Adam, Geoff, Stephen. Topics: self-hosting, Linux, Proxmox, Docker, LXC, Ansible, Jellyfin, Home Assistant, Tailscale, Unraid, open source infrastructure."
WHISPER_DIARIZE=true
WHISPER_HF_TOKEN_FILE="~/.config/bitflip/hf_token"
WHISPER_SSH_HOST="user@homeserver.local"
WHISPER_SSH_PORT="22"

# == Argument parsing ==========================================================

set -euo pipefail

MD_FILE=""
SOURCE_AUDIO=""
COVER_ART=""
DRY_RUN=false
SKIP_ENCODE=false
SKIP_UPLOAD=false
DO_TRANSCRIBE=false

usage() {
  echo "Usage: $0 <episode.md> <source-audio> [--dry-run] [--cover <file>] [--skip-encode] [--skip-upload] [--transcribe]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true;       shift ;;
    --skip-encode)  SKIP_ENCODE=true;   shift ;;
    --skip-upload)  SKIP_UPLOAD=true;   shift ;;
    --transcribe)   DO_TRANSCRIBE=true; shift ;;
    --cover)        COVER_ART="$2";     shift 2 ;;
    -*)             echo "Unknown option: $1"; usage ;;
    *)
      if   [[ -z "$MD_FILE" ]];      then MD_FILE="$1"
      elif [[ -z "$SOURCE_AUDIO" ]]; then SOURCE_AUDIO="$1"
      else echo "Unexpected argument: $1"; usage
      fi
      shift ;;
  esac
done

[[ -z "$MD_FILE" || -z "$SOURCE_AUDIO" ]] && usage

# == Validation ================================================================

[[ ! -f "$MD_FILE" ]]      && echo "Error: Episode file not found: $MD_FILE" && exit 1
[[ ! -f "$SOURCE_AUDIO" ]] && echo "Error: Audio file not found: $SOURCE_AUDIO" && exit 1

# ffmpeg -- prompt to install if missing
_install_ffmpeg() {
  echo; echo "  ffmpeg is required but not installed."
  local pkg_mgr="" cmd=""
  if   command -v apt-get &>/dev/null; then pkg_mgr="apt-get"; cmd="sudo apt-get install -y ffmpeg"
  elif command -v dnf     &>/dev/null; then pkg_mgr="dnf";     cmd="sudo dnf install -y ffmpeg"
  elif command -v pacman  &>/dev/null; then pkg_mgr="pacman";  cmd="sudo pacman -S --noconfirm ffmpeg"
  elif command -v brew    &>/dev/null; then pkg_mgr="brew";    cmd="brew install ffmpeg"
  fi
  if [[ -n "$pkg_mgr" ]]; then
    echo "  Install command: $cmd"
    read -r -p "  Run it now? [Y/n] " _r; _r="${_r:-Y}"
    [[ "$_r" =~ ^[Yy] ]] && eval "$cmd" && return
  else
    echo "  No supported package manager found. Install manually: https://ffmpeg.org/download.html"
  fi
  echo "  Aborted."; exit 1
}
command -v ffmpeg  &>/dev/null || _install_ffmpeg
command -v ffprobe &>/dev/null || _install_ffmpeg

# rclone -- hard requirement for upload
if [[ "$SKIP_UPLOAD" == false ]]; then
  command -v rclone &>/dev/null || {
    echo "Error: rclone is required for upload. See https://rclone.org/install/"
    echo "       or run with --skip-upload to skip."
    exit 1
  }
fi

# Transcription prerequisites
if [[ "$DO_TRANSCRIBE" == true ]]; then
  if [[ "$WHISPER_MODE" == "local" ]]; then
    command -v python3 &>/dev/null || { echo "Error: python3 is required for local transcription."; exit 1; }
  elif [[ "$WHISPER_MODE" == "remote" ]]; then
    command -v ssh &>/dev/null || { echo "Error: ssh is required for remote transcription."; exit 1; }
    command -v scp &>/dev/null || { echo "Error: scp is required for remote transcription."; exit 1; }
  else
    echo "Error: WHISPER_MODE must be 'local' or 'remote' (got: '$WHISPER_MODE')"; exit 1
  fi
  if [[ "$WHISPER_DIARIZE" == true ]]; then
    _hf_path="${WHISPER_HF_TOKEN_FILE/#\~/$HOME}"
    if [[ ! -f "$_hf_path" ]]; then
      echo "Error: WHISPER_DIARIZE=true but HF token file not found: $_hf_path"
      echo "       Accept model licenses at:"
      echo "         https://huggingface.co/pyannote/speaker-diarization-community-1"
      exit 1
    fi
    [[ -z "$(tr -d '[:space:]' < "$_hf_path")" ]] && {
      echo "Error: HF token file is empty: $_hf_path"; exit 1
    }
  fi
fi

[[ -z "$COVER_ART" ]] && COVER_ART="$DEFAULT_COVER"

# == Helpers ===================================================================

log()     { echo "  $*"; }
header()  { echo; echo ">> $*"; }
dry_log() { echo "  [dry-run] $*"; }

fm_get() {
  local key="$1"
  awk -v key="$key" '
    /^---$/ { delim++; next }
    delim == 2 { exit }
    delim == 1 && $0 ~ "^"key":" {
      sub("^"key":[[:space:]]*", ""); gsub(/^"|"$/, ""); print; exit
    }
  ' "$MD_FILE"
}

fm_set() {
  local key="$1" value="$2"
  if grep -q "^${key}:" "$MD_FILE"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$MD_FILE"
  else
    sed -i "0,/^---$/!{/^---$/i\\${key}: ${value}
}" "$MD_FILE"
  fi
}

to_ms() {
  local ts="$1" parts ms=0
  IFS=: read -ra parts <<< "$ts"
  for part in "${parts[@]}"; do ms=$(( ms * 60 + 10#$part )); done
  echo $(( ms * 1000 ))
}

# Strip any existing ## Transcript section and append new content
_append_transcript() {
  local src="$1" dest="$2" tmp
  tmp=$(mktemp)
  awk '/^## [Tt]ranscript/{found=1} found{next} {print}' "$dest" > "$tmp"
  awk 'NF{last=NR} {lines[NR]=$0} END{for(i=1;i<=last;i++) print lines[i]}' \
    "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
  { printf '\n\n## Transcript\n\n'
    printf '<!-- Generated by faster-whisper. Replace speaker labels with real names. -->\n\n'
    cat "$src"; } >> "$tmp"
  mv "$tmp" "$dest"
  rm -f "$src"
}

# Ensure venv has faster-whisper (and optionally pyannote) installed
_ensure_venv() {
  local venv="$1"
  local py="${venv}/bin/python" pip="${venv}/bin/pip"

  _torch_index() {
    local ver major
    ver=$(nvidia-smi 2>/dev/null | grep -oP "CUDA Version: \K[0-9]+\.[0-9]+" | head -1 || true)
    [[ -z "$ver" ]] && ver=$(nvcc --version 2>/dev/null | grep -oP "release \K[0-9]+\.[0-9]+" || true)
    if [[ -z "$ver" ]]; then echo ""; return; fi
    major=$(echo "$ver" | cut -d. -f1)
    if (( major >= 12 )); then echo "https://download.pytorch.org/whl/cu121"
    else                       echo "https://download.pytorch.org/whl/cu118"
    fi
  }

  _install_packages() {
    "$pip" install --quiet --upgrade pip
    local idx
    idx=$(_torch_index)
    if [[ -n "$idx" ]]; then
      echo "  Installing PyTorch (CUDA)..."
      "$pip" install --quiet torch torchaudio --index-url "$idx"
    else
      echo "  No CUDA detected -- installing CPU PyTorch..."
      "$pip" install --quiet torch torchaudio --index-url https://download.pytorch.org/whl/cpu
    fi
    echo "  Installing faster-whisper..."
    "$pip" install --quiet faster-whisper
    if [[ "$WHISPER_DIARIZE" == true ]]; then
      echo "  Installing pyannote.audio..."
      "$pip" install --quiet pyannote.audio
    fi
  }

  if [[ ! -f "$py" ]]; then
    echo
    echo "  No venv found at: $venv"
    echo "  faster-whisper will be installed (PyTorch + faster-whisper)."
    [[ "$WHISPER_DIARIZE" == true ]] && echo "  pyannote.audio will also be installed for diarization."
    echo
    read -r -p "  Create venv and install? [Y/n] " _r; _r="${_r:-Y}"
    [[ "$_r" =~ ^[Yy] ]] || { echo "  Aborted."; exit 1; }
    mkdir -p "$(dirname "$venv")"
    python3 -m venv "$venv"
    _install_packages
    echo "  Done."
  elif ! "$py" -c "import faster_whisper" 2>/dev/null; then
    echo
    echo "  faster-whisper not found in venv: $venv"
    read -r -p "  Install it now? [Y/n] " _r; _r="${_r:-Y}"
    [[ "$_r" =~ ^[Yy] ]] || { echo "  Aborted."; exit 1; }
    _install_packages
  elif [[ "$WHISPER_DIARIZE" == true ]] && ! "$py" -c "import pyannote.audio" 2>/dev/null; then
    echo
    echo "  pyannote.audio not found in venv: $venv"
    read -r -p "  Install it now? [Y/n] " _r; _r="${_r:-Y}"
    [[ "$_r" =~ ^[Yy] ]] || { echo "  Aborted."; exit 1; }
    "$pip" install --quiet pyannote.audio
  fi
}

# Write the faster-whisper transcription script to a temp file via heredoc
_write_whisper_script() {
  cat > "$1" << 'WHISPER_PYEOF'
import sys, os, subprocess
from faster_whisper import WhisperModel

audio_path     = sys.argv[1]
out_path       = sys.argv[2]
model_size     = sys.argv[3]
language       = sys.argv[4] if sys.argv[4] != 'auto' else None
diarize        = len(sys.argv) > 5 and sys.argv[5] == 'true'
hf_token       = sys.argv[6] if len(sys.argv) > 6 else ''
initial_prompt = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None
beam_size      = int(sys.argv[8]) if len(sys.argv) > 8 else 5

def fmt_ts(s):
    h, m, sec = int(s//3600), int((s%3600)//60), int(s%60)
    return f'{h}:{m:02d}:{sec:02d}' if h else f'{m:02d}:{sec:02d}'

def draw_progress(current, total, label=''):
    if total <= 0: return
    pct = min(current / total, 1.0)
    try: width = os.get_terminal_size().columns
    except OSError: width = 80
    suffix = f'] {int(pct*100):3d}%  {fmt_ts(current)} / {fmt_ts(total)}'
    if label: suffix += f'  {label}'
    prefix = '  ['
    bar_w = max(10, width - len(prefix) - len(suffix) - 1)
    bar = chr(0x2588) * int(bar_w * pct) + chr(0x2591) * (bar_w - int(bar_w * pct))
    print(f'\r{prefix}{bar}{suffix}', end='', flush=True)

def get_duration(path):
    try:
        r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries',
            'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', path],
            capture_output=True, text=True)
        return float(r.stdout.strip())
    except Exception: return 0.0

import torch
device = 'cuda' if torch.cuda.is_available() else 'cpu'
compute_type = 'float16' if device == 'cuda' else 'int8'
print(f'  Device: {device} ({compute_type})', flush=True)

total_dur = get_duration(audio_path)
print(f'  Loading model: {model_size}', flush=True)
model = WhisperModel(model_size, device=device, compute_type=compute_type)
print(f'  Transcribing ({fmt_ts(total_dur)})...', flush=True)
print(flush=True)

segments_iter, info = model.transcribe(
    audio_path, language=language,
    initial_prompt=initial_prompt,
    beam_size=beam_size,
    word_timestamps=True,
    vad_filter=True,
    vad_parameters={'min_silence_duration_ms': 500},
)
lang = info.language
print(f'  Language: {lang} ({info.language_probability:.2f})', flush=True)
print(flush=True)

# Collect all words with their timestamps from every segment
all_words = []  # list of (start, end, word_text)
segs = []
for seg in segments_iter:
    segs.append(seg)
    if seg.words:
        for w in seg.words:
            all_words.append((w.start, w.end, w.word))
    draw_progress(seg.end, total_dur)
draw_progress(total_dur, total_dur)
print(flush=True)
print(f'  Segments: {len(segs)}, Words: {len(all_words)}', flush=True)

speaker_map = []
if diarize and hf_token:
    try:
        print('  Running speaker diarization...', flush=True)
        import warnings
        warnings.filterwarnings('ignore', category=UserWarning, module='pyannote')
        warnings.filterwarnings('ignore', message='.*TensorFloat-32.*')
        warnings.filterwarnings('ignore', message='.*degrees of freedom.*')
        from pyannote.audio import Pipeline
        import torchaudio
        pipeline = Pipeline.from_pretrained(
            'pyannote/speaker-diarization-community-1', token=hf_token)
        pipeline.to(torch.device(device))
        # Load as waveform to avoid sample-count mismatch on file boundary
        waveform, sample_rate = torchaudio.load(audio_path)
        audio_in = {'waveform': waveform, 'sample_rate': sample_rate}
        output = pipeline(audio_in)
        # community-1 uses exclusive_speaker_diarization for clean STT alignment
        for turn, speaker in output.exclusive_speaker_diarization:
            speaker_map.append((turn.start, turn.end, str(speaker)))
        n = len({s[2] for s in speaker_map})
        print(f'  {n} speakers detected', flush=True)
    except ImportError:
        print('  WARNING: pyannote.audio not installed, skipping diarization', flush=True)
    except Exception as e:
        print(f'  WARNING: diarization failed ({e})', flush=True)

def get_speaker_at(t):
    """Return the speaker label for a given timestamp."""
    if not speaker_map: return 'Speaker'
    for s, e, lbl in speaker_map:
        if s <= t < e:
            return lbl.replace('SPEAKER_', 'Speaker_')
    # Fall back to nearest segment if t falls in a gap
    best = min(speaker_map, key=lambda x: min(abs(t - x[0]), abs(t - x[1])))
    return best[2].replace('SPEAKER_', 'Speaker_')

# Assign each word a speaker, then group consecutive same-speaker words into lines
def build_lines(words, fallback_segs):
    if not words:
        # No word timestamps — fall back to segment-level assignment
        lines = []
        for seg in fallback_segs:
            text = seg.text.strip()
            if text:
                spk = get_speaker_at(seg.start)
                lines.append((seg.start, spk, text))
        return lines

    labeled = [(w_start, w_end, w_text, get_speaker_at(w_start))
               for w_start, w_end, w_text in words]

    lines = []
    cur_spk = labeled[0][3]
    cur_start = labeled[0][0]
    cur_words = []

    for w_start, w_end, w_text, spk in labeled:
        if spk != cur_spk:
            # Speaker changed — flush current group
            lines.append((cur_start, cur_spk, ''.join(cur_words).strip()))
            cur_spk = spk
            cur_start = w_start
            cur_words = []
        cur_words.append(w_text)

    if cur_words:
        lines.append((cur_start, cur_spk, ''.join(cur_words).strip()))

    return [(s, spk, txt) for s, spk, txt in lines if txt]

lines = build_lines(all_words, segs)

with open(out_path, 'w') as f:
    for start, spk, text in lines:
        f.write(f'**{spk}**: {text}\n')
        f.write(f'*{fmt_ts(start)}*\n\n')

print(f'  Written: {out_path}', flush=True)
WHISPER_PYEOF
}

# == Read frontmatter ==========================================================

header "Reading episode metadata"

EPISODE_NUM=$(fm_get "episodeNumber")
EPISODE_TITLE=$(fm_get "title")
[[ -z "$EPISODE_NUM" ]] && echo "Error: episodeNumber not found in frontmatter" && exit 1

EPISODE_NUM_PADDED=$(printf "%04d" "$EPISODE_NUM")
MP3_FILENAME="bitflip-${EPISODE_NUM_PADDED}.mp3"
MP3_TEMP=$(mktemp /tmp/bitflip-encoded.XXXXXX.mp3)
METADATA_FILE=""
trap 'rm -f "$MP3_TEMP" "${METADATA_FILE:-/dev/null}" 2>/dev/null || true' EXIT

TOTAL_STEPS=4
[[ "$DO_TRANSCRIBE" == true ]] && TOTAL_STEPS=5
DIARIZE_LABEL=""
[[ "$WHISPER_DIARIZE" == true ]] && DIARIZE_LABEL=" + diarization"

log "Episode:    #${EPISODE_NUM} -- ${EPISODE_TITLE}"
log "Source:     $SOURCE_AUDIO"
log "Output:     $MP3_FILENAME"
[[ "$DO_TRANSCRIBE" == true ]] && log "Transcribe: ${WHISPER_MODE}, model: ${WHISPER_MODEL}${DIARIZE_LABEL}"
[[ "$DRY_RUN" == true ]]       && log "Mode:       DRY RUN -- no files will be modified"

# == Step 1: Encode MP3 ========================================================

header "Step 1/${TOTAL_STEPS}: Encoding MP3"

if [[ "$SKIP_ENCODE" == true ]]; then
  log "Skipping encode (--skip-encode), copying source as-is"
  [[ "$DRY_RUN" == false ]] && cp "$SOURCE_AUDIO" "$MP3_TEMP"
else
  COVER_ARGS=()
  if [[ -f "$COVER_ART" ]]; then
    log "Cover art: $COVER_ART"
    COVER_ARGS=(-i "$COVER_ART" -map 0:a -map 1:v -c:v mjpeg -metadata:s:v comment="Cover (front)")
  else
    log "Cover art: not found at $COVER_ART, skipping"
  fi
  log "Encoding: ${MP3_BITRATE} CBR, $([ "$MP3_CHANNELS" = "1" ] && echo mono || echo stereo)"
  if [[ "$DRY_RUN" == false ]]; then
    ffmpeg -y -loglevel warning \
      -i "$SOURCE_AUDIO" "${COVER_ARGS[@]}" \
      -c:a libmp3lame -b:a "$MP3_BITRATE" -ac "$MP3_CHANNELS" \
      -id3v2_version 3 \
      -metadata title="$EPISODE_TITLE" \
      -metadata artist="BitFlip" -metadata album="BitFlip" \
      -metadata comment="https://bitflip.show/${EPISODE_NUM}" \
      "$MP3_TEMP"
  else
    dry_log "ffmpeg ... -b:a $MP3_BITRATE -ac $MP3_CHANNELS -> $MP3_TEMP"
  fi
fi

# == Step 2: Embed chapters ====================================================

header "Step 2/${TOTAL_STEPS}: Embedding chapters"

CHAPTERS=$(awk '
  /^---$/ { delim++; next }
  delim == 1 && /^chapters:/ { in_ch=1; next }
  delim == 1 && in_ch && /^[a-z]/ { in_ch=0 }
  delim == 2 { exit }
  in_ch { print }
' "$MD_FILE")

if [[ -z "$CHAPTERS" ]]; then
  log "No chapters found, skipping"
else
  declare -a TIMES TITLES
  while IFS= read -r line; do
    if   [[ "$line" =~ time:[[:space:]]*\"([^\"]+)\" ]];  then TIMES+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ title:[[:space:]]*\"([^\"]+)\" ]]; then TITLES+=("${BASH_REMATCH[1]}")
    fi
  done <<< "$CHAPTERS"
  COUNT=${#TIMES[@]}
  log "Found $COUNT chapters"

  if [[ "$DRY_RUN" == false ]]; then
    DURATION_MS=$(ffprobe -v error -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 "$MP3_TEMP" | awk '{printf "%d", $1*1000}')
    METADATA_FILE=$(mktemp /tmp/ffmeta.XXXXXX)
    echo ";FFMETADATA1" > "$METADATA_FILE"
    for (( i=0; i<COUNT; i++ )); do
      START_MS=$(to_ms "${TIMES[$i]}")
      if (( i+1 < COUNT )); then END_MS=$(to_ms "${TIMES[$((i+1))]}"); else END_MS=$DURATION_MS; fi
      { echo "[CHAPTER]"; echo "TIMEBASE=1/1000"
        echo "START=$START_MS"; echo "END=$END_MS"
        echo "title=${TITLES[$i]}"; echo ""; } >> "$METADATA_FILE"
    done
    MP3_CHAPTERED=$(mktemp /tmp/bitflip-chaptered.XXXXXX.mp3)
    trap 'rm -f "$MP3_TEMP" "$MP3_CHAPTERED" "${METADATA_FILE}" 2>/dev/null || true' EXIT
    ffmpeg -y -loglevel warning -i "$MP3_TEMP" -i "$METADATA_FILE" \
      -map_metadata 1 -codec copy "$MP3_CHAPTERED"
    mv "$MP3_CHAPTERED" "$MP3_TEMP"
  else
    for (( i=0; i<COUNT; i++ )); do dry_log "Chapter $((i+1)): ${TIMES[$i]} -- ${TITLES[$i]}"; done
  fi
fi

# == Step 3: Transcribe ========================================================

if [[ "$DO_TRANSCRIBE" == true ]]; then
  header "Step 3/${TOTAL_STEPS}: Transcribing (${WHISPER_MODE}, model: ${WHISPER_MODEL}${DIARIZE_LABEL})"

  TRANSCRIPT_TEMP=$(mktemp /tmp/bitflip-transcript.XXXXXX.md)
  HF_TOKEN=""
  [[ "$WHISPER_DIARIZE" == true ]] && HF_TOKEN=$(tr -d '[:space:]' < "${WHISPER_HF_TOKEN_FILE/#\~/$HOME}")
  DIARIZE_ARG="false"
  [[ "$WHISPER_DIARIZE" == true ]] && DIARIZE_ARG="true"

  if [[ "$DRY_RUN" == true ]]; then
    dry_log "faster-whisper ${SOURCE_AUDIO} -> ## Transcript in ${MD_FILE}"
    [[ "$WHISPER_DIARIZE" == true ]] && dry_log "Diarization: speakers labelled Speaker_00, Speaker_01, etc."

  elif [[ "$WHISPER_MODE" == "local" ]]; then
    VENV_PATH="${WHISPER_VENV/#\~/$HOME}"
    _ensure_venv "$VENV_PATH"

    PY_SCRIPT=$(mktemp /tmp/bitflip-whisper.XXXXXX.py)
    trap 'rm -f "$MP3_TEMP" "${METADATA_FILE:-/dev/null}" "$TRANSCRIPT_TEMP" "$PY_SCRIPT" 2>/dev/null || true' EXIT
    _write_whisper_script "$PY_SCRIPT"

    INPUT_FOR_WHISPER="$MP3_TEMP"
    [[ ! -s "$MP3_TEMP" ]] && INPUT_FOR_WHISPER="$SOURCE_AUDIO"

    # Prefer venv pip-installed CUDA libs over any (potentially broken) system ones
    NVIDIA_LIBS="${VENV_PATH}/lib/python3.12/site-packages/nvidia"
    if [[ -d "$NVIDIA_LIBS" ]]; then
      CUDA_DIRS=$(find "$NVIDIA_LIBS" -name "*.so*" -printf "%h\n" 2>/dev/null | sort -u | tr '\n' ':')
      export LD_LIBRARY_PATH="${CUDA_DIRS}${LD_LIBRARY_PATH:-}"
    fi

    log "Running transcription..."
    # Pass HF token as env var to suppress unauthenticated Hub warnings
    HF_TOKEN_ENV="${HF_TOKEN:-}"
    if [[ -z "$HF_TOKEN_ENV" && -f "${WHISPER_HF_TOKEN_FILE/#\~/$HOME}" ]]; then
      HF_TOKEN_ENV=$(tr -d '[:space:]' < "${WHISPER_HF_TOKEN_FILE/#\~/$HOME}")
    fi
    HF_TOKEN="$HF_TOKEN_ENV" "${VENV_PATH}/bin/python" "$PY_SCRIPT" \
      "$INPUT_FOR_WHISPER" "$TRANSCRIPT_TEMP" \
      "$WHISPER_MODEL" "$WHISPER_LANG" "$DIARIZE_ARG" "$HF_TOKEN" "$WHISPER_PROMPT" "$WHISPER_BEAM"

    log "Appending transcript to ${MD_FILE}..."
    _append_transcript "$TRANSCRIPT_TEMP" "$MD_FILE"
    log "Done"

  elif [[ "$WHISPER_MODE" == "remote" ]]; then
    REMOTE_VENV="${WHISPER_VENV}"
    REMOTE_AUDIO="/tmp/bitflip-input-$$.mp3"
    REMOTE_MD="/tmp/bitflip-output-$$.md"
    REMOTE_PY="/tmp/bitflip-whisper-$$.py"

    trap 'rm -f "$MP3_TEMP" "${METADATA_FILE:-/dev/null}" "$TRANSCRIPT_TEMP" 2>/dev/null || true' EXIT

    INPUT_FOR_WHISPER="$MP3_TEMP"
    [[ ! -s "$MP3_TEMP" ]] && INPUT_FOR_WHISPER="$SOURCE_AUDIO"

    LOCAL_PY=$(mktemp /tmp/bitflip-whisper.XXXXXX.py)
    _write_whisper_script "$LOCAL_PY"

    log "Copying files to remote host (${WHISPER_SSH_HOST})..."
    scp -P "$WHISPER_SSH_PORT" -q "$INPUT_FOR_WHISPER" "$LOCAL_PY" \
      "${WHISPER_SSH_HOST}:/tmp/"
    ssh -p "$WHISPER_SSH_PORT" "$WHISPER_SSH_HOST" \
      "mv /tmp/$(basename "$INPUT_FOR_WHISPER") ${REMOTE_AUDIO} && \
       mv /tmp/$(basename "$LOCAL_PY") ${REMOTE_PY}"
    rm -f "$LOCAL_PY"

    log "Ensuring faster-whisper venv on remote..."
    ssh -p "$WHISPER_SSH_PORT" "$WHISPER_SSH_HOST" bash << REMOTE_SETUP
set -euo pipefail
VENV="${REMOTE_VENV/#\~/\$HOME}"
PY="\${VENV}/bin/python"
PIP="\${VENV}/bin/pip"
_torch_index() {
  local ver major
  ver=\$(nvidia-smi 2>/dev/null | grep -oP "CUDA Version: \\K[0-9]+\\.[0-9]+" | head -1 || true)
  [[ -z "\$ver" ]] && ver=\$(nvcc --version 2>/dev/null | grep -oP "release \\K[0-9]+\\.[0-9]+" || true)
  [[ -z "\$ver" ]] && return
  major=\$(echo "\$ver" | cut -d. -f1)
  (( major >= 12 )) && echo "https://download.pytorch.org/whl/cu121" || echo "https://download.pytorch.org/whl/cu118"
}
if [[ ! -f "\$PY" ]]; then
  echo "  Creating remote venv at \$VENV..."
  mkdir -p "\$(dirname "\$VENV")"
  python3 -m venv "\$VENV"
  "\$PIP" install --quiet --upgrade pip
  idx=\$(_torch_index)
  if [[ -n "\$idx" ]]; then
    echo "  Installing PyTorch (CUDA)..."
    "\$PIP" install --quiet torch torchaudio --index-url "\$idx"
  else
    "\$PIP" install --quiet torch torchaudio --index-url https://download.pytorch.org/whl/cpu
  fi
  echo "  Installing faster-whisper..."
  "\$PIP" install --quiet faster-whisper pyannote.audio
elif ! "\$PY" -c "import faster_whisper" 2>/dev/null; then
  echo "  Installing faster-whisper into existing remote venv..."
  "\$PIP" install --quiet faster-whisper pyannote.audio
fi
REMOTE_SETUP

    log "Running transcription on remote..."
    ssh -p "$WHISPER_SSH_PORT" "$WHISPER_SSH_HOST" \
      "${REMOTE_VENV/#\~/\$HOME}/bin/python ${REMOTE_PY} \
        ${REMOTE_AUDIO} ${REMOTE_MD} \
        ${WHISPER_MODEL} ${WHISPER_LANG} ${DIARIZE_ARG} '${HF_TOKEN}' $(printf '%q' "${WHISPER_PROMPT}") ${WHISPER_BEAM}"

    log "Retrieving transcript..."
    scp -P "$WHISPER_SSH_PORT" -q "${WHISPER_SSH_HOST}:${REMOTE_MD}" "$TRANSCRIPT_TEMP"
    ssh -p "$WHISPER_SSH_PORT" "$WHISPER_SSH_HOST" \
      "rm -f ${REMOTE_AUDIO} ${REMOTE_MD} ${REMOTE_PY}" 2>/dev/null || true

    log "Appending transcript to ${MD_FILE}..."
    _append_transcript "$TRANSCRIPT_TEMP" "$MD_FILE"
    log "Done"
  fi
fi

# == Step 4 (or 3): Get duration + file size ===================================

STEP_NUM=3; [[ "$DO_TRANSCRIBE" == true ]] && STEP_NUM=4
header "Step ${STEP_NUM}/${TOTAL_STEPS}: Reading duration and file size"

AUDIO_URL="" AUDIO_SIZE="" DURATION=""
if [[ "$DRY_RUN" == false ]]; then
  DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$MP3_TEMP" | \
    awk '{h=int($1/3600);m=int(($1%3600)/60);s=int($1%60); printf "%d:%02d:%02d",h,m,s}')
  AUDIO_SIZE=$(stat -c%s "$MP3_TEMP" 2>/dev/null || stat -f%z "$MP3_TEMP")
  AUDIO_URL="${PUBLIC_AUDIO_URL}/${MP3_FILENAME}"
  log "Duration: $DURATION"
  log "Size:     $AUDIO_SIZE bytes"
  log "URL:      $AUDIO_URL"
else
  dry_log "Duration: <from ffprobe>"
  dry_log "URL:      ${PUBLIC_AUDIO_URL}/${MP3_FILENAME}"
fi

# == Step 5 (or 4): Upload to R2 ===============================================

STEP_NUM=4; [[ "$DO_TRANSCRIBE" == true ]] && STEP_NUM=5
header "Step ${STEP_NUM}/${TOTAL_STEPS}: Uploading to R2"

if [[ "$SKIP_UPLOAD" == true ]]; then
  log "Skipping (--skip-upload)"
elif [[ "$DRY_RUN" == true ]]; then
  dry_log "rclone copyto $MP3_TEMP ${R2_REMOTE}:${R2_BUCKET}/${MP3_FILENAME}"
else
  log "Uploading to ${R2_REMOTE}:${R2_BUCKET}/${MP3_FILENAME} ..."
  rclone copyto "$MP3_TEMP" "${R2_REMOTE}:${R2_BUCKET}/${MP3_FILENAME}" \
    --progress --s3-acl public-read
  log "Upload complete"
fi

# == Patch frontmatter =========================================================

header "Patching frontmatter in $MD_FILE"

if [[ "$DRY_RUN" == false ]]; then
  fm_set "audioUrl"  "\"${AUDIO_URL}\""
  fm_set "audioSize" "$AUDIO_SIZE"
  fm_set "duration"  "\"${DURATION}\""
  log "audioUrl:  \"${AUDIO_URL}\""
  log "audioSize: $AUDIO_SIZE"
  log "duration:  \"${DURATION}\""
else
  dry_log "audioUrl:  \"${PUBLIC_AUDIO_URL}/${MP3_FILENAME}\""
  dry_log "audioSize: <bytes>"
  dry_log "duration:  <HH:MM:SS>"
fi

# == Done ======================================================================

echo
if [[ "$DRY_RUN" == true ]]; then
  echo "Done (dry run) -- no files were modified."
else
  echo "Done. Next step: git add ${MD_FILE} && git commit && git push"
  if [[ "$DO_TRANSCRIBE" == true ]]; then
    if [[ "$WHISPER_DIARIZE" == true ]]; then
      echo "  Tip: Replace Speaker_00, Speaker_01, etc. with real names in ${MD_FILE}"
    else
      echo "  Tip: Replace **Speaker** with real speaker names in ${MD_FILE}"
    fi
  fi
fi
echo