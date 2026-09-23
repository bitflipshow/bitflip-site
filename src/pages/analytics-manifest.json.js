import { getCollection } from "astro:content";

export async function GET() {
  const episodes = await getCollection("episodes", ({ data }) => !data.draft);
  return new Response(JSON.stringify(episodes.map(({ data }) => ({
    number: Number(data.episodeNumber),
    title: data.title,
    published: data.date,
    audioUrl: data.audioUrl,
    audioSize: data.audioSize,
    duration: data.duration,
    youtubeUrl: data.youtubeUrl ?? null,
  }))), { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=3600" } });
}
