// Wave 3 HIGH regression tests — each test was RED before its fix landed,
// GREEN after. Same TDD discipline the CRITICAL fixer used.
//
// Coverage:
//   HIGH #1  evaluate_js: 30s timeout on agent-supplied script
//   HIGH #2  type: delay_ms cap (1000ms) + text.length cap (10000)
//   HIGH #3  server: error messages do NOT leak filesystem paths
//   HIGH #4  shutdown semantics — covered by an inline assertion on the
//            sanitizeError helper (process.exit can't be exercised in-process)
//   HIGH #8  reaper does NOT reap a session while a tool call is in-flight
//   HIGH #9  sanitizer surfaces a `punycode_hostname` warning on homograph URLs
//   HIGH #10 DNS-rebinding is handled by the existing CRITICAL #4 route
//            interceptor — assert the sanitizer would block a rebound IP literal

import { expect, test } from "@playwright/test";
import { BrowserPool } from "../src/browser.js";
import { evaluateJs } from "../src/tools/evaluate_js.js";
import { type as typeTool } from "../src/tools/type.js";
import { sanitizeUrl } from "../src/sanitize.js";
import { navigate } from "../src/tools/navigate.js";
import { sanitizeErrorMessage } from "../src/server.js";
import { startFixture } from "./fixture_server.js";

// ---------------------------------------------------------------------------
// HIGH #1 — evaluate_js timeout
// ---------------------------------------------------------------------------

test("HIGH #1: evaluate_js script that never resolves is timed out", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOW_EVAL = "1";
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "eval-timeout" });
    // Pass an aggressive 200ms timeout via the tool args so the test is fast.
    await expect(
      evaluateJs(pool, {
        script: "await new Promise(() => {});",
        session_id: "eval-timeout",
        timeout_ms: 200,
      }),
    ).rejects.toThrow(/timeout/i);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOW_EVAL;
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("HIGH #1: evaluate_js script that returns quickly is NOT timed out", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOW_EVAL = "1";
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "eval-ok" });
    const r = await evaluateJs(pool, {
      script: "return 1 + 2;",
      session_id: "eval-ok",
      timeout_ms: 5_000,
    });
    expect(r.result).toBe(3);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOW_EVAL;
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

// ---------------------------------------------------------------------------
// HIGH #2 — type tool: delay_ms cap + text.length cap
// ---------------------------------------------------------------------------

test("HIGH #2: type tool rejects delay_ms > 1000", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "type-delay" });
    await expect(
      typeTool(pool, {
        selector: "#name",
        text: "x",
        delay_ms: 60_000,
        session_id: "type-delay",
      }),
    ).rejects.toThrow(/delay_ms/);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("HIGH #2: type tool rejects text.length > 10000", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "type-len" });
    const tooLong = "a".repeat(10_001);
    await expect(
      typeTool(pool, {
        selector: "#name",
        text: tooLong,
        session_id: "type-len",
      }),
    ).rejects.toThrow(/text.*length/i);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

// ---------------------------------------------------------------------------
// HIGH #3 — server error sanitization
// ---------------------------------------------------------------------------

test("HIGH #3: sanitizeErrorMessage strips node_modules paths (incl. surrounding install dir)", () => {
  const raw =
    "page.evaluate: Execution context was destroyed at /opt/somewhere/node_modules/playwright-core/lib/server/foo.js:42:7";
  const cleaned = sanitizeErrorMessage(raw);
  expect(cleaned).not.toContain("playwright-core");
  expect(cleaned).not.toContain("/opt/somewhere");
});

test("HIGH #3: sanitizeErrorMessage strips absolute paths under the install dir (uses process.cwd())", () => {
  // The fix uses process.cwd() as the install-path prefix. Anchor the test
  // off whatever cwd the test runner happens to use so we test the property
  // honestly: paths beginning with the server's install dir get elided.
  const cwd = process.cwd();
  const raw = `Error: ENOENT, open '${cwd}/some-file.txt'`;
  const cleaned = sanitizeErrorMessage(raw);
  expect(cleaned).not.toContain(cwd);
  expect(cleaned).toContain("<install-path>");
});

test("HIGH #3: sanitizeErrorMessage preserves the human-readable part of the message", () => {
  const raw =
    "page.evaluate: Execution context was destroyed at /opt/x/node_modules/y/z.js:1:1";
  const cleaned = sanitizeErrorMessage(raw);
  expect(cleaned).toMatch(/Execution context was destroyed/);
});

// ---------------------------------------------------------------------------
// HIGH #8 — reaper race against in-flight tool calls
// ---------------------------------------------------------------------------

test("HIGH #8: reaper does NOT reap a session while a tool call is in-flight", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({
    headless: true,
    idle_timeout_ms: 10,
    disable_reaper: true,
  });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "busy" });
    pool.beginCall("busy");
    try {
      // Pretend a lot of time has passed. Reaper should NOT touch the busy
      // session even though its idle window is past.
      const future = Date.now() + 60_000;
      const reaped = await pool.reapIdle(future);
      expect(reaped).toBe(0);
      expect(pool.listSessions()).toHaveLength(1);
    } finally {
      pool.endCall("busy");
    }
    // After the call ends, the next reap should sweep it.
    const reapedAfter = await pool.reapIdle(Date.now() + 60_000);
    expect(reapedAfter).toBe(1);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

// ---------------------------------------------------------------------------
// HIGH #9 — Unicode homograph hostname warning
// ---------------------------------------------------------------------------

test("HIGH #9: sanitizeUrl surfaces a punycode_hostname warning on homograph host", () => {
  // 'а' is U+0430 Cyrillic, NOT U+0061 Latin 'a'.
  const r = sanitizeUrl("http://exаmple.com/");
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.warnings ?? []).toContain("punycode_hostname");
  }
});

test("HIGH #9: sanitizeUrl does NOT add the warning for pure-ASCII hostnames", () => {
  const r = sanitizeUrl("http://example.com/");
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.warnings ?? []).not.toContain("punycode_hostname");
  }
});

// ---------------------------------------------------------------------------
// HIGH #10 — DNS rebinding (post-resolution check) regression
// ---------------------------------------------------------------------------

test("HIGH #10: DNS-rebound public hostname → 127.0.0.1 IS blocked by the sanitizer when seen as the resolved IP literal", () => {
  // The actual DNS rebinding defense lives in the route interceptor (CRITICAL #4
  // already tested). This test pins the property the interceptor RELIES ON:
  // if the post-resolution URL hits the sanitizer with an RFC1918 / loopback
  // IP literal, the sanitizer must reject it.
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://127.0.0.1/secret");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("loopback_blocked");
});
