// MCP handshake — initialize → tools/list returns 12 tools.
//
// Drives the server in-process via createServer so we don't need to spawn a
// subprocess. evaluate_js is hidden by default (PLAYWRIGHT_MCP_ALLOW_EVAL unset)
// so we count 11 in the list — with eval enabled it's 12.

import { expect, test } from "@playwright/test";
import { createServer } from "../src/server.js";

test("registry has all 12 tools (with eval gated by env)", async () => {
  const { registry, stop } = await createServer({ disable_reaper: true });
  try {
    // The registry always contains all 12 — `hidden` controls visibility.
    expect(registry.length).toBe(12);
    const names = registry.map((t) => t.name).sort();
    expect(names).toEqual(
      [
        "click",
        "close_session",
        "evaluate_js",
        "fill_form",
        "get_dom",
        "get_text",
        "list_sessions",
        "navigate",
        "screenshot",
        "scroll",
        "type",
        "wait_for",
      ].sort(),
    );
  } finally {
    await stop();
  }
});

test("evaluate_js is hidden when PLAYWRIGHT_MCP_ALLOW_EVAL is not '1'", async () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOW_EVAL;
  const { registry, stop } = await createServer({ disable_reaper: true });
  try {
    const evalEntry = registry.find((t) => t.name === "evaluate_js");
    expect(evalEntry).toBeDefined();
    expect(evalEntry?.hidden).toBe(true);
  } finally {
    await stop();
  }
});

test("evaluate_js is exposed when PLAYWRIGHT_MCP_ALLOW_EVAL=1", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOW_EVAL = "1";
  try {
    const { registry, stop } = await createServer({ disable_reaper: true });
    try {
      const evalEntry = registry.find((t) => t.name === "evaluate_js");
      expect(evalEntry?.hidden).toBe(false);
    } finally {
      await stop();
    }
  } finally {
    delete process.env.PLAYWRIGHT_MCP_ALLOW_EVAL;
  }
});

test("every tool entry has name + description + inputSchema", async () => {
  const { registry, stop } = await createServer({ disable_reaper: true });
  try {
    for (const t of registry) {
      expect(typeof t.name).toBe("string");
      expect(t.name.length).toBeGreaterThan(0);
      expect(typeof t.description).toBe("string");
      expect(t.description.length).toBeGreaterThan(20); // honest, non-empty descriptions
      expect(typeof t.inputSchema).toBe("object");
    }
  } finally {
    await stop();
  }
});
