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
 * Format seconds as MM:SS.mmm (matching AI-generated transcript style).
 * Omits the HH: component unless the episode is >= 1 hour.
 */
function toVtt(seconds, includeHours) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = (seconds % 60).toFixed(3).padStart(6, "0");
  if (includeHours) {
    return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${s}`;
  }
  return `${String(m).padStart(2, "0")}:${s}`;
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

  // Determine if any cue exceeds 1 hour — if so, use HH:MM:SS.mmm throughout
  const FALLBACK_DURATION = 30;
  const allSeconds = cues
    .map((c) => timestampToSeconds(c.timestamp))
    .filter((s) => s !== null);
  const maxSeconds = allSeconds.length ? Math.max(...allSeconds) : 0;
  const includeHours = maxSeconds >= 3600;

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

    lines.push(`${toVtt(startSec, includeHours)} --> ${toVtt(endSec, includeHours)}`);
    lines.push(`[${cue.speaker}]: ${cue.text}`);
    lines.push("");
  }

  return new Response(lines.join("\n"), {
    headers: { "Content-Type": "text/vtt; charset=utf-8" },
  });
}
