---
tags: [prose, prose/docs]
---

# Post-Compaction Handoff (2026-04-28)

**Purpose:** survive a compact. Self-contained context for the post-compact me.

## State at compaction

- **Main HEAD:** `a1990b3`
- **Binary built:** Apr 28 18:28
- **V1 code-side:** declared ship-ready (Track A 11/11 ✅)
- **PRs shipped today:** #57 through #69 (13 PRs, 2-day push)
- **Internals/ cite-bumped:** `2b8dee5` (NEEDS BUMP to `a1990b3` after compact)

## Today's PR ledger

| PR | Theme |
|---|---|
| #57 | Q1 — message-count cap deprecated (compaction sole governor) |
| #58 | Slash commands catalog + UX spec (frontend contract) |
| #59 | Q2 — Kimi reasoning_effort + context_snapshot honest |
| #60 | Q3 — modes-with-teeth (fast/balanced/deep → low/medium/high) |
| #61 | R15 — stream timeout defaults bound |
| #62 | R16 — reasoning fields disambiguation |
| #63 | V1 ship-readiness criteria doc |
| #64 | R18 — caps lifted (timeouts 1h, tool result 200K, max_iter 100/200/1000) |
| #65 | Single-mode gate (reverted by #66) |
| #66 | Revert single-mode — backend honors selected mode |
| #67 | Durable session delete (UI delete actually deletes) |
| #68 | SwissWatch architectural cleanups (5 fixes) |
| #69 | Attachment polish (filename validation + agent prompt) |

## Resume order (Nova's directive 2026-04-28)

### 1. Nova tests image uploads (Nova's column)
After gateway restart, verify:
- Upload image with parens (`image (1).png`), brackets, accents → saves to `attachments/`
- Ask agent "what file did I just upload?" → agent finds it via `file_read attachments/<name>`
- Verify `isSafeAttachmentFilename` no longer rejects common image filenames

If failures persist: investigate zaki-prod frontend (likely calls wrong endpoint OR wrong content-type).

### 2. Sandbox deep dive (me)

**Goal:** map exactly what's needed to activate `tool_sandbox_v1` so shared-runtime shell can be unlocked safely.

Files to audit:
- `src/tools/tool_sandbox_v1.zig` (full read — backend selector, exec config, validation)
- `src/tools/shell.zig:68-94` (refusal logic; how it gates on sandbox_enabled)
- `src/security/policy.zig` (workspace_only enforcement)
- `src/config_types.zig` (SandboxBackend enum, sandbox.* config fields)

Output: `docs/sandbox-activation-plan.md` covering:
1. What's wired today (backend hooks, config plumbing)
2. What backend options are real (docker / Firecracker / gVisor / CubeSandbox / SmolVM)
3. Per-tool latency budget per backend
4. k8s impact (do we need privileged containers? sysadmin? KVM?)
5. Config-flag activation steps
6. Test plan
7. Recommended backend for V1.5

### 3. UI activation list (me)

**Goal:** comprehensive frontend gap list — every backend capability not yet wired in zaki-prod.

Inventory dimensions:
- **Channel toggles:** Discord / Slack / WhatsApp / Email / MaixCam (Telegram already wired)
- **Slash command palette:** spec at `docs/slash-commands-spec.md` — needs implementation
- **Approval UI:** codex/claude-code-app pattern (inline card, risk badge, three actions)
- **Autonomy radio:** read_only / supervised / full (currently no UI surface)
- **Cost/usage dashboard:** `/cost` + `/usage` slash backend ready; no view component
- **Memory chat-rail:** MemoryViewer modal exists; not in chat flow
- **Image generation toggle:** image_generate tool ready; no UI
- **Settings sheet additions:** what already exists vs what's missing

Output: `docs/v1-frontend-activation-list.md` with priority-ordered table:
- Capability → Backend status → Frontend gap → V1-must / V1.5-defer → Estimated effort

### 4. Internals/ cite-bump to a1990b3 (cleanup)

After items 2+3 land, bump the 5 affected P-files (P1_arch, P2_context_v2, P2_agent_turn_loop, P2_providers, P2_tools) + root `project_nullalis_internals.md` to current HEAD with PR #67-#69 drift notes.

### 5. Then V1.5 design kickoff (the differentiator)

Memory graph + timeline + compose-memory tool. See `docs/post-compact-handoff-2026-04-28.md` (this file) Phase B from earlier conversation context.

## Critical context the post-compact me must NOT forget

1. **chatzaki.com is LIVE** with older nullalis. Stripe webhook + transactional email already wired on zaki-prod side. NOT V1 blockers.
2. **Per-user cell pod is DEFERRED** per Nova directive. Sandboxing via `tool_sandbox_v1` is the alternative path being investigated.
3. **Mode selection is HONORED at backend** (revert PR #66 reaffirmed this). Frontend can lock the dropdown if desired; backend stays truthful.
4. **R-effort-override** (user override of mode-driven reasoning_effort) is documented in `docs/deferred-register.md` for V1.X — Nova said "remind me later."
5. **DPAs** are NOT V1 blockers per Nova's reframe — queue when first non-Nova paying user signs up.
6. **Sentry-zig LICENSE** is missing on `nullclaw/sentry-zig` repo — operator action (Nova adds MIT via GitHub web UI, ~5 min).
7. **GitHub Actions billing** unlocks tomorrow per Nova.

## Files to read first after compact (for re-orientation)

1. This doc — full
2. `docs/v1-ship-readiness-criteria.md` — Track A/B/C definitions
3. `docs/v1-triage.md` — V1-must / V1-nice / V1.5-defer per item
4. `docs/deferred-register.md` — open follow-up items
5. `docs/slash-commands-spec.md` — frontend contract for slash palette
6. `CLOSURE_CHECKLIST.md` — sprint accounting

## Discipline reminders for post-compact me

1. Per-commit P-file updates — the rhythm broke once already, don't break again
2. Atomic PRs per item, sprint-granular per Nova's pattern
3. `zig build test` green before every commit
4. CI is informational only (Actions billing pending — locks in tomorrow)
5. Don't change behavior the user is actively testing without flagging
6. **Backend stays truthful — frontend handles UX simplification**. If forcing-and-lying ever feels tempting again, revert pattern from PR #66.
7. **Nova caught my false R3/R4 hallucination accusation** — never compare agent output to truncated SSE preview. Agent sees full tool output.
8. **Father, not godfather** — slow and honest > fast and theatrical.

---

*Written 2026-04-28 pre-compact. Update inline as items close.*
