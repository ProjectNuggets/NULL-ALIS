# Architecture

```
+--------------------+        WebSocket          +-------------------------+
|   nullalis gateway |  <-------------------->   |   extension background  |
|   (Zig, server)    |     JSON frames           |   (MV3 service worker)  |
+--------------------+                           +-------------------------+
                                                          |
                                          chrome.tabs.sendMessage
                                                          v
                                                 +------------------+
                                                 |  content script  |
                                                 | (runs in tab JS  |
                                                 |  isolated world) |
                                                 +--------+---------+
                                                          |
                                                  document / DOM
                                                          |
                                                          v
                                                 +------------------+
                                                 |     popup UI     |
                                                 | (React, MV3)     |
                                                 +------------------+
```

## Components

### Background service worker (`src/background.ts`)

- Holds the WebSocket via `WsClient` (`src/ws_client.ts`).
- On every incoming `Command` frame: validates, then either runs locally
  (`navigate` / `screenshot` / `list_tabs`) or forwards to the content script
  in the active tab.
- Talks to the popup via `chrome.runtime.onMessage` for status updates,
  token management, and the STOP action.
- Enforces per-tab consent (C1/H1): every tab-touching command checks the
  `consentedTabs` set and rejects with `consent_required` otherwise. Wraps each
  command in a per-command timeout (H3) and honors the STOP latch (H4).
- Validates the sender of popup-control messages (C2): they must come from this
  extension's own pages, not a content script or another extension.
- MV3 evicts idle workers (~30s). Durable config (token, gateway URL) lives in
  `chrome.storage.local`; session-scoped state (touched tabs, consented tabs,
  command count, the STOP latch) lives in `chrome.storage.session` so it
  survives worker eviction but resets on browser restart. The in-memory
  `status` object is rebuilt on revive.

### Content script (`src/content.ts`)

- **Injected ON DEMAND, never declaratively.** There is no `content_scripts`
  entry in `manifest.json`. The background injects the content script via
  `chrome.scripting.executeScript({ target:{tabId}, files:["content.js"] })`
  only when the user enables the agent on a tab from the popup (C1/H1). Pages
  the user never enables receive no extension code.
- Built as a SINGLE self-contained classic IIFE at `dist/content.js` by
  `vite.content.config.ts` (a second build pass). This is required because
  `executeScript({files})` injects a classic script, not an ESM module, and
  needs a stable author-known path. All of `src/commands.ts` is inlined, so no
  `web_accessible_resources` is needed.
- Validates `sender.id === chrome.runtime.id` so only this extension's
  background can drive it (C2), and guards against double-injection
  (`window.__nullalisContentLoaded__`) so re-enabling a tab doesn't register a
  second listener.
- Listens for `ExecuteInTab` and `ShowToast` messages from the background.
- Dispatches `ExecuteInTab.command` against the page's real `document` via
  the same pure functions used in unit tests (`src/commands.ts`).
- Injects a minimal toast UI ("nullalis agent → click") on every command so
  the user has in-place feedback that the agent is acting.

### Popup (`src/popup/`)

- React app rendered into a 360px panel that pops over the toolbar icon.
- Polls `chrome.runtime.sendMessage({ type: "get_status" })` once per second
  to keep the UI live while open.
- Three modes:
  - **No token:** prompts for gateway URL + token, then saves to
    `chrome.storage.local` and triggers connect.
  - **Configured + connected:** shows the connection state, last command,
    total commands, and STOP.
  - **Configured + disconnected:** same as above plus a connect button.

## WebSocket protocol (gateway-side contract)

The gateway must speak this protocol on its `/ext/ws` endpoint (or wherever it
chooses to host the extension socket — the path is configurable in the popup).

### Handshake (challenge / nonce first)

The extension does NOT send auth on open. The gateway speaks first with a
per-connection anti-replay challenge (Plan-8); the extension echoes the nonce.

1. Extension opens the socket. It sends NOTHING yet — it waits for the
   challenge. (The auth timer starts now, so a gateway that never challenges
   still trips `auth_timeout`.)
2. Gateway issues a fresh per-connection nonce:

   ```json
   { "type": "challenge", "nonce": "<64-char hex>" }
   ```

3. Extension echoes the nonce verbatim in its auth frame:

   ```json
   {
     "type": "auth",
     "token": "<bearer token>",
     "extension_version": "0.1.0",
     "nonce": "<the nonce from step 2>"
   }
   ```

   A captured `auth` frame replayed on a fresh connection carries a stale nonce
   and is rejected. A malformed challenge (missing/empty nonce) is ignored and
   the auth timer eventually closes the socket.

4. Gateway validates token + nonce and responds:

   ```json
   { "type": "auth_ack", "ok": true }
   ```

   or, on failure:

   ```json
   { "type": "auth_ack", "ok": false, "error": "invalid_token" }
   ```

   then closes with code 1008 (policy violation).

5. The extension blocks on `auth_ack` (since 2026-05-25, Wave 3 review
   CRITICAL #5). Inbound `Command` frames received before `auth_ack{ok:true}`
   are dropped and not dispatched. If `auth_ack` doesn't arrive within
   `authTimeoutMs` (default 5s), the extension closes the socket with code 1008
   and surfaces `last_error: "auth_timeout"` in the popup. `auth_ack{ok:false}`
   closes with `last_error: "auth_failed: <reason>"`. Ping/pong is exempt —
   heartbeat must work pre-ack so proxies don't drop the connection during the
   handshake window.

   Inbound frames are also size-capped: any frame larger than 8 MB is dropped
   before `JSON.parse` (M4).

### Commands

Gateway → extension:

```json
{
  "command_id": "01HN1...",
  "tool": "click",
  "args": { "selector": "button#submit" },
  "timeout_ms": 30000
}
```

Extension → gateway:

```json
{
  "command_id": "01HN1...",
  "ok": true,
  "result": { "clicked": "button#submit" },
  "duration_ms": 42
}
```

On failure:

```json
{
  "command_id": "01HN1...",
  "ok": false,
  "error": { "code": "not_found", "message": "no element matches button#submit" },
  "duration_ms": 12
}
```

### Tool surface (v1)

| Tool          | Runs in                | Args                                                      | Result                                                  |
| ------------- | ---------------------- | --------------------------------------------------------- | ------------------------------------------------------- |
| `navigate`    | background (chrome.tabs) | `url` (http/https public host only — SSRF allowlist), optional `new_tab: boolean` (requires the active tab to already be consented; the opened tab inherits consent + is touched) | `{ tab_id, url }` / `url_blocked` on a disallowed scheme or host / `consent_required` if `new_tab` without a consented active tab |
| `click`       | content script         | `selector`                                                | `{ clicked }`                                           |
| `type`        | content script         | `selector`, `text`; password/`cc-*` fields need `allow_sensitive: true` | `{ typed, sensitive }` / `sensitive_field_blocked`     |
| `fill_form`   | content script         | `fields: [{ selector, text }, ...]`; sensitive fields need `allow_sensitive: true` | `{ filled, sensitive }`                                 |
| `screenshot`  | background             | optional `full_page: boolean`                             | `{ data_url: "data:image/png;base64,...", full_page }`  |
| `get_text`    | content script         | optional `selector`                                       | `{ text, truncated }` (cap 100 KB)                      |
| `get_dom`     | content script         | optional `selector`                                       | `{ html, truncated }` (cap 1 MB)                        |
| `wait_for`    | content script         | `selector`, optional `timeout_ms` (10s), `state` (`attached` / `visible` / `detached`) | `{ found, ms }`                |
| `scroll`      | content script         | `direction: up/down/top/bottom`, optional `pixels` (800)  | `{ scrolled }`                                          |
| `list_tabs`   | background             | none                                                      | `[{ id, title, url, active }]` — v1 returns active only |

### Heartbeat

The extension sends `{ "type": "ping" }` every 25s if no other frame has been
sent. It auto-responds with `{ "type": "pong" }` to inbound `ping`s. The
gateway should treat absence of either as a half-open connection and close.

### Reconnect

The extension uses exponential backoff with full jitter:
`delay = random(0, current_backoff)`, with `current_backoff` doubling on each
failure from 1s up to 30s. On a successful open, `current_backoff` resets.
The gateway must issue a fresh `challenge` on every reconnect and expect a fresh
nonce-echoing `auth` frame in response (auth state never carries across sockets).

Reconnect is suppressed while the STOP latch is set (H4): only an explicit
**connect** from the popup clears the latch and allows the socket to reopen.

## Why this split (background vs content)?

- The DOM only exists in the page context — `click` / `type` / `wait_for`
  must run there.
- `chrome.*` APIs only exist in the background service worker — `navigate`,
  `screenshot`, and tab inspection must run there.
- The background owns the WebSocket because a content script lifecycle is
  tied to the page (navigations destroy it), while the background survives
  navigations and is the only stable network anchor.

## Out of scope for v1

- Cross-tab orchestration (multi-tab plans).
- Off-screen capture / scroll-and-stitch full-page screenshots.
- A Firefox build (MV3 background-script API divergence).
- Per-origin permission prompts (currently uses `activeTab` which gates by
  user focus; explicit allow-listing is a v1.1 item).
- Result-frame HMAC signing (designed in, not yet implemented; see SECURITY.md).
