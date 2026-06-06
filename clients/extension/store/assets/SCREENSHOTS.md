# Screenshot capture checklist — CWS store listing

The Chrome Web Store **requires at least one screenshot** of the actual running
product (minimum one; up to five). These **cannot be fabricated** — they must
show the real popup/feature, and CWS reviewers compare them against the
extension's behavior. This file is the capture checklist; the screenshots
themselves are **not** committed (they show a real device/session and are
captured at submission time).

## Required dimensions

- **1280×800** (preferred) or **640×400**. Must be exactly one of these two
  sizes; CWS rejects other dimensions.
- Format: **PNG** (24-bit, no alpha) or JPEG.
- The popup itself is small (~320px wide), so do **not** screenshot just the
  raw popup at native size — it will be far below 1280×800. Instead, place the
  popup on a 1280×800 canvas (screenshot the browser window with the popup open,
  then crop/pad to 1280×800), or compose the popup centered on a 1280×800
  background. The product shown must be the real popup, unmodified.

## How to capture (load unpacked → screenshot)

1. `cd clients/extension && npm run build` to produce `dist/`.
2. Chrome → `chrome://extensions` → enable **Developer mode** → **Load
   unpacked** → select `clients/extension/dist`.
3. Pin the nullalis extension so the toolbar icon is visible.
4. Point it at a working gateway (or a local `ws://127.0.0.1` dev gateway / WS
   echo server) so the states below are reachable. Paste the gateway URL +
   token in the popup and **save and connect**.
5. Open the popup and capture each state below. Use the OS screenshot tool, then
   crop/pad to 1280×800.
6. **Use a throwaway/demo gateway and a dummy token** — never capture a real
   production token or real personal page content. Redact the token field
   (it is a password input, so it renders masked) and avoid sensitive tabs.

## Shots to capture (in this recommended listing order)

### 1. Connected / authenticated state  (REQUIRED — the primary shot)

- Popup with the header badge showing **authenticated** (green).
- The **gateway** section showing the configured `wss://…` URL (anti-phishing:
  the URL is always visible).
- The **activity** section showing "commands executed" and the last command.
- This is the hero screenshot: it shows the extension working and talking to the
  user's own gateway.

### 2. Per-tab consent — "Enable agent on this tab"

- Popup on a tab where the agent is **not** yet enabled, showing the green
  **"Enable agent on this tab"** button under "agent access (this tab)".
- This communicates the core consent model: nothing runs until the user enables
  a specific tab.

### 3. Tab enabled + STOP control

- Popup on a tab where the agent **is** enabled: the "agent enabled on tab #…"
  chip with its **disable** button, the "agent has N tabs enabled" count, and
  the big red **"STOP — sever and reload agent tabs"** button at the bottom.
- This shows both the granted-consent state and the prominent hard-kill control.

### 4. (Optional) Token / gateway configuration

- The first-run state (no token): the **gateway url** + **token** inputs and the
  **save and connect** button. Shows the local-only configuration step.

### 5. (Optional) Zaki view-feed — agent browsing live

- If a Zaki/live view-feed surface is available, capture the agent driving an
  enabled tab (e.g. the in-page command toast appearing top-right of the page
  as the agent acts). Shows the per-command transparency toast in action.
- Only include this if you can capture it from the **real** product; otherwise
  omit it. Do not stage a fake feed.

## Do NOT

- Do not commit screenshot PNGs to the repo (they are session/device-specific
  and captured fresh at submission).
- Do not fabricate, mock, or composite fake UI — every screenshot must be the
  real running extension.
- Do not capture real tokens or real sensitive page content.
