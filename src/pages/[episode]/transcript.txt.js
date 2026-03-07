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

export async function GET({ props }) {
  const { episode } = props;

  const mdPath = path.resolve(
    process.cwd(),
    "src/content/episodes",
    `${episode.id}`
  );

  let raw;
  try {
    raw = await fs.readFile(mdPath, "utf-8");
  } catch {
    return new Response("No transcript available.", {
      headers: { "Content-Type": "text/plain; charset=utf-8" },
      status: 404,
    });
  }

  const body = raw.replace(/^---[\s\S]*?---\n/, "");
  const cues = parseTranscript(body);

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