# BitFlip.show — task runner

set shell := ["bash", "-euo", "pipefail", "-c"]

publish_script := "./publish.sh"

# ------------------------------------------------------------
# Default: list all recipes
# ------------------------------------------------------------

[private]
default:
    @just --list

# ------------------------------------------------------------
# Site
# ------------------------------------------------------------

# Start local dev server
dev:
    npm run dev

# Build the site
build:
    npm run build

# Build and preview locally (binds to all interfaces for LAN testing)
preview: build
    npm run preview -- --host

# ------------------------------------------------------------
# Data pull
# ------------------------------------------------------------

# Pull episode doc from Outline and audio from FileBrowser, create the episode .md file
# Usage: just pull 3
pull episode:
    ./pull-data.sh "{{ episode }}"

# Pull episode doc from Outline only (skip audio download)
# Usage: just pull-notes 3
pull-notes episode:
    ./pull-data.sh "{{ episode }}" --skip-audio

# ------------------------------------------------------------
# Publishing recipes
#
# Pass an episode number — files are resolved automatically from
# the episodes/ and audio/ directories.
#
# publish              transcribe + Claude chapters + upload
# publish-nochapters   transcribe only              + upload
# publish-notx         (no transcription)           + upload
# local                transcribe + Claude chapters  (no upload, saved locally)
# local-nochapters     transcribe only               (no upload)
# local-notx           (no transcription)            (no upload)
# ------------------------------------------------------------

# transcribe + Claude chapters + R2 upload + open GitHub PR
# Usage: just publish 3
#        just publish 3 --cover path/to/cover.png
publish episode *flags:
    {{ publish_script }} "{{ episode }}" --transcribe --open-pr {{ flags }}

# transcribe (no Claude chapters) + R2 upload
# Usage: just publish-nochapters 3
publish-nochapters episode *flags:
    {{ publish_script }} "{{ episode }}" --transcribe --no-chapters {{ flags }}

# encode + embed existing chapters + R2 upload (no transcription)
# Usage: just publish-notx 3
publish-notx episode *flags:
    {{ publish_script }} "{{ episode }}" {{ flags }}

# transcribe + Claude chapters, save locally (no R2 upload)
# Usage: just local 3
local episode *flags:
    {{ publish_script }} "{{ episode }}" --transcribe --skip-upload {{ flags }}

# transcribe (no Claude chapters), save locally (no R2 upload)
# Usage: just local-nochapters 3
local-nochapters episode *flags:
    {{ publish_script }} "{{ episode }}" --transcribe --no-chapters --skip-upload {{ flags }}

# encode + embed existing chapters, save locally (no transcription, no R2 upload)
# Usage: just local-notx 3
local-notx episode *flags:
    {{ publish_script }} "{{ episode }}" --skip-upload {{ flags }}

# ------------------------------------------------------------
# Utility recipes
# ------------------------------------------------------------

# Re-generate chapters from existing transcript in the episode file
# Usage: just chapters 3
#        just chapters 3 --force-chapters
chapters episode *flags:
    {{ publish_script }} "{{ episode }}" --generate-chapters {{ flags }}

# Upload an already-encoded MP3 to R2 (skips encode, no transcription)
# Usage: just upload episodes/0003.md audio/bitflip-e003.mp3
upload episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-encode

# Show what a publish run would do without making any changes
# Usage: just dry-run 3
dry-run episode *flags:
    {{ publish_script }} "{{ episode }}" --dry-run {{ flags }}

# Replace Speaker_NN labels in a transcript with real names, then git commit
# Usage: just fix-speakers 3
fix-speakers episode:
    ./fix-speakers.sh "{{ episode }}"
