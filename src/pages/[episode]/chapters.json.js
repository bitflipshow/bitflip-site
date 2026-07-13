import { getCollection } from "astro:content";
import { parseChapterTime } from "../../lib/chapters";

export async function getStaticPaths() {
  const episodes = await getCollection("episodes", ({ data }) => !data.draft);
  return episodes
    .filter((episode) => episode.data.chapters && episode.data.chapters.length > 0)
    .map((episode) => ({
      params: { episode: String(episode.data.episodeNumber) },
      props: { episode },
    }));
}

export async function GET({ props }) {
  const { episode } = props;

  const chapters = episode.data.chapters.map((chapter) => {
    const entry = { startTime: parseChapterTime(chapter.time), title: chapter.title };
    if (chapter.img) entry.img = chapter.img;
    if (chapter.url) entry.url = chapter.url;
    return entry;
  });

  return new Response(
    JSON.stringify({ version: "1.2.0", chapters }, null, 2),
    {
      headers: {
        "Content-Type": "application/json+chapters",
      },
    }
  );
}