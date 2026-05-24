# @nullalis/playwright-mcp

Server-side Playwright browser, exposed as an MCP (Model Context Protocol) stdio server. nullalis (the Zig agent) connects to it as an MCP client and drives a real Chromium running on the server. The user watches the navigation live via the `screenshot` tool — that's the "server-side browser the agent drives that the user watches" path documented in Wave 3A of the final-sprint plan.

Companion to the upcoming browser extension (Path B, separate worktree) which handles flows that need the user's own logged-in sessions. This server handles the ~60% of "do this on the web" requests that don't need user-side auth: summarize a page, fill out a public form, scrape a site, navigate through results, etc.

## Install

```bash
cd .spike/playwright-mcp
npm install
npx playwright install chromium   # one-time Chromium download (~150 MB)
npm run build                     # tsc → dist/
npm test                          # 25 tests, ~3s, all pass
```

## Run

```bash
node dist/server.js
# or
npm start
```

Speaks JSON-RPC 2.0 on stdio, protocol version `2024-11-05`. Stderr carries human logs; stdout carries only protocol frames (anything else corrupts the channel).

## Wire to nullalis

Merge `examples/nullalis_config.json` into your `~/.nullalis/config.json` `mcp_servers` map (or add the block alongside any existing entries). Replace the absolute path with your checkout's path:

```json
{
  "mcp_servers": {
    "browser": {
      "command": "node",
      "args": ["/abs/path/to/nullalis/.spike/playwright-mcp/dist/server.js"],
      "env": {
        "PLAYWRIGHT_HEADLESS": "true",
        "PLAYWRIGHT_MCP_ALLOWLIST": "",
        "PLAYWRIGHT_MCP_ALLOW_EVAL": "0"
      }
    }
  }
}
```

On startup, the nullalis tool loop will discover the 11 (or 12 if eval is enabled) browser tools alongside its native registry. The model can then call them by name.

## Tools

| Name | What it does | Honest preconditions / caveats |
|---|---|---|
| `navigate` | Go to an http(s) URL. Returns status + final URL + title. | SSRF-rejected for `file://`, loopback, link-local, RFC1918. |
| `click` | Click a selector. | Must `navigate` first. Fails fast on unmatched / non-actionable elements. |
| `type` | Type text via keyboard events. | Doesn't clear the field first — use `fill_form` for that. |
| `fill_form` | Fill `{selector, value}` pairs in order. | **Not atomic** — if field N fails, fields 0..N-1 stay filled. |
| `screenshot` | PNG, base64-encoded. | `full_page:true` is slow on tall pages; default viewport-only. |
| `get_text` | innerText of element / body. | 64KB cap; `truncated:true` if larger. |
| `get_dom` | outerHTML of element / body. | 1MB cap. |
| `wait_for` | Wait for selector to reach a state. | Throws on timeout (an honest signal — not silent false). |
| `evaluate_js` | Arbitrary JS in page context. | **GATED behind `PLAYWRIGHT_MCP_ALLOW_EVAL=1`.** Hidden from `tools/list` when disabled. |
| `scroll` | Scroll viewport. | Use to expose lazy-rendered content. |
| `close_session` | Free one session's BrowserContext. | Idempotent. |
| `list_sessions` | Inspect active sessions (id, age, idle, last URL). | |

Every tool takes an optional `session_id` string (default `"default"`). Each unique `session_id` gets its own BrowserContext — separate cookies, separate storage, no cross-tenant bleed. Idle sessions are reaped after 5 minutes.

## Environment

| Var | Default | Effect |
|---|---|---|
| `PLAYWRIGHT_HEADLESS` | `true` | Set to `false` to see the browser window (debugging only). |
| `PLAYWRIGHT_MCP_ALLOWLIST` | `""` | Comma-separated hostnames that bypass the SSRF deny list. Example: `localhost,127.0.0.1,my-staging.internal`. |
| `PLAYWRIGHT_MCP_ALLOW_EVAL` | `0` | Set to `1` to expose `evaluate_js`. **Off by default** — page-context JS can exfiltrate cookies and pivot internally. |

## Security model

Default-deny at the URL boundary (`src/sanitize.ts`):

- non-`http(s)` schemes rejected (`file://`, `javascript:`, `chrome://`, ...)
- loopback (`127.0.0.0/8`, `localhost`, `::1`) rejected
- link-local (`169.254.0.0/16`, `fe80::/10`) rejected — catches AWS/GCP/Azure metadata
- well-known metadata names (`metadata.google.internal`) rejected
- RFC1918 private IPs (`10/8`, `172.16-31`, `192.168/16`) rejected
- CGNAT (`100.64-127`) rejected

Hostnames in `PLAYWRIGHT_MCP_ALLOWLIST` bypass loopback + private-IP checks. Schemes and metadata-endpoint blocks are NOT bypassable by allowlist — they're structural.

`evaluate_js` is gated by env. When disabled, the tool is hidden from `tools/list` so the model doesn't see an advertised capability the server won't honor (per AGENTS.md §14.5 — "no tool description shall advertise an action the code can't perform").

Per-session BrowserContext is the multi-tenant isolation boundary. Two different `session_id` values cannot read each other's cookies (verified in `tests/session_isolation.test.ts`).

## Honesty notes (AGENTS.md §14.5)

What actually works end-to-end and was verified:

- **Works (covered by automated tests):** initialize handshake, tools/list returns 12 (11 visible by default), navigate, click, type, fill_form, screenshot, get_text, get_dom, wait_for, scroll, close_session, list_sessions, per-session cookie isolation, idle-context reaping, SSRF deny list (every reason path), allowlist bypass.
- **Works but best-effort:** `evaluate_js` runs and returns JSON when enabled, but the return value must be JSON-serializable; functions, DOM nodes, etc. come back as `{}` or throw. `fill_form` is sequential, not transactional — partial failures leave a partially-filled form.
- **Not implemented (out of scope for Wave 3A):** authenticated browser state (use Path B browser extension), proxy support, mobile viewport emulation, video recording, downloads, file uploads, network interception, frames/iframes navigation beyond the top page, persistent storage across server restarts.
- **Known limits:** screenshot/get_text/get_dom are capped (1MB / 64KB / 1MB respectively) to keep responses small enough for the model. Cap hits are surfaced via `truncated:true` so the agent can re-ask with a more specific selector.

## Manual smoke

```bash
npm run build
python3 tests/manual_probe.py
```

Drives the server from raw Python over stdio — same path as nullalis. Prints the handshake, the tool list, a navigate to `example.com`, and a screenshot size. Useful for sanity-checking a deploy where the test suite isn't available.

## Docker

```bash
docker build -t nullalis/playwright-mcp .
# Use -i (interactive, no TTY) to keep stdin open for the JSON-RPC channel:
docker run --rm -i -e PLAYWRIGHT_MCP_ALLOWLIST=my-host nullalis/playwright-mcp
```

The Dockerfile bases on `mcr.microsoft.com/playwright` so all the system deps for Chromium are pre-baked. Pin bumps go together.

## Layout

```
.spike/playwright-mcp/
├── package.json
├── tsconfig.json
├── playwright.config.ts
├── Dockerfile
├── README.md
├── src/
│   ├── server.ts        # MCP server entry — handshake + tools/list + tools/call dispatch
│   ├── browser.ts       # BrowserPool + per-session BrowserContext lifecycle
│   ├── sanitize.ts      # SSRF defense at the URL boundary
│   └── tools/           # one file per tool
└── tests/
    ├── fixture_server.ts        # in-process HTTP fixture (hermetic, no public net)
    ├── mcp_handshake.test.ts    # registry shape + eval gating
    ├── navigate.test.ts          # navigate / click / wait_for / screenshot
    ├── session_isolation.test.ts # per-session cookie isolation + close
    ├── idle_cleanup.test.ts      # idle reaper at the configured timeout
    ├── ssrf_defense.test.ts      # every deny-list reason + allowlist bypass
    └── manual_probe.py           # Python stdio probe for ops smoke tests
```

## License

Source-available. Not for redistribution. Tracks the parent nullalis license.
