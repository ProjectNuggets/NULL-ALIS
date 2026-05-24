// Two session_ids see different cookie jars.
// This is the core multi-tenant guarantee — without it one user could read
// another user's session.

import { expect, test } from "@playwright/test";
import { BrowserPool } from "../src/browser.js";
import { navigate } from "../src/tools/navigate.js";
import { getText } from "../src/tools/get_text.js";
import { listSessions } from "../src/tools/session.js";
import { startFixture } from "./fixture_server.js";

test("two session_ids have isolated cookies", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    // Alice gets cookie=alice
    await navigate(pool, { url: fixture.url + "/cookie?v=alice", session_id: "alice" });
    // Bob gets cookie=bob
    await navigate(pool, { url: fixture.url + "/cookie?v=bob", session_id: "bob" });

    // Alice asks for the cookie back
    await navigate(pool, { url: fixture.url + "/show-cookie", session_id: "alice" });
    const aliceText = await getText(pool, { session_id: "alice" });
    expect(aliceText.text).toContain("fixturecookie=alice");
    expect(aliceText.text).not.toContain("bob");

    // Bob asks for the cookie back
    await navigate(pool, { url: fixture.url + "/show-cookie", session_id: "bob" });
    const bobText = await getText(pool, { session_id: "bob" });
    expect(bobText.text).toContain("fixturecookie=bob");
    expect(bobText.text).not.toContain("alice");

    // list_sessions shows both
    const list = listSessions(pool);
    const ids = list.sessions.map((s) => s.session_id).sort();
    expect(ids).toEqual(["alice", "bob"]);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("close_session frees the BrowserContext", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await navigate(pool, { url: fixture.url + "/", session_id: "ephemeral" });
    expect(pool.listSessions().map((s) => s.session_id)).toContain("ephemeral");

    const { closeSession } = await import("../src/tools/session.js");
    const r = await closeSession(pool, { session_id: "ephemeral" });
    expect(r.existed).toBe(true);
    expect(pool.listSessions().map((s) => s.session_id)).not.toContain("ephemeral");

    // closing an unknown session returns existed:false, no throw
    const r2 = await closeSession(pool, { session_id: "nope" });
    expect(r2.existed).toBe(false);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});
