# nullALIS ZAKI BOT Kubernetes Deployment Pack

This folder is the deployment handoff package for running `nullALIS` as the dedicated `ZAKI BOT` backend in a namespace-based K8s cluster.

## Scope
This package is for the shared pool model with tenant isolation under `/data/users/{user_id}`.

Compatibility note:
- This deployment pack still uses `nullclaw` resource names, labels, lock-file names, and metric prefixes.
- Keep those names unless you also migrate the manifest objects and dashboards together.

It includes:
- Namespace, Secret template, ConfigMap, RWX PVC
- Deployment with drain/shutdown lifecycle hooks
- Litestream sidecar config for SQLite WAL replication to S3
- Service, Ingress, PDB, HPA
- ServiceMonitor for Prometheus Operator
- End-to-end smoke test script
- Restore drill script for sampled tenants

## Files
- `00-namespace.yaml`
- `01-secrets-template.yaml`
- `02-configmap.yaml`
- `03-pvc.yaml`
- `04-serviceaccount.yaml`
- `05-deployment.yaml`
- `06-service.yaml`
- `07-ingress.yaml`
- `08-pdb.yaml`
- `09-hpa.yaml`
- `10-servicemonitor.yaml`
- `11-litestream-configmap.yaml`
- `12-prometheusrule.yaml`
- `kustomization.yaml`
- `smoke.sh`
- `restore-drill.sh`
- `ZAKI_BACKEND_HANDOFF.md`
- `ZAKI_FRONTEND_HANDOFF.md`

## Runtime defaults
- Profile: `zaki_bot`
- Default model: `openrouter/moonshotai/kimi-k2.5`
- Tenant mode: enabled

## Integration handoff docs

- Backend contract: `deploy/k8s/zaki-bot/ZAKI_BACKEND_HANDOFF.md`
- Frontend UX contract: `deploy/k8s/zaki-bot/ZAKI_FRONTEND_HANDOFF.md`

## Prerequisites
1. RWX storage class exists.
2. Ingress controller supports `nginx.ingress.kubernetes.io/upstream-hash-by`.
3. TLS secret exists for `agent-staging.zaki.com`.
4. ZAKI backend can call nullALIS internal APIs with `X-Internal-Token`.
5. ZAKI backend sends canonical `X-Zaki-User-Id` for app chat calls.

## Required value replacement
Update these fields before apply:
1. `03-pvc.yaml`: `storageClassName`.
2. `05-deployment.yaml`: image tag.
3. `01-secrets-template.yaml`:
- `INTERNAL_SERVICE_TOKEN`
- `OPENROUTER_API_KEY`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_WEBHOOK_SECRET`
 - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (if not using workload identity)
4. `07-ingress.yaml`: host and TLS secret if different.
5. `02-configmap.yaml`:
- `PUBLIC_BASE_URL`, `TELEGRAM_ALLOW_FROM` policy
- `LITESTREAM_S3_BUCKET`, `LITESTREAM_S3_PREFIX`
- `AWS_REGION` (if required by your S3 endpoint)

## Apply order
```bash
kubectl apply -k deploy/k8s/zaki-bot
kubectl -n zaki-bot-staging rollout status deploy/nullclaw
```

## Post-deploy verification
1. Check pods and probes.
```bash
kubectl -n zaki-bot-staging get pods -l app.kubernetes.io/name=nullclaw
kubectl -n zaki-bot-staging describe deploy/nullclaw
```
2. Check metrics.
```bash
kubectl -n zaki-bot-staging port-forward svc/nullclaw 3000:80
curl -s http://127.0.0.1:3000/metrics | head -n 40
```
3. Run smoke test.
```bash
BASE_URL=https://agent-staging.zaki.com \
INTERNAL_TOKEN=... \
USER_ID=test-user-1 \
TELEGRAM_BOT_TOKEN=... \
WEBHOOK_BASE_URL=https://agent-staging.zaki.com \
TELEGRAM_WEBHOOK_SECRET=... \
./deploy/k8s/zaki-bot/smoke.sh
```
4. Run restore drill for sampled users.
```bash
NAMESPACE=zaki-bot-staging \
LITESTREAM_S3_BUCKET=... \
LITESTREAM_S3_PREFIX=nullclaw/users \
USER_IDS=test-user-1,test-user-2 \
./deploy/k8s/zaki-bot/restore-drill.sh
```

## Operational notes
1. Graceful rollout behavior is enabled.
- `preStop` calls `/internal/drain` then `/internal/shutdown`.
- Readiness returns `503` while draining.
- Gateway exits after in-flight requests finish.

2. Consistent user routing is enabled at ingress.
- Hash key: `X-Zaki-User-Id` for app traffic.
- Hash key fallback: `user_id` query arg for Telegram webhook traffic.

3. Telegram connect/disconnect API is active.
- Connect calls Telegram `setWebhook` + `getWebhookInfo`.
- Disconnect calls Telegram `deleteWebhook`.

4. Telegram webhook ingress is tenant-scoped.
- In tenant mode, `user_id` query param is required.
- Gateway loads per-user `telegram.json` + `secrets/telegram_bot_token`.
- Webhook secret-token validation is enforced per user.
- Gateway updates per-user `channel_state.json` with latest Telegram chat id.
- Tenant cron deliveries can use this state for proactive Telegram sends.

5. Tenant ownership lock is enabled for write paths.
- Lock file: `/data/users/{user_id}/.nullclaw-owner.lock`
- Lock conflicts return HTTP `409` with retry semantics.
- Conflict metric: `nullclaw_gateway_tenant_lock_conflicts_total`

6. Gateway concurrency is bounded and backpressure-safe.
- One acceptor thread + worker pool (`gateway.max_workers`).
- Bounded queue (`gateway.max_queued_requests`).
- Saturation returns `503 {"error":"overloaded","retry_hint":"retry shortly"}`.

7. SQLite backup/restore is Litestream-backed.
- Sidecar replicates all `memory.db` files under `${TENANT_DATA_ROOT}` using directory watcher mode.
- Replicas are uploaded under `s3://${LITESTREAM_S3_BUCKET}/${LITESTREAM_S3_PREFIX}/{user_id}/memory.db`.
- `restore-drill.sh` verifies sampled user replicas are restorable.

8. Alert rules are included for production signals.
- Lock conflict rate (`nullclaw_gateway_tenant_lock_conflicts_total`)
- Drain reject rate (`nullclaw_gateway_drain_rejected_total`)
- Telegram webhook reject spikes (`nullclaw_gateway_telegram_webhook_rejected_total`)
- Chat stream error ratio (`nullclaw_gateway_chat_stream_errors_total / _total`)
- Litestream lag (`litestream_replica_lag_seconds`)

## Readiness status
Current status: **ready for staging integration and production rollout after environment values are filled**.

## Next step in the plan
1. ZAKI backend integration sprint:
- Wire UI controls to new nullALIS APIs.
- Pass `X-Zaki-User-Id` and `X-Internal-Token` on all `/api/v1/*` calls.
- Use `/api/v1/chat/stream` SSE proxy end to end.

## ARM Linux image build
Validated binary cross-build command:
```bash
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

Build/push ARM64 runtime image:
```bash
docker buildx build \
  --platform linux/arm64 \
  --target release \
  -t registry.example.com/nullclaw:zaki-bot-arm64 \
  --push .
```

## Rollback
```bash
kubectl -n zaki-bot-staging rollout undo deploy/nullclaw
```

## Troubleshooting quick checks
1. 401 on internal endpoints: invalid or missing `X-Internal-Token`.
2. 503 on app chat: pod is draining; retry another pod.
3. Telegram webhook failures: verify `user_id` query param, per-user bot token secret, and per-user webhook secret token.
