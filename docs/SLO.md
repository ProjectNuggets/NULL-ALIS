# nullalis Service Level Objectives (SLO)

**Status:** initial draft (2026-04-26). Targets are operator-validated proposals; tighten or loosen based on real customer expectations once first paying multi-user lands.

**Owner:** Nova (revise after first SLA conversation).
**Audience:** operators (alert thresholds), customers (uptime expectations), engineering (regression bar).

---

## 1. Service inventory

| Service | What it does | SLO scope |
|---|---|---|
| `gateway` | HTTP entry point; SSE chat stream; control endpoints | YES |
| `daemon` | Cron scheduler tick + lane dispatch + heartbeat | YES |
| `nullalis runtime` | Agent turn execution + tool dispatch + memory pipeline | YES |
| `postgres` (DO managed) | Source-of-truth for sessions / memory / scheduler / vault | YES (managed by DO; we observe + alarm on connection) |
| `pgbouncer` | Connection pool fronting postgres | YES |
| `cell pods` | Per-tenant runtime isolation | DEFERRED (cell-pod flip per Nova directive) |

## 2. Service Level Indicators (SLI) and Objectives (SLO)

### 2.1 Gateway availability

| SLI | Definition | SLO target | Error budget (28-day) |
|---|---|---|---|
| Uptime | `(successful_requests / total_requests) ≥ 99.5% per rolling 28 days` | **99.5%** | ~3h 36m of allowed downtime per 28-day window |
| `/api/v1/chat/stream` SSE connect success | `(2xx connect responses / total connect attempts) ≥ 99% per rolling 7 days` | **99.0%** | ~1h 41m / week |
| Control endpoint success (provision, settings, /me) | `(2xx / total non-streaming) ≥ 99.5% per rolling 7 days` | **99.5%** | ~50min / week |

### 2.2 Latency (chat-stream)

| SLI | Definition | SLO target |
|---|---|---|
| Time-to-first-token (TTFT) p50 | 50th percentile of first SSE event arrival after request POST, measured at gateway | **≤ 1.5 s** |
| TTFT p95 | 95th percentile | **≤ 4.0 s** |
| TTFT p99 | 99th percentile | **≤ 8.0 s** |
| Stream completion p95 | request POST → stream `[DONE]` event, single agent turn no tools | **≤ 12 s** |
| Tool-heavy turn p95 | request POST → stream `[DONE]` for turns with 1-3 tool calls | **≤ 25 s** |

**Why these thresholds:** based on what feels acceptable for a conversational AI assistant. Background measurement: Together-served Kimi-K2.5 typically returns first token in 800ms-1.2s under cache-warm conditions; cache-cold turns add ~500ms-1s; hand-rolled SSE adds <50ms.

### 2.3 Daemon (cron + dispatch)

| SLI | Definition | SLO target |
|---|---|---|
| Cron tick liveness | Time since last heartbeat write to `health.json` | **≤ 90 s** (alert if exceeds) |
| Cron job dispatch success | `(successful job dispatches / total fired jobs) ≥ 99% per rolling 7 days` | **99.0%** |
| Cron schedule drift | Actual fire time vs scheduled fire time, p95 | **≤ 30 s** |

### 2.4 Postgres (DO managed)

| SLI | Definition | SLO target |
|---|---|---|
| Connection pool availability | `(successful_acquires / total_acquires) ≥ 99.9% per rolling 24h` | **99.9%** |
| Query p95 latency (read) | Per-query p95 from pgbouncer | **≤ 100 ms** |
| Query p95 latency (write) | Per-query p95 from pgbouncer | **≤ 250 ms** |

### 2.5 Memory pipeline

| SLI | Definition | SLO target |
|---|---|---|
| Memory recall p95 latency | `memory_recall` tool dispatch → result, p95 | **≤ 800 ms** |
| Memory store success | `(successful upserts / total store attempts) ≥ 99.5%` | **99.5%** |
| Vector sync lag (pgvector) | Lag between memory store and pgvector embedding write, p95 | **≤ 5 s** |

### 2.6 Tool execution

| SLI | Definition | SLO target |
|---|---|---|
| Tool dispatch success (non-network) | `(success / total) ≥ 99.5% per rolling 7 days` for shell, file_*, memory_*, runtime_info | **99.5%** |
| Tool dispatch success (network) | `(success / total) ≥ 95% per rolling 7 days` for web_search, web_fetch, composio | **95.0%** |

Network tools have lower SLO because upstream provider failures (Brave/Serper rate-limit, Composio 5xx) are out of our control. The lower number protects us from over-alarming on upstream noise.

### 2.7 Cost accuracy (post-D5)

| SLI | Definition | SLO target |
|---|---|---|
| Cost ledger continuity | Per-user `cost.jsonl` rollup matches sum of session weight increments within ±1% per rolling 7 days | **99% calendar-monthly accuracy** |

---

## 3. Error budget policy

**Burn-rate alerts** (SRE pattern — fast burn before the budget runs out):

| Budget burned | Window | Action |
|---|---|---|
| ≥ 2% in 1h | 1 hour | Page on-call (S14.8 unparked) — investigate immediately |
| ≥ 5% in 6h | 6 hours | Page on-call — likely sustained issue |
| ≥ 10% in 3 days | 3 days | Slack notify — degraded service, plan remediation |
| ≥ 50% in 14 days | 14 days | Engineering pause on new features; budget recovery focus |
| ≥ 100% (budget exhausted) | 28-day window | Postmortem + incident review + customer comms |

**Budget recovery rule:** when error budget is exhausted, no new feature deploys until budget regenerates above 50%. Hotfixes still allowed.

---

## 4. Measurement methodology

**Source of truth for each SLI:**

- Gateway uptime + 5xx rate → Prometheus scrape from gateway `/metrics` endpoint (Sprint 13.1)
- TTFT + stream completion → OTel collector spans tagged with `chat.stream.ttft_ms` + `chat.stream.duration_ms` (Sprint 13.3)
- Daemon liveness → file mtime check on `health.json` (already wired via S1.5)
- Postgres latency → pgbouncer stats + DO console (managed)
- Memory recall latency → OTel span on `memory.recall` operation
- Tool dispatch success → `lane_metrics.recordToolDispatch{ok,fail}` counters (D13/D27 work)
- Cost ledger continuity → diff of `{users_root}/{user_id}/cost.jsonl` rollup vs `usage_runtime` accumulator (D5)

**Dashboards to build (Sprint 13.6):**
1. SLO compliance dashboard — one row per SLI, current value vs target, error budget remaining
2. Per-tenant burn dashboard — token cost per user, request rate, cost-per-conversation
3. Latency heatmap — TTFT distribution across the day

---

## 5. Customer-facing SLA derivation

**Recommended SLA published commitments** (more conservative than internal SLOs to leave engineering breathing room):

- **Uptime:** 99.0% rolling 30 days (vs 99.5% internal SLO)
- **Latency:** p95 chat reply within 30s for non-tool turns (vs 12s internal SLO)
- **Cost-per-call accuracy:** ±5% billed vs metered (vs 1% internal SLO)

**SLA breach remedies:** customer credit equal to 10% of monthly fee per breach hour, capped at 30% per month.

---

## 6. What's NOT covered

- **First paying customer onboarding** — no SLA before first paying signup
- **Free tier** — explicit "best effort, no uptime guarantee" in TOS (S16.5 to draft)
- **Beta features** — anything behind a feature flag is exempt from SLOs until promoted GA
- **Channels other than chat** (Telegram, voice) — separate SLOs after channel-specific load patterns are observed
- **Cell-pod isolation** — deferred per Nova directive; SLOs assume shared runtime today

---

## 7. Triggers to revise this doc

1. **First paying customer with explicit SLA conversation** → tighten uptime + latency targets to match customer expectation
2. **First post-launch incident** → review whether budget burn-rate alerts fired correctly; tune thresholds
3. **Cell-pod flip lands** → add per-cell-pod isolation SLOs
4. **AlertManager rules deployed (S13.4)** → cross-check that every SLO has a matching alert rule
5. **Quarterly SLO review** → re-baseline targets vs actual measurements; remove SLIs that don't move

---

## 8. Operator commitments (Nova validates)

Before declaring this doc "live":
- [ ] Nova reviews proposed targets vs gut-feel acceptable; tighten or loosen where needed
- [ ] First Prometheus deploy (S13.1) → confirm at least uptime + 5xx rate are measured
- [ ] First Grafana dashboard (S13.6) → confirm SLO dashboard renders the targets above
- [ ] Sprint 13.4 AlertManager rules → confirm burn-rate alerts wire to Slack/PagerDuty channel
- [ ] Document published on chatzaki.com/docs/sla once S16.5 legal review approves customer SLA derivation
