# Per-User Cell Pod Delivery Plan v0.2

Status: proposed delivery plan  
Owner lane: platform/runtime  
Scope: staged path from today's shared hosted runtime to full per-user nullalis cells

## Goal

Deliver hosted nullalis so that:
1. each active user gets their own full nullalis cell
2. the cell is fully capable, not a crippled shell-only sidecar
3. the user experience feels closer to "my hosted computer"
4. strong user isolation comes from Kubernetes boundaries first
5. current local/source-of-truth semantics do not drift

This plan assumes the architecture in [Per-User Cell Pod Architecture v0.2](./per-user-cell-pod-architecture-v0.2.md).

## Planning Principle

There are two big stages:
1. get-ready phase
2. implementation and rollout phases

That split matters because the architecture only works cleanly if the current shared control plane, Postgres truth, routing, and workspace contract are already stable.

## Policy Principle

The intent is not to keep layering more in-app command policy forever.

When a user is inside a real per-user cell:
1. relax most in-app command restrictions
2. let the agent feel like it owns a machine
3. rely on K8s/container/network/storage walls for the hard boundary

But do not remove all safety invariants.

Keep these invariants even in cell mode:
1. no other users' storage mounted
2. no blanket access to global infra secrets
3. no default access to Kubernetes API
4. no default access to private/internal ranges unless explicitly intended
5. auditable identity on every request and tool turn

In short:
1. fewer app policies
2. stronger substrate walls

## Session And TTL Principle

The user cell owns the user's lanes while warm:
1. `main`
2. `thread:*`
3. `task:*`
4. `cron:*`

Operationally:
1. the cell stays warm while active
2. it is evicted after idle TTL
3. the next request recreates it from canonical truth

`v0.2` recommendation:
1. start with operator-controlled idle TTL
2. default to 30 minutes if that matches current runtime expectations
3. user-adjustable TTL can come after the base lifecycle proves stable
4. TTL must always stay within operator-defined floors and ceilings

## Phase 0: Get Ready

Purpose:
prove the current baseline is stable enough that cells become a real upgrade instead of a moving target

Required outcomes:
1. shared control plane is stable under current canary/load posture
2. sticky routing by canonical `X-Zaki-User-Id` is proven
3. Postgres truth is stable and documented
4. workspace contract is frozen
5. lifecycle and rollback contracts are explicit

Checklist:
1. freeze the architecture contract docs
2. freeze the ZAKI memory/runtime contract:
   - Postgres canonical
   - markdown projection
   - pgvector derived index under `zaki_bot`
3. verify current shared control-plane rollout evidence
4. verify PgBouncer path and connection-budget assumptions
5. verify current RWX workspace behavior and mount semantics
6. define internal control-plane to cell auth
7. define minimal secret materialization mechanism
8. define canary and rollback gates for cell rollout

Exit criteria:
1. no open ambiguity around routing identity
2. no open ambiguity around canonical memory/state truth
3. no open ambiguity around where workspace data lives
4. no open ambiguity around rollback path

## Phase 1: Minimal Cell Foundation

Purpose:
introduce the smallest real per-user cell path without overengineering

What to build:
1. single-user cell runtime mode in nullalis
2. thin control-plane proxy mode
3. small external controller service for pod lifecycle
4. cell pod manifests
5. workspace-only per-user mount
6. per-cell network policy

Nullalis changes:
1. add a cell mode pinned to one `user_id`
2. make the cell authoritative for that user's lane/session execution
3. keep drain/shutdown endpoints for lifecycle
4. keep shared control-plane mode thin: auth, route, proxy, observe

Infra changes:
1. add `nullalis-cells` workload template
2. add cell controller deployment
3. add per-cell service
4. add network policies
5. add resource classes for standard cells
6. mount shared RWX PVC with per-user `subPath` at `/workspace`
7. set `HOME=/workspace/.home`
8. give private `emptyDir` to `/tmp`

Explicit non-goals in this phase:
1. no CRD/operator
2. no adoptable warm-pool handoff
3. no premium tier yet
4. no direct public ingress to user cells

Exit criteria:
1. one test user can be created on demand as a cell
2. that user's requests route to the same cell while warm
3. the cell cannot see sibling users' workspace paths
4. the cell survives restart with canonical state intact

## Phase 2: Capability Cutover

Purpose:
make the cell the real hosted machine for opted-in users

What changes:
1. full user runtime executes inside the cell
2. shared control plane stops owning that user's lane/session execution
3. user tools run inside the cell
4. workspace behavior matches local mental model

Policy shift in this phase:
1. reduce in-app command restrictions for users in cell mode
2. keep only the invariant walls described above
3. let the agent use the machine more naturally

Practical meaning:
1. broad shell/git/file/browser behavior is allowed in the cell
2. the feeling becomes closer to local Codex/OpenHands-style usage
3. the hard limit is the pod boundary, not the old shared-process policy maze

Exit criteria:
1. cell-backed users experience the cell as the authoritative runtime
2. no split-brain between shared gateway execution and cell execution
3. no hidden fallback to shared-process execution except explicit rollback mode

## Phase 3: Canary Rollout

Purpose:
prove the model with real cohorts before broad rollout

Rollout sequence:
1. internal/test users
2. tiny canary cohort
3. staged percentage rollout
4. broad standard-tier rollout

Metrics to watch:
1. cell cold-start latency
2. cell warm-hit latency
3. pod churn
4. restart rate
5. drain correctness
6. PgBouncer/Postgres pressure
7. memory pressure and OOMs
8. route correctness by `user_id`
9. isolation correctness

Rollback triggers:
1. routing mismatch
2. cross-user mount or data exposure risk
3. unacceptable cold-start or restart churn
4. DB pressure outside agreed limits
5. user-facing reliability regression

Exit criteria:
1. canary is boring
2. rollback path is proven
3. standard-tier economics are understood from measurement, not guesswork

## Phase 4: Standard Tier Production

Purpose:
make per-user cells the normal hosted experience

What becomes standard:
1. active hosted users run in per-user cells
2. shared control plane remains shared
3. cells are created on demand and reaped on idle TTL
4. substrate walls, not app policies, are the main safety boundary

Operator posture:
1. tune requests/limits from measured behavior
2. tune idle TTL from measured real usage
3. keep standard cells on shared node pools
4. keep observability and rollback always available

## Phase 5: Premium And Advanced Classes

Purpose:
layer resource classes and specialized placement on top of the same model

What may be added later:
1. premium cells with higher requests/limits
2. dedicated pools or namespaces
3. denser or more advanced storage models
4. optional user-tunable TTL within operator bounds
5. environment-specific cells for special network reach

Important:
1. premium is a placement and quota difference
2. premium is not a separate product architecture

## What We Should Not Build Yet

1. CRD/operator-first orchestration
2. smart warm-pool adoption
3. per-user Postgres credential issuance
4. blanket secret replication into K8s
5. lane-per-pod or lane-per-machine model
6. custom scheduler logic
7. direct ingress hacks to route straight to user pods

## Deliverables By Stage

Phase 0 deliverables:
1. frozen docs
2. baseline evidence references
3. clear go/no-go prerequisites

Phase 1 deliverables:
1. cell runtime mode
2. thin proxy mode
3. minimal controller
4. cell manifests
5. network/storage/secret contract

Phase 2 deliverables:
1. authoritative cell execution for opted-in users
2. reduced in-app policy posture for cell users
3. no split-brain ownership

Phase 3 deliverables:
1. canary reports
2. rollback reports
3. measured density/cost/latency data

Phase 4 deliverables:
1. standard-tier production rollout
2. stable operator runbook

## Founder Summary

This plan means:
1. first we get the current shared foundation boring and trustworthy
2. then we add full per-user nullalis cells
3. once a user is in a cell, the agent can feel much more like it owns a real machine
4. we stop depending on lots of in-app restrictions and let Kubernetes provide the main walls
5. rollout stays staged, measured, and reversible

## One-Line Summary

Get the baseline stable first, then roll out full per-user nullalis cells in phases so each user gets a real hosted machine boundary, most app policies can relax, and the product starts to feel like a durable digital life computer instead of a shared gated runtime.
