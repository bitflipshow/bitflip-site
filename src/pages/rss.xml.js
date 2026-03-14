import { getCollection } from "astro:content";
import { SITE } from "../config";
import fs from "node:fs/promises";
import path from "node:path";

function inferEnclosureType(audioUrl) {
  const normalized = audioUrl.split("?")[0].toLowerCase();
  if (normalized.endsWith(".wav")) return "audio/wav";
  if (normalized.endsWith(".flac")) return "audio/flac";
  if (normalized.endsWith(".m4a")) return "audio/mp4";
  if (normalized.endsWith(".ogg")) return "audio/ogg";
  if (normalized.endsWith(".opus")) return "audio/opus";
  return "audio/mpeg";
}

async function hasTranscript(episode) {
  try {
    const mdPath = path.resolve(
      process.cwd(),
      "src/content/episodes",
      episode.id
    );
    const raw = await fs.readFile(mdPath, "utf-8");
    return /^##\s+transcript/im.test(raw);
  } catch {
    return false;
  }
}

function escapeXml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export async function GET(context) {
  const episodes = await getCollection("episodes", ({ data }) => !data.draft);

  const sortedEpisodes = episodes.sort(
    (a, b) => new Date(b.data.date).getTime() - new Date(a.data.date).getTime()
  );

  const siteUrl =
    context.site?.toString().replace(/\/$/, "") || "https://bitflip.show";

  const transcriptFlags = await Promise.all(
    sortedEpisodes.map((ep) => hasTranscript(ep))
  );

  const items = sortedEpisodes.map((episode, idx) => {
    const coverUrl = episode.data.coverImage?.startsWith("http")
      ? episode.data.coverImage
      : `${siteUrl}${episode.data.coverImage}`;

    const hasChapters =
      episode.data.chapters && episode.data.chapters.length > 0;
    const chaptersUrl = `${siteUrl}/${episode.data.episodeNumber}/chapters.json`;

    const epHasTranscript = transcriptFlags[idx];
    const vttUrl = `${siteUrl}/${episode.data.episodeNumber}/transcript.vtt`;
    const txtUrl = `${siteUrl}/${episode.data.episodeNumber}/transcript.txt`;

    const pubDate = new Date(
      `${episode.data.date}T12:00:00.000Z`
    ).toUTCString();

    return `<item>
      <title>${escapeXml(episode.data.title)}</title>
      <link>${siteUrl}/${episode.data.episodeNumber}</link>
      <guid isPermaLink="true">${siteUrl}/${episode.data.episodeNumber}</guid>
      <description>${escapeXml(episode.data.summary)}</description>
      <pubDate>${pubDate}</pubDate>
      <enclosure url="${escapeXml(episode.data.audioUrl)}" length="${episode.data.audioSize}" type="${inferEnclosureType(episode.data.audioUrl)}" />
      <itunes:title>${escapeXml(episode.data.title)}</itunes:title>
      ${episode.data.episodeNumber > 0 ? `<itunes:episode>${episode.data.episodeNumber}</itunes:episode>` : ""}
      <itunes:episodeType>full</itunes:episodeType>
      <itunes:duration>${escapeXml(episode.data.duration)}</itunes:duration>
      <itunes:explicit>${episode.data.explicit ? "true" : "false"}</itunes:explicit>
      <itunes:summary>${escapeXml(episode.data.summary)}</itunes:summary>
      <itunes:image href="${coverUrl}" />
      ${hasChapters ? `<podcast:chapters url="${chaptersUrl}" type="application/json+chapters" />` : ""}
      ${epHasTranscript ? `<podcast:transcript url="${vttUrl}" type="text/vtt" rel="captions" />` : ""}
      ${epHasTranscript ? `<podcast:transcript url="${txtUrl}" type="text/plain" />` : ""}
    </item>`;
  });

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
  xmlns:podcast="https://podcastindex.org/namespace/1.0"
  xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>${escapeXml(SITE.title)}</title>
    <description>${escapeXml(SITE.tagline)}</description>
    <link>${siteUrl}/</link>
    <language>en-us</language>
    <itunes:author>${escapeXml(SITE.title)}</itunes:author>
    <itunes:summary>${escapeXml(SITE.tagline)}</itunes:summary>
    <itunes:type>episodic</itunes:type>
    <itunes:owner>
      <itunes:name>${escapeXml(SITE.title)}</itunes:name>
      <itunes:email>${escapeXml(SITE.email)}</itunes:email>
    </itunes:owner>
    <itunes:explicit>false</itunes:explicit>
    <itunes:category text="Technology" />
    <itunes:image href="${siteUrl}/images/podcast-cover.png" />
    <atom:link href="${siteUrl}/rss.xml" rel="self" type="application/rss+xml" />
    <podcast:locked>no</podcast:locked>
    <podcast:guid>0c9a64c8-fda0-4fb3-bd87-60f8faeb13c3</podcast:guid>
    ${items.join("\n    ")}
  </channel>
</rss>`;

  return new Response(xml, {
    headers: {
      "Content-Type": "application/rss+xml; charset=utf-8",
    },
  });
}