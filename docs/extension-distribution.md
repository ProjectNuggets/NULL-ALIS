# nullalis extension — distribution + packaging runbook

How to get the nullalis browser extension onto a machine, from a single
developer loading it unpacked through to an enterprise fleet receiving a
signed auto-updating build. Accurate to Chrome MV3 (`minimum_chrome_version`
116). The extension source lives in `clients/extension/`.

This doc also records the **request-signing decision** (per-message HMAC) —
see the last section.

---

## 0. Build the artifacts

```bash
cd clients/extension
npm install
npm run build      # tsc --noEmit && vite build → dist/
npm test           # vitest run — 51 tests (ws_client + commands + manifest)
npm run package    # build + zip dist/ → nullalis-extension.zip
```

`npm run package` is the one-liner that produces a shippable archive:

```json
"package": "npm run build && cd dist && zip -r ../nullalis-extension.zip . && cd .."
```

The resulting `nullalis-extension.zip` is **gitignored** (`*.zip`) — it is a
build output, regenerated on demand, never committed.

### Icons

`public/icon-{16,48,128}.png` are real branded icons (rounded nullalis-purple
tile, white "n" glyph), not placeholders. They are generated reproducibly:

```bash
npm run icons      # bash scripts/gen-icons.sh — requires ImageMagick 7 (`magick`)
```

`scripts/gen-icons.sh` renders each size natively at 4× and downsamples for
clean antialiasing at 16px, then writes 8-bit PNGs. Re-run it only when the
brand mark changes; the PNGs themselves are committed so a contributor without
ImageMagick can still build. The manifest references exactly 16/48/128 (the
sizes Chrome uses for the toolbar, extensions page, and store/management
surfaces respectively); there is intentionally no 32px entry.

---

## 1. Developer install (unpacked)

The day-to-day path. No signing, no hosting.

1. `npm run build` (or `npm run dev` for a watch-mode `dist/` with popup HMR).
2. Chrome → `chrome://extensions` → enable **Developer mode** (top-right).
3. **Load unpacked** → select `clients/extension/dist`.
4. Pin the extension from the puzzle-piece menu so the toolbar icon shows.
5. Click the icon, set the gateway URL (`wss://…/api/v1/extension/ws`) and your
   per-user extension token, Save.

After a rebuild, hit the reload arrow on the extension card. This path is for
developers only — unpacked extensions show a "Developer mode extensions"
warning and are disabled on managed/locked-down profiles.

---

## 2. Self-hosted distribution

nullalis is source-available and self-hostable, so the default distribution
story is **operator-owned**, not Web-Store-dependent. Two self-hosted options,
in increasing operational weight.

### 2a. Manual sideload (the zip)

For a handful of trusted users (a team, a pilot).

1. Operator runs `npm run package`, producing `nullalis-extension.zip`.
2. Distribute the zip over a trusted channel (internal file share, signed
   release asset).
3. Each user unzips it and **Load unpacked** the unzipped folder (as in §1),
   OR drags the zip onto `chrome://extensions` if Developer mode is on.

Pros: zero infrastructure. Cons: no auto-update (every bump = re-distribute +
re-load), and it requires Developer mode, which managed fleets usually
disable. Fine for dev/pilot, not for a fleet.

### 2b. Enterprise managed install — signed `.crx` + private `update_url`

The real fleet path for managed Chrome (ChromeOS, or Chrome under an MDM /
Google Admin / Windows Group Policy / macOS configuration profile). This
delivers a signed, auto-updating build **without** the Chrome Web Store.

What MV3 / managed Chrome requires:

1. **A signing key.** Generate an extension private key once and keep it
   secret (it defines the extension ID forever):
   ```bash
   # one-time: produce key.pem and an initial .crx
   # (Chrome → chrome://extensions → "Pack extension", or the chrome CLI:)
   chrome --pack-extension=./dist --pack-extension-key=./key.pem
   ```
   The public key embedded in the `.crx` deterministically derives the
   32-char extension ID. **Operator owns this key** — losing it means a new
   ID and a forced reinstall for every user.

2. **An `update_url` in the manifest** pointing at a private update manifest
   you host:
   ```jsonc
   // manifest.json (managed build only)
   "update_url": "https://updates.your-org.example/nullalis/updates.xml"
   ```
   We deliberately do **not** ship `update_url` in the in-repo `manifest.json`
   — it is added only when an operator cuts a managed build, so the dev/
   Web-Store builds aren't pinned to anyone's private update server.

3. **A private update manifest (`updates.xml`)** you host at that URL,
   following Chrome's `gupdate` schema:
   ```xml
   <?xml version='1.0' encoding='UTF-8'?>
   <gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
     <app appid='YOUR_EXTENSION_ID'>
       <updatecheck codebase='https://updates.your-org.example/nullalis/nullalis-1.2.0.crx'
                    version='1.2.0' />
     </app>
   </gupdate>
   ```
   Bump `version` + `codebase` on each release; Chrome polls this and
   auto-updates managed clients.

4. **A force-install / allowlist policy** so managed clients actually pick it
   up. Via Google Admin console, or
   `ExtensionInstallForcelist` / `ExtensionInstallAllowlist` policy:
   ```
   ExtensionInstallForcelist = YOUR_EXTENSION_ID;https://updates.your-org.example/nullalis/updates.xml
   ```
   Without a policy entry, modern Chrome blocks off-store `.crx` installs by
   default — the `update_url` + force-install policy is what makes an off-store
   extension installable at all on a non-developer profile.

**Still operator-owned** in this path: the signing key, the HTTPS hosting for
the `.crx` and `updates.xml`, the version-bump/release cadence, and the MDM
policy push. nullalis ships the buildable source + the `package` script; the
operator owns the PKI and the distribution endpoints. This is the correct
trust boundary — the people who can drive the fleet's browsers should be the
people who hold the signing key.

### 2c. Chrome Web Store — the alternative

An operator who prefers Google-hosted distribution and review can instead
submit `nullalis-extension.zip` to the Chrome Web Store (public or
unlisted/private to a Google Workspace org). Trade-offs vs §2b:

- Google hosts + signs + auto-updates; no `update_url` / `updates.xml` / key
  management on the operator.
- But: Google review latency on each release, Google's policy surface, and a
  public-ish listing. For an agent that drives a user's logged-in sessions,
  many operators will prefer the self-hosted managed path so the extension
  never sits in a public catalog. Pick per your compliance posture.

---

## Request signing — decision: **deliberately deferred**

The contract's v1.1-deferred item is per-message HMAC: signing
`command_id + result-hash` with the per-user token as the shared secret, so the
gateway can verify result frames weren't tampered with. **We are not building
it.** Rationale and the precise trigger that would change this:

### Why HMAC does not meaningfully raise the bar today

The transport and auth model already provide what HMAC would:

1. **Confidentiality + integrity on the wire is TLS's job, and it does it.**
   In production the connection is `wss://` (TLS). An on-path attacker cannot
   read or modify frames without breaking TLS. A per-message HMAC keyed by the
   token adds no integrity guarantee over what the TLS record layer already
   gives every frame.

2. **The token already authenticates the channel, constant-time, server-side**
   (`src/extension_ws/auth.zig`). The token maps to exactly one server-derived
   `user_id`; the inbound frame's `user_id` is ignored, so cross-tenant
   impersonation is closed at auth. HMAC with the *same* token as key would be
   proving channel authenticity that the auth handshake already proved — it
   reuses the one secret that's already gating the socket.

3. **The secret lives in the trusted context, not the page.** The token and
   the WS connection live in the background service worker. Page scripts and
   content scripts never see the token (`chrome.storage.local` is
   per-extension, isolated world). There is no untrusted in-page surface that
   could forge a frame the gateway would accept but that HMAC would catch — the
   only thing that *can* send frames already holds the token.

4. **It does not defend against the two real threats.** A *compromised
   gateway* can already drive the browser directly, so signing results it
   receives is theater. A *compromised extension surface* holds the token, so
   it can mint a valid HMAC too. HMAC keyed by the auth token closes neither.

So per-message HMAC here would be **security theater**: ceremony that looks
like defense-in-depth but adds no attacker work over `token-auth + TLS`.

### The one real property worth naming (and why it still doesn't justify HMAC)

The token **is** long-lived and reusable across reconnects — there is no
per-session nonce binding the token to a single connection
(`auth.zig` validates the token statelessly; `hub.zig` mints per-connection
`command_id`s but those are correlation IDs, not authenticators). On a
**TLS** deployment this is fine: an attacker who can replay an auth frame
already sits inside the TLS session, i.e. has already lost you the channel.
Result frames are correlated to a per-connection pending map by `command_id`
and unknown IDs are dropped, so cross-connection replay of a *result* frame
lands nowhere. Per-message HMAC keyed by the same static token would **not**
fix the long-lived-token property anyway — the fix for that is token rotation
/ short-lived tokens, not signing.

### The concrete trigger that would justify revisiting

Build per-message signing (or, more likely, the better fix below) **only when
one of these becomes true**:

- **A non-TLS / TLS-terminating-proxy deployment becomes supported.** If the
  WS ever runs over plain `ws://` beyond loopback, or terminates TLS at an
  untrusted hop, frame integrity is no longer guaranteed by the transport and
  a per-message MAC (with a per-session nonce to stop replay) starts earning
  its keep.
- **Token rotation / short-lived per-session credentials land** (the contract
  already anticipates a BFF pairing flow minting rotating tokens). At that
  point the right move is a **per-session nonce in the auth handshake**
  (binding the token to one connection and killing replay), which is the
  minimal, honest fix for the long-lived-token property — *not* per-message
  result HMAC. If we do this, do the nonce, not the theater.

Until one of those triggers fires, request signing stays deferred and this
section is the rationale of record. Tracked alongside the other intentional
gaps in `clients/extension/docs/SECURITY.md`.
