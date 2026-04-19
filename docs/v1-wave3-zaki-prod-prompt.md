# V1 Wave 3 — zaki-prod Execution Prompt

This is the copy-paste prompt for your zaki-prod agent session. It covers Wave 3 of the Nullalis V1 Convergence Plan — the frontend/BFF work for the web app.

**How to use:** paste the entire block below into your zaki-prod agent session. That agent has the full context of the zaki-prod codebase and will inspect what exists before building.

---

## Prompt for zaki-prod agent session

```
You are the zaki-prod Wave 3 execution agent for the Nullalis V1 Convergence Plan.

GOVERNING CONTEXT
- Nullalis (the Zig agent runtime) just completed Wave 1 (truth restoration) and Wave 2 (core loop completion) of the V1 plan.
- Wave 3 is UX and trust polish for the web app that this repo (zaki-prod) owns.
- The product is a deployable personal second brain for a high-agency user (founder, operator, researcher, serious knowledge worker). Single-user-first. Not team-first. Not consumer-assistant-first.
- Primary surfaces: web app (this repo) + Telegram (nullalis). CLI is admin/ops only, not product.

BINDING V1 RULES (do not violate)
1. No new product surfaces. No new channels beyond Telegram + web.
2. Bias the web app toward transparency and power-user control. Provenance chips, approval queue, context detail, memory inspection are CORE TRUST FEATURES, shipped visible by default — not hidden advanced toggles.
3. Multimodality is a capability, not an axis. Admitted V1 paths (see acceptance below) render in the UI; non-admitted paths stay absent.
4. UI is product truth. If a trust-critical behavior isn't visible in the UI, it isn't done.
5. Silent fallback is forbidden. Compaction notices, provider fallback, connector stale, multimodal failure — all visible.
6. One source of truth per concept. Do not create a second session/memory/approval model; reuse what exists.
7. No speculative abstractions. Direct, simple code. Three similar lines beats a premature abstraction.

WAVE 3 SCOPE — 8 packages
W3.1 — Thread pane: message list, source chips visible by default, tool-call disclosure, narration sidecar, approval queue INLINE. Voice/image inline only if admitted by W2.7 (see MULTIMODAL ADMISSION below).
W3.2 — Memory pane: facts, summaries, anchors, filters by source/time/session. Edit/forget. Provenance chips visible by default. Image-sourced entries render with their source image reference. Show artifact role (continuity/audit/index).
W3.3 — Connect pane: Telegram per-user bot token wizard; mail/calendar/drive via Composio.
W3.4 — Settings pane: mode (fast/balanced/deep), proactivity, voice (if admitted), session timeout. Deterministic preset mapping.
W3.5 — Empty/failure states: compaction notices, connector stale, provider fallback, multimodal failure. No silent fallback anywhere.
W3.6 — Soft-limit + usage pane: show request/token/session counters, soft-limit state (normal/warning/near_limit).
W3.7 — Power-user control pane: /context detail view, /memory doctor view, approval queue as first-class tab. SHIPPED VISIBLE BY DEFAULT, not hidden.
W3.8 — Onboarding golden path: sign-in → provision → connect Telegram → first message → first memory → first recalled memory with visible source chip — under 5 minutes for a new user.

MULTIMODAL ADMISSION (from Wave 2 W2.7)
Admitted (render these in UI):
- Telegram STT (inbound voice → transcript)
- Telegram TTS (outbound) — gated by voice_replies preset
- Image input + image understanding
- Image-based context ingestion
- image_info tool (read-only metadata)
Frozen (do NOT build UI for these in V1):
- Web-app STT/TTS (requires new subsystem)
- Image generation (any form)
- Screenshot tool

NULLALIS-SIDE READY
- Memory tools (memory_list, memory_recall) now emit role={continuity|audit|index|user} and at={timestamp} on every entry. Your memory pane can display the role.
- Agent exposes pendingApprovalSnapshot() as a read-model. HTTP binding is NOT yet wired (deferred to post-V1 gateway refactor). If your BFF needs pending approvals, proxy the existing /api/v1/sessions/.../approve POST and consider asking nullalis to expose a GET endpoint in a targeted follow-up.
- SessionIdentity, User, Workspace are canonical types inside nullalis. The session key format is stable: agent:zaki-bot:user:{id}:main and agent:zaki-bot:user:{id}:thread:{topic}.
- Telegram lane routing: DMs → main, groups/topics → thread. App + Telegram DMs share the same main-lane session key. This is the cross-surface continuity invariant.
- Compaction silent fallback already surfaces a flag on nullalis finalize: context_was_compacted + context_force_compressed. Ensure the web app renders the resulting prefix/notice (per W3.5 empty/failure states rule).

YOUR EXECUTION PROTOCOL
1. AUDIT FIRST. Do not build assuming clean slate. For each W3.x package, inspect what already exists in zaki-prod (check src/app/components/{memory,chat,sidebar,onboarding,agent}, src/types, backend/src/memory, backend/src/session). Report what's present and what's missing.
2. FIX GAPS ONLY. Anything already implemented — leave it alone unless it violates a binding rule (silent fallback, hidden trust feature, missing provenance).
3. NARROW PACKAGES. Each W3.x gets its own commit. Small atomic diffs. No drive-by refactors.
4. EXPLICIT DEFERRAL. If a gap requires a new subsystem (new provider family, new product pane beyond the 5 V1 panes, speculative abstraction), defer it and explain why.
5. TEST-FIRST WHERE PRACTICAL. Integration tests for provenance display, approval flow, empty states. Avoid flaky e2e; prefer component-level.
6. NO BACKEND-ONLY BREAKTHROUGHS. Every UI behavior must have a visible rendering. Backend work without a UI consumer is a flag that W3 scope was misinterpreted.

OUTPUT SHAPE PER PACKAGE
For each W3.x you touch, report:
- Code reality: what exists in zaki-prod today for this pane/flow.
- Gap: what's missing vs the W3.x acceptance.
- Fix: the narrowest implementation that closes the gap.
- Files changed / tests added.
- Verification evidence (screenshots/logs/test output).
- Open follow-ups that deserve a separate package.

DO NOT
- Add new channels to the UI (Slack, Discord, etc. are frozen).
- Add a creative image studio or proactive image generation UI.
- Hide provenance chips, approval queue, context detail, or memory inspection behind "advanced" toggles.
- Build team/workspace multi-user features.
- Rebuild the memory or session data models (reuse what's canonical).
- Ship UI that silently falls back (compaction, provider failure, connector stale must be visible).

ACCEPTANCE GATES (all must pass before marking Wave 3 done)
- New user reaches "first recalled memory with visible source chip" in < 5 minutes (W3.8).
- Every retrieved memory in the memory pane shows a source chip (channel / lane / time / role) — W3.2.
- Approval queue is a first-class tab visible by default — W3.7.
- No silent fallback path — W3.5.
- 6-pillar UI audit (visual, accessibility, copy, layout, performance, trust) passes for the 5 V1 panes.

START BY: reading src/app/App.tsx, listing src/app/components/ directories, and running the existing test suite. Then audit each W3.x package against code reality. Then execute gaps narrowly. Commit atomically per package. Report progress package-by-package before moving on.
```

---

## For Nova (meta)

**What this prompt does:**
- Gives the zaki-prod agent the full V1 binding context without handholding.
- Lists all 8 W3 packages with acceptance criteria.
- Explicitly names what's NOT V1 (frozen multimodal paths, no new surfaces, no speculative features).
- Mandates audit-first to avoid conflicts with your existing frontend.
- Sets the execution protocol: atomic packages, gap-only fixes, no silent fallback.

**What to watch for in the zaki-prod agent's output:**
- Audit findings should be detailed (names of existing components + what they do). If the agent jumps to "building" without auditing, pause it.
- If the agent proposes a new subsystem (new auth flow, new storage layer, new design token family), that's scope drift — push back.
- If W3.7 (power-user controls) gets quietly buried behind a toggle, that's a rule-12 violation.

**Likely nullalis-side follow-ups that surface from Wave 3:**
- HTTP route for `pendingApprovalSnapshot` (GET endpoint). Your agent will ask for this when building the approval queue tab. Tell me and I'll add it as a targeted post-V1 gateway package.
- Any missing HTTP endpoint the frontend needs for `/context detail` / `/memory doctor` display — also a gateway follow-up.
- Any discrepancy between what nullalis exposes and what the frontend needs for provenance chips.

**This prompt is also committed to [docs/v1-wave3-zaki-prod-prompt.md](docs/v1-wave3-zaki-prod-prompt.md)** so you can re-run it later or share it with future agents.
