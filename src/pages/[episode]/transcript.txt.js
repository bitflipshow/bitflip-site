import { getCollection } from "astro:content";
import { readEpisodeSource } from "../../lib/episode-source";
import { parseTranscript, stripFrontmatter } from "../../lib/transcript";

export async function getStaticPaths() {
  const episodes = await getCollection("episodes", ({ data }) => !data.draft);
  return episodes.map((episode) => ({
    params: { episode: String(episode.data.episodeNumber) },
    props: { episode },
  }));
}

export async function GET({ props }) {
  const { episode } = props;

  const raw = await readEpisodeSource(episode);
  const cues = parseTranscript(stripFrontmatter(raw));

  if (cues.length === 0) {
    return new Response("No transcript available.", {
      headers: { "Content-Type": "text/plain; charset=utf-8" },
      status: 404,
    });
  }

  const output = cues
    .map(({ speaker, text, timestamp }) => {
      const prefix = timestamp ? `[${timestamp}] ` : "";
      return `${prefix}${speaker}: ${text}`;
    })
    .join("\n\n");

  return new Response(output, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
