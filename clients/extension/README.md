# nullalis browser extension

The "agent drives your own browser with your own logged-in sessions" path.

When you ask the nullalis agent to "find that email from my boss about Q3" or
"summarize this paywalled article I'm reading," server-side automation cannot
do that without smuggling your cookies (a privacy disaster). This extension
solves that the right way: it runs IN your real Chrome/Edge/Arc/Brave with
your real sessions, and only acts on the tab you're looking at.

This is Wave 3B of the final-sprint scaffold. The companion Wave 3A path
(server-side Playwright for fresh, anonymous browsing) is a separate
deliverable. They share the same tool surface so the agent has one mental
model — only the execution location differs.

## Status

**v0.1 / scaffold.** Loads unpacked in Chrome. Connects (or fails to connect)
to a gateway WebSocket. Executes the full command surface against the active
tab. Gateway-side wiring is implemented in a follow-up nullalis commit; until
then, you can verify the extension by pointing it at any WebSocket echo
server.

## Install (developer mode)

1. `cd clients/extension`
2. `npm install`
3. `npm run build` → produces `dist/`
4. In Chrome: `chrome://extensions` → enable **Developer mode** (top right) →
   click **Load unpacked** → select `clients/extension/dist`.
5. Pin the nullalis extension from the puzzle-piece menu so the toolbar icon
   is visible.
6. Click the icon. Paste your gateway URL (e.g. `wss://gateway.nullalis.local/ext/ws`)
   and your nullalis extension token. Save.

You should see the badge flip to **connected** within a second if the gateway
is up, or **disconnected** with the underlying error otherwise.

## Dev workflow

```bash
npm run dev      # Vite dev server with HMR for the popup
npm run build    # production build into dist/
npm test         # vitest run — ws_client + commands + manifest
npm run typecheck
```

The `dev` mode produces a watch-mode `dist/` you can keep loaded in Chrome;
just hit the reload arrow on the extension card after a rebuild. The popup
itself hot-reloads.

## Pointing at a local gateway

For local development, run your nullalis gateway with a WebSocket endpoint
bound to `/ext/ws`, then in the popup set:

- gateway url: `ws://127.0.0.1:8090/ext/ws`
- token: whatever your local dev token is

(The popup accepts `ws://` for localhost dev, but always use `wss://` in any
non-loopback scenario — your auth token rides this connection.)

## v1 limitations (deliberate)

- **Chromium only.** Firefox MV3 has small but real divergences (background
  script lifecycle, `browser.*` namespacing) — those are deferred. Marked as
  `TODO(firefox)` in the source where relevant.
- **Active-tab only.** The agent operates only on the currently-focused tab.
  Multi-tab orchestration (e.g. "open these 5 search results and summarize
  each") is a v1.1 item that needs a permission-gating UX, not just code.
- **No `<all_urls>` host permission.** We rely entirely on the declarative
  content-script injection + `activeTab`. The agent cannot reach into other
  origins without your active focus.
- **Viewport screenshots only.** `screenshot(full_page: true)` returns the
  visible viewport with `full_page: true` echoed back. Scroll-and-stitch
  full-page screenshots are v1.1.
- **No request-signing.** Per-message HMAC is **deliberately deferred** — over
  `wss`/TLS with per-user constant-time token auth in the trusted service
  worker, it adds no attacker work over what the channel already provides. See
  the "Request signing" section of `../../docs/extension-distribution.md` for
  the full threat-model rationale and the concrete trigger (a non-TLS
  deployment, or token rotation) that would justify revisiting it.

Branded icons (`public/icon-{16,48,128}.png`) are real, generated reproducibly
via `npm run icons` (see `scripts/gen-icons.sh`).

## Architecture pointer

See `docs/ARCHITECTURE.md` for the gateway-side contract this extension
expects, and `docs/SECURITY.md` for the threat model.

## License

Source-available under the nullalis repo's existing dual license. See the
root `LICENSE` and `LICENSE-COMMERCIAL.md`.
