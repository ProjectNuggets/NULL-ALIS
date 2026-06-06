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
- The extension does NOT request `<all_urls>` host permission, and as of the
  consent redesign it does NOT request the broad `tabs` permission either. The
  full permission set is exactly `activeTab`, `scripting`, `storage`.
- **There is NO declarative content script.** The agent's in-page code is
  injected ON DEMAND — only into tabs you explicitly enable — via
  `chrome.scripting.executeScript`. Pages you never enable never receive any
  extension code.

## Per-tab consent (the real model)

This is the core of the security model and the manifest's "explicit consent per
tab" claim. It is implemented, not aspirational:

1. **Nothing runs until you opt in.** Open the popup on a tab and click
   **"Enable agent on this tab."** That click is a user gesture, so Chrome
   grants `activeTab` for that tab; the background then (a) records the tab id
   in a `consentedTabs` set persisted in `chrome.storage.session`, and (b)
   injects the content script into that one tab.
2. **Every tab-touching command checks consent.** `click`, `type`, `fill_form`,
   `get_text`, `get_dom`, `wait_for`, `scroll`, `navigate` (same-tab),
   `screenshot`, and `list_tabs` all reject with
   `{ ok:false, error:{ code:"consent_required" } }` if the active tab is not in
   `consentedTabs`. There is no code path that acts on a non-consented tab.
   (A new tab the agent opens via `navigate new_tab:true` follows a bounded
   **consent-inheritance** model: it is allowed ONLY when the current active
   tab is already consented — that already-enabled tab is the gesture-of-record.
   If the active tab is not consented, `navigate new_tab:true` is rejected with
   `consent_required` and no tab is created. When allowed, the URL still passes
   the SSRF allowlist and the new tab is added to BOTH the consented and touched
   sets, so the agent may drive it and STOP reloads it. The agent can never
   self-grant consent out of nothing — every consented tab traces back to a tab
   the user explicitly enabled. The popup shows the count of currently-enabled
   tabs so the agent's full reach is visible.)
3. **Revocation is immediate and total.**
   - **STOP** sets a latch, aborts in-flight commands, reloads touched tabs,
     severs the socket, AND clears the entire `consentedTabs` set.
   - **Disconnect** clears the entire `consentedTabs` set.
   - **Closing a tab** removes it from the set (`chrome.tabs.onRemoved`).
   - The popup has a per-tab **disable** control.
   - Consent lives in `chrome.storage.session`, so a browser restart wipes it —
     consent is never durable across restarts.
4. **v1 scope note:** for v1, navigation *within* an already-consented tab keeps
   consent (we don't re-prompt on every in-tab navigation). Switching focus to a
   different, non-enabled tab does not grant the agent anything.

## Latched STOP

The STOP button is a hard kill, not a soft pause. Pressing it:
- sets a `stopped` latch (persisted to `chrome.storage.session`) — while set,
  no command is dispatched (they return a `stopped` error) and the socket will
  NOT auto-reconnect, even across service-worker eviction/revival;
- aborts and awaits any in-flight command before reloading;
- reloads every tab the agent touched this browser session;
- clears all per-tab consent and severs the WebSocket.

The latch is cleared **only** by an explicit **connect** from the popup. An
idle-worker revival or browser restart cannot silently bring a stopped agent
back online.

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
  currently focused on AND have explicitly enabled. Switch tabs and the agent's
  reach goes with you.
- **`navigate` URL allowlist (SSRF defense).** The one command that takes an
  attacker-influenceable URL only accepts `http:`/`https:` to public hosts. It
  rejects `javascript:`, `data:`, `file:`, `chrome:`, `about:`,
  `view-source:`, `blob:` and any loopback / RFC1918 / link-local /
  `169.254.*` / cloud-metadata / `*.local` host — so a compromised gateway
  can't pivot through the browser to internal services or run script URLs.
  This mirrors the gateway's own SSRF guard (`url_sanitize.zig` / `urlguard.go`),
  including IPv4-mapped IPv6 (`[::ffff:127.0.0.1]` / `[::ffff:169.254.169.254]`,
  whether the parser hands us the dotted or hex-hextet form) and trailing-dot
  FQDN-root hosts (`localhost.`), both of which decode to a blocked address.
- **Sensitive-field write guard.** `type` / `fill_form` default-DENY writing to
  `input[type=password]` and `autocomplete=cc-*` fields. The server must set an
  explicit `allow_sensitive:true` on the command to write them, and when it
  does the in-page toast says so.
- **Inbound frame size cap.** WebSocket frames larger than 8 MB are dropped
  before parsing so a hostile gateway can't OOM or stall the service worker.
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

- **No result-frame HMAC signing — deliberately deferred, not a TODO.** Over
  `wss://` (TLS) the record layer already gives every frame integrity +
  confidentiality, and the per-user token already authenticates the channel
  constant-time server-side (`src/extension_ws/auth.zig`) from inside the
  trusted background service worker (the token never reaches page scripts).
  HMAC keyed by that same token would re-prove channel authenticity TLS + auth
  already prove, and defends against neither real threat (a compromised gateway
  can drive the browser directly; a compromised extension surface holds the
  token and could mint a valid MAC). It is therefore theater here. The token
  *is* long-lived/reusable across reconnects with no per-session nonce, but the
  honest fix for that is token rotation + a handshake nonce, not result HMAC.
  Full rationale + the trigger that would change this (a non-TLS deployment, or
  rotating tokens) is in `../../docs/extension-distribution.md` →
  "Request signing".
- **No per-origin allow-lists.** Consent is per-tab, not per-origin: enabling a
  tab enables the agent on whatever that tab navigates to next. v1.1 will let
  you say "allow nullalis on github.com and gmail.com only."
- **No command audit log inside the extension.** The popup shows the most
  recent command and a count, but there's no scrollable history. The
  gateway side has the full audit trail; the extension is intentionally
  stateless beyond the auth config.

## Manifest hardening (implemented)

- **Explicit, locked-down CSP.** `manifest.json` declares
  `content_security_policy.extension_pages = "script-src 'self'; object-src
  'self'"`. This pins the popup / extension-page script + object sources to the
  extension's own origin on top of the MV3 defaults.
- **No `web_accessible_resources`.** Removed entirely — the on-demand content
  script is a self-contained classic script injected via `executeScript`, not a
  page-reachable module, so nothing in the extension is exposed to page script.
- **Least-privilege permissions.** Exactly `activeTab`, `scripting`, `storage`.
  `tabs` was dropped; `<all_urls>` / host permissions were never requested.

## Reporting

Security issues that affect the extension specifically should follow the
existing nullalis disclosure path in the repository root `SECURITY.md`.
