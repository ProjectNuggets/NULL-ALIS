# Developer guide

## Prereqs

- Node 20+ (tested on 24.x). Use `nvm use 20` or similar.
- Chrome 116+ / Edge 116+ / Arc / Brave.
- A nullalis gateway endpoint for end-to-end testing (or any WebSocket echo
  server to confirm the popup wiring).

## First-time setup

```bash
cd clients/extension
npm install
npm run build
```

Then in Chrome:

1. Open `chrome://extensions`.
2. Toggle **Developer mode** (top-right).
3. Click **Load unpacked**.
4. Pick `clients/extension/dist`.
5. Pin the extension from the puzzle-piece menu.

## Iteration loop

```bash
npm run dev
```

Vite + crxjs rebuilds on file change. After a rebuild:

- For background / content / manifest changes: click the reload arrow on the
  extension card in `chrome://extensions`. (Service workers don't HMR.)
- For popup changes: just close and reopen the popup. Or live-edit while the
  popup is open — crxjs's HMR usually picks it up.

## Debugging

- **Background service worker:** on the extension card, click "service
  worker" → opens DevTools attached to the worker. Look here for WS
  connection logs, command dispatch errors, popup messaging.
- **Content script:** open DevTools on the page itself. The content script
  shares the page's DevTools but in the "isolated world" — use the
  context dropdown (top-left of console) to switch.
- **Popup:** right-click the popup → Inspect. The popup itself is a normal
  React app and DevTools React extension works in there.

## Tests

```bash
npm test            # vitest run, all suites
npm run test:watch  # vitest watch mode
```

Test suites:

- `tests/ws_reconnect.test.ts` — WsClient open/close/backoff/heartbeat against
  a MockWebSocket.
- `tests/commands.test.ts` — every content-script command against happy-dom.
- `tests/manifest.test.ts` — manifest sanity (MV3, permissions, entry points).

No chrome.* APIs are mocked because the unit tests cover the bits that don't
need them. End-to-end coverage of `chrome.tabs.sendMessage`, the real WS
handshake against a real gateway, and the popup mounted in a real browser
profile is **manual** for now — see the smoke checklist below.

## Manual smoke checklist

1. `npm run build` — confirms tsc + Vite both succeed.
2. Load unpacked in Chrome (above).
3. Click the icon. Popup opens. Expect: "no token" badge, gateway-URL +
   token input fields visible.
4. Paste a placeholder token + a deliberately wrong URL (e.g.
   `wss://127.0.0.1:1/ext/ws`). Save.
5. Badge flips to "disconnected" with a `last error` message. Confirm that
   the gateway URL shown matches what you pasted.
6. Click **STOP — sever and reload agent tabs**. Should be a no-op other
   than confirming nothing crashes.
7. Click **clear token**. Form returns.
8. (If a real gateway is up:) Repeat with the real URL + token; badge flips
   to "connected"; issue a `navigate` from the gateway side and confirm a
   "nullalis agent → navigate" toast appears in the target tab.

## Adding a new tool

1. Add the name to the `ToolName` union in `src/types.ts`.
2. If it operates on the DOM: write a pure `cmdXxx(doc, args)` in
   `src/commands.ts`, register it in `CONTENT_COMMANDS`. Add tests.
3. If it operates via `chrome.*`: register the name in `BACKGROUND_TOOLS` in
   `src/commands.ts`, add the implementation to `runBackgroundCommand` in
   `src/background.ts`.
4. Document the tool in `docs/ARCHITECTURE.md` table.
5. Update the gateway-side dispatcher to know about the new tool.

## Bundle inspection

```bash
npm run build
ls -lh dist/
```

Expected outputs: `manifest.json`, `assets/` with the popup HTML/JS/CSS, the
background and content workers, and the icon copies. Keep the total under
~500 KB — anything bigger usually means a stray dep snuck in.

## Cleaning up

```bash
rm -rf node_modules dist
```
