# Local E2E runbook — the EXTENSION lane (your real browser)

This runbook walks through testing the **extension lane** end-to-end on a
single machine: the gateway's extension WebSocket hub (`src/extension_ws/`)
paired with the MV3 browser extension client (`.spike/nullalis-extension/`),
so an agent turn can drive **your own logged-in browser** via the ten
`extension_*` tools.

This is the "agent drives your own browser with your own sessions" path
(Wave 3B). The companion server-side Playwright lane (fresh, anonymous
browsing) is separate; the two share the same tool surface — only the
execution location differs.

> **Scope of "locally testable."** The extension client builds and tests
> cleanly (`npm run build` → `dist/`; `npm test` → 51 passing). The gateway
> extension half is fully covered by Zig unit tests (auth, SSRF sanitizer,
> the mock-hub happy-path/error/timeout frames). The one step that is
> **inherently manual** is loading the unpacked extension into a real Chrome
> and clicking **connect** in the popup — Chrome has no headless "load
> unpacked + open popup" automation that round-trips a live WebSocket. That
> manual step is documented in full below.

---

## What you need

- This worktree built: `zig build` (Zig 0.15.2).
- Node ≥ 20 + npm (for the extension build).
- A Chromium browser (Chrome / Edge / Arc / Brave). **Chromium only** in
  v0.1 — Firefox MV3 divergences are deferred.

---

## Step 1 — Gateway config

The extension endpoint is **off by default** and **closed-by-default** (no
tokens ⇒ every connection rejected). Enable it and provision at least one
`(token, user_id)` pair in your gateway `config.json`:

```jsonc
{
  "gateway": {
    "host": "127.0.0.1",
    "port": 8080,

    // Turn on GET /api/v1/extension/ws + the per-user ExtensionWsHub.
    // When false (default), the endpoint returns 503 and the ten
    // extension_* tools are NOT registered.
    "extension_ws_enabled": true,

    // Per-user extension tokens. Each entry maps token -> user_id.
    // The gateway IGNORES any user_id in the inbound auth frame and
    // registers the connection under the user_id from the MATCHING
    // entry here (closes cross-tenant impersonation). Entries missing
    // either field are silently skipped. Empty list + enabled =
    // NO user can authenticate (a boot warning fires).
    "extension_tokens": [
      { "token": "dev-secret-rotate-me", "user_id": "alice" }
    ],

    // OPTIONAL — hosts that bypass the SSRF deny check in
    // extension_navigate (and future URL-taking extension_* tools).
    // Use only for trusted LAN / internal-staging automation. Default
    // empty = deny all non-public targets (RFC1918, link-local,
    // 169.254.169.254 metadata, file://, data:, chrome://, etc.).
    // Comparison is case-insensitive; trailing dots tolerated.
    "extension_browser_allowlist": []
  }
}
```

Notes that are easy to get wrong:

- `extension_tokens` field names are **`token`** and **`user_id`** exactly.
- Use a real secret in `token`; it rides the WS connection. For loopback dev
  `ws://` is fine, but anything non-loopback **must** be `wss://`.
- The token is the only credential — whatever `user_id` the *client* sends in
  its auth frame is discarded; the server uses the mapped `user_id`.

Start the gateway with this config. At boot, confirm there is **no**
"extension_tokens empty" warning (that warning means the list didn't parse /
is empty and every auth will be rejected).

---

## Step 2 — Build the extension and load it unpacked

```bash
cd .spike/nullalis-extension
npm install        # ~120 pkgs, 0 vulnerabilities on a clean v0.1 tree
npm run build      # tsc --noEmit && vite build -> produces dist/
# (optional) npm test   # vitest run -> 51 tests across 6 files
```

`npm run build` writes `dist/` containing `manifest.json`, the
`background.ts` service worker, the `content.ts` content script, and the
React popup.

Load it in Chrome:

1. Open `chrome://extensions`.
2. Enable **Developer mode** (top-right toggle).
3. Click **Load unpacked** and select
   `.spike/nullalis-extension/dist`.
4. Pin the **nullalis** extension from the puzzle-piece menu so the toolbar
   icon is visible.

> `npm run dev` gives you a watch-mode `dist/` with popup HMR; after a
> rebuild, hit the reload arrow on the extension card in `chrome://extensions`.

---

## Step 3 — Connect the popup to your local gateway

Click the nullalis toolbar icon to open the popup, then in the **no token**
view enter:

- **Gateway URL:** `ws://127.0.0.1:8080/api/v1/extension/ws`
  (match the `host`/`port` from your config; the path is
  `/api/v1/extension/ws`).
- **Token:** the `token` you provisioned above (e.g. `dev-secret-rotate-me`).

Click **Save / connect**. On open the extension immediately sends an auth
frame and **blocks on `auth_ack`** before dispatching any command:

```json
{ "type": "auth", "token": "dev-secret-rotate-me", "extension_version": "0.1.0" }
```

Expected outcomes:

- **Success:** badge flips to **connected** within ~1s. The gateway sends
  `{ "type": "auth_ack", "ok": true }`.
- **Bad token:** gateway replies `{ "type": "auth_ack", "ok": false,
  "error": "invalid_token" }` then closes with code 1008; popup shows
  `auth_failed: invalid_token`.
- **No `auth_ack` within 5s:** popup closes with `auth_timeout`.

Heartbeat: the extension pings every 25s and pongs inbound pings (exempt from
the pre-ack block so proxies don't drop the handshake window). Reconnect uses
exponential backoff with full jitter (1s → 30s), sending a fresh auth frame
each time.

---

## Step 4 — Verify pairing + drive the browser

### 4a. Confirm the gateway logged the pairing

On successful auth the hub emits the canonical log line:

```
extension_ws.event=pair user_id='alice'
```

and bumps the `extension_ws_connections_active` gauge. You can also confirm
via the control-plane diagnostics (operator-only, `X-Internal-Token`):

```bash
# system-wide
curl -s -H "X-Internal-Token: <internal>" \
  http://127.0.0.1:8080/api/v1/diagnostics/extension/status
# -> {"enabled":true,"total_active":1,"connections_total":1,"auth_failed_total":0}

# per-user
curl -s -H "X-Internal-Token: <internal>" \
  http://127.0.0.1:8080/api/v1/diagnostics/extension/users/alice
# -> {"user_id":"alice","paired":true,"connected_at_unix":...,"last_command_tool":"","last_command_result":""}
```

### 4b. Have an agent turn drive your real browser

Run an agent turn as `user_id=alice` (the same user the token maps to) and
ask for something that exercises the extension tools, e.g. *"navigate to
example.com and tell me the page heading."* The agent should call:

1. `extension_navigate` → background runs `chrome.tabs`; result `{ tab_id, url }`.
2. `extension_get_text` → content script reads the active tab's DOM; result
   `{ text, truncated }` (capped 100 KB).

You will **see it happen in your real browser**: the active tab navigates,
and the content script paints a small in-page toast ("nullalis agent →
navigate / get_text") on each command. Results flow back over the WS as
result frames:

```json
{ "command_id": "01HN…", "ok": true, "result": { "text": "Example Domain" }, "duration_ms": 42 }
```

After the turn, `GET /api/v1/diagnostics/extension/users/alice` shows
`last_command_tool` / `last_command_result` (`ok`, `timeout`, `conn_closed`,
`oom`, or `error_other`).

**Approval behavior:** every `extension_*` tool is `.mutating` +
`.risk_level=.high`. Under `.supervised` autonomy the agent raises an
approval prompt before each call; under `.full` it proceeds without prompt
but the call is still recorded in the run trace.

### The ten v1 tools (the surface you can exercise)

| Tool                  | Runs in           | Args                                                         |
|-----------------------|-------------------|-------------------------------------------------------------|
| `extension_navigate`  | background        | `url`, optional `new_tab`                                    |
| `extension_click`     | content script    | `selector`                                                  |
| `extension_type`      | content script    | `selector`, `text`                                          |
| `extension_fill_form` | content script    | `fields: [{ selector, text }]`                              |
| `extension_screenshot`| background        | optional `full_page` (viewport only in v0.1; flag echoed)   |
| `extension_get_text`  | content script    | optional `selector` → `{ text, truncated }` (cap 100 KB)    |
| `extension_get_dom`   | content script    | optional `selector` → `{ html, truncated }` (cap 1 MB)      |
| `extension_wait_for`  | content script    | `selector`, optional `timeout_ms`, `state`                  |
| `extension_scroll`    | content script    | `direction: up/down/top/bottom`, optional `pixels`          |
| `extension_list_tabs` | background        | none (v1 returns the active tab only)                       |

---

## v0.1 limitations (deliberate)

- **Active-tab only.** The agent operates on the currently-focused tab.
  Multi-tab orchestration is a v1.1 item (needs a permission-gating UX).
- **Viewport screenshots only.** `extension_screenshot(full_page: true)`
  returns the visible viewport with `full_page` echoed back; scroll-and-
  stitch is v1.1.
- **Chromium only.** Firefox MV3 build is deferred.
- **No `<all_urls>` host permission.** Content scripts inject on `http(s)`
  only; `file://`, `data:`, `chrome://`, etc. are excluded. Relies on
  `activeTab` + declarative injection.
- **Unpacked-only.** Placeholder icons; no Chrome Web Store listing.
- **No request-signing yet.** The wire format reserves a signature field
  (HMAC of `command_id` + result hash, token as secret); the impl is not
  landed.

Productionization — real icons, Chrome Web Store publish, result-frame
request-signing, multi-tab + full-page screenshots — is tracked as
**Plan 7 (extension productionization)**, not part of this lane's local
validation.

---

## Quick reference — what's automatable vs. manual

| Step                                              | Automatable? |
|---------------------------------------------------|--------------|
| Extension `npm install` / `build` / `test`        | Yes (CI-able)|
| Gateway extension unit tests (auth, SSRF, hub)    | Yes — `zig build test -Dtest-filter="extension"` |
| Gateway config + boot with `extension_ws_enabled` | Yes          |
| Load unpacked `dist/` in Chrome + click connect   | **Manual**   |
| Observe a real tab navigate / read-back in-browser| **Manual**   |
