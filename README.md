# BitFlip.show

The official site for BitFlip.show — the pragmatic side of infrastructure.

## Stack

- Astro (static site)
- Cloudflare Pages (hosting)
- Cloudflare R2 (audio files)
- YouTube (video)

## Content authoring

Episodes are authored as single Markdown files in `episodes` (symlinked to `src/content/episodes/`) with YAML frontmatter and a Markdown body.

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

1. Record and mix audio.
2. Run `jivedrop` to generate MP3 with embedded metadata.
3. Upload MP3 to R2 and copy the public URL.
4. Update the episode Markdown frontmatter with `audioUrl`, `audioSize`, and `duration`.
5. Commit and push — GitHub Actions deploys to Cloudflare Pages.

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
