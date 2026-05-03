---
tags: [prose, prose/docs]
---

# Sprint 11 — Security Hardening Full — PARKED operator-pending (2026-04-26)

**Branch:** `sprint/closure-pending-docs` (off `main` tip `a7a2ec8`)
**Opened:** 2026-04-26
**Status:** PARKED — every item is a k8s/infra deploy action that lives in `zaki-infra` and requires Nova/operator execution. No in-repo nullalis-side code change unblocks any of these.

## Goal

Defense in depth at the cluster level: default-deny network, mTLS between services, sealed-secrets instead of plain k8s Secrets, scheduled secret rotation, TLS cert lifecycle.

## Why parked

Every Sprint 11 item ships as zaki-infra k8s manifests + ArgoCD apps + sealed-secrets Bitnami controller install. None of it lands as a Zig code change in this repo. The pattern here mirrors Sprint 1's zaki-infra companion (`c329e9a`) and Sprint 3's S3.5/S3.6/S3.7 cross-repo carry-over: nullalis-side close-out documents the trigger + acceptance criteria; the work itself goes into a zaki-infra PR when the operator window opens.

**Today's posture:** single-replica nullalis behind Cloudflare TLS, plain k8s Secrets injected via `envFrom`, no service mesh. Acceptable for v0.1 single-tenant beta; not acceptable once any of the unpark triggers below fire.

## Operator-pending items

| ID | Item | Where | Trigger to unpark | Acceptance criteria |
|---|---|---|---|---|
| **S11.1** | NetworkPolicy default-deny + per-flow allow | `zaki-infra/cluster/networkpolicies/` | First multi-service pod compromise drill OR pentest finding | `kubectl exec pod_a -- curl pod_b:unlisted_port` denied; `kubectl exec pod_a -- curl pod_b:allowed_port` succeeds |
| **S11.2** | mTLS between services (linkerd OR istio OR app-layer) | `zaki-infra/charts/service-mesh/` | First two-service nullalis topology (post cell-pod flip OR added BFF replica) | Pod-to-pod traffic encrypted in transit; sidecar overhead documented OR app-layer mTLS cert lifecycle documented |
| **S11.3** | Sealed-secrets OR external-secrets-operator | `zaki-infra/cluster/sealed-secrets/` | Second committer added (per-secret access control becomes load-bearing) OR audit requirement | etcd has no plaintext secret contents; secret rotation doesn't require kubectl + plaintext copy in operator's clipboard |
| **S11.4** | Documented quarterly secret rotation | `zaki-infra/docs/secret-rotation-runbook.md` | First quarter after S11.3 ships | Runbook exists; first rotation logged with date + provider + rotation method |
| **S11.5** | cert-manager OR explicit Cloudflare-only decision | `zaki-infra/cluster/cert-manager/` OR `zaki-infra/docs/tls-decision.md` | Custom domain beyond chatzaki.com OR mTLS rollout (S11.2) | Either cert-manager renewing TLS automatically OR documented decision: Cloudflare terminates TLS edge, cluster-internal HTTP only, mTLS via S11.2 for service-to-service |

## Cross-cut considerations

- **Cell-pod prerequisite for S11.2:** until per-cell pod flip, nullalis is one process — service-to-service mTLS has nothing to terminate against. S11.2 effectively blocks on the cell-pod architecture decision (deferred per Nova directive).
- **Sealed-secrets vs external-secrets:** sealed-secrets (Bitnami) is simpler, fits one-cluster topology; external-secrets-operator scales to multi-cluster + AWS Secrets Manager / GCP / Vault backends. Today's footprint = single DigitalOcean cluster → sealed-secrets is the right pick. Re-evaluate at S12.1 multi-region.
- **NULLCLAW_ → NULLALIS_ env rename (S8.3 + D28):** S11.3 sealed-secrets re-encryption is a natural moment to drop NULLCLAW_ fallback shims if sunset has passed.

## What in-repo work this enables (not blocks)

S11 closure does not block any in-repo nullalis work. The reverse is not true:
- S11.4 secret rotation runbook needs nullalis to handle provider-key reload without restart (today: process-restart required for env changes). Future ticket: hot-reload provider keys.
- S11.3 sealed-secrets means nullalis can sanely declare which env vars are secrets vs config (today: ad-hoc; everything in `envFrom` is opaque). Future ticket: structured secret manifest in this repo, sealed-secret references in zaki-infra.

## Sprint 11 DoD (at unpark time)

- `kubectl exec pod_a -- curl pod_b:unlisted_port` denied
- etcd has no plaintext secret contents
- TLS cert lifecycle documented (auto OR explicit)
- Secret rotation runbook exists; first rotation logged
- Pentest re-test passes (paired with S14.9)

## Tracking

This doc IS the Sprint 11 close-out. When triggers fire, branch `repair/sprint-11-security-hardening` off zaki-infra, follow Sprint 1's `c329e9a` PR pattern, mark items `[x]` in `CLOSURE_CHECKLIST.md` as they ship, link the zaki-infra PR SHAs back to this doc.

**Closure rule:** Sprint 11 is "closed" for V1 purposes when this doc exists with explicit triggers. Real execution happens at unpark.
