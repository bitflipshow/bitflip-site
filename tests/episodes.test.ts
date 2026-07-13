import { expect, it } from "vitest";
import { findEpisodeByNumber, getLatestEpisode } from "../src/lib/episodes";

it("returns most recent by date", () => {
  const episodes = [
    { date: new Date("2025-01-01") },
    { date: new Date("2025-02-01") },
  ];
  expect(getLatestEpisode(episodes).date.toISOString()).toBe(
    "2025-02-01T00:00:00.000Z"
  );
});

it("finds by episodeNumber", () => {
  const eps = [{ episodeNumber: 101 }, { episodeNumber: 102 }];
  expect(findEpisodeByNumber(eps, 102)?.episodeNumber).toBe(102);
});

it("converts duration to ISO 8601", async () => {
  const { toIso8601Duration } = await import("../src/lib/episodes");
  expect(toIso8601Duration("52:52")).toBe("PT52M52S");
  expect(toIso8601Duration("01:02:03")).toBe("PT1H2M3S");
});

it("slugifies tags", async () => {
  const { slugifyTag } = await import("../src/lib/tags");
  expect(slugifyTag("vibe coding")).toBe("vibe-coding");
  expect(slugifyTag("Bambu Lab")).toBe("bambu-lab");
  expect(slugifyTag("dns-filtering")).toBe("dns-filtering");
});
