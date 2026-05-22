---
tags: [prose, prose/docs]
---

# zaki-prod legal hygiene handoff (chatzaki.com)

**Paste the block below into a fresh Claude Code session at the zaki-prod repo root.**

This handoff covers three legal-page deltas identified during the nullalis V1 ship-readiness review on 2026-04-28. The current chatzaki.com privacy and ToS pages exist and are GDPR-aware, but three concrete gaps need closing before the next non-Nova paying user signs up. None of these are V1 blockers; queue as P1 hygiene.

---

You are landing legal-hygiene deltas on chatzaki.com. The frontend repo is `zaki-prod`. nullalis (the runtime backend) has shipped V1; chatzaki.com has Privacy and ToS pages routed at `/privacy` and `/terms`, but they have three documented gaps.

## Working repo

`zaki-prod`. Likely paths (verify in your repo):
- `frontend/src/pages/Privacy.{tsx,jsx}` or `frontend/src/routes/privacy/...`
- `frontend/src/pages/Terms.{tsx,jsx}` or equivalent
- `frontend/src/components/Footer.{tsx,jsx}` for footer links
- `frontend/src/App.{tsx,jsx}` for router config (look for `path:"/privacy"`, `path:"/terms"`)

## Audit findings (2026-04-28)

Bundle scan of `https://chatzaki.com/assets/index-*.js` confirmed:

✅ Privacy Policy at `/privacy` — contains "GDPR", "subprocessor", "third-party", "tracking"
✅ Terms of Service at `/terms` — contains "you agree", "liability", "jurisdiction", "subscription"
✅ Subprocessor list mentions: Anthropic, OpenAI, Together
✅ Footer links: "Privacy Policy", "Terms of Service", "support@chatzaki.com"
✅ Pricing tiers visible: Free / Pro / Premium / `/month`

❌ **Stripe NOT mentioned** anywhere in bundle (gap 1)
❌ **Cloudflare NOT mentioned** as subprocessor (gap 2; site is verified behind Cloudflare via response headers)
❌ **No cookie consent banner** detected — no "accept cookies" / "We use cookies" text anywhere in bundle (gap 3)
❌ **No "Effective date" / "Last updated" header** on either page (gap 4)
❌ No `/dpa` route (acceptable — DPA stays request-only via mailto)

## Three deltas to land

### Delta 1 — Subprocessor list update

In the Privacy Policy page, find the existing subprocessor section (currently lists Anthropic, OpenAI, Together). **Append two entries:**

```markdown
### Subprocessors

We use the following third-party processors to deliver the service:

| Processor | Purpose | Data shared |
|---|---|---|
| Stripe, Inc. (US) | Payment processing for paid tiers | Email, billing details, transaction metadata. Stripe stores card data; chatzaki never sees PAN. |
| Cloudflare, Inc. (US) | DDoS protection, CDN, edge routing | Request IPs, headers, request paths. No content of conversations. |
| Anthropic, PBC (US) | Model inference (Claude family) | Conversation contents when this provider is selected. |
| OpenAI, OpenAI LLC (US) | Model inference (when fallback or user-selected) | Conversation contents when this provider is selected. |
| Together AI, Inc. (US) | Primary model inference (Kimi K2.5 / Moonshot family) | Conversation contents when this provider is selected. |

Updates to this list are published in this Policy. Material changes are emailed to active accounts at least 14 days before the change takes effect.
```

If the Privacy page uses a different format (paragraphs, list, JSON config), preserve the existing format and just add the Stripe + Cloudflare rows in the same shape.

### Delta 2 — Effective-date header

At the top of `/privacy` and `/terms` pages, add a single line below the title:

```jsx
<p className="text-sm text-muted-foreground mb-6">
  Effective: April 28, 2026 · Last updated: April 28, 2026
</p>
```

Pick a real date — the date you ship this delta. Going forward, any material change increments "Last updated." A document without a date is weak in a dispute and signals neglect to enterprise prospects.

### Delta 3 — Cookie consent banner

EU (and increasingly US) traffic without a cookie banner is a real GDPR exposure. Pick **one** option:

**Option A — Lightweight (recommended for V1):** install `cookieconsent` (vanilla JS) or `react-cookie-consent` (React component). Show on first visit, store dismissal in localStorage. Two categories: "necessary" (always on, can't refuse) + "analytics" (default off, opt-in only).

```bash
pnpm add react-cookie-consent
```

```tsx
import CookieConsent from "react-cookie-consent";

<CookieConsent
  location="bottom"
  buttonText="Accept"
  declineButtonText="Decline analytics"
  enableDeclineButton
  cookieName="chatzaki-cookie-consent"
  expires={365}
>
  We use cookies to keep you signed in and (with your consent) to understand
  how the product is used. <a href="/privacy#cookies">Learn more</a>.
</CookieConsent>
```

**Option B — Heavyweight (if enterprise prospects ask):** use a CMP (Consent Management Platform) like Cookiebot, OneTrust, or Iubenda. Costs $10-50/mo, gives proper IAB TCF compliance. Overkill until you have a B2B prospect requesting it.

Wire `cookieName` to gate any analytics scripts (PostHog, Plausible, etc. — if any are loaded; verify by grepping for `posthog`, `plausible`, `gtag` in the bundle). If only "necessary" cookies are used today, the banner can be informational-only — but the banner must still appear on first visit.

### Delta 4 — DPA mention (no new route, just text)

In the Privacy Policy, near the subprocessor list, add:

> **For business customers:** A Data Processing Agreement (DPA) is available on request. Email [legal@chatzaki.com](mailto:legal@chatzaki.com?subject=DPA%20Request) and we will provide our standard DPA template within 5 business days.

Make sure `legal@chatzaki.com` actually routes to a checked inbox (or an alias to support@). If not, use `support@chatzaki.com` instead.

## Sequencing

1. Delta 2 (effective-date) — 5 minutes, ship first
2. Delta 1 (subprocessor list) — 30 minutes, requires copy review
3. Delta 4 (DPA mention) — 5 minutes, ships with Delta 1
4. Delta 3 (cookie banner) — 1-2 hours including testing dismissal/persistence

All four can ship in one PR titled "legal: Stripe/Cloudflare subprocessors, effective date, cookie consent, DPA reference." Estimated total effort: **half a day** including review.

## What's NOT in scope

- DPA template document itself (keep request-only via email)
- Full ToS rewrite (existing content is sufficient; deltas above are additive)
- Imprint / legal entity disclosure (separate task — only required if EU business presence)
- CCPA "Do Not Sell" link (only required if you sell user data; you don't)

## Verification after ship

- [ ] Visit `https://chatzaki.com/privacy` in incognito → effective-date visible at top
- [ ] Stripe + Cloudflare appear in subprocessor list
- [ ] First visit shows cookie banner; reload after Accept does not re-show
- [ ] DPA mention links to `mailto:legal@chatzaki.com` (or `support@`)
- [ ] `View Source` on the page shows the new content (not just the SPA shell)

## Why these specific four

Source: nullalis-side audit on 2026-04-28 grepping the chatzaki.com JS bundle for legal-content markers. The bundle contained "GDPR," "subprocessor," "Anthropic," "OpenAI," "Together," but did NOT contain "Stripe," "Cloudflare," "cookie banner," "Effective," or "Last updated." Fixing the four gaps turns the legal pages from "obviously partial" into "audit-defensible by a B2B prospect's procurement team."

— handoff drafted from chatzaki.com bundle audit + nullalis V1 ship-readiness review, 2026-04-28
