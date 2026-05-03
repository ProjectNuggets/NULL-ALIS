---
tags: [prose, prose/docs]
---

# Execution Cell Contract

Status: proposed contract for hosted execution isolation  
Owner lane: platform/runtime  
Scope: define the shortest path from current V1 sandboxing to a real per-user execution cell with Kubernetes hard walls

## Goal

Define one stable execution model that keeps the existing multi-user control plane, preserves lane semantics, and upgrades powerful tool execution into a hard per-user runtime boundary.

This document is intentionally concrete. It is not a generic future-runtime brainstorm.

## Why This Exists

Current repo truth already gives us:
1. per-user runtime identity
2. per-user workspace roots
3. per-session continuity/concurrency lanes
4. tenant-aware tool context
5. V1 sandboxing for `shell` and `git_operations`

Current repo truth does **not** yet give us:
1. a mandatory per-user execution boundary for command-capable tools
2. pod/container/network limits that are always enforced for that boundary
3. a single operator contract that deployment can validate

This contract fills that gap.

## Relationship To Existing Docs

This document does not replace the existing control-plane and scale docs.

It builds on:
1. [v0.2 Operational Model Runbook](./v0.2-operational-model-agent-runbook.md)
2. [V2 Runner Architecture](./v2-runner-architecture.md)
3. [Reliability Ops Runbook](./reliability-ops-runbook.md)
4. [Session Key Policy](./session-key-policy.md)
5. [Per-User Cell Pod Architecture v0.2](./per-user-cell-pod-architecture-v0.2.md)

Interpretation rule:
1. `v0.2-operational-model-agent-runbook.md` remains the control-plane and sticky-routing truth
2. `session-key-policy.md` remains the lane and ownership truth
3. this document defines the execution boundary that command-capable tools should use

## Current State

From current code:
1. `user_id` already identifies a tenant runtime
2. `session_key` already identifies a lane inside that tenant runtime
3. `shell` and `git_operations` can optionally run through sandbox V1
4. powerful tools are still instantiated from the shared gateway-side tenant runtime

Operationally, that means:
1. user identity is already correct
2. lane identity is already correct
3. workspace scoping is already correct at the app/path layer
4. hard execution isolation is only partial and opt-in

## Frozen Identity Model

This model is frozen across all substrates.

Definitions:
1. `user_id` = cell owner
2. `session_key` = lane within the cell
3. `cell_key` = canonical execution identity for the hosted runtime boundary

Canonical mapping:
1. `cell_key = user_id`
2. `lane_key = session_key`

Interpretation:
1. one user owns one execution cell by default
2. that user's `main`, `thread:*`, `task:*`, and `cron:*` lanes run inside that cell
3. lane semantics do not disappear when we introduce a container boundary

Non-goal:
1. `session_key` is **not** the default machine boundary

## Hosted V1 Target

Hosted V1 default substrate is:
1. shared multi-user gateway/control plane
2. one per-user runner pod as the execution cell

This means:
1. the gateway stays multi-user
2. execution for command-capable tools moves into a per-user pod
3. Kubernetes becomes the hard wall for CPU, memory, filesystem mount scope, and network policy

This is the shortest path from today to a real hosted per-user cell.

## Execution Cell Definition

An execution cell is the runtime environment where powerful tools execute for one user.

Hosted V1 cell shape:
1. one runner pod per active user
2. one runner container inside that pod
3. user workspace mounted at `/workspace`
4. `HOME=/workspace/.home`
5. private `/tmp`
6. public internet access according to network policy
7. no sibling user data mounted
8. no raw Postgres DSN or shared infra secrets injected by default

The cell should feel like "the user's machine" for:
1. shell
2. git
3. CLI installs in user-space
4. SSH config and keys
5. browser/session state if later moved into the cell
6. user-maintained files and assets

## Kubernetes Hard-Wall Contract

For hosted V1, deployment must satisfy all of the following:

Filesystem wall:
1. mount only that user's workspace into the runner pod
2. do not mount shared `/data` into the runner pod
3. do not mount sibling users' paths

Network wall:
1. pod gets its own network namespace and pod IP
2. allow DNS
3. allow public egress according to profile
4. block cluster-private, metadata, and internal service ranges by default unless explicitly required

Identity wall:
1. gateway sends canonical `user_id` and `session_key` on every runner request
2. runner rejects mismatched or missing identity

Secret wall:
1. tenant secrets are materialized on demand
2. no blanket injection of all tenant secrets
3. no global infra secrets in the runner pod

Resource wall:
1. CPU limit
2. memory limit
3. ephemeral storage limit
4. restart and idle recycle policy
5. bounded concurrent executions per cell

## Hosted V1 Config Contract

Add a new execution surface:

```json
{
  "execution": {
    "substrate": "shared_process | user_pod",
    "cell_scope": "user",
    "runner_image": "ghcr.io/nullalis/runner:<sha>",
    "idle_ttl_secs": 1800,
    "workspace_mount": "workspace_only",
    "home_subdir": ".home",
    "network_profile": "public",
    "allow_private_networks": false,
    "secrets_mode": "on_demand",
    "max_execs_per_cell": 4
  }
}
```

Required meanings:
1. `substrate=shared_process` means current legacy/in-process path
2. `substrate=user_pod` means command-capable tools execute in a per-user runner pod
3. `cell_scope=user` is the only supported default for hosted V1
4. `workspace_mount=workspace_only` means only the user's workspace is mounted into the runner

## Runner RPC Contract

The control plane should talk to the runner through one substrate-neutral interface.

`POST /v1/cells/ensure`

```json
{
  "cell_key": "42",
  "cell_scope": "user",
  "user_id": "42",
  "session_key": "agent:zaki-bot:user:42:main",
  "network_profile": "public"
}
```

`POST /v1/cells/exec`

```json
{
  "request_id": "req_123",
  "cell_key": "42",
  "user_id": "42",
  "session_key": "agent:zaki-bot:user:42:thread:abc",
  "tool": "shell",
  "cwd": "/workspace",
  "argv": ["bash", "-lc", "git status"],
  "stdin_b64": null,
  "timeout_ms": 60000,
  "max_output_bytes": 1048576,
  "secret_refs": ["ssh.default", "api.github"]
}
```

`POST /v1/cells/materialize-secret`

```json
{
  "cell_key": "42",
  "user_id": "42",
  "session_key": "agent:zaki-bot:user:42:main",
  "secret_ref": "ssh.default",
  "target": "file",
  "path": "/workspace/.home/.ssh/id_ed25519",
  "mode": "0600"
}
```

`GET /v1/cells/{cell_key}/status`

`POST /v1/cells/{cell_key}/recycle`

Contract rules:
1. runner must validate `user_id`
2. runner must preserve `session_key` for audit and lane attribution
3. runner must not accept execution without a valid `cell_key`

## Tool Migration Order

Move these first:
1. `shell`
2. `git_operations`

Reason:
1. they are already the V1 sandbox surface
2. they carry the highest cross-tenant blast radius
3. they give the biggest trust win for the smallest code move

Move later:
1. browser automation
2. screenshot/download-capable tools
3. optional HTTP client tooling if we later want all outbound action to originate from the cell

Keep in the shared gateway runtime initially:
1. memory tools
2. scheduler/message tools
3. tenant state orchestration
4. retrieval and memory topology

## Shortest Path From V1

Phase 1:
1. freeze this contract
2. add `execution.substrate`
3. implement a substrate-neutral `ExecutionClient`
4. keep `shared_process` as the initial backend

Phase 2:
1. implement `user_pod` backend
2. move `shell`
3. move `git_operations`
4. keep V1 sandboxing as fallback for non-Kubernetes or local paths

Phase 3:
1. add pod lifecycle management
2. add secret materialization
3. add network policy validation
4. canary one tenant cohort

Phase 4:
1. expand to all command-capable tenants
2. move more tools only if needed

## Deployment Validation Requirements

Deployment is not complete unless it can prove all of the following for `substrate=user_pod`:

1. same `user_id` resolves to the same cell while that cell is warm
2. the runner pod mounts only that user's workspace
3. runner pod CPU/memory limits are present in the live manifest
4. runner pod has public egress but cannot reach blocked internal ranges unless explicitly approved
5. `shell` and `git_operations` actually execute inside the runner pod, not in the gateway container
6. runner logs and audit events preserve both `user_id` and `session_key`

## Future Substrates

This document does not block future substrates.

Possible later substrates:
1. `nested_user_cell_manager`
2. `appliance_native`

Those are explicitly out of scope for hosted V1.

The frozen part remains:
1. `cell_key = user_id`
2. `lane_key = session_key`

## Sweep Notes

After sweeping the current design docs, the repo is internally consistent on these points:
1. control plane scale model is "sticky route by user to a shared gateway cell"
2. lane model is "keep lanes inside the user runtime"
3. V1 sandbox is opt-in and limited in scope
4. V2 runner doc already points toward a tenant-scoped runner

The main missing piece is not design direction.  
It is the concrete operator/runtime contract for the hosted execution boundary.
