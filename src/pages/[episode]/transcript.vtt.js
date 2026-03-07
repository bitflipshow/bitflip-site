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
 *   *HH:MM:SS*
 *
 * Consecutive lines from the same speaker (no timestamp in between) are merged.
 */
function parseTranscript(rawMarkdown) {
  const lines = rawMarkdown.split("\n");

  // Find the transcript section
  const transcriptStart = lines.findIndex((l) =>
    /^##\s+transcript/i.test(l.trim())
  );
  if (transcriptStart === -1) return [];

  const section = lines.slice(transcriptStart + 1);

  const cues = [];
  let i = 0;

  while (i < section.length) {
    const line = section[i].trim();

    // Speaker line: **Name**: text
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

/** Convert HH:MM:SS to total seconds */
function toSeconds(ts) {
  if (!ts) return null;
  const parts = ts.split(":").map(Number);
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return parts[0];
}

/** Format seconds as WebVTT timestamp: HH:MM:SS.000 */
function toVtt(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}.000`;
}

export async function GET({ props, params }) {
  const { episode } = props;

  // Read the raw .md file from the content collection
  const mdPath = path.resolve(
    process.cwd(),
    "src/content/episodes",
    `${episode.id}`
  );

  let raw;
  try {
    raw = await fs.readFile(mdPath, "utf-8");
  } catch {
    return new Response("WEBVTT\n\n# No transcript available\n", {
      headers: { "Content-Type": "text/vtt; charset=utf-8" },
    });
  }

  // Strip frontmatter
  const body = raw.replace(/^---[\s\S]*?---\n/, "");
  const cues = parseTranscript(body);

  if (cues.length === 0) {
    return new Response("WEBVTT\n\n# No transcript available\n", {
      headers: { "Content-Type": "text/vtt; charset=utf-8" },
      status: 404,
    });
  }

  // Build VTT cues — use next cue's timestamp as end time, +30s fallback for last
  const FALLBACK_DURATION = 30;
  const lines = ["WEBVTT", ""];

  for (let i = 0; i < cues.length; i++) {
    const cue = cues[i];
    const startSec = toSeconds(cue.timestamp) ?? 0;

    let endSec;
    // Find the next cue that has a timestamp
    let nextTimestamp = null;
    for (let k = i + 1; k < cues.length; k++) {
      if (cues[k].timestamp) {
        nextTimestamp = cues[k].timestamp;
        break;
      }
    }
    endSec = nextTimestamp
      ? toSeconds(nextTimestamp)
      : startSec + FALLBACK_DURATION;

    // Ensure end is always after start
    if (endSec <= startSec) endSec = startSec + FALLBACK_DURATION;

    lines.push(`${toVtt(startSec)} --> ${toVtt(endSec)}`);
    lines.push(`<v ${cue.speaker}>${cue.text}`);
    lines.push("");
  }

  return new Response(lines.join("\n"), {
    headers: { "Content-Type": "text/vtt; charset=utf-8" },
  });
}