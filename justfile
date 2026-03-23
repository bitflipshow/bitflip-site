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
# Publishing recipes
#
# publish              transcribe + Claude chapters + upload
# publish-nochapters   transcribe only              + upload
# publish-notx         (no transcription)           + upload
# local                transcribe + Claude chapters  (no upload)
# local-nochapters     transcribe only               (no upload)
# local-notx           (no transcription)            (no upload)
# ------------------------------------------------------------

# transcribe + Claude chapters + R2 upload
# Usage: just publish episodes/0042-slug.md recording.flac
#        just publish episodes/0042-slug.md recording.flac cover.png  (with custom cover art)
publish episode audio cover="":
    #!/usr/bin/env bash
    args=("{{ episode }}" "{{ audio }}" --transcribe)
    [[ -n "{{ cover }}" ]] && args+=(--cover "{{ cover }}")
    {{ publish_script }} "${args[@]}"

# transcribe (no Claude chapters) + R2 upload
# Usage: just publish-nochapters episodes/0042-slug.md recording.flac
publish-nochapters episode audio cover="":
    #!/usr/bin/env bash
    args=("{{ episode }}" "{{ audio }}" --transcribe --no-chapters)
    [[ -n "{{ cover }}" ]] && args+=(--cover "{{ cover }}")
    {{ publish_script }} "${args[@]}"

# encode + embed existing chapters + R2 upload (no transcription, no Claude chapters)
# Usage: just publish-notx episodes/0042-slug.md recording.flac
publish-notx episode audio cover="":
    #!/usr/bin/env bash
    args=("{{ episode }}" "{{ audio }}")
    [[ -n "{{ cover }}" ]] && args+=(--cover "{{ cover }}")
    {{ publish_script }} "${args[@]}"

# transcribe + Claude chapters, save locally (no R2 upload)
# Usage: just local episodes/0042-slug.md recording.flac
#        just local episodes/0042-slug.md recording.flac output.mp3
local episode audio output="":
    #!/usr/bin/env bash
    args=("{{ episode }}" "{{ audio }}" --transcribe --skip-upload)
    [[ -n "{{ output }}" ]] && args+=(--output "{{ output }}")
    {{ publish_script }} "${args[@]}"

# transcribe (no Claude chapters), save locally (no R2 upload)
# Usage: just local-nochapters episodes/0042-slug.md recording.flac
local-nochapters episode audio output="":
    #!/usr/bin/env bash
    args=("{{ episode }}" "{{ audio }}" --transcribe --no-chapters --skip-upload)
    [[ -n "{{ output }}" ]] && args+=(--output "{{ output }}")
    {{ publish_script }} "${args[@]}"

# encode + embed existing chapters, save locally (no transcription, no Claude chapters, no R2 upload)
# Usage: just local-notx episodes/0042-slug.md recording.flac
local-notx episode audio output="":
    #!/usr/bin/env bash
    args=("{{ episode }}" "{{ audio }}" --skip-upload)
    [[ -n "{{ output }}" ]] && args+=(--output "{{ output }}")
    {{ publish_script }} "${args[@]}"

# ------------------------------------------------------------
# Utility recipes
# ------------------------------------------------------------

# Re-generate chapters from existing transcript in the episode file.
# Pass --force-chapters to overwrite existing frontmatter chapters without prompting.
# Usage: just chapters episodes/0042-slug.md
#        just chapters episodes/0042-slug.md --force-chapters
chapters episode *flags:
    {{ publish_script }} "{{ episode }}" --generate-chapters {{ flags }}

# Upload an already-encoded MP3 to R2 (skips encode, no transcription)
# Usage: just upload episodes/0042-slug.md episode.mp3
upload episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --skip-encode

# Show what a publish run would do without making any changes
# Usage: just dry-run episodes/0042-slug.md recording.flac
dry-run episode audio:
    {{ publish_script }} "{{ episode }}" "{{ audio }}" --dry-run
