export type EpisodeLike = {
  date?: string | Date;
  episodeNumber?: number;
  data?: { date: string | Date; episodeNumber?: number };
};

function readDate(episode: EpisodeLike): string | Date {
  if (episode.date) return episode.date;
  if (episode.data?.date) return episode.data.date;
  throw new Error("Episode is missing date");
}

function readEpisodeNumber(episode: EpisodeLike): number {
  if (typeof episode.episodeNumber === "number") return episode.episodeNumber;
  if (typeof episode.data?.episodeNumber === "number") return episode.data.episodeNumber;
  throw new Error("Episode is missing episodeNumber");
}

function toDate(value: string | Date): Date {
  return value instanceof Date ? value : new Date(value);
}

export function getLatestEpisode<T extends EpisodeLike>(episodes: T[]): T {
  return [...episodes].sort((a, b) => {
    return toDate(readDate(b)).getTime() - toDate(readDate(a)).getTime();
  })[0];
}

export function getOlderEpisodes<T extends EpisodeLike>(
  episodes: T[],
  latest: T
): T[] {
  return episodes
    .filter((episode) => episode !== latest)
    .sort((a, b) => toDate(readDate(b)).getTime() - toDate(readDate(a)).getTime());
}

export function findEpisodeByNumber<T extends EpisodeLike>(
  episodes: T[],
  episodeNumber: number
): T | undefined {
  return episodes.find((episode) => readEpisodeNumber(episode) === episodeNumber);
}

export function formatEpisodeDate(date: string): string {
  return new Date(`${date}T12:00:00.000Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}
