# nullALIS — STATUS

**Hydrated:** 2026-05-10 from code truth (git log, source tree, bench artifacts). Not memory.

This is the single cold-start document. If it disagrees with `.planning/STATE.md`, `PROJECT_LEDGER.md` (archived), or anything in `docs/archive/`, **this wins**.

---

## What nullALIS is right now

Single-binary Zig agent runtime (`src/main.zig`). Per-user cell-pod architecture, 15 LLM providers, 48 tools, 20 channel integrations, 9-stage memory retrieval over 4 storage backends + vector plane. Postgres canonical, SQLite + markdown mirror, filesystem workspace first-class.

| Surface | Count | Where |
|---|---|---|
| `.zig` files | 293 | `src/**` |
| Source LoC | ~256K | `src/**` |
| LLM providers | 15 | `src/providers/` (anthropic, openai, openrouter, gemini, ollama, claude_cli, codex_cli, openai_codex, compatible, NNGTs_cache, NNGTs_prefix_order, factory, helpers, error_classify, api_key) |
| Tools | 48 | `src/tools/` |
| Channels | 20 | `src/channels/` (cli, discord, email, imessage, irc, lark, line, maixcam, matrix, mattermost, nostr, onebot, qq, signal, slack, teams, telegram, whatsapp, +dispatch, root) |
| Memory layers | L0-L7 | `src/memory/` (engines, lifecycle, retrieval, vector, importance) |

**Zig:** 0.15.2 (locked). **Build:** `zig build -Doptimize=ReleaseFast -Dengines=all`. **Test:** `zig build test --summary all`.

---

## Where we are in the version timeline

The **last git tag is `v1.9.0`** but commit history runs through **V1.14.8** — version tags lag the in-flight semver-in-commit-messages convention. The `iter*` rows in `.spike/results.tsv` track sub-version Karpathy iteration.

### Most recent shipped versions

| Version | Theme | Status |
|---|---|---|
| **V1.14.8** (today, on `origin/main`) | Unified boundary extraction — `src/agent/extraction/` (schema + prompts + parser + runner). All 4 boundaries (Pass A, Pass C, session-end, force-compress) flow through one `extractAtBoundary`. slot_intent → working_memory.promote sync. Pass A extract-only (hydration skipped). | **Shipped, not yet bench-validated** |
| V1.14.7 | Per-turn extraction deletion. F-A1 calibrated-honesty regression fix. Layer 4 graph-empty bug fixed (parseSummaryResponse triple-drop). | Shipped + verified |
| V1.14.6 | F-CB1 cache breakpoints (system_and_3), F-PA2 drop-from-middle Pass A, S-tier prompt rewrite. | Shipped, headline bench result |
| V1.14.4 | Pre-WebSummit polish, code-review fixes. | Shipped |

### Most recent measured bench (publishable)

**LoCoMo full battery, 2026-05-09, pre-V1.14.7/V1.14.8:** 541/600 = **90.17% recall**. +16pp over mem0. Cat 2 multi-hop = 93.6% (strongest). Cat 3 temporal/inference = 75.3% (soft spot). Per-sample range 80-96.7%.

This is the **last known-good measured number**. V1.14.7 + V1.14.8 changes since then are unbench-validated.

---

## Branches alive on local

- `main` — canonical, ahead of all version tags
- `autoresearch/apr19` — Karpathy spike branch, harness lives here
- `DB`, `correction`, `codex/branding-nullclaw-cleanup`, `codex/first-public-posture-doc-freeze`, `codex/session-crash-fix` — feature/cleanup branches
- `d8/secret-vault-api`, `debt/d16-silent-catch-classification`, `debt/d19-hardware-surface-removal`, `debt/d20-dead-chat-stream-paths` — debt-tagged branches; status unknown without inspection

**Working copy clean** as of this writing (0 ahead, 0 behind `origin/main`). Only untracked items are `.spike/external/baselines/` JSONs.

---

## Open queue (ranked by signal × cost)

| # | Item | Source | Cost | Notes |
|---|---|---|---|---|
| 1 | **Bench-validate V1.14.8** — Pass C + session-end + Pass A all routing through unified runner. Expect Layer 4 graph to populate where it was empty pre-V1.14.7. | This sprint | ~1h | LoCoMo conv-26 or one 60-Q batch is enough signal. |
| 2 | **Subagent "received" bug** — agent runs subagent, completes, reply is literal "received" instead of work result. Memory says fixed via `EMPTY_TURN_PLACEHOLDER` / `TurnOutcome` struct (S1.10). Needs code-truth re-verification. | Memory `project_subagent_received_bug` | 1-2h | Touches `src/agent/root.zig` `TurnOutcome`, gateway SSE render. |
| 3 | **Approval-drop bug** — user clicks approve, tool drops instead of executing. | Memory `project_approval_drop_bug` | unknown | Scheduled after gateway HTTP endpoints land. |
| 4 | **Modes post-context-v2 pass** — fast/balanced/deep presets sized for old 12K budget; message-count caps fire before token-aware compaction trigger. | Memory `project_modes_need_post_context_v2_pass` | <1h | Mechanical resize. |
| 5 | **Refresh `.planning/STATE.md`** — month stale (claims "Phase 3 pending"). Either rewrite or archive + point to this STATUS.md. | This sprint | 30min | Note: gsd-* skills consume STATE.md schema — don't break their machinery. |
| 6 | **Autonomy UI toggle** — default flipped to `.full`; need frontend toggle so users pick supervised/full without editing `config.json`. | Memory `project_ui_toggle_autonomy` | zaki-prod work | Cross-repo. |

---

## Open architecture concerns (carried)

- **Lifecycle gaps** — hygiene startup-only, `conversation_retention_days=0` default, no background scheduler. Not urgent; documented at `project_lifecycle_investigation_2026_04_20`.
- **Agent turn audit** — `memory_enrich` 900ms variance; `elideUnverifiedHistory` O(N) scan. Tolerated; post-profiling.
- **Repair queue R1-R7 / C1-C4** — tiered from prior P1 x-ray; lives in memory `project_repair_queue_2026_04_21`. Note: the `internals/P1_*.md` files referenced from memory **do not exist on disk** — either deleted or never written. Treat memory ref as historical pointer, not active doc.
- **`internals/` directory missing** despite memory pointer. Action: either rebuild the x-ray or update memory to drop the reference.

---

## What this doc replaced (archived 2026-05-10)

Moved to `docs/archive/2026-05-10/`:
- Root-level historical: `CLOSURE_CHECKLIST.md`, `CODE_REVIEW_REPORT.md`, `CORRECTION_PLAN.md`, `HTTP_TRANSPORT_MIGRATION.md`, `PROJECT_LEDGER.md`, `REVIEW.md`-`REVIEW4.md`, `TOOL_MATRIX.md`
- Per-version reviews: `REVIEW-v1.11..v1.14.3-*.md` (6 files)
- Post-compact handoffs: `post-compact-handoff-2026-04-28` through `2026-05-04-v3` (6 files)
- One-shot fix doc: `F-G1-tls-sigill-on-apple-silicon.md`

**Kept at root:** `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE-COMMERCIAL.md`, **this** `STATUS.md`.

**Kept in `docs/`:** operational specs (`SLO.md`, `agent-lifecycle-spec.md`, `config-authority-map.md`, `deferred-register.md`, `execution-cell-contract.md`, `memory-architecture-map.md`, `migrations-policy.md`, `multi-instance.md`, `online-agent-contract.md`, `openapi-v1.yaml`, `reliability-ops-runbook.md`, `sandbox-activation-plan.md`), research (`graph-memory-research.md`, `frontend-vision-brief.md`, `multimodal-admission.md`, `research-*`), most-recent bundle (`REVIEW-v1.14.4-2026-05-09.md`, `post-publishable-fixes-2026-05-09.md`).

---

## Maintenance rule

When you ship a meaningful version (≥ minor bump) or land a measurement-changing bench result, **update this doc, not a new dated one**. Date-stamped review docs are for ship-gate evidence and belong under `docs/archive/<date>/` after the next refresh.

Last hydration: 2026-05-10. Next hydration trigger: post-V1.14.8 bench validation or first material change post-WebSummit signal absorption.
