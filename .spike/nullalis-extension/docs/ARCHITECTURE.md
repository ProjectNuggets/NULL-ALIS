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
- MV3 evicts idle workers (~30s). All persistent state lives in
  `chrome.storage.local` (token, gateway URL) — the in-memory `status` object
  is rebuilt on revive.

### Content script (`src/content.ts`)

- Installed via `manifest.json` content_scripts for `http://*/*` and
  `https://*/*` only (NOT `<all_urls>` — we exclude `file://`, `data:`,
  `blob:`, `ftp:`, `view-source:` etc. since the agent only automates
  the user's web-based logged-in sessions). Runs at `document_idle`.
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

### Handshake

1. Extension opens the socket.
2. Extension immediately sends:

   ```json
   { "type": "auth", "token": "<bearer token>", "extension_version": "0.1.0" }
   ```

3. Gateway validates the token. If valid, gateway MAY respond with:

   ```json
   { "type": "auth_ack", "ok": true }
   ```

   If invalid, gateway MAY respond:

   ```json
   { "type": "auth_ack", "ok": false, "error": "invalid_token" }
   ```

   and then close the socket with code 1008 (policy violation).

4. The extension DOES block on `auth_ack` (since 2026-05-25, Wave 3
   review CRITICAL #5). Inbound `Command` frames received before
   `auth_ack{ok:true}` are dropped on the floor and not dispatched. If
   `auth_ack` doesn't arrive within `authTimeoutMs` (default 5s), the
   extension closes the socket with code 1008 and surfaces
   `last_error: "auth_timeout"` in the popup. `auth_ack{ok:false}`
   closes with `last_error: "auth_failed: <reason>"`. Ping/pong is
   exempt — heartbeat must work pre-ack so proxies don't drop the
   connection during the handshake window.

   Gateways MUST send `auth_ack` immediately after validating the token.
   The pre-fix "we just close the socket on bad auth" behavior also
   works (the extension reconnects with backoff) but is less informative
   for the user — a fast `auth_ack{ok:false}` produces a clean popup
   message; a silent close produces a generic "closed (code 1006)".

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
| `navigate`    | background (chrome.tabs) | `url`, optional `new_tab: boolean`                       | `{ tab_id, url }`                                       |
| `click`       | content script         | `selector`                                                | `{ clicked }`                                           |
| `type`        | content script         | `selector`, `text`                                        | `{ typed }`                                             |
| `fill_form`   | content script         | `fields: [{ selector, text }, ...]`                       | `{ filled }`                                            |
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
The gateway should expect a fresh `auth` frame on every reconnect.

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
