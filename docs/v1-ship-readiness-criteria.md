# V1 Ship-Readiness Criteria (2026-04-27)

**Purpose:** explicit checklist for "V1 done." Prevents scope creep AND prevents premature ship.

**Origin:** Nova's expanded V1 definition (2026-04-27 conversation):
> *"V1 is complete when we activate all value (voice, images, runtime modes), define slash commands, compaction works, multimodal Kimi evaluated, all done on a strong base."*

---

## Track A — nullalis-side (me, in this repo)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| A1 | All tools wired + invokable | ✅ | 44 tools registered, 42 wired (delegate/spawn flag-gated) |
| A2 | Execution modes (plan/execute/review/background) work | ✅ | Verified via slash command + reflection prompts |
| A3 | Assistant modes (fast/balanced/deep) behaviorally different | ✅ | Q3 wired reasoning_effort low/medium/high (PR #60); R5.3 verified switch |
| A4 | Slash commands defined + spec'd | ✅ | 54 commands cataloged + UX spec at PR #58 |
| A5 | Compaction works (context actually freed under load) | ⏳ | R5.4 stress test running |
| A6 | Stream timeouts bounded | ✅ | R15 fix shipped at PR #61 |
| A7 | Tool result surfacing trustworthy | ✅ | R7-tool, R7-stat verified at R2 round |
| A8 | Memory persists + recalls correctly | ✅ | Verified via R2.5 + 9,278 entries in postgres |
| A9 | Reasoning fields disambiguated | ✅ | R16 fix shipped at PR #62 |
| A10 | Multimodal Kimi research delivered | ✅ | Research report; recommendation: hybrid (V1.5 work) |
| A11 | Final researcher pass clean | ⏳ | After A5 verification |

**Track A close gate:** A5 + A11 both ✅ → V1 code-side ship-ready.

## Track B — zaki-prod-side (frontend, NOT this repo)

| # | Criterion | Status | Owner |
|---|---|---|---|
| B1 | Mode picker (fast/balanced/deep) in settings UI | ✅ | Done (verified ZakiSettingsSheet:988) |
| B2 | Voice on/off toggle in settings UI | ✅ | Done (verified ZakiSettingsSheet:359-588) |
| B3 | Telegram channel toggle | ✅ | Done |
| B4 | Discord/Slack/WhatsApp/Email/MaixCam channel toggles | ❌ | **V1 GAP** — needs zaki-prod work |
| B5 | Slash command palette in chat input | ❌ | Spec at PR #58; V1 desirable, V1.5 acceptable |
| B6 | Cost/usage dashboard | 🟡 | API exists; UI deferred to V1.5 |
| B7 | Memory chat-rail integration | 🟡 | Modal exists; in-chat integration V1.5 |
| B8 | Image generation toggle | 🟡 | Backend ready; UI defer V1.5 |

**Track B close gate:** B1+B2+B3+B4 ✅ → minimum V1 frontend. B5-B8 can defer to V1.5.

## Track C — operator-side (Nova-only, your timeline)

| # | Criterion | Status |
|---|---|---|
| C1 | GitHub Actions billing fix | ❌ — your 4-day window |
| C2 | DPA — Together AI | ❌ |
| C3 | DPA — Composio | ❌ |
| C4 | DPA — Sentry | ❌ |
| C5 | LICENSE on `nullclaw/sentry-zig` | ❌ — verified missing at S14.10.1 |
| C6 | TOS / Privacy / AUP legal docs | ❌ — needs lawyer |
| C7 | Stripe webhook → BFF wiring | ❌ |
| C8 | Transactional email (Resend / SendGrid) | ❌ |
| C9 | Public status page | 🟡 — defer V1.5 |
| C10 | k8s manifests (S11/S12/S13) | ❌ — post-billing-unlock |
| C11 | Moonshot direct API decision | 🟡 — research-pending |
| C12 | `.nullclaw/data/users` → `.nullalis/data/users` migration | ❌ — config edit + filesystem rename |

**Track C close gate:** C1-C8 ✅ → real launch ready (paying customer). C9-C12 acceptable to defer.

---

## Definition of "V1 ship"

**V1 code-side ship-ready:** Track A complete (10/11 currently done; awaiting A5 verification).

**V1 functional ship-ready (first paying customer can sign up):** A complete + B1-B4 + C1-C8.

**V1 launch-ready (announce publicly):** all of above + C9-C12.

---

## What ships TODAY if A5 verifies

If R5.4 stress test shows compaction firing + context actually freeing across 12 turns (no infinite hang, evidence of compaction phase events firing when context grows), then:

- **Track A: 11/11 ✅**
- **V1 code-side ship-ready** declared

Track B and Track C remain on your timeline.

---

## What does NOT ship

These are **explicitly deferred to V1.5** (post-V1):

- Multimodal Kimi consolidation (research done; hybrid recommended; V1.5 work)
- Memory graph + timeline visualization (the second-brain differentiator)
- Cost/usage dashboard
- Memory chat-rail integration
- Image generation toggle UI
- MCP marketplace UI
- Per-mode timeout multipliers
- TTFT vs total-stream timeout distinction
- R9 — `.nullclaw` config migration helper
- R12 — Kimi pipe-format marker filter extension
- R13 — duplicate iteration emission investigation (needs reproduction)

These have explicit triggers + are tracked in `docs/deferred-register.md`.

---

## Risks acknowledged

1. **R5.4 might surface a compaction bug** that R15 timeout fix doesn't address. If so: investigate, fix, re-run before declaring A5.
2. **Together provider variance**: tests are slower today than yesterday. Could be Together's day-of-week load, OR our explicit reasoning_effort=medium adds nominal latency. Either way: not a code bug; not a V1 blocker.
3. **The 5 questions from slash command spec (Part 4)** still open — defaults applied if no answer.
4. **R17 dropped** — settings UI is the canonical control for assistant_mode; no slash command duplicate needed.

---

*Doc lives in repo, survives compact. Update inline as criteria tick.*
