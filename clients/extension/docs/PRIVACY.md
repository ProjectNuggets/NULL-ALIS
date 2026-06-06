# Privacy Policy — nullalis browser extension

_Last updated: 2026-06-07_

This is the privacy disclosure for the **nullalis** Chrome extension. It also
serves as the privacy policy for the Chrome Web Store listing. The extension
lets the nullalis agent drive **your own** browser using **your own** logged-in
sessions, under your explicit per-tab consent.

## What the extension reads

The extension only reads from a browser tab **after you explicitly enable the
agent on that specific tab** (the "Enable agent on this tab" button in the
popup). On an enabled tab, in response to commands from the gateway you
configured, it may read:

- **Page content** — the DOM / visible text of the enabled tab
  (`get_text`, `get_dom`), and element state for automation
  (`click`, `type`, `fill_form`, `wait_for`, `scroll`).
- **Screenshots** — a PNG of the visible area of the enabled tab
  (`screenshot`).
- **Tab metadata** — the title and URL of the active enabled tab
  (`list_tabs`, which returns only the active tab).

Tabs you never enable are never read. The extension contains **no declarative
content script**: code is injected on demand only into tabs you enable.

## What the extension writes

On an enabled tab the agent may fill or click form fields. Writing to **password
fields** and **credit-card fields** (`autocomplete=cc-*`) is **denied by
default** and only permitted when the gateway explicitly flags the command as
sensitive — in which case the in-page toast tells you.

## Where data goes

- **Only to the gateway you configure.** Page content, screenshots, and command
  results are transmitted **only** to the single gateway WebSocket URL you enter
  in the popup, over a **secure WebSocket (`wss://`)** connection. Plaintext
  `ws://` is rejected for any non-loopback host, so your data and token are
  never sent in cleartext over a network.
- **No third parties.** The extension sends data to **no** servers other than
  the gateway you configure. There are **no analytics, no telemetry, no
  trackers, no advertising SDKs**, and no other network destinations.

## What is stored locally, and where

- **`chrome.storage.local` (persists on this device):** only your **gateway
  token** and **gateway URL**. This storage is per-profile, is **not** synced to
  any Google/Chrome account, and is never exposed to web page scripts. The token
  is never transmitted anywhere except to your configured gateway during the
  authenticated handshake.
- **`chrome.storage.session` (in-memory, cleared on browser restart):**
  operational state only — which tabs you enabled, which tabs the agent touched,
  a command counter, and the STOP latch. No page content is persisted here.

The extension keeps **no history of page content or screenshots**. Command
results flow through to the gateway and are not retained in the extension.

## What the extension does NOT do

- Does not read tabs you have not enabled.
- Does not request `<all_urls>` or broad host permissions. Its full permission
  set is `activeTab`, `scripting`, `storage`.
- Does not intercept or modify network traffic (no `webRequest`).
- Does not read or set cookies directly (no `cookies` permission).
- Does not sell, share, or transmit your data to anyone other than your
  configured gateway.

## Your controls

- **Per-tab enable/disable** in the popup — consent is granted one tab at a
  time and can be revoked per tab.
- **STOP** — severs the connection, reloads tabs the agent touched, clears all
  consent, and latches the agent off until you explicitly reconnect.
- **Disconnect** — drops the connection and clears all per-tab consent.
- **Clear token** — wipes the stored token and gateway URL from this device.
- A **browser restart** clears all consent and session state.

## Contact

For privacy questions or security disclosures, follow the disclosure path in the
repository root `SECURITY.md`.
