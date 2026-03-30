# ZAKI Nullalis Runtime Contract

This document defines the production runtime contract for running Nullalis as the
internal agent service behind `zaki-prod`.

Current validated baseline:
- `profile = "zaki_bot"`
- primary chat model = `together-ai/moonshotai/kimi-k2.5`
- chat fallback chain = `openrouter`
- embedding provider = `together-ai`
- `state.backend = "postgres"`
- `scheduler_backend = "postgres"`
- `degraded = false`

Frozen ZAKI memory contract:
- Postgres is the canonical durable source of truth.
- Markdown is a projection and manual-edit mirror, not the canonical store.
- Tenant runtime topology is `zaki_dual` in tenant+postgres mode.
- pgvector is a derived index only.
- pgvector must live in `zaki_bot.memory_embeddings`, never `public.memory_embeddings`.
- pgvector rows must be keyed by `(user_id, key)` with `PRIMARY KEY (user_id, key)`.

Related design note:
- durable automation uses the contract in [scheduler-automation-contract.md](./scheduler-automation-contract.md)
- `schedule` is the user-facing durable automation API
- heartbeat is a wake/reconcile lane, not the source of exact-time scheduling

## Ownership

- `NULL-ALIS` owns:
  - config schema
  - provider/model semantics
  - secret consumption behavior
  - startup validation
  - image build and publishing
- `zaki-infra` owns:
  - Helm/ArgoCD deployment
  - ConfigMap values for non-secret runtime config
  - Secret references and service wiring
- `zaki-prod` owns:
  - backend proxy to Nullalis
  - service discovery via `NULLCLAW_BASE_URL`
  - fail-fast behavior and diagnostics for the browser-facing agent route

## Config Split

1. Built-in defaults in Nullalis
2. Global non-secret runtime config from `zaki-infra`
3. Secrets injected by Kubernetes and consumed by Nullalis
4. Per-user state/config in tenant storage and Postgres
5. Per-request overrides in API payloads only

Never store per-user config in Helm values, ConfigMaps, or env vars.

## Required Global Config

The deployed config file should contain non-secret settings only:

- `profile: "zaki_bot"`
- `agents.defaults.model.primary: "together-ai/moonshotai/kimi-k2.5"`
- `agents.defaults.model.fallbacks[0]: "openrouter/<validated-fallback-model>"`
- `models.providers["together-ai"].base_url: "https://api.together.xyz/v1"`
- `models.providers["openrouter"].base_url: "https://openrouter.ai/api/v1"` when fallback is enabled
- `gateway.host`
- `gateway.port`
- `tenant.enabled`
- `tenant.data_root`
- `state.backend: "postgres"`
- `state.postgres.schema`
- `memory.profile: "postgres_hybrid"`
- `memory.backend: "postgres"`
- `memory.search.store.kind: "pgvector"`
- `memory.search.store.pgvector_schema: "zaki_bot"`
- `memory.search.store.pgvector_table: "memory_embeddings"`
- runtime pool / timeout knobs as needed

For ZAKI production, omitting the pgvector schema or relying on the default schema is invalid.
The rendered runtime config must explicitly encode the memory contract above so production cannot
silently drift back to `public.memory_embeddings`.

## Required Secret/Env Inputs

Supported secret env inputs for the ZAKI deployment path:

- `TOGETHER_API_KEY`
- `NULLCLAW_INTERNAL_SERVICE_TOKEN`
- `NULLCLAW_POSTGRES_CONNECTION_STRING`

Backward-compatible fallbacks still supported during migration:

- `INTERNAL_SERVICE_TOKEN`
- `POSTGRES_CONNECTION_STRING`

Placeholder values are not valid runtime secrets. The `zaki_bot` profile must reject:

- empty values
- `REPLACE_WITH_*`
- `changeme`
- `change-me`
- `default`
- `test-internal-token`
- `dev-internal-token`

## Startup Validation

For `profile: "zaki_bot"`, startup validation requires:

- a valid `agents.defaults.model.primary`
- a matching provider entry under `models.providers` with `base_url`
- any configured fallback model must also resolve to a provider entry with `base_url`
- at least one internal service token
- `state.backend = "postgres"`
- a Postgres connection string

Local/dev note:
- restoring an older config backup without `models.providers[*].base_url` is no longer valid for `zaki_bot`
- placeholder internal tokens must fail startup, not degrade silently

## Kubernetes Service Contract

For the cleaned-up production layout:

- service name: `nullclaw`
- namespace: `zaki`
- backend discovery URL from `zaki-prod`: `http://nullclaw:3000`

Posture note:
- current product posture is internal-service first
- direct public Telegram webhook delivery to Nullalis is not the canonical deployment baseline in this document

## Runtime Topology Notes

Observed init logs that mention `backend=markdown` during memory initialization are not by
themselves evidence of drift. Under the ZAKI contract, tenant runtime later promotes into the
canonical `zaki_dual` topology where:

- Postgres remains canonical for durable state
- markdown remains the editable projection surface for files like `SOUL.md`
- pgvector remains the derived retrieval index in `zaki_bot.memory_embeddings`

Any production behavior that writes active pgvector rows into `public.memory_embeddings` is drift.

## Production Promotion

- `NULL-ALIS` publishes immutable image tags on `main`.
- `zaki-infra` chooses which exact image tag is live in production.
- Production must not depend on `latest`.
- During the migration to fully immutable promotion, both of these image tag formats are valid:
  - `sha-<40-char git sha>`
  - `<40-char git sha>`
