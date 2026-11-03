import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // worker/worker.test.js is a node:test file (CI runs it with `node --test`),
    // so keep vitest to the site unit tests.
    include: ["tests/**/*.test.ts"],
  },
});
