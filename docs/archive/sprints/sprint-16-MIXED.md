---
tags: [prose, prose/docs]
---

# Sprint 16 — V1 Gaps Not In Prior Sprints — MIXED status (2026-04-26)

**Branch:** `sprint/closure-pending-docs` (off `main` tip `a7a2ec8`)
**Opened:** 2026-04-26
**Status:** MIXED — S16.6 (dep SHA pinning) is structurally already shipped via S14.10 audit; the remaining items are operator/cross-repo work or external-service signups. No in-repo nullalis-side code change closes any of these (S16.6 is satisfied; the others live elsewhere).

## Goal

Close items surfaced on final V1 pressure-test that don't fit any earlier sprint theme. Mostly: things that need an external account, a lawyer, a cross-repo audit, or a load-test harness.

## Per-item status

| ID | Item | Where it lives | Status | Trigger / acceptance |
|---|---|---|---|---|
| **S16.1** | Load-test harness (k6/vegeta) for chat-stream, webhook inbound, scheduler tick | `.spike/load/` (new subdir) OR separate `nullalis-load` repo | **Operator-pending** | Trigger: first paying customer projection OR pre-launch readiness. Acceptance: documented pass at 100/500/1000 concurrent users; results in `.spike/load/README.md` |
| **S16.2** | SLO definitions (`docs/SLO.md`) | `nullalis/docs/SLO.md` | **Operator-pending** | Trigger: customer SLA conversation OR pre-launch. Acceptance: uptime target + p50/p95/p99 latency targets + error budget math; tied to AlertManager thresholds (S13.4) |
| **S16.3** | Public status page (statuspage.io / Cachet) | External SaaS OR `zaki-infra/charts/cachet/` | **Operator-pending** | Trigger: first paying customer OR pre-launch. Acceptance: status page deployed; embedded on chatzaki.com; AlertManager updates status |
| **S16.4** | Transactional email (Resend / SendGrid) | zaki-prod BFF (Stripe webhook → email; signup → welcome; password reset) | **Operator-pending — cross-repo** | Trigger: first Stripe billing event OR signup-flow completion. Acceptance: receipt email arrives on test subscription; welcome email on signup; password reset round-trip |
| **S16.5** | Legal docs (TOS / Privacy Policy / AUP) | `chatzaki.com/legal/*` (zaki-prod side) | **Operator-pending — needs lawyer** | Trigger: any paying user OR EU user OR external launch. Acceptance: TOS / Privacy / AUP live; consent checkbox on signup; re-consent on material changes. Sprint 14.2 (EU AI Act) closely related |
| **S16.6** | Dependency SHA pinning (`build.zig.zon`) | `nullalis/build.zig.zon` | **STRUCTURALLY SHIPPED via S14.10** | sqlite3 + sentry_zig already hash-pinned via Zig's native `.hash` field per `docs/audits/s14.10-license-audit.md`. Update cadence: review on every Zig minor bump (S14.6 trigger condition) |
| **S16.7** | Frontend audit (zaki-web React) | zaki-prod repo, `internals/P5_zaki_web.md` (mapper output) | **Operator-pending — cross-repo** | Trigger: pre-launch OR a11y compliance requirement. Acceptance: error boundaries verified, WCAG AA validated, SSR/hydration audit, offline/reconnect UX, keyboard nav |
| **S16.8** | Typ custom-patches inventory (`zaki-infra/charts/typ/PATCHES.md`) | zaki-infra | **Operator-pending — cross-repo** | Trigger: typ image needs SHA-pinning per S3.7 OR upstream AnythingLLM bump. Acceptance: pull running `:latest` image, diff vs upstream AnythingLLM, document every patch, rebuild on pinned SHA. Then flip S3.7 |

## What's structurally shipped (S16.6)

`build.zig.zon` deps:
- `sqlite3` → `git+https://github.com/allyourcodebase/sqlite3#8f840560eae88ab66668c6827c64ffbd0d74ef37` + `.hash`
- `sentry_zig` → `https://github.com/nullclaw/sentry-zig/archive/refs/tags/v0.1.0.tar.gz` + `.hash`

Both deps are hash-pinned via Zig's native `.hash` field — supply chain hash mismatch fails the build. Inventoried in `docs/audits/s14.10-license-audit.md`.

**Update cadence (S16.6 ongoing):**
- Review deps on every Zig minor version bump (per S14.6 trigger conditions)
- Sentry-zig pin tied to `S14.10.1` follow-up (verify nullclaw/sentry-zig LICENSE file presence)
- New deps added to `build.zig.zon` MUST include `.hash` field — enforce in PR review

## Cross-cut considerations

- **S16.4/S16.5/S16.7 are zaki-prod-side.** This repo can't ship them; doc states the trigger + lives where, then closes accounting via this file.
- **S16.8 (typ patches) blocks S3.7** (the deferred Sprint 3 item on flipping typ off `:latest`). Same operator surface.
- **S16.1 load-test harness** could ship in-repo as `.spike/load/` shell scripts even before paying customers — useful for catching regressions. Low-priority but available.
- **S16.2 SLO.md** is in-repo doc work. ~1 hr to draft initial version with placeholder targets that operator validates against real customer expectations. Available for solo execution if Nova prioritizes.

## What in-repo work could close some items now

If Nova greenlights, the following S16 items are nullalis-doable today without operator dependencies:

- **S16.1 partial:** stub load-test harness in `.spike/load/` with placeholder k6 scripts + README — gives shape to the surface, real numbers come later
- **S16.2 partial:** draft `docs/SLO.md` with reasonable defaults (99.5% uptime, p95 < 2s) that Nova validates/adjusts
- **S16.6 ongoing:** sentinel test in `build.zig` that fails build if any dep lacks `.hash` field — locks the policy structurally

These are not blocking; flagged for Nova to pick up if/when desired.

## Sprint 16 DoD (at full close)

- Load-test numbers in `.spike/load/README.md`
- `docs/SLO.md` published
- Status page green
- Billing receipt arrives on test subscription
- TOS/Privacy consented on signup
- 2 zon deps SHA-pinned (✅ already)
- zaki-web audit doc at `internals/P5_zaki_web.md`
- Typ `PATCHES.md` committed

## Tracking

This doc IS the Sprint 16 close-out. S16.6 is structurally complete. S16.1/S16.2 can be solo-executed if Nova prioritizes (each ~1 hr stub). The rest are operator/cross-repo/lawyer work tracked here as the single source of truth.

**Closure rule:** Sprint 16 is "closed" for V1 purposes when this doc exists with per-item status AND S16.6 is verified shipped (it is). Other items unblock per their triggers.

When triggers fire, mark `[x]` in `CLOSURE_CHECKLIST.md`, link cross-repo PR SHAs back to this doc.
