// navigate against the in-process fixture — assert title + final URL.
// Loopback is allowlisted via env so 127.0.0.1 passes the sanitizer.

import { expect, test } from "@playwright/test";
import { BrowserPool } from "../src/browser.js";
import { navigate } from "../src/tools/navigate.js";
import { getText } from "../src/tools/get_text.js";
import { startFixture } from "./fixture_server.js";

test("navigate to fixture returns title and final_url", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    const r = await navigate(pool, { url: fixture.url + "/" });
    expect(r.status).toBe(200);
    expect(r.title).toBe("nullalis fixture");
    expect(r.final_url).toContain(fixture.url);

    const text = await getText(pool, {});
    expect(text.text).toContain("hello");
    expect(text.truncated).toBe(false);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("click + wait_for new element flows through one session", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await navigate(pool, { url: fixture.url + "/" });
    // Use the click + wait_for tools directly.
    const { click } = await import("../src/tools/click.js");
    const { waitFor } = await import("../src/tools/wait_for.js");
    await click(pool, { selector: "#go" });
    const w = await waitFor(pool, { selector: "#clicked", timeout_ms: 3000 });
    expect(w.found).toBe(true);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("screenshot returns base64 PNG header bytes", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await navigate(pool, { url: fixture.url + "/" });
    const { screenshot } = await import("../src/tools/screenshot.js");
    const s = await screenshot(pool, {});
    expect(s.bytes).toBeGreaterThan(100);
    const bin = Buffer.from(s.png_base64, "base64");
    // PNG signature: 89 50 4E 47 0D 0A 1A 0A
    expect(bin[0]).toBe(0x89);
    expect(bin[1]).toBe(0x50);
    expect(bin[2]).toBe(0x4e);
    expect(bin[3]).toBe(0x47);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});
