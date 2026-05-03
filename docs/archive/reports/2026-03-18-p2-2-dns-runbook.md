---
tags: [prose, prose/docs]
---

# P2-2 DNS Closure Runbook (Internal Staging)

Date: 2026-03-18  
Scope: `zaki-bot-staging` / `nullclaw` / `agent-staging.zaki.com`

## Goal
Close `P2-2` by proving staging DNS resolves end-to-end and by enforcing DNS as a hard smoke gate.

## Preconditions
1. Ingress exists: `deploy/k8s/zaki-bot/07-ingress.yaml`
2. Host is `agent-staging.zaki.com`
3. TLS secret exists: `agent-staging-zaki-com-tls`
4. Postgres path already healthy (`state_effective=postgres`, `degraded=false`)

## Step 1: Verify ingress endpoint
```bash
kubectl -n zaki-bot-staging get ingress nullclaw -o wide
kubectl -n zaki-bot-staging get ingress nullclaw -o jsonpath='{.status.loadBalancer.ingress[*].ip}{"\n"}{.status.loadBalancer.ingress[*].hostname}{"\n"}'
```

## Step 2: Update authoritative DNS
Point `agent-staging.zaki.com` to the ingress endpoint from Step 1.

Internal-only posture:
1. Keep ingress source-range restrictions in place.
2. Do not expose unrelated public routes.
3. Keep TLS on `agent-staging.zaki.com`.

## Step 3: Verify DNS from operator host
```bash
getent ahosts agent-staging.zaki.com || nslookup agent-staging.zaki.com || dig +short agent-staging.zaki.com
curl -fsS https://agent-staging.zaki.com/health
```

## Step 4: Verify DNS from inside cluster
```bash
kubectl -n zaki-bot-staging run dnscheck --image=busybox:1.36 --restart=Never --rm -i -- \
  nslookup agent-staging.zaki.com
```

## Step 5: Enforce strict smoke gates (hard pass/fail)
```bash
BASE_URL=https://agent-staging.zaki.com \
INTERNAL_TOKEN=... \
USER_ID=test-user-1 \
TELEGRAM_BOT_TOKEN=... \
WEBHOOK_BASE_URL=https://agent-staging.zaki.com \
TELEGRAM_WEBHOOK_SECRET=... \
EXPECT_BASE_URL_DNS=true \
EXPECT_WEBHOOK_BASE_URL_DNS=true \
EXPECT_STATE_EFFECTIVE=postgres \
EXPECT_NOT_DEGRADED=true \
PGBOUNCER_EXPECTED=true \
./deploy/k8s/zaki-bot/smoke.sh
```

Expected:
1. DNS checks pass for both base and webhook host.
2. Runtime state checks pass (`postgres`, non-degraded).
3. Smoke exits `0`.

## Rollback (if DNS cutover fails)
1. Revert DNS record to previous target.
2. Re-run host and in-cluster DNS checks.
3. Keep staging blocked until strict smoke is green again.

