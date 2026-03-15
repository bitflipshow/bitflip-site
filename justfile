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
# Publish: full pipeline (encode + chapter embed + upload + patch frontmatter)
# Usage: just publish episodes/0042-slug.md recording.flac
# ------------------------------------------------------------

publish episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}"

# Full publish with transcription
publish-transcribe episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --transcribe

# Full publish with custom cover art
publish-cover episode audio cover:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --cover "{{ cover }}"

# ------------------------------------------------------------
# Encode only: encode + chapters, save to local file, no upload
# Usage: just encode episodes/0042-slug.md recording.flac
#        just encode episodes/0042-slug.md recording.flac output.mp3
# ------------------------------------------------------------

encode episode audio output="":
    #!/usr/bin/env bash
    if [[ -n "{{ output }}" ]]; then
        {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-upload --output "{{ output }}"
    else
        {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-upload
    fi

# Encode and transcribe, save locally, no upload
encode-transcribe episode audio output="":
    #!/usr/bin/env bash
    if [[ -n "{{ output }}" ]]; then
        {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-upload --transcribe --output "{{ output }}"
    else
        {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-upload --transcribe
    fi

# ------------------------------------------------------------
# Transcribe only: skip encode (audio must already be MP3), skip upload
# Usage: just transcribe episodes/0042-slug.md episode.mp3
# ------------------------------------------------------------

transcribe episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-encode --skip-upload --transcribe

# ------------------------------------------------------------
# Upload only: skip encode (audio must already be MP3)
# Usage: just upload episodes/0042-slug.md episode.mp3
# ------------------------------------------------------------

upload episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-encode

# ------------------------------------------------------------
# Dry run: show what would happen without making any changes
# Usage: just dry-run episodes/0042-slug.md recording.flac
# ------------------------------------------------------------

dry-run episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --dry-run
