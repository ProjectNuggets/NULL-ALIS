// BrowserContext > idle_timeout is freed.
// We use a 100ms timeout and drive the reaper manually so the test is fast +
// deterministic (AGENTS.md §3.6 — no flake).

import { expect, test } from "@playwright/test";
import { BrowserPool } from "../src/browser.js";
import { navigate } from "../src/tools/navigate.js";
import { startFixture } from "./fixture_server.js";

test("idle session is reaped after the configured timeout", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({
    headless: true,
    idle_timeout_ms: 100,
    disable_reaper: true, // we drive it manually
  });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "doomed" });
    expect(pool.listSessions()).toHaveLength(1);

    // Pretend a lot of time has passed.
    const future = Date.now() + 60_000;
    const reaped = await pool.reapIdle(future);
    expect(reaped).toBe(1);
    expect(pool.listSessions()).toHaveLength(0);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("active session is NOT reaped while within the idle window", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({
    headless: true,
    idle_timeout_ms: 60_000, // 1 minute
    disable_reaper: true,
  });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "alive" });
    // Run the reaper "now" — nothing should be reaped.
    const reaped = await pool.reapIdle();
    expect(reaped).toBe(0);
    expect(pool.listSessions()).toHaveLength(1);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});
