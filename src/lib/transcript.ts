export interface TranscriptCue {
  speaker: string;
  text: string;
  timestamp: string | null;
}

/**
 * Parse the raw .md body for transcript lines.
 *
 * Expected format in the markdown body:
 *   ## Transcript
 *   **Speaker Name**: line of dialogue
 *   *HH:MM:SS*  or  *MM:SS*
 */
export function parseTranscript(rawMarkdown: string): TranscriptCue[] {
  const lines = rawMarkdown.split("\n");

  const transcriptStart = lines.findIndex((l) =>
    /^##\s+transcript/i.test(l.trim())
  );
  if (transcriptStart === -1) return [];

  const section = lines.slice(transcriptStart + 1);
  const cues: TranscriptCue[] = [];
  let i = 0;

  while (i < section.length) {
    const line = section[i].trim();
    const speakerMatch = line.match(/^\*\*(.+?)\*\*:\s*(.*)$/);

    if (speakerMatch) {
      const speaker = speakerMatch[1];
      const text = speakerMatch[2];

      // Look ahead for timestamp on next non-empty line
      let timestamp: string | null = null;
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
export function timestampToSeconds(ts: string | null): number | null {
  if (!ts) return null;
  const parts = ts.split(":").map(Number);
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return parts[0];
}

/** Strip YAML frontmatter from raw markdown */
export function stripFrontmatter(rawMarkdown: string): string {
  return rawMarkdown.replace(/^---[\s\S]*?---\n?/, "");
}
