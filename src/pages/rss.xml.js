import rss from "@astrojs/rss";
import { getCollection } from "astro:content";
import { SITE } from "../config";

export async function GET(context) {
  const episodes = await getCollection("episodes", ({ data }) => !data.draft);
  
  // Sort episodes by date, newest first
  const sortedEpisodes = episodes.sort((a, b) => 
    new Date(b.data.date).getTime() - new Date(a.data.date).getTime()
  );

  const siteUrl = context.site?.toString().replace(/\/$/, "") || "https://bitflip.show";

  return rss({
    title: SITE.title,
    description: SITE.tagline,
    site: siteUrl,
    items: sortedEpisodes.map((episode) => {
      const coverUrl = episode.data.coverImage?.startsWith("http")
        ? episode.data.coverImage
        : `${siteUrl}${episode.data.coverImage}`;

      return {
        title: episode.data.title,
        description: episode.data.summary,
        pubDate: new Date(`${episode.data.date}T12:00:00.000Z`),
        link: `${siteUrl}/${episode.data.episodeNumber}`,
        enclosure: {
          url: episode.data.audioUrl,
          length: episode.data.audioSize,
          type: "audio/mpeg",
        },
        customData: `
        <itunes:title>${episode.data.title}</itunes:title>
        <itunes:episode>${episode.data.episodeNumber}</itunes:episode>
        <itunes:episodeType>full</itunes:episodeType>
        <itunes:duration>${episode.data.duration}</itunes:duration>
        <itunes:explicit>${episode.data.explicit ? "yes" : "no"}</itunes:explicit>
        <itunes:summary>${episode.data.summary}</itunes:summary>
        <itunes:image href="${coverUrl}" />
        `.trim(),
      };
    }),
    customData: `
    <language>en-us</language>
    <itunes:author>${SITE.title}</itunes:author>
    <itunes:summary>${SITE.tagline}</itunes:summary>
    <itunes:type>episodic</itunes:type>
    <itunes:owner>
      <itunes:name>${SITE.title}</itunes:name>
      <itunes:email>${SITE.email}</itunes:email>
    </itunes:owner>
    <itunes:explicit>no</itunes:explicit>
    <itunes:category text="Technology" />
    <itunes:image href="${siteUrl}/images/podcast-cover.png" />
    `.trim(),
    xmlns: {
      itunes: "http://www.itunes.com/dtds/podcast-1.0.dtd",
    },
  });
}