# nullALIS / ZAKI BOT Plan v02

Status: Proposed execution baseline  
Date: 2026-03-10  
Scope: Phase 1 (Digital Twin Core) + Monetization foundation

## 1. Why v02

v0.1 proved product viability at small scale:
1. Core runtime works.
2. Tenant+Postgres path is viable.
3. SSE + progress improves perceived responsiveness.
4. Benchmark framework exists.

v02 objective is not just "more features."  
v02 objective is:
1. make the system reliably work at multi-tenant production conditions, and
2. make revenue model executable with clean unit economics.

## 2. Locked Product Positioning (Phase 1)

`nullALIS = ZAKI BOT` as a persistent digital twin:
1. one central main conversation per user
2. memory continuity across app + Telegram
3. proactive follow-up with bounded autonomy
4. integrated execution across daily tools

Phase 1 excludes platform expansion:
1. no full A2A network rollout
2. no marketplace rollout
3. no memory inheritance product surface
4. no public Agent-as-API launch

Those remain Phase 2+.

## 3. Phase 1 Product Outcomes (Must Be True)

1. Reliability and truth:
- no contradictory runtime state for same user across surfaces
- no split-brain scheduler behavior
- deterministic morning-brief behavior

2. UX quality:
- user can always tell "working vs stuck"
- concise and trustworthy failure messages
- no haunted autonomous chatter loops

3. Integration quality:
- Gmail/Calendar/Drive read flows are robust under large payloads
- failures degrade gracefully with partial/continuation semantics

4. Multi-tenant safety:
- zero cross-tenant leakage
- bounded noisy-neighbor impact
- lock/lease correctness under load

## 4. Monetization Strategy (Phase 1)

## 4.1 Who Pays First (ICP)

Primary ICP for v02 monetization:
1. solo operators/founders
2. high-leverage professionals (execs, PMs, creators)
3. small teams (2–20) needing a digital chief-of-staff

## 4.2 What Is Sold

Sell outcomes, not tokens:
1. persistent memory continuity
2. proactive execution reliability
3. integrated daily operations (chat + schedule + integrations)

## 4.3 Packaging (Default v02 Proposal)

### Free (Acquisition)
1. 1 user
2. limited monthly turns
3. limited integrations
4. no advanced proactive automation
5. community support only

### Pro (Core Revenue)
1. single-user premium limits
2. proactive scheduling + richer automation
3. integration depth (email/calendar/drive)
4. priority model routing and better latency
5. export/reporting + advanced runtime diagnostics

### Team (Expansion Revenue)
1. per-seat + shared org controls
2. tenant governance controls
3. stronger observability and audit
4. team policy templates
5. support SLA targets

### Enterprise (Later)
1. SSO/SCIM
2. custom retention/compliance
3. dedicated support/SLA
4. deployment and data residency options

## 4.4 Metering Model (What to Bill On)

Use hybrid metering with simple defaults:
1. base subscription per plan
2. included monthly usage budget
3. overage for high-cost dimensions

Meter dimensions:
1. assistant turns (input/output token normalized)
2. tool executions (weighted by cost class)
3. autonomous job runs
4. integration payload volume (read/write)
5. memory vector operations/storage footprint

Cost classes for tools:
1. Class A (cheap): local reads, schedule ops, runtime_info
2. Class B (medium): web search, composio list/read small payload
3. Class C (expensive): large integration payloads, heavy model calls

## 4.5 Unit Economics Guardrails (Must Hold)

Target guardrails for Phase 1:
1. gross margin positive on Pro median user
2. hard usage caps prevent runaway loss events
3. autonomous features have explicit budget ceilings

Operational controls:
1. per-user monthly budget caps
2. per-day autonomous action budgets
3. emergency throttles for expensive tool classes
4. overage alerts before hard cutoff

## 4.6 Commercial Readiness Gates

Before charging broadly:
1. billing meter accuracy validated vs runtime logs
2. plan limits enforced correctly at API/runtime layer
3. usage visibility page (what was consumed and why)
4. graceful limit handling UX (no silent hard failures)

## 5. Pricing and Offer Mechanics (Execution Defaults)

Phase 1 default pricing model (to validate, not final public commitment):
1. Free: no-card onboarding
2. Pro: monthly subscription + included usage
3. Team: per-seat subscription + org controls

Offer mechanics:
1. 14-day Pro trial (optional by channel)
2. annual prepay discount for Team+
3. usage notifications at 70/90/100%
4. soft limit warnings before hard cap

## 6. Billing and Entitlement Architecture (v02)

Required components:
1. `plans` catalog (feature flags + limits)
2. `entitlements` service at request-time
3. usage meter ingestion pipeline
4. billing provider integration (invoice/subscription state)
5. audit table for usage and entitlement decisions

Runtime enforcement points:
1. chat stream entry
2. tool execution entry
3. scheduler/proactive execution
4. integration adapters

Failure policy:
1. deny expensive operations when out-of-entitlement
2. keep essential safety/status ops available
3. always return user-facing reason code

## 7. Benchmark + Monetization Link

Use benchmark outputs as commercial trust signals:
1. publish verified reliability/latency/isolation metrics by profile
2. map profile to plan limits and SLA language
3. do not claim SOTA/compliance without gate evidence

Commercial mapping:
1. Free/Pro use shared baseline SLO
2. Team/Enterprise get tighter SLO targets and support response windows

## 8. Phase 1 Execution Sequence

1. Reliability/runtime truth hardening (A1)
2. wake/proactive bounded control (A2)
3. UX liveness + failure clarity (A3)
4. integration robustness under payload stress (A4)
5. SRE scale profiles + canary policy (A5)
6. benchmark and evidence pipeline (A6)
7. monetization layer activation (entitlements + metering + billing)

Note:
- Monetization can begin in private beta after A1–A4 stabilize.
- Broad paid rollout waits for A5/A6 gates.

## 8.1 Runtime Operating Model Execution Doc

For production-scale operational rollout (cell routing, quotas, canary gates, premium dedicated mode), execute:
1. `docs/v0.2-operational-model-agent-runbook.md`

This runbook is agent-executable and is the source of truth for:
1. standard tier cell architecture
2. noisy-neighbor containment
3. promotion/rollback SLO gates
4. premium dedicated tenant activation

## 9. KPIs (Product + Revenue)

Product KPIs:
1. contradiction rate across runtime surfaces
2. proactive duplicate/misfire rate
3. first-visible-progress latency
4. successful integration-read rate under mixed payloads
5. cross-tenant isolation incident count

Business KPIs:
1. free->pro conversion
2. monthly active paid users
3. gross margin by plan
4. overage revenue share vs churn impact
5. support tickets per 100 paid users

## 10. Risks and Mitigations

1. Risk: high infra/model cost burns margin.
- Mitigation: strict metering + hard caps + tiered model routing.

2. Risk: autonomy errors harm trust and paid retention.
- Mitigation: origin policy, dedupe, explainable actions, simulation-first for risky domains.

3. Risk: integration payload instability (provider-side constraints).
- Mitigation: bounded adapters, partial results, retry taxonomy, observability.

4. Risk: pricing complexity confuses users.
- Mitigation: simple public plans, transparent usage dashboard, clear overage rules.

## 11. Go/No-Go for v02 Release

Go only if all are true:
1. Phase 1 product acceptance KPIs are green.
2. Program hard gates pass (tests/build/isolation/soak/canary).
3. Metering and entitlement checks are validated.
4. Paid plan UX is transparent and non-surprising.

No-go if any are true:
1. unresolved runtime truth contradictions,
2. repeated proactive misfires,
3. unbounded cost paths without enforcement,
4. benchmark evidence incomplete for claimed tier.

## 12. Source of Truth Links

1. Workstation execution spec:
- `docs/v0.2-sota-agent-workstation.md`
2. Benchmark spec:
- `docs/dtaas-bench-v0.2-spec.md`
3. Ops runbook:
- `docs/reliability-ops-runbook.md`
4. API contract:
- `docs/openapi-v1.yaml`
