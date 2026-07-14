import { getCollection } from "astro:content";
import { readEpisodeSource } from "../../lib/episode-source";
import {
  parseTranscript,
  timestampToSeconds,
  stripFrontmatter,
} from "../../lib/transcript";

export async function getStaticPaths() {
  const episodes = await getCollection("episodes", ({ data }) => !data.draft);
  return episodes.map((episode) => ({
    params: { episode: String(episode.data.episodeNumber) },
    props: { episode },
  }));
}

/**
 * Format seconds as HH:MM:SS.mmm. The short MM:SS.mmm form is valid WebVTT,
 * but some podcast app transcript parsers only accept full-length timestamps.
 */
function toVtt(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = (seconds % 60).toFixed(3).padStart(6, "0");
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${s}`;
}

export async function GET({ props }) {
  const { episode } = props;

  const raw = await readEpisodeSource(episode);
  const cues = parseTranscript(stripFrontmatter(raw));

  if (cues.length === 0) {
    return new Response("WEBVTT\n\n# No transcript available\n", {
      headers: { "Content-Type": "text/vtt; charset=utf-8" },
      status: 404,
    });
  }

  const FALLBACK_DURATION = 30;

  const lines = ["WEBVTT", ""];

  for (let i = 0; i < cues.length; i++) {
    const cue = cues[i];
    const startSec = timestampToSeconds(cue.timestamp) ?? 0;

    // Find next cue with a timestamp for end time
    let nextTimestamp = null;
    for (let k = i + 1; k < cues.length; k++) {
      if (cues[k].timestamp) {
        nextTimestamp = cues[k].timestamp;
        break;
      }
    }
    let endSec = nextTimestamp
      ? timestampToSeconds(nextTimestamp)
      : startSec + FALLBACK_DURATION;

    if (endSec <= startSec) endSec = startSec + FALLBACK_DURATION;

    lines.push(`${toVtt(startSec)} --> ${toVtt(endSec)}`);
    lines.push(`[${cue.speaker}]: ${cue.text}`);
    lines.push("");
  }

  return new Response(lines.join("\n"), {
    headers: { "Content-Type": "text/vtt; charset=utf-8" },
  });
}
