---
tags: [prose, prose/docs]
---

# ZAKI Nullalis Runtime Contract

This document defines the production runtime contract for running Nullalis as the
internal agent service behind `zaki-prod`.

Current validated baseline (code truth at HEAD, 2026-06-10 — see
`src/config.zig:applyProfileDefaults` for the authoritative defaults):
- `profile = "zaki_bot"`
- primary chat model = `moonshot` / `kimi-k2.6` (Moonshot native API; Kimi
  `thinking` cross-turn reasoning round-trip enabled on this route)
- chat fallback chain = `together/moonshotai/Kimi-K2.6` (auto-injected by the
  profile when the operator does not pin a different primary; Together receives
  its own model ID via the per-provider override)
- embedding provider = `together`; extraction sidecar =
  `together` / `meta-llama/Llama-3.3-70B-Instruct-Turbo`
- `TOGETHER_API_KEY` is mandatory (profile validation hard-fails without it)
- `state.backend = "postgres"` (hard requirement)
- `scheduler_backend = "postgres"`
- `degraded = false`

Historical note: the pre-2026-05-21 baseline was Together-first
`moonshotai/kimi-k2.5` with `openrouter` fallback. The deployed value is owned
by the `zaki-infra` rendered config; this section documents the code default
that applies when the rendered config does not pin a primary.

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
- `agents.defaults.model.primary` — omit to inherit the profile default
  (`moonshot/kimi-k2.6` + auto-injected Together fallback), or pin explicitly.
  If pinned to a non-default model, the profile does NOT auto-inject a
  fallback — set `reliability.fallback_providers` explicitly.
- `models.providers["moonshot"].base_url: "https://api.moonshot.ai/v1"`
- `models.providers["together"].base_url: "https://api.together.xyz/v1"`
  (required — embeddings, sidecar, and the fallback route run on Together)
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

- `MOONSHOT_API_KEY` (primary route; read by the `moonshot`/`kimi` providers —
  `src/providers/api_key.zig`)
- `TOGETHER_API_KEY` (mandatory: fallback route + embeddings + sidecar)
- `NULLALIS_INTERNAL_SERVICE_TOKEN`
- `NULLALIS_POSTGRES_CONNECTION_STRING`
- Capability keys, fail-soft when absent: `GROQ_API_KEY` (voice STT),
  `COMPOSIO_API_KEY` (integrations), `EXA_API_KEY`/`BRAVE_API_KEY` (web search),
  `BROWSER_ORCHESTRATOR_AUTH_TOKEN` (server-side browser lane)

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
