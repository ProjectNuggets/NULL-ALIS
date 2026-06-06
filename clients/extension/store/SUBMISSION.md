# Chrome Web Store submission runbook — nullalis extension

Step-by-step procedure to publish the nullalis browser extension to the Chrome
Web Store (CWS). The **copy** for every listing field lives in `LISTING.md`;
this file is the **procedure**. Accurate to the CWS flow as of 2026.

> **Self-hosted is the default path.** nullalis is source-available and
> self-hostable; the Web Store is one of several distribution options. See
> `../../../docs/extension-distribution.md` for the full picture (manual
> sideload, enterprise managed `.crx` + `update_url`, and this CWS path). Pick
> per your compliance posture. The CWS path means Google hosts, signs, and
> auto-updates the extension, at the cost of review latency and a public-ish
> listing.

---

## What needs a human (cannot be automated)

These steps are manual actions a person must perform — flagged up front so
nothing is assumed done:

- **Creating the CWS developer account** and paying the one-time fee (below).
- **Hosting the privacy policy** at a public HTTPS URL (the *content* is
  `../docs/PRIVACY.md`; someone must publish it and supply the URL).
- **Capturing real screenshots** of the running extension (see
  `assets/SCREENSHOTS.md`). These must show the real product and cannot be
  faked.
- **Clicking "Submit for review"** and responding to any reviewer follow-ups.

---

## Step 0 — One-time: Chrome Web Store developer account  (MANUAL)

You only do this once per publishing identity.

1. Go to the **Chrome Web Store Developer Dashboard**:
   <https://chrome.google.com/webstore/devconsole>.
2. Sign in with the Google account that will own the listing. (For an org,
   prefer a shared/role account over a personal one.)
3. Pay the **one-time US$5 developer registration fee** when prompted. This is a
   manual Google-account action — there is no API for it.
4. Accept the developer agreement. Optionally complete the publisher
   verification / contact-email steps Google asks for; an unverified publisher
   can still publish but shows less trust signal.

---

## Step 1 — Build the upload artifact

From the extension root:

```bash
cd clients/extension
npm install          # first time only
npm run typecheck    # tsc --noEmit — must be clean
npm test             # vitest run — must be green
npm run package      # build + zip dist/ → nullalis-extension.zip
```

`npm run package` runs the production build and zips the **contents of
`dist/`** (not the `dist/` folder itself), producing `nullalis-extension.zip`
with `manifest.json` at the **root of the zip**. CWS requires the manifest at
the zip root — verify it:

```bash
unzip -l nullalis-extension.zip | grep -E '(^|/)manifest\.json'
# Expect a line ending in "  manifest.json" with NO directory prefix.
```

The manifest in this artifact is **version 1.0.0** (first public release) and
declares the least-privilege permission set (`activeTab`, `scripting`,
`storage`), an explicit locked-down CSP, and no `update_url` (the Web Store
supplies updates; `update_url` is only for the self-hosted managed path).

`nullalis-extension.zip` is gitignored — it is a build output, regenerated on
demand, never committed.

---

## Step 2 — Create the listing (New item)

1. In the Developer Dashboard, click **New item**.
2. **Upload** `nullalis-extension.zip`. CWS validates the manifest on upload;
   fix any errors it reports and re-upload.
3. After upload succeeds you land on the item's listing editor.

---

## Step 3 — Fill the "Store listing" tab  (from `LISTING.md`)

Copy each field from `LISTING.md`:

- **Product name** → `nullalis`.
- **Summary** → the ≤132-char summary string (matches the manifest description).
- **Description** → the "Detailed description" block.
- **Category** → **Developer Tools**.
- **Language** → English (United States).
- **Single purpose** → the single-purpose statement.

---

## Step 4 — Upload graphic assets  (Store listing tab)

- **Store icon** — CWS auto-derives this from the manifest's 128×128 icon
  (`public/icon-128.png`); no separate upload needed.
- **Screenshots** — **required: at least one** 1280×800 (preferred) or 640×400
  PNG/JPEG showing the real product. Capture these per
  `assets/SCREENSHOTS.md` (load unpacked → screenshot the popup states). Upload
  in the recommended order from that checklist. **Do not fabricate
  screenshots** — they must show the actual popup/feature.
- **Small promo tile** — upload `assets/promo-440x280.png` (440×280, generated
  by `scripts/gen-store-assets.sh`). Optional but recommended; it improves the
  listing's presentation.
- (Optional) Marquee/large promo tiles are not provided and are not required.

---

## Step 5 — Fill the "Privacy practices" tab  (from `LISTING.md`)

1. **Single purpose** → paste the single-purpose statement.
2. **Permission justifications** → paste the per-permission justifications
   (`activeTab`, `scripting`, `storage`) into their respective fields.
3. **Data usage** → check the data categories per the `LISTING.md` "Privacy
   practices" table (Website content: yes; Authentication information: yes;
   analytics/web history/location: no), and paste the plain-English
   data-handling summary.
4. **Certifications** → check the three required disclosure boxes (no selling to
   third parties; no use beyond single purpose; not for creditworthiness).
5. **Privacy policy URL** → paste the **public HTTPS URL** where the operator
   has hosted the content of `../docs/PRIVACY.md`. This must be live and
   reachable without login **before** submitting — CWS will reject or flag a
   missing/broken policy URL for an extension that handles user data.

---

## Step 6 — Distribution / visibility

On the **Distribution** (or "Visibility") settings:

- Choose **Public**, **Unlisted**, or **Private** (restricted to a Google
  Workspace org). For an agent that drives a user's logged-in sessions, many
  operators prefer **Unlisted** or **Private** so the listing is not in the
  public catalog. Pick per your compliance posture.
- Set the regions if you want to restrict availability.

---

## Step 7 — Submit for review

1. Resolve any remaining "draft incomplete" warnings the dashboard shows
   (missing screenshot, missing privacy URL, etc.).
2. Click **Submit for review**.
3. CWS runs automated checks plus a human review.

---

## Step 8 — After submission

- **Review latency:** typically a few business days, but it can be longer —
  extensions that request scripting/host-style access or handle page content
  are reviewed more carefully. There is no guaranteed SLA. Watch the dashboard
  status and the publisher email for follow-up questions.
- **If rejected:** the dashboard explains why. Fix the listing or the
  extension, **bump the version** if you changed the code, re-`npm run package`,
  re-upload, and resubmit.
- **Updates require a version bump.** Every new upload must have a higher
  `manifest.json` `version` than the published one (e.g. `1.0.0` → `1.0.1`).
  Re-run `npm run package` and upload the new zip; each update goes through
  review again.
- **Keep `LISTING.md` and the dashboard in sync.** If you change the summary,
  description, or permissions, update `LISTING.md` in the same change so this
  repo stays the source of truth.

---

## Cross-references

- Listing copy (all fields): `./LISTING.md`
- Screenshot capture checklist: `./assets/SCREENSHOTS.md`
- Privacy policy content: `../docs/PRIVACY.md`
- Security/threat model: `../docs/SECURITY.md`
- Full distribution options (sideload / managed `.crx` / Web Store):
  `../../../docs/extension-distribution.md`
