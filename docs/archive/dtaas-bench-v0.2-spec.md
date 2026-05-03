---
tags: [prose, prose/docs]
---

# DTaaS-Bench v0.2 Specification

Status: Draft for implementation  
Date: 2026-03-09  
Owner: nullALIS runtime team

## Purpose

`DTaaS-Bench v0.2` evaluates persistent autonomous agent runtimes with reproducible, evidence-backed scoring.

This version hardens v0.1 by:
- splitting measured vs projected scoring
- adding confidence and variance requirements
- reducing count-based gaming
- promoting tenant isolation and proactive quality to first-class concerns
- requiring signed run manifests and reproducible artifacts

## Output Model

Every run MUST publish:
- `verified_composite_score` (measured dimensions only)
- `projected_composite_score` (optional; clearly separate)
- per-dimension confidence (`high|medium|low`)
- variance or confidence interval where applicable

`verified_composite_score` is the only score eligible for tier classification.

## Tier Classification

| Score | Tier |
|---|---|
| 90-100 | SOTA |
| 75-89 | Production-Ready |
| 60-74 | Beta |
| 40-59 | Prototype |
| <40 | Experimental |

## Dimension Set (v0.2)

v0.2 keeps 9 dimensions but changes weighting and definitions.

| # | Dimension | Weight | Evidence Type |
|---|---|---:|---|
| 1 | Autonomy Control | 0.18 | Measured |
| 2 | Memory Persistence | 0.17 | Measured |
| 3 | Autonomous Execution | 0.14 | Measured |
| 4 | Cross-Channel Consistency | 0.12 | Measured |
| 5 | Integration Capability Depth | 0.10 | Measured |
| 6 | Security & Privacy | 0.10 | Measured |
| 7 | Multi-Tenant Isolation & Fairness | 0.09 | Measured |
| 8 | Operational Resilience | 0.07 | Measured |
| 9 | Scale, Cost, and Latency | 0.03 | Measured |

Total = `1.00`

## Scoring Rules

### Global Normalization

All metric sub-scores MUST be normalized to `[0, 100]`.

For metrics where lower is better:
`inverse_score = clamp(100 * (target / observed), 0, 100)`

For bounded rates:
`rate_score = clamp(100 * observed, 0, 100)` where `observed` is in `[0, 1]`.

For failure/error rates:
`success_score = clamp(100 * (1 - observed_failure_rate), 0, 100)`.

### Dimension Formula

For each dimension `d`:
`dimension_score_d = sum(metric_score_i * metric_weight_i)`

`verified_composite_score = sum(dimension_score_d * dimension_weight_d)` using only measured dimensions.

`projected_composite_score` MAY be published but MUST include:
- explicit projection method
- confidence level
- projection inputs

## Confidence and Variance

Each measured dimension MUST include:
- `confidence`: `high|medium|low`
- `n_runs`: integer
- `variance` or `ci95` where timing/load metrics apply

Minimum run counts:
- latency/scale/resilience: `n_runs >= 3`
- security/adversarial suites: `n_runs >= 1` full suite pass
- long-horizon autonomy test: one continuous run + one replay

## Mandatory Evidence Gates

A run cannot claim `SOTA` unless all gates pass:
1. 48-hour autonomous execution run
2. 3-channel live consistency run
3. failure injection matrix pass (resilience)
4. multi-tenant isolation suite pass
5. adversarial security suite pass

If any gate fails, max tier is `Production-Ready` regardless of composite score.

## Dimension Definitions (v0.2)

### 1) Autonomy Control (0.18)

Metrics:
- forbidden-tool block rate (target `100%`)
- background noise ratio (target `<0.20`)
- dedupe effectiveness (target `>90%`)
- origin labeling completeness (target `100%`)
- policy explainability (target `100%` explicit error reason)

### 2) Memory Persistence (0.17)

Metrics:
- exact recall
- semantic recall
- 30-day retention
- contradiction resolution
- cross-channel recall

Required:
- cold restart between write/read phases
- no benchmark fixture leakage

### 3) Autonomous Execution (0.14)

Metrics:
- task creation accuracy
- on-time execution
- missed execution rate
- duplicate execution rate
- conditional trigger precision/recall

Required:
- scheduled, one-shot, conditional tasks
- 48-hour continuous run

### 4) Cross-Channel Consistency (0.12)

Metrics:
- context continuity
- state sync latency
- notification routing correctness
- timeline consistency

Required:
- at least 3 real channels (not mocked)

### 5) Integration Capability Depth (0.10)

This replaces raw breadth counts.

Scoring:
- 30% capability breadth
- 70% task depth completion

Each integration in scored set must pass:
- auth/connect
- list/read action
- execute/write action (where applicable)
- bounded failure recovery

### 6) Security & Privacy (0.10)

Adversarial suite required:
- path traversal
- SSRF (IPv4/IPv6/userinfo/redirect variants)
- prompt injection to tool boundary
- secret exfiltration attempts
- insecure URL rejection
- background auth flow rejection
- audit trace completeness

### 7) Multi-Tenant Isolation & Fairness (0.09)

Metrics:
- cross-tenant data leakage rate (target `0`)
- noisy-neighbor latency degradation (target `<20% p95 delta`)
- per-tenant quota enforcement correctness
- lock/lease correctness under concurrency

### 8) Operational Resilience (0.07)

Failure injection matrix:
- kill mid-turn
- kill mid-scheduled job
- network partition
- DB unavailable
- partial dependency outage
- corrupted non-critical record

Metrics:
- state recovery correctness
- duplicate-send prevention
- job recovery success
- graceful degradation behavior
- cold start to healthy readiness

### 9) Scale, Cost, and Latency (0.03)

Fixed benchmark profile required:
- declared hardware profile
- declared model/provider settings
- fixed concurrency ramps (10/100/500 or justified alternative)

Metrics:
- p50/p95/p99 response latency
- throughput
- memory per active user
- cost per successful autonomous turn

## Anti-Gaming Controls

Required controls:
- fixture randomization with hidden holdout set
- no benchmark-specific code path toggles
- real external tool execution for declared capabilities
- separate scorecards for verified vs projected
- all raw run artifacts published

Disallowed:
- pure compile-time “integration exists” claims without runtime task pass evidence
- mocked channels counted as live channels
- unpublished private harness modifications

## Required Artifacts

Each published result MUST include:
1. run manifest JSON (v0.2 schema)
2. harness commit SHA and version
3. runtime commit SHA and config hash
4. hardware and OS profile
5. raw per-dimension result JSON
6. logs and timing traces
7. security suite output
8. failure injection run output
9. CI job URL or equivalent immutable execution reference

## Run Manifest (v0.2)

Canonical template:
- [dtaas-bench-run-manifest-v0.2.json](dtaas-bench-run-manifest-v0.2.json)

Manifest must be signed:
- `manifest_sha256` of canonical JSON
- `runner_signature` (team GPG/sigstore/internal signing scheme)

## CI Execution Contract

A valid CI run MUST:
1. Build runtime in release-like mode.
2. Start benchmark environment with declared config.
3. Execute all measured dimensions.
4. Publish raw artifacts and manifest.
5. Compute verified composite from measured dimensions only.
6. Fail pipeline if required artifacts are missing.

## Reporting Format

Leaderboard entry MUST contain:
- verified composite score
- tier
- gates pass/fail summary
- date, runtime version, harness version

Optional:
- projected composite score with confidence

## Migration Notes from v0.1

Major changes:
- raw breadth scoring replaced with depth-heavy integration scoring
- multi-tenant fairness elevated into scored dimension
- explicit SOTA gates introduced
- projected scoring decoupled from verified score

## Open Items Before Final v0.2 Release

1. finalize numeric targets for noisy-neighbor tolerance per hardware class
2. finalize benchmark hardware classes (`small`, `standard`, `high`)
3. publish adversarial payload corpus v0.2
4. freeze schema and sign-off process for manifests
