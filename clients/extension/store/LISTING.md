# Chrome Web Store listing — nullalis

This file is the **source of truth** for every field the Chrome Web Store (CWS)
Developer Dashboard asks for when publishing the nullalis extension. Copy each
section into the matching dashboard field at submission time. Everything here is
written to be honest and accurate to the real consent model — do not embellish
it; CWS reviewers compare the listing against the actual behavior.

The submission *procedure* lives in `SUBMISSION.md`. This file is the *copy*.

---

## Product name

```
nullalis
```

## Summary  (CWS "Summary", ≤132 characters — becomes the store one-liner)

```
Lets the nullalis agent act in browser tabs you explicitly enable, driven only by your own self-hosted gateway. STOP anytime.
```

(125 characters. This string is identical to `manifest.json` → `description`,
which CWS uses as the default summary. Keep the two in sync if either changes.)

## Category

```
Developer Tools
```

nullalis is a developer/operator tool: it connects a browser to a self-hosted
nullalis gateway so an agent can drive tabs the user enables. "Developer Tools"
is the honest fit; it is not a consumer productivity or shopping extension.

## Default language

```
English (United States)
```

---

## Detailed description  (CWS "Description")

> nullalis lets the nullalis agent act inside browser tabs that **you**
> explicitly turn on — using **your own** logged-in sessions, on **your own**
> machine. It is the "drive my real browser" path for nullalis, as opposed to
> server-side automation that would have to smuggle your cookies.
>
> **You are always in control, one tab at a time.**
> Nothing happens automatically. The extension does not read or touch any page
> until you open the toolbar popup on a specific tab and click **"Enable agent
> on this tab."** That click is the consent. Only tabs you enable can be read or
> driven; every other tab is untouched. There is no content script that loads on
> page open — the agent's code is injected on demand, only into a tab you
> enabled.
>
> **It talks only to your own gateway.**
> The extension connects to exactly one WebSocket endpoint — the nullalis
> gateway URL **you** type into the popup — over a secure `wss://` connection.
> nullalis is open and self-hostable: you run the gateway. The extension sends
> page content, screenshots, and command results to that gateway and **nowhere
> else**. There are no analytics, no telemetry, no trackers, and no third-party
> servers of any kind.
>
> **STOP is a hard kill.**
> A big red **STOP** button in the popup instantly severs the connection,
> reloads every tab the agent touched (discarding any half-typed input), clears
> all per-tab consent, and latches the agent off until you explicitly reconnect.
> You can also disable any single tab, disconnect, or clear your stored token at
> any time. A browser restart clears all consent automatically.
>
> **Built for people who want to verify, not trust.**
> The popup always shows the gateway URL it is connected to (so you can spot a
> wrong endpoint), shows a live count of which tabs are enabled, and shows the
> most recent command the agent ran. Writing to password and credit-card fields
> is denied by default. The extension requests a minimal permission set —
> `activeTab`, `scripting`, `storage` — and **no** host permissions, so it
> cannot silently reach into sites you have not focused and enabled.
>
> nullalis is source-available and self-hostable. The extension source, its
> security model, and its privacy policy are public.

---

## Single-purpose statement  (CWS requires one clear single purpose)

```
Let the nullalis agent perform actions in browser tabs you explicitly enable, driven by your own self-hosted nullalis gateway.
```

The extension does exactly one thing: it acts as the in-browser execution
endpoint for a user-operated nullalis gateway, performing read/automation
actions only on tabs the user has explicitly enabled. It has no secondary
features (no new-tab page, no search hijack, no ads, no analytics).

---

## Permission justifications  (CWS "Permissions" — one per requested permission)

Paste each justification into the matching permission field in the dashboard.
These map 1:1 to `manifest.json` → `permissions` (`activeTab`, `scripting`,
`storage`). No other permissions are requested.

### `activeTab`

```
Used so the agent can act ONLY on the tab the user explicitly enables from the
toolbar popup. Clicking "Enable agent on this tab" is the user gesture that
grants activeTab for that single tab; the agent reads or automates that tab and
no other. There are no host permissions and no <all_urls> access — the
extension cannot reach a tab the user has not focused and enabled.
```

### `scripting`

```
Used to inject the agent's command-runner on demand, via
chrome.scripting.executeScript, into the one tab the user just enabled. There is
NO declarative content script that loads on page open: code is injected only
into a consented tab, only after the user enables it. This is what lets the
agent read page content and perform clicks/typing on that tab.
```

### `storage`

```
Used to persist the two pieces of configuration the user enters in the popup —
the gateway WebSocket URL and the per-user gateway token — in
chrome.storage.local on this device. This is local-only, per-profile, not synced
to any Google account, and never exposed to web page scripts. The token is
transmitted only to the user's own configured gateway during the authenticated
handshake.
```

### Reviewer note (not a field — context for the permissions reviewer)

```
No host permissions and no <all_urls>. No declarative content_scripts (injection
is on-demand into consented tabs only). No remote code — the locked-down CSP
(script-src 'self'; object-src 'self') forbids loading any off-extension script,
and there is no eval/Function(string). No analytics, telemetry, or third-party
network destinations: the only network endpoint is the single gateway WebSocket
URL the user configures.
```

---

## Privacy practices  (CWS "Privacy" tab — Data usage form)

This section answers the CWS "Privacy practices" / data-disclosure form. The
full policy text is `../docs/PRIVACY.md`; this is the dashboard-form mapping.
The privacy-policy **URL** must be a public page the operator hosts — see
"Privacy policy URL" below.

### Single purpose (Privacy tab also asks this)

```
Let the nullalis agent perform actions in browser tabs you explicitly enable,
driven by your own self-hosted nullalis gateway.
```

### What user data is handled, and why  (check these categories)

| CWS data category | Collected? | What / why |
|---|---|---|
| Personally identifiable information | No | Not collected by the extension. |
| Health information | No | — |
| Financial / payment information | Indirectly | Only if a tab the user enables shows it. Writing to credit-card (`autocomplete=cc-*`) and password fields is denied by default. |
| Authentication information | Yes | The user's gateway **token** (stored locally) is sent only to the user's configured gateway to authenticate. |
| Personal communications | Indirectly | If the user enables a tab containing email/chat, its page content can be read on that tab — sent only to the user's gateway. |
| Location | No | — |
| Web history | No | The extension keeps no browsing history; it reads only the active enabled tab's title/URL on demand. |
| Website content | Yes | Page DOM/text and screenshots of **enabled tabs only**, read on demand to fulfill agent commands, sent only to the user's configured gateway. |
| User activity (analytics/clicks) | No | No analytics, no telemetry, no click tracking. |

### Required disclosure certifications  (CWS checkboxes — all must be true here)

- ☑ **I do not sell or transfer user data to third parties**, outside of the
  approved use cases. (True: data goes only to the user's own configured
  gateway; there are no third parties.)
- ☑ **I do not use or transfer user data for purposes unrelated to my item's
  single purpose.** (True.)
- ☑ **I do not use or transfer user data to determine creditworthiness or for
  lending purposes.** (True.)

### Plain-English data-handling summary  (for the "Why do you need this data?" box)

```
The extension handles data ONLY from tabs the user explicitly enables: the page
content/DOM/text and screenshots of those tabs, plus the active tab's title/URL.
It also stores the user's gateway URL and gateway token locally on the device.
All of this is transmitted ONLY to the single self-hosted gateway WebSocket URL
the user configures, over wss://. Nothing is sold, shared, or sent to any third
party. There are no analytics or trackers. The gateway URL and token are stored
in chrome.storage.local (local, per-profile, not account-synced); operational
state (which tabs are enabled) lives in chrome.storage.session and is cleared on
browser restart. The extension retains no history of page content or
screenshots.
```

### Privacy policy URL  (required field)

CWS requires a **publicly reachable HTTPS URL** for the privacy policy. The
policy *content* is `clients/extension/docs/PRIVACY.md`. The **operator must
host that content at a stable public URL** and paste that URL here, e.g.:

```
https://<your-domain>/nullalis/extension-privacy
```

(Suggested sources to host from: render `docs/PRIVACY.md` on the operator's
site, or link to the file on the public repo host. It must resolve over HTTPS
and be reachable without login.)

---

## Cross-references

- Full privacy policy text: `../docs/PRIVACY.md`
- Threat model / security claims behind this copy: `../docs/SECURITY.md`
- Submission runbook (how to actually publish): `./SUBMISSION.md`
- Screenshot capture checklist: `./assets/SCREENSHOTS.md`
- Promo tile asset: `./assets/promo-440x280.png`
