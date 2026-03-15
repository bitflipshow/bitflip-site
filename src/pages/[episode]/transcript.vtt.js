import { getCollection } from "astro:content";
import fs from "node:fs/promises";
import path from "node:path";

export async function getStaticPaths() {
  const episodes = await getCollection("episodes", ({ data }) => !data.draft);
  return episodes.map((episode) => ({
    params: { episode: String(episode.data.episodeNumber) },
    props: { episode },
  }));
}

/**
 * Parse the raw .md body for transcript lines.
 *
 * Expected format in the markdown body:
 *   ## Transcript
 *   **Speaker Name**: line of dialogue
 *   *HH:MM:SS*  or  *MM:SS*
 */
function parseTranscript(rawMarkdown) {
  const lines = rawMarkdown.split("\n");

  const transcriptStart = lines.findIndex((l) =>
    /^##\s+transcript/i.test(l.trim())
  );
  if (transcriptStart === -1) return [];

  const section = lines.slice(transcriptStart + 1);
  const cues = [];
  let i = 0;

  while (i < section.length) {
    const line = section[i].trim();
    const speakerMatch = line.match(/^\*\*(.+?)\*\*:\s*(.*)$/);

    if (speakerMatch) {
      const speaker = speakerMatch[1];
      const text = speakerMatch[2];

      // Look ahead for timestamp on next non-empty line
      let timestamp = null;
      let j = i + 1;
      while (j < section.length && section[j].trim() === "") j++;

      if (j < section.length) {
        const tsMatch = section[j].trim().match(/^\*(\d{1,2}:\d{2}(?::\d{2})?)\*$/);
        if (tsMatch) {
          timestamp = tsMatch[1];
          i = j + 1;
        } else {
          i++;
        }
      } else {
        i++;
      }

      cues.push({ speaker, text, timestamp });
    } else {
      i++;
    }
  }

  return cues;
}

/** Convert HH:MM:SS or MM:SS to total seconds */
function toSeconds(ts) {
  if (!ts) return null;
  const parts = ts.split(":").map(Number);
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return parts[0];
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

  const mdPath = path.resolve(
    process.cwd(),
    "src/content/episodes",
    episode.id   // episode.id already includes .md
  );

  let raw;
  try {
    raw = await fs.readFile(mdPath, "utf-8");
  } catch {
    return new Response("WEBVTT\n\n# No transcript available\n", {
      headers: { "Content-Type": "text/vtt; charset=utf-8" },
    });
  }

  const body = raw.replace(/^---[\s\S]*?---\n/, "");
  const cues = parseTranscript(body);

  if (cues.length === 0) {
    return new Response("WEBVTT\n\n# No transcript available\n", {
      headers: { "Content-Type": "text/vtt; charset=utf-8" },
      status: 404,
    });
  }

  // Determine if any cue exceeds 1 hour — if so, use HH:MM:SS.mmm throughout
  const FALLBACK_DURATION = 30;
  const allSeconds = cues
    .map((c) => toSeconds(c.timestamp))
    .filter((s) => s !== null);
  const maxSeconds = allSeconds.length ? Math.max(...allSeconds) : 0;
  const includeHours = maxSeconds >= 3600;

  const lines = ["WEBVTT", ""];

  for (let i = 0; i < cues.length; i++) {
    const cue = cues[i];
    const startSec = toSeconds(cue.timestamp) ?? 0;

    // Find next cue with a timestamp for end time
    let nextTimestamp = null;
    for (let k = i + 1; k < cues.length; k++) {
      if (cues[k].timestamp) {
        nextTimestamp = cues[k].timestamp;
        break;
      }
    }
    let endSec = nextTimestamp
      ? toSeconds(nextTimestamp)
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