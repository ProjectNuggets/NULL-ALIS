---
tags: [prose, prose/docs]
---

# Sprint 12 — HA + DR — PARKED operator-pending (2026-04-26)

**Branch:** `sprint/closure-pending-docs` (off `main` tip `a7a2ec8`)
**Opened:** 2026-04-26
**Status:** PARKED — every item is a k8s/infra topology change in zaki-infra (replicas, NFS mitigation, ResourceQuota, ArgoCD AppProject scoping, PDBs) plus written runbooks. The one nullalis-side prerequisite (cell-pod flip enabling >1 replica) is itself deferred per Nova directive.

## Goal

Eliminate single points of failure that take the service down for paying users. Define + test recovery time / recovery point objectives.

## Why parked

S12.1 (replicas > 1) is the keystone item — without it, S12.2/S12.5/S12.6/S12.7 are either unnecessary (PDB on a 1-replica deployment is meaningless) or severely limited (NFS-SPOF mitigation matters more once concurrent writers exist). And S12.1 itself blocks on the cell-pod architecture flip, which is **explicitly deferred per Nova directive** in favor of shared-runtime simplicity for v0.1.

**Today's posture:** single-replica nullalis on a single DO droplet, NFS volume mounted from a single NFS droplet, no documented RTO/RPO, no DR runbook. Acceptable for v0.1 single-user beta; the moment a paying user with uptime expectations onboards, S12 becomes blocking.

## Operator-pending items

| ID | Item | Where | Trigger to unpark | Acceptance criteria |
|---|---|---|---|---|
| **S12.1** | nullalis replicas > 1 (staged canary) | `zaki-infra/charts/zaki-bot/values.yaml` `replicaCount` | Cell-pod architecture flip (currently deferred) AND first paying user with uptime expectations | Two pods both serving traffic; no state-race regressions in 48-hour soak; sticky-session routing documented |
| **S12.2** | NFS data-SPOF mitigation | `zaki-infra/terraform/storage.tf` decision: dual-AZ NFS rsync OR DO Managed Storage (block) OR DO Spaces + cache | NFS droplet hardware failure simulation OR first paying user | One node loss does not lose persistent state; failover documented; restore drill < RTO |
| **S12.3** | RTO/RPO targets documented + tested | `zaki-infra/docs/rto-rpo.md` | Customer SLA conversation OR first paying user | RTO ≤ 15 min, RPO ≤ 5 min validated via simulated failure (or operator-defined targets if these don't fit) |
| **S12.4** | Multi-region DR plan on paper (runbook) | `zaki-infra/docs/dr-runbook.md` | Customer compliance questionnaire OR EU-region paying user | Runbook exists; cross-region restore procedure walked-through (paper exercise OK) |
| **S12.5** | `ResourceQuota` + `PriorityClass` per namespace | `zaki-infra/cluster/quotas/` | Multi-tenant cell-pod flip OR resource-exhaustion incident | Each namespace has documented CPU/memory ceiling; critical pods (gateway, daemon) have higher PriorityClass than batch jobs |
| **S12.6** | ArgoCD `AppProject` scoping | `zaki-infra/argocd/projects/` | Second cluster OR audit requirement | Each app bound to specific repo + cluster + namespace; cross-app blast radius limited |
| **S12.7** | `PodDisruptionBudget` for every >1 replica service | `zaki-infra/charts/*/values.yaml` (zaki-api, zaki-web, zaki-website, pgbouncer, post-S12.1 nullalis) | After S12.1 ships AND first node-drain incident | All multi-replica services have PDB; node drain doesn't take service to zero |

## Cross-cut considerations

- **S12.1 blocks on cell-pod flip:** today nullalis holds in-process state (session_cache, daemon scheduler tick, daemon supervisor). Two pods would race on cron tick + on session ownership. Cell-pod architecture (one pod per tenant cell) eliminates the race by partitioning state. Until cell-pod ships, S12.1 stays parked. **Per Nova directive: cell-pod is deferred for v0.1.** Re-evaluate quarterly.
- **NFS vs block-storage trade:** NFS lets multi-replica nullalis share workspace files; block storage forces sticky-session routing. Pick depends on whether v1 state is per-session (NFS works) or per-cell-pod (block storage works). Tied to cell-pod decision.
- **DO Managed Postgres + PgBouncer already HA:** the database tier is already covered by managed-Postgres replication (S10.6 documents PITR). S12 is about the application tier and the file-system tier, not the database tier.
- **S14.9 pentest** can include DR test: hire pentester to simulate availability attacks; their report informs S12.3 RTO/RPO targets.

## What in-repo work this enables (not blocks)

S12 closure does not block any in-repo nullalis work today. The cell-pod architecture decision is the gating prerequisite, not S12 itself.

Future in-repo work that S12 unlocks:
- Distributed cron leader election (today: single-process daemon owns the tick; multi-replica needs Postgres advisory lock OR Redis leader)
- Session-affinity-aware routing (today: in-memory session_cache; multi-replica needs sticky routing OR Postgres session_cache backing)
- Multi-cell-pod fanout (already partial via cell_k8s_api but not exercised in production)

## Sprint 12 DoD (at unpark time)

- Simulated node drain doesn't kill service
- RTO clocked ≤ target on restore drill
- DR runbook exists and walked-through
- ResourceQuota + PDB present on every multi-replica service
- ArgoCD AppProjects scoped per app

## Tracking

This doc IS the Sprint 12 close-out. When the cell-pod flip lands AND a paying user with uptime expectations exists, branch `repair/sprint-12-ha-dr` off zaki-infra, follow Sprint 1's `c329e9a` PR pattern, mark items `[x]` in `CLOSURE_CHECKLIST.md` as they ship.

**Closure rule:** Sprint 12 is "closed" for V1 purposes when this doc exists with explicit triggers. Real execution happens at unpark, gated on cell-pod flip.
