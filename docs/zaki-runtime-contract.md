# ZAKI Nullalis Runtime Contract

This document defines the production runtime contract for running Nullalis as the
internal agent service behind `zaki-prod`.

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
- `models.providers["together-ai"].base_url: "https://api.together.xyz/v1"`
- `gateway.host`
- `gateway.port`
- `tenant.enabled`
- `tenant.data_root`
- `state.backend: "postgres"`
- `state.postgres.schema`
- runtime pool / timeout knobs as needed

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
- at least one internal service token
- `state.backend = "postgres"`
- a Postgres connection string

## Kubernetes Service Contract

For the cleaned-up production layout:

- service name: `nullclaw`
- namespace: `zaki`
- backend discovery URL from `zaki-prod`: `http://nullclaw:3000`
