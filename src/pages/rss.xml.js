import rss from "@astrojs/rss";
import { getCollection } from "astro:content";

export async function GET(context) {
  const episodes = await getCollection("episodes");
  
  // Sort episodes by date, newest first
  const sortedEpisodes = episodes.sort((a, b) => 
    new Date(b.data.date).getTime() - new Date(a.data.date).getTime()
  );

  return rss({
    title: "BitFlip.show",
    description: "The pragmatic side of infrastructure.",
    site: context.site || "https://bitflip.show",
    items: sortedEpisodes.map((episode) => ({
      title: episode.data.title,
      description: episode.data.summary,
      pubDate: new Date(episode.data.date),
      link: `/${episode.data.episodeNumber}`,
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
      ${episode.data.coverImage ? `<itunes:image href="${episode.data.coverImage}" />` : ''}
      `.trim(),
    })),
    customData: `
    <language>en-us</language>
    <itunes:author>BitFlip.show</itunes:author>
    <itunes:summary>The pragmatic side of infrastructure.</itunes:summary>
    <itunes:type>episodic</itunes:type>
    <itunes:owner>
      <itunes:name>BitFlip.show</itunes:name>
      <itunes:email>podcast@bitflip.show</itunes:email>
    </itunes:owner>
    <itunes:explicit>no</itunes:explicit>
    <itunes:category text="Technology" />
    <itunes:image href="https://bitflip.show/cover.png" />
    `.trim(),
    xmlns: {
      itunes: "http://www.itunes.com/dtds/podcast-1.0.dtd",
    },
  });
}