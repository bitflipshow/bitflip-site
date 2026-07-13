import { getCollection } from "astro:content";
import { SITE } from "../config";
import { readEpisodeSource } from "../lib/episode-source";
import { stripFrontmatter } from "../lib/transcript";
import MarkdownIt from "markdown-it";
import sanitizeHtml from "sanitize-html";

const md = new MarkdownIt({ html: true, linkify: true });

function inferEnclosureType(audioUrl) {
  const normalized = audioUrl.split("?")[0].toLowerCase();
  if (normalized.endsWith(".wav")) return "audio/wav";
  if (normalized.endsWith(".flac")) return "audio/flac";
  if (normalized.endsWith(".m4a")) return "audio/mp4";
  if (normalized.endsWith(".ogg")) return "audio/ogg";
  if (normalized.endsWith(".opus")) return "audio/opus";
  return "audio/mpeg";
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

  const episodeSources = await Promise.all(
    sortedEpisodes.map(async (episode) => {
      const raw = await readEpisodeSource(episode);
      const withoutFrontmatter = stripFrontmatter(raw);
      const hasTranscript = /^##\s+transcript/im.test(withoutFrontmatter);
      // Strip ## Transcript section (and everything after) appended by publish script
      const body = withoutFrontmatter.replace(/^##\s+transcript[\s\S]*/im, "").trimEnd();
      const html = sanitizeHtml(md.render(body), {
        allowedTags: sanitizeHtml.defaults.allowedTags.concat(["img"]),
        allowedAttributes: {
          ...sanitizeHtml.defaults.allowedAttributes,
          img: ["src", "alt", "title", "width", "height"],
          a: ["href", "name", "target", "rel"],
        },
      });
      return { hasTranscript, html };
    })
  );

  const items = sortedEpisodes.map((episode, idx) => {
    const coverUrl = episode.data.coverImage?.startsWith("http")
      ? episode.data.coverImage
      : `${siteUrl}${episode.data.coverImage}`;

    const hasChapters =
      episode.data.chapters && episode.data.chapters.length > 0;
    const chaptersUrl = `${siteUrl}/${episode.data.episodeNumber}/chapters.json`;

    const epHasTranscript = episodeSources[idx].hasTranscript;
    const vttUrl = `${siteUrl}/${episode.data.episodeNumber}/transcript.vtt`;
    const txtUrl = `${siteUrl}/${episode.data.episodeNumber}/transcript.txt`;

    const pubDate = new Date(
      `${episode.data.date}T12:00:00.000Z`
    ).toUTCString();

    return `<item>
      <title>${escapeXml(episode.data.title)}</title>
      <link>${siteUrl}/${episode.data.episodeNumber}</link>
      <guid isPermaLink="true">${siteUrl}/${episode.data.episodeNumber}</guid>
      <description><![CDATA[${episode.data.summary}]]></description>
      <pubDate>${pubDate}</pubDate>
      <enclosure url="${escapeXml(episode.data.audioUrl)}" length="${episode.data.audioSize}" type="${inferEnclosureType(episode.data.audioUrl)}" />
      <content:encoded><![CDATA[${episodeSources[idx].html}]]></content:encoded>
      <itunes:title>${escapeXml(episode.data.title)}</itunes:title>
      ${episode.data.episodeNumber > 0 ? `<itunes:episode>${episode.data.episodeNumber}</itunes:episode>` : ""}
      <itunes:episodeType>full</itunes:episodeType>
      <itunes:duration>${escapeXml(episode.data.duration)}</itunes:duration>
      <itunes:explicit>${episode.data.explicit ? "true" : "false"}</itunes:explicit>
      <itunes:summary>${escapeXml(episode.data.summary)}</itunes:summary>
      <itunes:image href="${coverUrl}" />
      ${hasChapters ? `<podcast:chapters url="${chaptersUrl}" type="application/json+chapters" />` : ""}
      ${epHasTranscript ? `<podcast:transcript url="${vttUrl}" type="text/vtt" rel="captions" language="en" />` : ""}
      ${epHasTranscript ? `<podcast:transcript url="${txtUrl}" type="text/plain" language="en" />` : ""}
    </item>`;
  });

  const coverImageUrl = `${siteUrl}${SITE.coverImage}`;

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
  xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
  xmlns:podcast="https://podcastindex.org/namespace/1.0"
  xmlns:atom="http://www.w3.org/2005/Atom"
  xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>${escapeXml(SITE.title)}</title>
    <description><![CDATA[${SITE.tagline}]]></description>
    <link>${siteUrl}/</link>
    <language>en-us</language>
    <image>
      <url>${coverImageUrl}</url>
      <title>${escapeXml(SITE.title)}</title>
      <link>${siteUrl}/</link>
    </image>
    <itunes:author>${escapeXml(SITE.title)}</itunes:author>
    <itunes:summary>${escapeXml(SITE.tagline)}</itunes:summary>
    <itunes:type>episodic</itunes:type>
    <itunes:owner>
      <itunes:name>${escapeXml(SITE.title)}</itunes:name>
      <itunes:email>${escapeXml(SITE.email)}</itunes:email>
    </itunes:owner>
    <itunes:explicit>false</itunes:explicit>
    <itunes:category text="Technology" />
    <itunes:image href="${coverImageUrl}" />
    <atom:link href="${siteUrl}/rss.xml" rel="self" type="application/rss+xml" />
    <podcast:locked>no</podcast:locked>
    <podcast:guid>${SITE.podcastGuid}</podcast:guid>
    ${items.join("\n    ")}
  </channel>
</rss>`;

  return new Response(xml, {
    headers: {
      "Content-Type": "application/rss+xml; charset=utf-8",
    },
  });
}