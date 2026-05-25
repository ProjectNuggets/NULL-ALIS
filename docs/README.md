---
tags: [prose, prose/docs, prose/index]
authored: 2026-05-25
status: canonical index
---

# nullalis docs index

Top-level living docs. Historical snapshots live in `archive/`. If a doc
isn't listed below, it's been archived or doesn't exist.

## Strategic + state

| Doc | Purpose |
|---|---|
| [`ROADMAP.md`](ROADMAP.md) | Canonical roadmap — the single source of truth for the plan |
| [`../STATUS.md`](../STATUS.md) | Current state — "where we are now" (cold-start doc) |
| [`deferred-register.md`](deferred-register.md) | Operational debt ledger — every deferred item D1+ with status |
| [`ui-handoff.md`](ui-handoff.md) | UI agent handoff — capability inventory, settings, UX strategy |

## Live capability contracts (what the FE / external clients bind to)

| Doc | Purpose |
|---|---|
| [`online-agent-contract.md`](online-agent-contract.md) | SSE event vocabulary the FE consumes |
| [`extension-ws-contract.md`](extension-ws-contract.md) | Browser-extension WebSocket protocol |
| [`scheduler-automation-contract.md`](scheduler-automation-contract.md) | Cron job schema |
| [`mcp-client.md`](mcp-client.md) | How nullalis consumes external MCP servers |
| [`openapi-access.md`](openapi-access.md) | OpenAPI tool ingestion + per-tenant API integrations |
| [`state-secrets-wiring.md`](state-secrets-wiring.md) | Where secrets live + how the vault gates them |

## Operational + ops

| Doc | Purpose |
|---|---|
| [`sandbox-deploy.md`](sandbox-deploy.md) | Operator deployment guide (bubblewrap / firejail / docker) |
| [`sandbox-tool-coverage.md`](sandbox-tool-coverage.md) | Per-tool sandbox coverage matrix |
| [`reliability-ops-runbook.md`](reliability-ops-runbook.md) | Operations runbook |
| [`SLO.md`](SLO.md) | Service level objectives |
| [`multi-instance.md`](multi-instance.md) | Multi-instance deployment guide |
| [`session-key-policy.md`](session-key-policy.md) | Session-key issuance + rotation policy |
| [`silent-catches-policy.md`](silent-catches-policy.md) | §14.5 honesty policy — when catches are allowed |
| [`migrations-policy.md`](migrations-policy.md) | Schema-migration policy |
| [`config-authority-map.md`](config-authority-map.md) | Per-config-field ownership (operator vs tenant) |

## Specs + reference

| Doc | Purpose |
|---|---|
| [`agent-lifecycle-spec.md`](agent-lifecycle-spec.md) | Agent turn lifecycle reference |
| [`slash-commands-spec.md`](slash-commands-spec.md) | Slash command catalog |
| [`execution-cell-contract.md`](execution-cell-contract.md) | Runtime cell contract |
| [`zaki-runtime-contract.md`](zaki-runtime-contract.md) | zaki-prod runtime contract |
| [`openapi-v1.yaml`](openapi-v1.yaml) | Full HTTP API spec |

## Sub-directories

- [`audits/`](audits/) — closed/active audit ledgers
- [`ops/`](ops/) — operations playbooks
- [`research/`](research/) — research notes (read-only references)
- [`superpowers/`](superpowers/) — superpowers skill definitions
- [`assets/`](assets/) — doc assets
- [`archive/`](archive/) — historical snapshots (organized by date)

## Recently archived (2026-05-25)

- `MULTI_AGENT_PLAN.md` → `archive/2026-05-25/` — Sprint 2 plan, shipped
- `CONFIG_CONTROL_PLANE_AUDIT.md` → `archive/2026-05-25/` — v1.14.19 audit, closed
- `LONG_CONV_QA.md` → `archive/2026-05-25/` — commercial-readiness QA snapshot
- `SPRINT4_READINESS.md` → `archive/2026-05-25/` — Sprint 4 readiness snapshot
- `SUBSTRATE_AUDIT.md` → `archive/2026-05-25/` — v1.14.19 substrate audit
