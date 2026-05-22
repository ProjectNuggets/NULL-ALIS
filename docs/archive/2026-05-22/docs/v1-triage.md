---
tags: [prose, prose/docs]
---

# V1 Deferral Triage (2026-04-26, HEAD `9e8fb40`)

**Purpose:** Before the LLM researcher pass, classify every open deferral + parked-sprint item into V1-must / V1-nice / V1.5-defer. Prevents wasted parenting on items that don't move V1 readiness.

**Method:** walked all 28 open items in `docs/deferred-register.md` + 4 parked sprints + S14.5 MED findings + 3 D1 activation follow-ups from `docs/sprints/v1-closure-and-second-brain-plan.md`. Per-item classification with reasoning + estimate.

**Definitions:**
- **V1-must** — close before researcher pass. Either user-visible bug, license/security hygiene gap, or completes-a-promise that's currently theatrically half-done.
- **V1-nice** — close if ≤2 hr each. Reduces drift, adds observability, latent UX win. Acceptable to skip if researcher pass surfaces higher-priority work.
- **V1.5-defer** — explicit park stays. Either operator-only, scope-expansion, or trigger-conditional.

---

## Triage table

### V1-must (close before researcher pass — ~5-9 hr total)

**Updated 2026-04-26 post-Nova review:** D14 + S16.2 + D5 lifted; D31 marked obsolete-for-V1 (Qdrant unused — production = pgvector via default `store.kind = "auto"`). V1 = "first paying multi-user" (Nova confirmation), so calendar-monthly cost persistence becomes load-bearing.

| ID | Item | Why V1-must | Effort |
|---|---|---|---|
| **D1.14c** | Flag `web_search` (30s, global) + `memory_recall` (300s, session) + `composio list` (60s, tenant) as cacheable | Infra shipped (D1.14); activation = real user-felt latency win on common tools. Near-zero risk: metadata flag only. | 30 min |
| **S14.10.1** | Verify `nullclaw/sentry-zig` upstream LICENSE file presence + content | License hygiene from S14.10 audit. 5-min check; if missing, escalate. | 5 min |
| **D14** | Investigate 2 pre-existing scheduler test failures (carried since baseline) | Lifted from V1-nice per Nova call. Open failing tests erode trust; either fix or document explicitly why broken. | 1-2 hr |
| **S16.2** | Draft `docs/SLO.md` with reasonable defaults (99.5% uptime, p95 < 2s) | Lifted from V1-nice per Nova call. Cheap operator-doc; sets the bar before first paying customer. Nova validates targets. | 1 hr |
| **D5** | `CostTracker` calendar-monthly persistence: per-user JSONL at `{users_root}/{user_id}/cost.jsonl` + monthly rollup | **Lifted to V1-must per Nova call (V1 = first paying multi-user).** S2.8 session-scoped weight cap insufficient for monthly billing-grade accounting. Min-viable: append-on-call JSONL + on-demand rollup. Postgres counter for fast operator reads = follow-up. | 3-4 hr |

### V1-nice (close if cheap — ~5-7 hr total)

| ID | Item | Why V1-nice | Effort |
|---|---|---|---|
| **D9** | HTTP roundtrip test for `/internal/entitlements/revoke` | Endpoint is composition of well-tested primitives, but unit-coverage gap is auditable. | 30-60 min |
| **S14.5 MED-1** | `DaemonState.components` race (add mutex) | Cheap insurance. Becomes blocking if S12.1 multi-replica fires. | 30 min |
| **S14.5 MED-2** | `dispatch_stats` counter race (atomic.Value) | Counter drift fix; observability accuracy. | 30 min |
| **D1.14b** | Wire generalized cache into `executeToolCallsParallel` | Today serial-only. Cacheable tools tend serial in practice; activation closes the gap. | 1-2 hr |
| **D1.15b** | Auto-spawn `MemoryRuntime.warmupSession` from session-init in background thread | Per-session warmup state shipped (post-finding-3); auto-spawn = real boot-time UX. | 1-2 hr |
| **D27** | `lane_metrics.recordGdprPurge{ok,partial,fail}` counters | Observability parity with secret_mutations audit. | 30 min |
| **D13** | `lane_metrics.recordSecretMutation{ok,fail}` counters | Audit rows exist; metrics counters do not. | 30 min |
| ~~**D31**~~ | ~~Qdrant `deleteAllForUser` count-before-delete~~ | **OBSOLETE-FOR-V1** — production vector store = pgvector (`config.example.json` defaults `store.kind = "auto"` → resolves to pgvector via `config_types.zig:732`). Qdrant is wired as optional alternative backend but not on the active path. Revives only if anyone flips production to Qdrant. |

### V1.5-defer (explicit park stays)

#### Sprint 1
| ID | Item | Why deferred |
|---|---|---|
| **D2** | Run-scoped approvals (`/approve allow-run`) | Needs UX design for verb + cache lifetime. Not a V1 must — agent works without multi-tool batching. |
| **D4** | Live-staging verification of S1.4 + S1.8 | Post-deploy smoke; verified by researcher pass implicitly. |

#### Sprint 2 + D8
| ID | Item | Why deferred |
|---|---|---|
| **D5** | CostTracker JSONL persistence (calendar-monthly) | S2.8 session-scoped weight cap covers single-user V1. True monthly persistence needs tenant-runtime threading; for a paying-multi-user product, not single-user beta. |
| **D6** | Idempotency-Key strict mode flip | Soft mode is correct V1 posture; flip after zaki-prod confirms every mutating call attaches key. |
| **D7** | Idempotency-Key on attachments POST | Needs handler-signature refactor; current attachments path works. |
| **D10** | `resolver` → `std.atomic.Value` | Explicit "revisit if dynamic reload added." Not added. NEAR-ZERO real-world risk. |
| **D12** | zaki-prod frontend `SecretsVaultSheet.tsx` GET broken | **Operator-task — cross-repo zaki-prod**, can't fix from this repo. User-visible bug; track for Nova or zaki-prod session. |

#### Sprint 3
| ID | Item | Why deferred |
|---|---|---|
| **D15** | Create `production-image-promotion` GitHub environment | **Operator-only** UI click; can't represent in YAML. |

#### Sprint 4
| ID | Item | Why deferred |
|---|---|---|
| **D16** | Noise-catch classification sweep (302 sites remain) | Partially shipped + policy doc. Operator-pain-triggered; no specific pain reported. |

#### Sprint 5
| ID | Item | Why deferred |
|---|---|---|
| **D17** | Anthropic two-block cache | **Anthropic NOT primary** — Together is. Latent value only when Anthropic returns. |
| **D18** | Error classification carrier (delete string-matchers) | String-matchers work today. Hygiene refactor; needs threadlocal/Provider-state work. |

#### Sprint 6
| ID | Item | Why deferred |
|---|---|---|
| **D21** | `pending_exec_*` consolidation into `pending_tool_approval` | 8-12 hr including test rewrite; needs own dedicated mini-sprint. Two systems coexist working. |

#### Sprint 7
| ID | Item | Why deferred |
|---|---|---|
| **D25** | Live-pg E2E for `gdpr.purgeUser` | Hermetic tests + structural cascade proof exist (S10.4 static FK contract test). Belt-and-suspenders only. |
| **D26** | 2-phase token on `DELETE /api/v1/users/:id/data` | Operator-only endpoint today. Upgrade if frontend exposes the verb to end users. |

#### Sprint 8
| ID | Item | Why deferred |
|---|---|---|
| **D29** | Vtable-level lane filtering | Conditional, not scheduled. Activate only if production retrieval shows real cross-lane confusion. |

#### PR #21/#22 reviews
| ID | Item | Why deferred |
|---|---|---|
| **D33** | Live-pg cascade integration test | Static contract via S10.4 covers structural claim. Live-pg pairs naturally with D25. |
| **D34** | Banner-once env-fallback integration test | Once-fire contract locked (`50c9ec4`); env-integration needs setenv shim across platforms. |

#### Strategic
| ID | Item | Why deferred |
|---|---|---|
| **D22** | Billing-v2 feature-flag architecture | Explicit "post-closure" — pricing math sound, plumbing latent. |
| **D23** | nullalis-v2 partial rewrite | Explicit "post-Sprint-16." V1 absorbs fixes. |
| **D24** | Retroactive Sprint 1 + 3 self-reviews | Low priority; doc completeness only. |
| **D35** | Sprint 9 (Supply Chain Full) — 8-item set | Parked with explicit triggers (external audit / second committer / public release / supply-chain CVE). |

#### S14 parked items
| ID | Item | Why deferred |
|---|---|---|
| **S14.1** | STRIDE threat model | Trigger: collab session with Nova (~2-3 hr). |
| **S14.2** | EU AI Act classification | Legal + product decision. Trigger: EU paying user OR external counsel. |
| **S14.7** | Bus factor mitigation | Trigger: Nova drafts process. |
| **S14.8** | On-call rotation | Trigger: first paying customer with uptime expectations. |
| **S14.9** | Pentest engagement | Trigger: Sprint 11 (Security Hardening) completion. |

#### S15 parked items
| ID | Item | Why deferred |
|---|---|---|
| **S15.1** | `config_parse.zig` table-driven tests | Trigger: future config-parse bug OR contributor-side work. |
| **S15.2** | log.warn vs log.info rebalance | Trigger: operator log-noise pain OR Sprint 13 absorbs. |

#### S16 operator/cross-repo items
| ID | Item | Why deferred |
|---|---|---|
| **S16.1** | Load test harness | Operator-pending; could solo-stub but researcher pass replaces real-load signal for V1 single-user. |
| **S16.3** | Public status page | Operator-pending; SaaS deploy. |
| **S16.4** | Transactional email (Resend/SendGrid) | **Operator-only — cross-repo zaki-prod** |
| **S16.5** | Legal docs (TOS / Privacy / AUP) | **Needs lawyer** |
| **S16.7** | zaki-web frontend audit | **Cross-repo zaki-prod** |
| **S16.8** | Typ custom-patches inventory | **Cross-repo zaki-infra** |

#### Operator-only (Nova-side, blocks real launch but not V1 closure)
- GitHub Actions billing fix (your 4-day window)
- DPAs to submit (Together / Composio / Sentry)
- Moonshot direct provider research outcome (your call)
- S11/S12/S13 k8s manifest deploys (zaki-infra; after billing unlock + triggers)

---

## Summary

| Bucket | Count | Effort |
|---|---|---|
| V1-must | 5 items | ~5-9 hr |
| V1-nice | 7 items | ~5-7 hr |
| V1.5-defer | 30 items | n/a (parked) |
| Operator-only | 9 items | n/a (Nova-side) |
| Obsolete-for-V1 | 1 item (D31, Qdrant unused) | n/a |

**Total V1 work I can solo:** ~10-16 hours focused. Atomic commits, batched by surface. Then researcher pass.

## Final close-order (post-Nova-greenlight 2026-04-26)

**Phase 1 — V1-must batch A: quick wins (~35 min, 1 PR):**
1. D1.14c — flag 3 tools cacheable (web_search/memory_recall/composio list)
2. S14.10.1 — sentry-zig LICENSE check

**Phase 2 — V1-must batch B: scheduler tests (~1-2 hr, 1 PR):**
3. D14 — investigate 2 pre-existing scheduler failures (fix or document explicitly)

**Phase 3 — V1-must batch C: SLO.md (~1 hr, 1 PR):**
4. S16.2 — draft `docs/SLO.md` with proposed defaults; Nova validates targets pre-merge

**Phase 4 — V1-must batch D: CostTracker monthly persistence (~3-4 hr, 1 PR):**
5. D5 — per-user JSONL at `{users_root}/{user_id}/cost.jsonl` + on-demand monthly rollup. Hooks into existing UsageRuntime.recordWeight. New tests cover seed-write-rollup roundtrip.

**Phase 5 — V1-nice batch A: observability + insurance (~2 hr, 1 PR):**
6. S14.5 MED-1 — DaemonState mutex
7. S14.5 MED-2 — dispatch_stats atomic
8. D27 — gdpr_purge metrics
9. D13 — secret_mutations metrics

**Phase 6 — V1-nice batch B: test gap (~30-60 min, 1 PR):**
10. D9 — entitlements/revoke HTTP roundtrip test

**Phase 7 — V1-nice batch C: D1 activation (~3-4 hr, 1 PR):**
11. D1.14b — parallel tool cache wire-up
12. D1.15b — warmupSession auto-spawn

**Then: LLM researcher pass.** Karpathy-style. Real human prompts across tasks. Log every rough edge with severity. Round-2 fixes. Re-test. Declare V1 ready when researcher comes back quiet.

---

## Nova's adjustments (2026-04-26)

- **D14 → V1-must** (was nice): open failing tests erode trust
- **S16.2 → V1-must** (was nice): cheap operator-doc, sets the bar pre-launch
- **D5 → V1-must** (was defer): V1 = first paying multi-user → calendar-monthly cost persistence becomes load-bearing
- **D31 → obsolete-for-V1**: Qdrant unused in production (default = pgvector); revives only on backend swap
- Everything else: agreed as classified. Open items stay open per their parks.
