# V2 Runner Architecture (Design Only)

Status: design document for next execution slice  
Scope: preserve full shell power with stronger tenant isolation than V1

## Goal

Deliver strong tenant-isolated execution for command-capable tools without reducing agent utility:
1. keep broad shell/git capability for legitimate user tasks
2. prevent cross-tenant filesystem/process data access
3. keep operational behavior auditable and rollback-safe

## High-Level Architecture

V2 introduces a tenant-scoped runner service:
1. gateway/runtime resolves tenant user identity
2. tool execution requests are dispatched to tenant runner
3. runner executes command in tenant-isolated environment
4. stdout/stderr/exit metadata is returned to gateway and surfaced to agent

Core model:
1. per-tenant warm runners (not one-off per command by default)
2. workspace-root mount policy for each tenant
3. profile-based outbound network allowlists
4. strict audit trail for every execution request

## Isolation Model

Execution boundary:
1. each tenant runs in isolated runtime boundary (container namespace/jail)
2. only tenant workspace path is mounted read-write
3. host/global paths are not mounted
4. shared mutable state access is blocked by policy

Identity and authorization:
1. gateway attaches canonical tenant identity to each execution request
2. runner validates identity claim and rejects mismatches
3. cross-tenant execution is rejected at dispatch layer and runner layer

## Security and Policy

Policy profiles:
1. standard profile: no public network by default, allowlist only
2. integration profile: explicit domain/IP allowlist for approved workflows
3. privileged profile: available only for controlled/admin lanes

Controls:
1. execution timeout
2. max output bytes
3. CPU/memory process limits
4. process count caps
5. audit event signing (optional)

## Operational Model

Runner lifecycle:
1. warm runner per active tenant
2. idle TTL-based recycle
3. health-check + readiness probe
4. bounded restart backoff on failures

Capacity:
1. per-runner queue cap and backpressure
2. global cell-level caps to prevent noisy-neighbor starvation
3. deterministic overload responses and retry hints

Observability:
1. queue depth per tenant
2. exec latency p50/p95/p99 per profile
3. rejection counters by reason (`auth`, `policy`, `capacity`, `timeout`)
4. runner churn and restart metrics

## Migration Plan From V1

Phase A (shadow):
1. keep V1 as source of truth
2. mirror execution intent to runner in non-authoritative mode
3. compare output/error/latency parity

Phase B (canary):
1. enable V2 for one channel or tenant cohort
2. enforce strict rollback gates on error and isolation signals
3. collect canary artifacts and decision report

Phase C (progressive):
1. expand tenant cohorts by staged percentages
2. hold/rollback on gate breach
3. keep V1 code path as emergency fallback until full cutover is stable

## Rollback Strategy

1. feature flag route back to V1 path only
2. keep runner state non-authoritative during early rollout
3. preserve request IDs for end-to-end incident correlation
4. publish rollback artifact with trigger reason and cohort impact

## Acceptance Gates For V2 Activation

1. no cross-tenant access in isolation tests
2. no regression in existing profile-B error gates
3. latency regression bounded by agreed threshold
4. deterministic behavior under runner restart/failure scenarios
5. auditable command trail for all runner-executed turns
