# Security model

Honest threat-model document for the v1 extension. Read this before installing
it on a machine that handles anything sensitive.

## What the user is trusting

When you install this extension, you are trusting that:

1. **The nullalis gateway you point it at is the real nullalis gateway.**
   The popup always shows the gateway URL the extension is connected to,
   precisely so you can verify you're not connected to a phishing nullalis
   service. If the URL in the popup doesn't match what you configured,
   something is wrong.

2. **Your gateway token is a high-trust secret.** It authenticates your
   browser to the nullalis service. Anyone with this token can issue
   commands to your browser the same way the agent does. Store it like a
   password.

3. **Whoever controls the gateway can drive your browser** as if they were
   sitting in front of it, with all your logged-in sessions. The agent is
   constrained to the active tab and shows a toast on every command, but
   "constrained to the active tab" still means it can read your inbox,
   read your bank account, submit forms — anything you yourself could do.

4. **A compromised page can read the toast notification but cannot read the
   token.** The token never leaves `chrome.storage.local`, which is
   per-extension and not exposed to page scripts.

## What the extension is NOT trusting

- The current page is **never** trusted. The content script lives in an
  isolated JS world; page scripts cannot read variables or call functions
  defined in the content script.
- No `eval()`, `Function(string)`, or other dynamic-code-execution surfaces
  exist in any extension context. Selectors are passed to `querySelector`,
  which is safe by design (it's not an `eval`).
- The extension does NOT request `<all_urls>` host permission. The content
  script attaches declaratively, and the background uses `activeTab` only,
  so the agent's reach is gated by user focus.
- The declarative content-script injection itself is also narrowed: it only
  matches `http://*/*` and `https://*/*`, not `<all_urls>`. `file://`,
  `data:`, `blob:`, `ftp:`, and `view-source:` documents do NOT get the
  content script injected — they're outside the use case (the agent
  automates web-based logged-in sessions) and were prior in-page surface
  with no purpose.

## Mitigations in v1

- **In-place toast on every command.** Every time the agent acts in the tab,
  a small dark toast appears top-right of the page saying what tool the
  agent invoked. This is best-effort (some pages — XML viewers, sandboxed
  iframes — can't host the toast) but it works on the overwhelming
  majority.
- **Big red STOP button** in the popup. Pressing it severs the WebSocket
  and reloads every tab the agent has touched in the current session,
  discarding any half-typed input or in-flight form.
- **Active-tab-only operation.** The agent can only act on the tab you are
  currently focused on. Switch tabs and the agent's reach goes with you.
- **No `webRequest` permission.** The extension cannot intercept or modify
  network traffic.
- **No `cookies` permission.** The extension cannot read or set cookies
  directly — it only interacts at the DOM layer, so any auth state it uses
  is the auth state your real browser session has.
- **Gateway URL is shown in the popup.** Pin the extension. Glance at the
  URL when in doubt.
- **Token validation on save.** The popup rejects gateway URLs that aren't
  `ws://` or `wss://`, and refuses empty tokens.

## Known v1 gaps (deferred)

These are tracked and intentional, not blind spots:

- **No result-frame HMAC signing.** A compromised gateway today can already
  drive the browser, so signing the result doesn't help against gateway
  compromise. The real risk this addresses is a MITM-injected gateway URL
  that intercepts results before the real gateway sees them. Mitigation:
  always use `wss://` to a hostname under a cert your machine trusts. The
  HMAC-sign-results work is v1.1.
- **No per-origin allow-lists.** The agent can act on any tab you're
  focused on. v1.1 will let you say "allow nullalis on github.com and
  gmail.com only."
- **No command audit log inside the extension.** The popup shows the most
  recent command and a count, but there's no scrollable history. The
  gateway side has the full audit trail; the extension is intentionally
  stateless beyond the auth config.
- **The placeholder icons (`public/icon-*.png`) are tiny PNG stubs.** They
  are visually distinct enough to not be confused with another extension
  during dev, but real branding lands at Chrome Web Store publish time.
- **No CSP/permissions policy lockdown in `manifest.json`** beyond the MV3
  defaults. We deliberately omit `content_security_policy` because the MV3
  defaults are stricter than anything we'd write and we want them.

## Reporting

Security issues that affect the extension specifically should follow the
existing nullalis disclosure path in the repository root `SECURITY.md`.
