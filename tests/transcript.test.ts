import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import {
  parseTranscript,
  stripFrontmatter,
  timestampToSeconds,
} from "../src/lib/transcript";

it("parses speaker cues with timestamps", () => {
  const md = [
    "## Transcript",
    "",
    "**Alex**: welcome to the show",
    "*00:00*",
    "",
    "**Geoff**: glad to be here",
    "*01:23:45*",
  ].join("\n");

  const cues = parseTranscript(md);
  expect(cues).toEqual([
    { speaker: "Alex", text: "welcome to the show", timestamp: "00:00" },
    { speaker: "Geoff", text: "glad to be here", timestamp: "01:23:45" },
  ]);
});

it("returns no cues when there is no transcript section", () => {
  expect(parseTranscript("## Links\n\n- https://example.com\n")).toEqual([]);
});

it("strips YAML frontmatter", () => {
  const stripped = stripFrontmatter("---\ntitle: x\n---\n## Body\n");
  expect(stripped).toBe("## Body\n");
});

it("converts timestamps to seconds", () => {
  expect(timestampToSeconds("01:02:03")).toBe(3723);
  expect(timestampToSeconds("12:34")).toBe(754);
  expect(timestampToSeconds(null)).toBeNull();
});

// Guard the real pipeline: a published episode's transcript must parse.
it("extracts cues from a published episode file", () => {
  const raw = readFileSync(new URL("../episodes/0001.md", import.meta.url), "utf-8");
  const cues = parseTranscript(stripFrontmatter(raw));
  expect(cues.length).toBeGreaterThan(10);
  expect(cues[0].speaker).toBe("Alex");
});
