import fs from "node:fs/promises";
import path from "node:path";

/**
 * Read the raw markdown source of a content collection entry.
 *
 * Uses the loader-provided `filePath` (relative to the project root) rather
 * than reconstructing the path from `entry.id`, which no longer includes the
 * file extension. Throws at build time if the file cannot be read — the entry
 * came from this file, so a read failure is always a bug.
 */
export async function readEpisodeSource(entry: {
  id: string;
  filePath?: string;
}): Promise<string> {
  if (!entry.filePath) {
    throw new Error(`Episode entry "${entry.id}" has no filePath`);
  }
  return fs.readFile(path.resolve(process.cwd(), entry.filePath), "utf-8");
}
