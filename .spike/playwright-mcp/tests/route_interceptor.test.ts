// Route interceptor — sanitizer runs on EVERY outgoing request, not just the
// user-input URL handed to navigate().
//
// Defends Wave 3 review CRITICAL #4: a public attacker URL that returns a 302
// to http://169.254.169.254/ used to bypass sanitization because Playwright
// followed the redirect after the URL had already been approved.
//
// We install a context.route('**', ...) handler in BrowserPool that
// classifies every request via sanitizeUrl and aborts blocked ones. This
// also closes DNS rebinding (HIGH #10): the sanitizer runs against the
// post-resolution URL Chromium actually intends to fetch.

import http from "node:http";
import type { AddressInfo } from "node:net";
import { expect, test } from "@playwright/test";
import { BrowserPool } from "../src/browser.js";
import { navigate } from "../src/tools/navigate.js";

interface RedirectFixture {
  url: string;
  hitCount: () => number;
  close: () => Promise<void>;
}

/** Tiny fixture: GET /redirect-to-metadata returns 302 Location: http://169.254.169.254/. */
async function startRedirectFixture(): Promise<RedirectFixture> {
  let hits = 0;
  const server = http.createServer((req, res) => {
    if (req.url === "/redirect-to-metadata") {
      hits++;
      res.writeHead(302, {
        location: "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
      });
      res.end();
      return;
    }
    if (req.url === "/img-from-metadata") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(
        '<!doctype html><html><body>' +
          '<img src="http://169.254.169.254/latest/meta-data/iam/security-credentials/badge.png">' +
          "</body></html>",
      );
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address() as AddressInfo;
  const url = `http://127.0.0.1:${addr.port}`;
  return {
    url,
    hitCount: () => hits,
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((err) => (err ? reject(err) : resolve())),
      ),
  };
}

test("CRITICAL #4: 302 redirect to 169.254.169.254 is aborted by the route interceptor", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startRedirectFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    // Attach the request listener BEFORE navigating so we capture the full
    // request lifecycle even if page.goto times out (which it will: an
    // aborted main-frame redirect doesn't propagate a load event, so the
    // 'load' wait_until hangs — that's a property of Chromium's net stack,
    // not a bug in our interceptor).
    const { page } = await pool.getOrCreate("redirect-test");
    const metadataReqs: { url: string; failed: boolean }[] = [];
    page.on("requestfinished", (req) => {
      if (req.url().includes("169.254.169.254")) {
        metadataReqs.push({ url: req.url(), failed: false });
      }
    });
    page.on("requestfailed", (req) => {
      if (req.url().includes("169.254.169.254")) {
        metadataReqs.push({ url: req.url(), failed: true });
      }
    });

    // Fire-and-(don't-)await navigate: it will hang waiting for the load
    // event that never arrives. The defense contract we care about is "no
    // bytes reached the metadata host", measured by the request events.
    void navigate(pool, {
      url: fixture.url + "/redirect-to-metadata",
      session_id: "redirect-test",
    }).catch(() => undefined);

    // Give Chromium time to issue and abort the redirect-followed request.
    await page.waitForTimeout(2_000);

    // Defense: no request to 169.254.169.254 may complete successfully.
    const anySucceeded = metadataReqs.some((r) => !r.failed);
    expect(anySucceeded).toBe(false);
    // Belt-and-suspenders: page never landed on the metadata host.
    expect(page.url()).not.toContain("169.254.169.254");
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("CRITICAL #4: sub-resource <img src=http://169.254.169.254/...> is aborted by the route interceptor", async () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1";
  const fixture = await startRedirectFixture();
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    const { page } = await pool.getOrCreate("img-test");
    const metadataReqs: { url: string; outcome: "finished" | "failed" }[] = [];
    page.on("requestfinished", (req) => {
      if (req.url().includes("169.254.169.254")) {
        metadataReqs.push({ url: req.url(), outcome: "finished" });
      }
    });
    page.on("requestfailed", (req) => {
      if (req.url().includes("169.254.169.254")) {
        metadataReqs.push({ url: req.url(), outcome: "failed" });
      }
    });

    await navigate(pool, {
      url: fixture.url + "/img-from-metadata",
      session_id: "img-test",
    });
    await page.waitForTimeout(500);

    // Defense: NO request to 169.254.169.254 may complete successfully.
    // (Aborted/failed requests are acceptable — they prove the interceptor
    // saw the request and stopped it before bytes left the browser.)
    const succeeded = metadataReqs.filter((r) => r.outcome === "finished");
    expect(succeeded.length).toBe(0);
  } finally {
    await pool.shutdown();
    await fixture.close();
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});
