import { defineConfig } from "@playwright/test";

// Test runner config. We use @playwright/test as the runner (not jest/mocha) per
// the build spec. Tests live in `tests/` and are plain Node.js — most of them
// don't even drive a browser, they exercise the MCP wire protocol or the
// per-session lifecycle in isolation. The tests that DO need Chromium spawn
// the server as a child process and talk to it over stdio.
export default defineConfig({
  testDir: "./tests",
  testMatch: /.*\.test\.ts$/,
  timeout: 30_000,
  fullyParallel: false, // server tests share global Chromium install; serial avoids contention.
  workers: 1,
  reporter: [["list"]],
  use: {
    // Most tests don't use the Playwright browser fixture; they drive the MCP
    // server which has its OWN browser pool. These are just sensible defaults
    // for the rare test that does spin up a browser directly.
    headless: true,
    actionTimeout: 10_000,
  },
});
