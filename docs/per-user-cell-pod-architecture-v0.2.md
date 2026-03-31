# Per-User Cell Pod Architecture v0.2

Status: proposed hosted `v0.2` architecture  
Owner lane: platform/runtime  
Scope: full per-user cell pods for hosted nullalis without overengineering the control plane

## Goal

Give each active user a real Kubernetes-backed execution boundary that feels like "their machine" while preserving the existing nullalis user identity, lane model, and Postgres-first runtime truth.

This document is the cleaned-up `v0.2` version of the external full-design draft. It keeps the strong parts of that proposal and corrects the parts that were too optimistic, too heavy, or out of alignment with current repo truth.

## Core Decision

Hosted `v0.2` target:
1. shared control plane stays shared
2. one full nullalis cell pod per active `user_id`
3. `session_key` lanes remain inside that pod
4. Postgres remains canonical truth
5. workspace remains the user's durable file/artifact surface

This is a stronger and more direct target than the incremental execution-cell contract alone. It is closer to the intended product model: one user, one machine-like hosted cell.

## What This Corrects From The Earlier Draft

The external draft got the main direction right: full per-user cell pods are the cleanest strong-wall design.

This `v0.2` revision changes these details:
1. shared control plane should be thin: auth, routing, lifecycle, observability
2. once a user is on a cell, the cell owns lane/session execution for that user
3. avoid warm-pool adoption and mutable live-pod handoff in `v0.2`
4. avoid per-user Postgres credentials as a default model
5. avoid blanket cloning of every user secret into Kubernetes Secret objects
6. do not oversell burstability or density; start conservative and measure
7. prefer the existing shared RWX workspace substrate with per-user mount scope over per-user RWO PVCs for the first hosted cut

## Why Full Per-User Pods

Options considered:
1. shared pod + stronger sandboxing
2. per-user execution pods for only dangerous tools
3. full per-user cell pods

Decision:
1. shared pod + sandboxing is still useful as a safety layer, but not the final hosted boundary
2. split execution pods are a valid transition, but they keep the agent mentally split across runtimes
3. full per-user cell pods match the product goal most directly: the agent has a real per-user machine boundary

## Identity Model

This stays frozen:
1. `user_id` = cell owner
2. `session_key` = lane inside the cell
3. lanes remain `main`, `thread:*`, `task:*`, `cron:*`

Meaning:
1. the pod boundary is per user, not per lane
2. the cell hosts all of that user's lanes
3. lane semantics do not disappear just because the runtime boundary becomes a pod

## Plain-English Architecture

Think of the hosted system as two layers:

1. control plane
   - ingress
   - auth/API
   - routing/broker
   - pod lifecycle controller
   - metrics and audit
2. user cell
   - one nullalis runtime pinned to one `user_id`
   - one visible workspace mount for that user
   - all tools execute there
   - all lane/session activity for that user happens there

Mental model:
1. control plane is the receptionist
2. the user cell pod is the user's hosted machine

## Shared Vs Per-User

Shared:
1. ingress / edge routing
2. `zaki-api` auth, account, billing, app orchestration
3. thin nullalis broker/control-plane role
4. Postgres and PgBouncer
5. cluster observability
6. pod lifecycle controller

Per-user:
1. full nullalis runtime pinned to one `user_id`
2. workspace mount at `/workspace`
3. lane/session execution
4. tool execution
5. user-scoped CLI installs and caches under `HOME=/workspace/.home`
6. user-scoped materialized secrets when needed

## The Biggest Design Correction: Ownership

The earlier draft blurred ownership between shared `nullalis gateway` and the cell pod.

`v0.2` rule:
1. the control plane does not remain the long-term owner of user lane/session execution after the cell is authoritative
2. the control plane routes, authenticates, observes, and drains
3. the user cell runs the user's actual runtime and lane/session activity

That keeps one clear owner for each user turn.

## Storage Model

### Canonical Truth

Canonical truth stays where it already belongs:
1. Postgres for state, messages, schedules, config, secret metadata, memory truth, and pgvector index state
2. workspace for user-visible files, repos, markdown projection, skills, screenshots, and other durable artifacts

### `v0.2` Recommendation

Use the existing shared RWX storage class, but mount only the user's workspace path into the cell:
1. shared RWX PVC remains the cluster substrate
2. the user cell mounts `users/<user_id>/workspace` via `subPath`
3. mount it inside the pod as `/workspace`
4. set `HOME=/workspace/.home`
5. provide private `emptyDir` for `/tmp`

Why this wins for `v0.2`:
1. it preserves current local/runtime semantics best
2. it reuses the repo's current shared workspace model
3. it avoids per-user PVC sprawl and node pinning
4. it avoids restore-latency complexity from ephemeral+S3-first workspace boot

Non-goal for `v0.2`:
1. do not mount shared `/data` into the user cell

Future alternatives:
1. per-user PVC for premium or special workloads
2. ephemeral+restore for dense or disposable classes

## Secret Model

Principle:
1. secrets remain canonically managed by the existing tenant secret/state system
2. the cell only receives what it needs

`v0.2` rules:
1. do not create a distinct per-user Postgres DSN by default
2. do not blanket-clone all user secrets into Kubernetes Secret objects
3. materialize only the required user secrets for the active cell
4. prefer file-based or scoped-env injection only for the secrets actually needed by the runtime/tools
5. never inject global infra secrets into the user cell

This keeps the cluster from becoming the long-term secret source of truth.

## Routing Model

Use the existing canonical routing identity:
1. `X-Zaki-User-Id` remains the canonical hosted user routing key
2. the control plane resolves `user_id -> cell service/pod`
3. the control plane proxies to the cell over internal service DNS

`v0.2` routing recommendation:
1. ingress -> shared control plane
2. shared control plane -> `nullalis-cell-<user_id>` internal service
3. no direct public ingress to user cell pods
4. no custom ingress tricks that directly bind user headers to pod backends

This is more standard and debuggable than direct ingress-to-pod routing.

## Lifecycle Model

`v0.2` keeps lifecycle simple:
1. create cell on first request or explicit prewarm
2. keep it warm while active
3. reap it after idle TTL
4. recreate on failure

Important simplification:
1. no adoptable warm-pool pods in `v0.2`
2. no mutable live reassignment of a running pod from one user to another

Warm pools can come later if cold-start data proves they are worth the complexity.

## Resource Model

Use burstable resource classes, but be honest about what that means:
1. requests reserve minimum guaranteed resources
2. limits set the ceiling if the node has headroom
3. bursts improve feel
4. bursts do not equal guaranteed unlimited power

`v0.2` guidance:
1. start with conservative density targets
2. treat any `users-per-node` number as a measurement question, not a truth claim
3. plan tiers, but prove standard first

Suggested starting point:
1. standard: low requests, moderate limits
2. premium: higher requests and limits, separate quotas/node pools if needed

## Network Policy

The cell should be able to do useful user work while staying fenced:
1. allow DNS
2. allow outbound public internet
3. allow explicitly required shared services such as PgBouncer/Postgres if the runtime needs them directly
4. deny other user pods
5. deny Kubernetes API by default
6. deny metadata service and private/internal ranges by default

Important correction:
1. metadata blocking must explicitly cover `169.254.0.0/16`, not just RFC1918 ranges

## Controller Shape

For `v0.2`, use a small separate controller service:
1. it is not on the hot path for every token streamed to the user
2. it manages cell creation, deletion, health, and idle cleanup
3. it should be simple HTTP + Kubernetes API orchestration

Do not start with:
1. a CRD/operator
2. a custom scheduler
3. a very smart warm-pool system

Those can come later if the plain model proves insufficient.

## Minimal App Changes

What nullalis needs:
1. a single-user cell mode pinned to one `user_id`
2. a shared control-plane mode that proxies routed user requests to the correct cell
3. graceful drain/shutdown endpoints for lifecycle
4. startup wiring that treats the cell as authoritative for that user's lane/session execution

What nullalis does not need first:
1. a brand-new abstract runtime hierarchy for every possible future substrate
2. live pod adoption semantics
3. a second partial execution surface that splits the agent between shared and per-user runtimes

## Migration Path

Phase 0:
1. keep shared control plane stable
2. keep sticky routing and Postgres truth stable
3. confirm workspace and state contracts are correct

Phase 1:
1. introduce the minimal controller
2. introduce single-user cell mode
3. launch standard-tier user cells with workspace-only mounts
4. route a canary cohort through cells

Phase 2:
1. progressively move users to cell-backed execution
2. measure cold starts, steady-state latency, pod churn, PG pressure, and node packing
3. adjust requests/limits and idle TTL from measured behavior

Phase 3:
1. add premium resource tiers
2. add denser optimizations only after the base model is boring

## Explicit Non-Goals For `v0.2`

1. no CRD/operator-first design
2. no adoptable warm-pool handoff protocol
3. no direct ingress-to-user-pod hackery
4. no per-user PG credential issuance as the primary model
5. no blanket secret replication into Kubernetes
6. no requirement that standard-tier pods be live-migratable

## Why This Is Different From The Incremental Execution-Cell Contract

The execution-cell contract is still useful, but it describes the shortest migration seam from today.

This document is stronger:
1. it chooses full per-user pods as the hosted `v0.2` target
2. it treats partial per-tool isolation as a transition, not the destination
3. it makes the pod boundary the real product boundary

## One-Line Summary

Hosted `v0.2` should be: shared control plane, one full nullalis cell pod per active user, canonical Postgres truth, workspace-only per-user mounts from shared RWX storage, thin lifecycle controller, no adoptable warm pools, and no split-brain ownership between shared gateway and cell runtime.
