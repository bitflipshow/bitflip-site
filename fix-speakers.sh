#!/usr/bin/env bash
# Replaces Speaker_NN labels in an episode transcript with real names,
# then commits the updated file to the current git branch.
#
# Usage:
#   ./fix-speakers.sh <episode-number>
#   ./fix-speakers.sh episodes/0003.md
#
# Requirements:
#   git, python3

set -Eeuo pipefail

########################################
# Configuration
########################################

EPISODES_DIR="episodes"   # Relative to script location

########################################
# Utility
########################################

log()    { echo "  $*"; }
header() { echo; echo ">> $*"; }
fatal()  { echo "Error: $*" >&2; exit 1; }

########################################
# Argument Parsing
########################################

usage() {
  echo "Usage: $0 <episode-number>"
  echo "       $0 <episode.md>"
  echo "Example: $0 3"
  echo "         $0 episodes/0003.md"
  exit 1
}

resolve_md_file() {
  local arg="$1"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    local padded
    padded=$(printf "%04d" "$(( 10#$arg ))")
    echo "${script_dir}/${EPISODES_DIR}/${padded}.md"
  else
    echo "$arg"
  fi
}

########################################
# Find Unique Speakers
########################################

find_speakers() {
  local md_file="$1"

  python3 - "$md_file" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Find all unique Speaker_NN labels (case-insensitive)
speakers = sorted(set(re.findall(r'Speaker_\d+', content, re.IGNORECASE)))
for s in speakers:
    print(s)
PYEOF
}

########################################
# Replace Speaker Labels
########################################

replace_speakers() {
  local md_file="$1"
  shift
  # Remaining args: pairs of "Speaker_NN=Real Name"

  python3 - "$md_file" "$@" <<'PYEOF'
import sys, re

md_file  = sys.argv[1]
mappings = {}

for arg in sys.argv[2:]:
    label, _, name = arg.partition("=")
    if name:
        mappings[label] = name

with open(md_file) as f:
    content = f.read()

for label, name in mappings.items():
    # Replace **Speaker_NN**: and plain Speaker_NN references
    content = re.sub(re.escape(label), name, content, flags=re.IGNORECASE)

with open(md_file, "w") as f:
    f.write(content)

print(f"Replaced {len(mappings)} speaker label(s)")
PYEOF
}

########################################
# Main
########################################

main() {
  if [[ $# -ne 1 ]]; then usage; fi

  local md_file
  md_file=$(resolve_md_file "$1")

  if [[ ! -f "$md_file" ]]; then
    fatal "Episode file not found: ${md_file}"
  fi

  header "Scanning transcript in: $(basename "$md_file")"

  local speakers
  mapfile -t speakers < <(find_speakers "$md_file")

  if [[ "${#speakers[@]}" -eq 0 ]]; then
    echo "No Speaker_NN labels found in transcript — nothing to do."
    exit 0
  fi

  log "Found ${#speakers[@]} speaker(s): ${speakers[*]}"

  # Prompt for each speaker name
  local mappings=()
  echo

  for speaker in "${speakers[@]}"; do
    printf "  Name for %-12s → " "$speaker"
    local name
    read -r name
    if [[ -z "$name" ]]; then
      log "Skipping ${speaker} (no name given)"
    else
      mappings+=("${speaker}=${name}")
    fi
  done

  if [[ "${#mappings[@]}" -eq 0 ]]; then
    echo "No names provided — nothing to replace."
    exit 0
  fi

  header "Replacing speaker labels"
  replace_speakers "$md_file" "${mappings[@]}"

  header "Committing changes"

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  log "Branch: ${branch}"

  git add "$md_file"

  if git diff --cached --quiet; then
    log "No changes detected after replacement — skipping commit."
  else
    git commit -m "fix speakers in transcript for episode $(basename "$md_file" .md)"
    log "Committed: $(basename "$md_file")"
  fi

  echo
  echo "Done."
}

main "$@"