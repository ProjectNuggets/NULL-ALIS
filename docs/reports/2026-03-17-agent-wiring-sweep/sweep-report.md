# Agent Wiring + Memory Sweep Report

Date: 2026-03-17
Scope: investigation only. No source edits, no config mutations, no rollouts.
Canonical runtime under test: `zaki-bot-staging`
Fast references: archived `nullalis-local` runtime shape plus commits `62fe879` and `7429313`

## Executive Summary

1. Short-turn latency on the canonical stack is dominated by provider round-trip time, not memory enrichment, tool reflection, or response parsing.
2. Same-user overlap on the default `main` lane causes large serialized waits. This is the clearest internal latency blocker.
3. Trivial runtime/meta prompts can trigger `runtime_info`, which adds a second provider pass and turns a short request into a 9-17s turn.
4. Canonical memory truth is Postgres-first. The file config and markdown workspace are projections and seed inputs, not the durable source of truth.
5. The commonly suspected `balanced` mode mapping change around `7429313` is not supported as a latency explanation. The mapping is unchanged in the current tree and still resolves to `serial` / `summarize` semantics.
6. The `S2` burst capture did not isolate provider variance cleanly because repeated traffic hit `user:1:main`, introducing real lock waits into the tail.

## Environment Stability

- Pre-sweep drift guard: passed (`scripts/local-k8s-drift-guard.sh`)
- Diagnostics before/after sweep were stable in backend, provider, scheduler, and config-source posture.
- `s5-post-diagnostics.json` shows no runtime mode drift; only request counters changed.

## 1. Hot-Path Timing Attribution

Artifacts used:
- `docs/reports/2026-03-17-agent-wiring-sweep/s1/pod.log`
- `docs/reports/2026-03-17-agent-wiring-sweep/s3/pod.log`
- `docs/reports/2026-03-17-agent-wiring-sweep/s3/turn-1.sse`
- `docs/reports/2026-03-17-agent-wiring-sweep/s4/pod.log`
- `docs/reports/2026-03-17-agent-wiring-sweep/s2-pod.log`
- `docs/reports/2026-03-17-agent-wiring-sweep/parsed-summary.json`

Note: stage lines are emitted twice by separate observers in the pod logs. Counts are noisy, but the durations themselves are still useful. For small sample sizes, p95 should be treated as directional, not statistically stable.

### S1: short prompt, single user, consecutive turns on `main`

Observed complete turns: 5

| Stage | Median ms | p95 ms | Interpretation |
|---|---:|---:|---|
| `memory_enrich` | 0 | 0 | Not a short-turn blocker in this capture |
| `compact_pre_provider` | 0 | 6747 | Mostly zero; one late outlier needs caution |
| `build_provider_messages` | 0 | 0 | Negligible |
| `llm.response` | 2294 | 6169 | Dominant cost on clean short turns |
| `parse_provider_response` | 0 | 0 | Negligible |
| `finalize_no_tools` | 6 | 11 | Negligible |
| `message.process total` | 3075 | 8636 | Tail driven by LLM latency and occasional lock/compaction |

Observed complete-turn totals:
- 3075 ms
- 6955 ms
- 2125 ms
- 2268 ms
- 9056 ms

Observed `llm.response` samples:
- 3064 ms
- 6945 ms
- 2111 ms
- 2260 ms
- 2294 ms

Attribution:
- Median clean short turn is roughly 75% provider time (`2294 / 3075`).
- `memory_enrich`, provider message building, parsing, and finalize stages are effectively zero-to-single-digit milliseconds.
- One late turn showed `compact_pre_provider=6747 ms` followed by `session_lock_wait=3137 ms`; that is evidence of a possible long-history or overlapped-session tail, but it is a low-confidence outlier rather than the baseline path.

### S3: deep/tool-seeking turn

The clearest exact sample is `s3/turn-1.sse`:
- first provider response: 4019 ms
- `runtime_info` tool call: 2 ms
- second provider response: 13259 ms
- finalize: 7 ms
- total: 17290 ms

Across the 3 captured S3 turns:
- turn total median: 11317 ms
- turn total p95: 16693 ms
- tool call durations: 2-4 ms
- tool reflection: 0-1 ms

Attribution:
- The second LLM pass is the real cost of tool-driven turns.
- Tool execution itself is negligible.
- If a trivial prompt triggers a tool, the system pays another full provider round-trip.

### S4: same-session overlap while prior turn is active

Exact evidence from `s4/pod.log`:
- turn A: `message.process total_ms=7477`
- turn B: `session_lock_wait duration_ms=7160`, then `message.process total_ms=9507`

Attribution for turn B:
- lock wait consumed about 75% of total turn time (`7160 / 9507`)
- the actual second-turn provider work was only about 2336 ms
- this is the strongest measured internal blocker in the current wiring

### S2: short prompt burst across multiple users

Burst artifact summary:
- requests: 10
- workers: 10
- p50: 3000 ms
- p95: 46855 ms
- wall: 46887 ms
- errors: 0

Important caveat:
- This run did not isolate provider variance cleanly.
- `s2-pod.log` shows repeated hits to `agent:zaki-bot:user:1:main`, including `session_lock_wait=17377` and `session_lock_wait=29389`.
- It also shows one tool-triggered `runtime_info` path on `user:1:main` before the largest tail.

Conclusion for S2:
- The measured tail is a blend of provider latency, same-session contention, and a tool-triggered second pass.
- It is useful as evidence that the tail can become extreme, but not as a pure provider-only isolation run.

## 2. Runtime Config + Mode Wiring Audit

### Effective config chain

1. Kubernetes `ConfigMap` + `Secret` feed environment into the app container startup command.
2. Pod startup writes `/nullclaw-data/.nullalis/config.json`.
3. On first tenant runtime init, the server loads per-user config from Postgres.
4. If the user config is empty, it seeds Postgres from file-derived defaults.
5. The tenant runtime then parses the Postgres config and uses that as the effective runtime config.

Measured diagnostics for `user=1`:
- `effective_config_source=postgres_seeded_from_file`
- `effective_config_hash=59750d4df997b660`
- `state_backend_effective=postgres`
- `tenant_lock_backend=postgres_lease`
- `scheduler_backend=postgres`
- `chat_provider_effective=openrouter`
- `chat_fallback_chain=none`
- `provider_data_source=config`

### Current canonical base runtime shape

Live pod-generated base config shows:
- primary model: `openrouter/moonshotai/kimi-k2.5`
- one configured provider in the file: `openrouter`
- gateway workers: 16
- gateway queued requests: 2048
- tenant runtime cache: 2048 users
- tenant runtime idle TTL: 1800s
- state backend: Postgres via PgBouncer on `6432`
- schema: `nullalis_local_canonical`
- session sharing: `cross_channel_shared_main=true`
- memory profile: `postgres_hybrid`
- memory backend: `markdown`
- pgvector store configured, but memory search disabled in base file
- `product_settings=null`
- `agent=null`

### Assistant mode and queue semantics

The base file does not include `product_settings` or `agent` settings. That means tenant seeding falls back to `user_settings.defaults()` and then writes the mapped agent knobs into the seeded user config.

High-confidence inferred effective user defaults:
- `assistant_mode=balanced`
- `queue_mode=serial`
- `queue_cap=12`
- `queue_drop=summarize`
- `compact_context=true`
- `max_history_messages=50`
- `session_ttl_secs=1800`

Why this inference is strong:
- `user_settings.ProductSettings` defaults to `balanced`
- `buildSeedConfigJsonFromFile()` resolves settings from the base file
- when `product_settings` and `agent` are absent, resolution falls back to defaults
- `mergeSettingsIntoConfigJson()` writes the `balanced` mapping into the seeded config JSON

### Config delta matrix: canonical vs fast reference

| Area | Canonical `zaki-bot-staging` | Fast reference / archived `nullalis-local` | Likely latency effect |
|---|---|---|---|
| App image | pinned digest from current HEAD | mutable tag `nullalis:prestaging-20260316-220139` | not a direct latency factor, but removes rollout drift |
| Primary provider/model | `openrouter/moonshotai/kimi-k2.5` | `together/moonshotai/Kimi-K2.5` with `openrouter` also configured | high; provider path is the largest clean-turn delta |
| Fallback chain | none | mixed provider presence in config | medium; canonical is more deterministic |
| DB route | Postgres via PgBouncer (`6432`) | direct Postgres connection | low-to-medium on steady turns; more about parity and connection behavior |
| Schema | `nullalis_local_canonical` | `zaki_bot` | low latency, high reproducibility |
| Gateway workers / queue | explicit `16 / 2048` | not explicitly set in archived base file | medium under load, low on single clean turns |
| Tenant runtime cache / TTL | explicit `2048 / 1800s` | not explicitly set in archived base file | low on hot turns, medium for churn/restart behavior |
| Session main-sharing | `true` | `true` | medium; same default lane means overlap contention remains possible |
| Memory config | explicit `postgres_hybrid` + pgvector store config, search disabled | no explicit memory block in archived base file | low for short turns because `memory_enrich=0ms` in captures |
| Assistant-mode mapping | inferred `balanced -> serial/summarize` | same mapping already present at `7429313` | ruled out as major delta |
| `message_timeout_secs` | default 300s | likely same | low |
| `max_tool_iterations` | default 25 | likely same | low |

## 3. Session / Lane / Lock / Queue Sweep

### Request wiring behavior

- If the request omits `session_key`, the gateway routes the user to `agent:zaki-bot:user:<id>:main`.
- Allowed explicit tenant lanes are `main`, `thread:<id>`, `task:<id>`, and `cron:<id>`.
- `SessionManager.processMessageWithContext()` serializes access with a per-session mutex.
- Queue behavior only matters after a lock collision; otherwise the turn runs immediately.
- Idle sessions can be recycled by `session_idle_timeout_secs`, and tenant runtimes can be pruned by `runtime_idle_ttl_secs`, but neither showed up as a measured short-turn penalty in this sweep.

### What the evidence says

Confirmed with high confidence:
- Same-user overlap on `main` incurs real wait time before provider work starts.
- The contention is not theoretical; `S4` measured `7160 ms` of session lock wait on a single overlapped turn.
- `S2` shows that even a burst intended to be multi-user can create heavy tails if requests collide on the same default lane.

Not confirmed in this sweep:
- Queue overflow/drop behavior as a steady-state baseline blocker.
- TTL recycling as a contributor to the short-turn path.

## 4. Memory Canonical-State Sweep

### Canonical memory truth map

```text
K8s env -> pod startup writes base file config
       -> TenantRuntime.init(user)
          -> read Postgres user_config
             -> if empty: seed from file-derived defaults into Postgres
          -> parse effective config from Postgres
          -> apply tenant semantic memory defaults
          -> init memory runtime
          -> if Postgres state enabled:
             -> create ZakiPostgresMemory
             -> wrap with ZakiDualMemory
             -> syncFromMarkdown(workspace)
          -> attach Postgres-backed UserSessionStore
          -> serve turns through SessionManager
```

### Durable source of truth

Postgres-backed canonical state:
- user registry and workspace binding
- user config JSON
- session metadata and session store records
- tenant ownership lease rows
- heartbeat, onboarding, channel-state rows
- Postgres memory records via `ZakiPostgresMemory`

### Projections and runtime-derived artifacts

Derived or projected artifacts:
- pod-generated `/nullclaw-data/.nullalis/config.json`
- seeded user config JSON written once from file-derived defaults
- workspace markdown mirror under `/data/users/<id>/workspace`
- diagnostics snapshots

### What affects short-turn latency right now

On the hot path:
- session mutex / queue behavior
- provider request / response
- persisted session message writes

Not a measured short-turn blocker in current captures:
- memory enrichment and retrieval (`memory_enrich=0 ms`)
- tool reflection
- pgvector semantic search

Interpretation:
- The memory system is wired in a production-like way, but the current short-turn latency is not being consumed by memory lookup.
- `62fe879` added pgvector pooling/config knobs, but that is not the dominant short-turn explanation under this configuration because semantic retrieval is not active in the observed path.

## 5. Provider / Tool Interaction Sweep

### Turn taxonomy observed

Single-pass, no-tools:
- short conversational turns
- one provider round-trip
- 2.1s to 6.9s in S1

Tool-triggered multi-pass:
- runtime/meta questions that triggered `runtime_info`
- tool work itself: 2-4 ms
- extra cost: a second provider round-trip
- total impact: roughly 9.5s to 17.3s in captured examples

Outlier long turns:
- same-session overlap on `main`
- possible history/compaction growth on long-lived sessions
- extreme tails in S2 were amplified by both lock waits and tool-triggered second passes

### Candidate design guardrails

No code changes were made here. These are design candidates only.

1. Reduce auto-tooling for trivial runtime/meta prompts unless the user clearly asks for structured diagnostics.
2. Push overlapping work onto `thread:` or `task:` lanes instead of defaulting everything to `main`.
3. Revisit history/compaction thresholds only after lane separation is addressed, because the clean short-turn path is still mostly provider-bound.

## 6. Comparative Gap Report

| Suspect | Changed vs fast reference? | Latency impact | Confidence | Evidence |
|---|---|---|---|---|
| Same-session `main` lane serialization | present in canonical and materially visible now | high | high | `S4` lock wait `7160 ms`; `S2` user `1` waits `17377/29389 ms` |
| Provider RTT on clean short turns | yes, provider path changed | high | high | `S1` median `llm.response=2294 ms`, p95 `~6169 ms` |
| Trivial prompts causing `runtime_info` loops | yes, observed live | high | high | `S3 turn-1.sse` shows 2 ms tool call but 13.3s second provider pass |
| PgBouncer vs direct Postgres | yes | low-to-medium | medium | live config delta; not visible in short-turn stage times |
| Gateway worker/queue knobs | yes | medium under concurrency | medium | canonical explicit `16/2048`; archived base file omitted them |
| Long-session compaction growth | unclear | medium | medium-low | one `6747 ms` S1 outlier and one noisy `28469 ms` S3 outlier |
| `balanced` mode mapping around `7429313` | no material delta | none / ruled out | high | same mapping still present in `src/user_settings.zig` |
| Memory enrichment / semantic retrieval | changed infra exists, but not active in observed path | low / ruled out for short turns | high | `memory_enrich=0 ms` across captured scenarios |
| Tool reflection / parse response | no | low / ruled out | high | 0-1 ms observed |

## Ranked Blockers

### P0 likely blockers

1. Same-session serialization on the default `main` lane
   - Confidence: high
   - Why: direct measured lock waits dominate overlapped turns.

2. Provider round-trip time on clean short turns
   - Confidence: high
   - Why: clean short turns spend most time waiting on `llm.response`.

### P1 plausible contributors

1. Trivial prompts unnecessarily entering a tool-driven two-pass flow
   - Confidence: high
   - Why: `runtime_info` itself is cheap; the second provider call is not.

2. History growth / compaction on long-lived `main` sessions
   - Confidence: medium-low
   - Why: outlier evidence exists, but it was not consistently isolated into complete turns.

3. Concurrency behavior from the burst harness itself
   - Confidence: medium
   - Why: the intended multi-user run still collided on `user:1:main`.

### P2 ruled-out suspects for short-turn latency

1. Memory enrichment / retrieval under current canonical config
2. Tool reflection cost
3. Response parsing cost
4. `balanced` queue mapping drift around `7429313`
5. `62fe879` pgvector pooling as the primary explanation for short-turn latency

## Concise Next Implementation Plan

Recommended patch order, lowest-risk/highest-signal first:

1. Separate same-user overlap from `main`
   - Preserve `main` for the conversational lane.
   - Route concurrent background or burst-like work to explicit `thread:` or `task:` lanes.
   - Expected gain: removes the clearest internal blocker.

2. Add guardrails for trivial prompts that currently trigger `runtime_info`
   - Keep tool use for explicit diagnostics requests.
   - Prefer direct model replies for short conversational prompts.
   - Expected gain: prevents accidental second-pass turns.

3. Re-measure clean short turns after lane/tool changes
   - Re-run S1 and a corrected S2 with guaranteed unique users or explicit per-request lanes.
   - Expected gain: separates provider floor from internal contention noise.

4. Only then tune compaction/history behavior
   - If long-session tails remain after step 1 and 2, investigate `compact_pre_provider` and history size policies.
   - Expected gain: medium, but only after the larger blockers are addressed.

5. Leave memory/vector work for later unless the workload changes
   - Under the current canonical config, memory lookup is not the short-turn bottleneck.

## Source Anchors

- Tenant config seeding and effective runtime setup: `src/gateway.zig:636-675`, `src/gateway.zig:689-833`
- Tenant runtime cache/TTL: `src/gateway.zig:1005-1071`
- Chat stream request path and default main-lane routing: `src/gateway.zig:5030-5248`
- Per-session lock/queue behavior: `src/session.zig:375-515`
- User settings defaults and balanced mapping: `src/user_settings.zig:42-47`, `src/user_settings.zig:67-88`, `src/user_settings.zig:181-213`
- Agent defaults for timeout/queue/history: `src/config_types.zig:138-169`
- Canonical tenant session key formats: `src/zaki_session.zig:3-17`
- Durable user/session/config provisioning: `src/zaki_state.zig:770-840`
- Provider bundle fallback behavior: `src/providers/runtime_bundle.zig:29-68`
