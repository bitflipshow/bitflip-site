# BitFlip.show

The official site for BitFlip.show — the pragmatic side of infrastructure.

## Stack

- Astro (static site)
- Cloudflare Pages (hosting)
- Cloudflare R2 (audio files)
- YouTube (video)

## Content authoring

Episodes are authored as single Markdown files in `src/content/episodes/` (symlinked to `episodes`) with YAML frontmatter and a Markdown body.

Required frontmatter:

```yaml
episodeNumber: 0001
title: "Episode title"
date: "2026-01-30"
summary: "Short summary for cards and RSS"
audioUrl: "https://<public-r2-url>/episode.mp3"
audioSize: 12345678
duration: "00:58:12"
explicit: false
```

Optional:

```yaml
draft: false
coverImage: "/images/cover-101.png" # Default is /images/podcast-cover.png, use for special episode covers
youtubeUrl: "https://youtube.com/watch?v=..."
transcriptUrl: "https://example.com/transcripts/episode.txt"
chapters:
  - time: "00:00:00"
    title: "Intro"
tags:
  - backups
  - networking
hosts:
  - geoff
  - adam
  - stephen
  - alex
guests:
  - name: "Jane Smith"
    avatar: "generic-guest.jpg"
    link: "https://janesmith.dev"
sponsors:
  - name: "Sponsor Name"
    url: "https://example.com"
    blurb: "Sponsor message"
```

The Markdown body is used for full show notes and links.

## Publishing workflow

1. **Record and mix audio.** Export your final mix as WAV or FLAC.

2. **Create the episode Markdown file** in `episodes/` with required frontmatter. Leave `audioUrl`, `audioSize`, and `duration` blank — the publish script fills these in.

3. **Run `publish.sh`:**

```bash
./publish.sh episodes/0042-slug.md recording.flac [options]
```

The script will:
- Encode a distribution-ready MP3 (112kbps CBR mono, ID3v2 tags, embedded cover art and chapters)
- Upload the MP3 to Cloudflare R2
- Patch `audioUrl`, `audioSize`, and `duration` in the episode frontmatter automatically

**Options:**

| Flag | Description |
|---|---|
| `--cover <file>` | Cover art image (default: `public/images/podcast-cover.png`) |
| `--skip-encode` | Skip encoding; use source file as-is (must already be an MP3) |
| `--skip-upload` | Skip R2 upload |
| `--transcribe` | Transcribe with faster-whisper and embed transcript in the episode Markdown |
| `--dry-run` | Show what would happen without making any changes |

**Transcription** (`--transcribe`) uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) and optionally [pyannote](https://github.com/pyannote/pyannote-audio) for speaker diarization. Configure at the top of the script:

```bash
WHISPER_MODE="local"          # "local" or "remote" (SSH)
WHISPER_MODEL="large-v3-turbo"
WHISPER_BEAM=10               # 1=fastest, 5=default, 10=most accurate
WHISPER_LANG="en"
WHISPER_DIARIZE=true         # true to label Speaker_00, Speaker_01, etc.
WHISPER_HF_TOKEN_FILE="~/.config/bitflip/hf_token"   # required for diarization
WHISPER_PROMPT="..."          # optional context to improve accuracy
```

Diarization requires a [Hugging Face](https://huggingface.co/) token with access to [`pyannote/speaker-diarization-community-1`](https://huggingface.co/pyannote/speaker-diarization-community-1). Store your token in `~/.config/bitflip/hf_token`.

4. **Commit and push** — GitHub Actions deploys to Cloudflare Pages.

### One-time setup

**rclone R2 remote** (required for upload):

```bash
rclone config
# New remote > name: r2 > type: s3 > provider: Cloudflare
# access_key_id + secret_access_key from R2 dashboard > API tokens
# endpoint: https://<account-id>.r2.cloudflarestorage.com
# leave region blank
```

**Script dependencies:** `ffmpeg`, `ffprobe`, `rclone`. For `--transcribe local`: `python3`. For `--transcribe remote`: `ssh`, `scp`, and `python3` on the remote host. The Python venv and all packages are created and managed automatically.

## Audio player

The site uses a sticky footer player that can be triggered from the episode list or episode pages. It stores playback state in local storage and resumes on navigation.

## RSS feed

`/rss.xml` is generated at build time from episode metadata.

## Local development

```bash
npm install
npm run dev
```

## Local testing

```bash
npm run build && npm run preview -- --host
```

## Deploy

Set the following GitHub secrets for Pages:

- `CF_API_TOKEN`
- `CF_ACCOUNT_ID`

Update `projectName` in `.github/workflows/deploy.yml` if needed.