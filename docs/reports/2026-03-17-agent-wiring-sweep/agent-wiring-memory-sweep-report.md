# Agent Wiring + Memory Sweep Report (No Code Changes)

Date: 2026-03-17  
Scope: investigation only (logs, runtime inspection, DB inspection, code-path audit)  
Canonical namespace: `zaki-bot-staging`

## 1) Drift Guard + Environment Integrity

- Pre-sweep drift guard: `DRIFT_GUARD_OK`
- Post-sweep drift guard: `DRIFT_GUARD_OK`
- Config fingerprint stayed stable: `4c29bc9504cf196eed66fe2b6878e9262b68bd05108aaf9a0c73647d25c77a81`
- Runtime effective config (`user=1`) stayed stable:
  - `effective_config_source=postgres_seeded_from_file`
  - `effective_config_hash=59750d4df997b660`
- No crash/restart loop observed in this sweep window.

Evidence:
- `evidence/pre-diagnostics-user1.json`
- `evidence/post-diagnostics-user1.json`
- `evidence/scenario-results.json`
- `evidence/s1-isolated-user55001.json`
- `evidence/s1-isolated-stage-attribution.json`
- `evidence/lock-wait-by-scenario.json`

## 2) Timing Attribution (Where Time Goes)

### Scenario summary (from sweep harness)

| Scenario | n | p50 (ms) | p95 (ms) | Key attribution |
|---|---:|---:|---:|---|
| S1 short, same user, consecutive (`user=1`) | 20 | 9,132 | 90,020 | Heavy queue debt/lock wait contamination in this lane; 2 client timeouts |
| S2 short, multi-user burst | 20 | 29,481 | 71,837 | Dominated by provider/model time under concurrency |
| S3 deep/tool-heavy | 2 | 25,966 | 30,333 | Dominated by model passes/tools as expected |
| S4 same-session rapid input (`user=54001`) | 10 | 74,728 | 101,247 | Dominated by `session_lock_wait` on serial main lane |

### Lock-wait attribution from gateway/session logs

| Scenario | lock_wait n | lock_wait p50 (ms) | lock_wait p95 (ms) | lock_wait max (ms) |
|---|---:|---:|---:|---:|
| S1 (`user=1`) | 16 | 10,996 | 78,562 | 110,334 |
| S2 | 0 | - | - | - |
| S3 | 0 | - | - | - |
| S4 (`user=54001`) | 10 | 63,944 | 95,724 | 98,988 |

### Isolated control run to remove lane contamination

Fresh user (`55001`), same short prompts, no overlapping load:

- p50: `3,391 ms`
- p95: `11,136 ms`
- errors: `0`
- lock wait: `n=0` (none observed)
- message_process p50: `3,334 ms`

Interpretation:
- Runtime can be snappy on short turns when lane is uncontended.
- Worst spikes in observed regressions are queue/lock effects, not `memory_enrich`.

## 3) Config + Mode Wiring Audit

### Effective chain confirmed (tenant runtime)

`base config file -> postgres user_config -> effective runtime`

Code path:
- tenant config load + source tagging: `src/gateway.zig:733-771`
- empty DB seed behavior: `src/gateway.zig:748-767`
- runtime diagnostics exposure: `src/gateway.zig:4211-4307`

### Runtime mode knobs (user=1) from canonical DB config

From `/api/v1/users/1/config` and `nullalis_local_canonical.user_config`:
- `assistant_mode=balanced`
- `queue_mode=serial`
- `queue_cap=12`
- `queue_drop=summarize`
- `max_history_messages=50`
- `compact_context=true`
- `session_ttl_secs=1800`

Mapping source:
- `src/user_settings.zig:67-88`

### Delta matrix vs fast-reference commits (`7429313`, `62fe879`)

| Area | Canonical now | Fast reference | Changed since fast ref? | Likely latency impact |
|---|---|---|---|---|
| Balanced queue mapping | `serial + summarize + cap=12` | same (`7429313`) | No behavioral delta | Neutral |
| Pgvector pooling/knobs | present | introduced in `62fe879` | No regression delta in this sweep | Neutral |
| Tenant config source diagnostics | present | absent | Yes | Observability only |
| Empty-user DB config seeding | `postgres_seeded_from_file` | absent | Yes | Low direct latency impact |
| Compaction timeout wiring | explicit timeout path | implicit | Yes | Risk-reduction for hidden stalls, not observed as dominant in this run |

## 4) Session/Lane/Queue Findings

Primary session lock path:
- `SessionManager.processMessageWithContext`: `src/session.zig:375-516`
- lock wait instrumentation: `src/session.zig:469-477`

Findings:
- Serial lane behavior is working as coded.
- Same-session rapid inputs stack behind the session mutex and produce large `session_lock_wait`.
- In S4, `mean_non_model_ms_ok ~57.3s`, matching lock-wait evidence almost exactly.
- This explains “short prompt but very slow” reports when multiple turns are in-flight on the same `main` lane.

## 5) Memory Canonical-State Sweep

### Canonical state vs projection

Canonical durable state (authoritative):
- User config JSON in Postgres: `src/zaki_state.zig:832-843`
- Session messages/checkpoints in Postgres tables (`messages`, `sessions`)
- Durable memories in Postgres (`memories`): `src/zaki_state.zig:1126-1273`

Runtime memory composition:
- Tenant runtime forces memory backend to markdown when state backend is postgres: `src/gateway.zig:772-776`
- Then wraps canonical Postgres memory with `zaki_dual`:
  - primary store: Postgres (`zaki_postgres`)
  - projection: markdown workspace file(s), synced both directions  
  - `src/gateway.zig:809-834`
  - `src/memory/engines/zaki_dual.zig:35-79`

### Current memory pipeline status in canonical deployment

Observed memory plan logs repeatedly show:
- `backend=markdown`
- `retrieval=disabled`
- `vector=none`

Log source formatter:
- `src/memory/root.zig:1167-1187`

Important nuance:
- `memory_enrich` is not currently a latency hotspot (mostly `0 ms` in this sweep), but retrieval being disabled is a memory-quality gap.

## 6) Provider/Tool Interaction Sweep (Short-Turn Impact)

From `provider-tool-taxonomy.json`:

- S2 (short multi-user burst) had `mean_model_total_ms_ok ~27,985 ms` and `mean_non_model_ms_ok ~5,940 ms`.
  - This is provider/model dominated under concurrency.
- S1 had one short prompt escalate to a 3-pass tool loop (`runtime_info` calls), but this was rare.
- S4 had single-pass responses with no tool calls; latency came from queue/lock, not tool reflection.

## 7) Ranked Blockers (Canonical vs Yesterday-Fast)

### P0 likely blockers (high confidence)

1. Same-lane contention on `main` (serial queue + concurrent user inputs/channels)  
Confidence: High  
Evidence: `session_lock_wait` p95 up to ~95s in S4; isolated run has zero lock wait and fast p50.

2. Existing queue debt on `user=1 main` contaminates perceived short-turn speed  
Confidence: High  
Evidence: S1 had backlog and lock waits before/through scenario window; isolated user shows fast baseline.

### P1 plausible contributors (medium confidence)

1. Provider latency variance and concurrency effects  
Confidence: Medium-high  
Evidence: S2 dominated by model durations, not internal stages.

2. Occasional short-turn multi-pass tool loop (`runtime_info`)  
Confidence: Medium  
Evidence: Rare but present in S1; inflates individual outliers.

### P2 ruled-out suspects (for this sweep)

1. `memory_enrich` as primary latency cause  
Confidence: High (ruled out in this run)  
Evidence: stage mostly `0 ms`; isolated run fast with same enrich path.

2. New commits as sole root cause of current spikes  
Confidence: Medium-high (not supported by timing evidence)  
Evidence: post-`62fe879/7429313` changes are mostly diagnostics/seeding/timeout wiring; spikes map directly to lock contention patterns.

## 8) Implementation-Ready Recommendations (No Changes Applied Yet)

### Patch order (low-risk/high-impact first)

1. **P0 Session-lane contention hardening**
- Keep correctness-first serial default for `main`.
- Enforce one active turn per lane at client/BFF edge (queue explicitly, no hidden parallel sends to same lane).
- Add explicit queue/lock telemetry to client-facing progress (wait_ms, queue depth snapshot).
- Add ops alert on sustained `session_lock_wait` p95 > threshold.

Expected gain: removes worst “short prompt took 1-2 minutes” perception without changing model quality logic.
Risk: low (behavioral clarity, not semantic rewrite).

2. **P1 Provider/tool short-turn guardrails**
- Guard trivial prompts from unnecessary tool probes (`runtime_info`) in balanced mode.
- Keep multi-pass/tool behavior for prompts that clearly need it.
- Continue provider-focused tracking separately from session contention.

Expected gain: trims avoidable outliers and token/latency overhead.
Risk: medium (prompt/tool policy tuning).

3. **P1 Memory activation correctness (quality, not speed)**
- Fix semantic defaults gating so tenant postgres can actually activate intended retrieval/vector path when expected.
- Validate that canonical deployment reflects intended memory profile (hybrid/pgvector) before judging memory quality.

Expected gain: memory continuity and recall quality.
Risk: medium (config policy semantics).

## 9) Next Implementation Plan (Concise)

1. Add lock-wait visibility and queue-state progress first (no semantic behavior change).
2. Add same-lane request discipline at ingress/BFF (deterministic serial user experience).
3. Add short-turn tool-loop guardrails in balanced mode.
4. Fix semantic-memory default gating and verify `memory plan resolved` shows intended retrieval/vector mode.
5. Re-run S1/S2/S4 and isolated control with same harness; accept only if:
- S4 p95 drops materially (queue wait collapse),
- S1 no timeout pattern on clean lane,
- no regressions in deep/tool-heavy correctness.

---

No source code or runtime config was modified as part of this sweep report.
