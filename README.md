# nullALIS

<p align="center">
  <img src="docs/assets/nullalis-logo.svg" alt="nullALIS logo" width="420" />
</p>

<p align="center">
  Zig-first autonomous agent runtime for persistent digital twins and multitenant products.
</p>

## Current Status (March 25, 2026)

`nullALIS v0.1` is the declared baseline for public beta stabilization.

Scope of this declaration:
- Freeze current runtime/API behavior as the canonical baseline.
- Defer larger upstream ports to controlled cherry-pick/upsert tracks.
- Prioritize clean reproducibility over new feature intake.

Current verified baseline:
- Full tests pass: `zig build test --summary all` (`4709` passed, `25` skipped).
- Build passes with production engines: `zig build -Dengines=base,sqlite,postgres`.
- Postgres-backed tenant runtime is the authoritative state path when configured.
- Current validated `zaki_bot` runtime posture is Together-first:
  `together-ai/moonshotai/kimi-k2.5` primary, `openrouter` fallback,
  `together-ai` embeddings.
- Chat SSE contract is stable, with additive `progress` events for live UX (`status/progress/token/done`).

References:
- [v0.1 public posture (2026-03-25)](docs/releases/v0.1-public-posture-2026-03-25.md)
- [ZAKI runtime contract](docs/zaki-runtime-contract.md)
- [ops runbook](docs/reliability-ops-runbook.md)
- [v0.1 declaration (2026-03-18)](docs/releases/v0.1-declaration-2026-03-18.md)
- [v1.1 next steps](docs/releases/v1.1-next-steps.md)
- [historical archive note](docs/archive/historical-archive.md)

## What nullALIS Is

`nullALIS` is the runtime engine behind productized agents like `ZAKI BOT`.

It is designed for:
- persistent per-user sessions
- durable memory and runtime state
- proactive scheduling and background autonomy
- secure, multitenant operation
- backend/frontend integration through stable APIs and SSE streams

Naming note:
- Brand: `nullALIS`
- Runtime/CLI/config path: `nullalis` (binary), `~/.nullalis/`

## Current Capabilities

### 1) Conversation Runtime
- Persistent main-session model per user.
- Session-scoped history, autosave, and slash command support.
- Tool-call loop with reflection, bounded iterations, and fallback completion behavior.
- Streaming reply transport via `/api/v1/chat/stream`.

Operator slash commands (chat surface, not REST endpoints):

| Command | Purpose |
|---|---|
| `/permissions` (alias `/perm`) | Read-only snapshot of permission, approval, and execution posture. |
| `/mode [plan\|execute\|review\|background]` | Inspect or switch execution posture. |
| `/plan`, `/review`, `/execute` | Direct execution-mode switches. `plan`/`review` block mutating tools; `execute` applies the current security policy. |
| `/approve <allow-once\|deny>` | Resolve the single pending tool approval. |
| `/usage [off\|tokens\|full\|cost]` | Toggle per-turn usage reporting. |
| `/cost` | Read-only token/cost snapshot for the session. |
| `/help` | Categorized discovery of all implemented commands. |

See [src/agent/commands.zig](src/agent/commands.zig) for the full set, and
[docs/online-agent-contract.md](docs/online-agent-contract.md) for the
operator-surface contract. These are chat slash commands — REST parity is
planned/deferred and is not implemented in v0.1.

### 2) Memory and State
Hybrid memory architecture:
- Workspace markdown files for human-readable continuity.
- Postgres-backed tenant state for durable canonical runtime data.
- pgvector-compatible semantic retrieval path (when configured).
- Runtime introspection via `runtime_info` and `/runtime` command surfaces.

### 3) Autonomy and Scheduling
- Heartbeat and scheduler execution paths with turn-origin wiring (`user`, `heartbeat`, `scheduler`).
- Background policy guardrails (restricted tools for autonomous/background turns).
- Postgres-backed scheduler path in tenant mode.
- Reminder/proactive guardrails (dedupe/rate-limit instrumentation available in diagnostics).

### 4) Tooling and Integrations
- Broad built-in tool surface (files, shell, git, memory, web, browser, scheduling, integrations).
- Composio integration path for Gmail/Drive/Calendar readiness in multitenant deployments.
- Per-user Composio entity scoping supported at runtime.
- Telegram and app channel integration with shared main timeline model.

### 5) Platform and Deployment
- Local runtime for operator/dev workflows.
- Docker-friendly runtime packaging.
- Kubernetes manifests and integration handoff docs for ZAKI backend/frontend.
- Health/readiness/metrics/internal diagnostics endpoints.

## Tech Stack

Core stack:
- Language: Zig (`0.15.2` baseline in this repository).
- Runtime style: vtable-driven interfaces, modular factories.
- State: Postgres (tenant runtime), SQLite and markdown where configured.
- Semantic store: pgvector and pluggable vector/embedding providers.
- Transport: native HTTP + SSE chat streams (`/api/v1/chat/stream`).
- Channels: Telegram plus app/backend API pathways.
- Integrations: Composio and tool adapters.

Ops stack:
- Observability: structured runtime logs + metrics endpoints.
- Deployment: Docker image publishing in this repo; production rollout is owned by `zaki-infra`.
- Reference manifests and handoff docs live under `deploy/k8s/zaki-bot/` for local/dev and contract reference.

Current-truth rule:
1. Read [v0.1 public posture](docs/releases/v0.1-public-posture-2026-03-25.md) first.
2. Use [ZAKI runtime contract](docs/zaki-runtime-contract.md) as the deployment/runtime contract.
3. Treat `docs/reports/*` and `deploy/k8s/zaki-bot/*` as archive/reference unless a current document says otherwise.

## Architecture At a Glance

Primary extension boundaries:
- Providers: model backends and routing
- Channels: inbound/outbound messaging transports
- Tools: runtime action surface
- Memory: storage/retrieval backends
- Observability: event/metric emission backends

Key source entry points:
- [src/main.zig](src/main.zig)
- [src/gateway.zig](src/gateway.zig)
- [src/agent/root.zig](src/agent/root.zig)
- [src/session.zig](src/session.zig)
- [src/tools/root.zig](src/tools/root.zig)
- [src/memory/root.zig](src/memory/root.zig)
- [src/providers/root.zig](src/providers/root.zig)
- [src/channels/root.zig](src/channels/root.zig)
- [src/observability.zig](src/observability.zig)

## API and Swagger

OpenAPI contract:
- [docs/openapi-v1.yaml](docs/openapi-v1.yaml)

Important endpoints:
- `/health`, `/ready`, `/metrics`
- `/internal/diagnostics`
- `/api/v1/chat/stream`
- `/api/v1/users/*` tenant surfaces
- `/api/v1/users/{user_id}/usage` — read-only token and cost summary
- `/api/v1/users/{user_id}/tasks` and `.../tasks/{task_id}` — task read surface; `.../tasks/{task_id}/stop` for queued-only cancellation
- `/api/v1/users/{user_id}/traces` and `.../traces/{run_id}` — read-only sanitized run-event traces (in-memory, bounded)

SSE chat stream contract (structured run events):
- `event: status` (initial status)
- `event: progress` (phase transitions, tool dispatch, keepalives)
- `event: reasoning_summary` (short narration; when reasoning mode is on)
- `event: tool_start` (tool invocation starting)
- `event: tool_result` (tool invocation finished, success or failure)
- `event: approval_required` (supervised mutating tool awaiting `/approve`)
- `event: task_update` (subagent task state change)
- `event: token` (assistant text deltas)
- `event: error` (stream error payload)
- `event: done` (terminal frame)

Full schema, correlation ids (`run_id`, `tool_use_id`), approval behavior,
and ordering invariants: [docs/online-agent-contract.md](docs/online-agent-contract.md).

Integration handoff specs:
- [ZAKI backend handoff](deploy/k8s/zaki-bot/ZAKI_BACKEND_HANDOFF.md)
- [ZAKI frontend handoff](deploy/k8s/zaki-bot/ZAKI_FRONTEND_HANDOFF.md)

Production ownership note:
- `NULL-ALIS` owns provider integrations, app code, tests, and published images.
- `zaki-infra` owns live Kubernetes manifests, secrets references, ArgoCD/Helm rollout policy, and service wiring.
- `zaki-prod` owns frontend/backend proxy behavior and service discovery to internal apps only.
- The legacy `deploy/k8s/zaki-bot/` pack is reference-only and must not be used as the live production source of truth.

## Quick Start

### Build

```bash
zig build
```

### Full Test Suite

```bash
zig build test --summary all
```

### Build with Postgres + SQLite Engines

```bash
zig build -Dengines=base,sqlite,postgres
```

### Run Gateway

```bash
./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000
```

### Run Gateway (Clean Ops Terminal)

Use the noise-filtered launcher for high-signal runtime logs:

```bash
scripts/gateway-clean.sh --host 127.0.0.1 --port 3000
```

Profiles:
- `--profile ops` (default): startup/runtime truth, stage summaries, errors/warnings.
- `--profile debug`: full runtime logs except Postgres `NOTICE` spam.
- `--raw`: no filtering.

### Health Check

```bash
curl http://127.0.0.1:3000/health
```

## Runtime Truth and Diagnostics

Authoritative source order for runtime state:
1. `GET /internal/diagnostics` (`startup_self_check` + ops state)
2. `runtime_info` with explicit `data_source` markers
3. Local config/file fallback surfaces (always marked as fallback/context-incomplete)

CLI diagnostics:

```bash
nullalis doctor
nullalis arzt    # alias of doctor
nullalis status
```

`doctor`/`arzt` now report:
- runtime source (`gateway_internal` or `local_fallback`)
- state backend (configured vs effective)
- scheduler backend and limits (configured/effective)
- degraded and context-incomplete markers

Cron CLI is backend-aware:

```bash
nullalis cron list --backend auto
nullalis cron list --backend postgres --user-id 1
nullalis cron add "0 8 * * *" "message \"Morning brief\"" --backend postgres --user-id 1
```

In tenant+Postgres mode, postgres cron operations require explicit `--user-id`.

## Configuration

Default config path:

```text
~/.nullalis/config.json
```

Example:
- [config.example.json](config.example.json)

Web search provider selection:
- `WEB_SEARCH_PROVIDER=auto|exa|brave` (default `auto`)
- `EXA_API_KEY`
- `BRAVE_API_KEY`

## Roadmap

### v0.1 (Current): Reliability and Runtime Truth
- Stabilize runtime behavior under continuous operation.
- Keep Postgres runtime path authoritative.
- Harden autonomous/background behavior and UX.
- Ship stream progress visibility and better perceived liveness.

### v0.2: Orchestration Maturity
- Wire reserved origins (`wake`, `proactive`) into explicit execution flows.
- Improve subagent/A2A control surfaces and lifecycle observability.
- Reduce startup/operator noise and tighten deployment ergonomics.

### v0.3: DTaaS Expansion
- Deeper live-data integrations and richer proactive intelligence.
- More adaptive memory retrieval and context shaping.
- UI/UX polish for multi-modal and operator experiences.

## Benchmark

- [DTaaS-Bench v0.2 spec](docs/dtaas-bench-v0.2-spec.md)
- [DTaaS-Bench v0.2 run manifest template](docs/dtaas-bench-run-manifest-v0.2.json)

## Enablers

- Strong test baseline with high coverage and leak-sensitive allocators.
- Clear extension boundaries (providers/channels/tools/memory/observer).
- Tenant runtime isolation model and canonical user/session routing.
- Existing runbooks and deployment docs for operational rollout.

## Blockers and Risks

- Startup schema/migration `NOTICE` verbosity still hurts operator signal quality.
- Reserved origins `wake` and `proactive` are defined but not yet active execution paths.
- Subagent control is still completion-oriented (limited in-flight steering model).
- Any cross-service integration quality is coupled to upstream API stability and token hygiene.

## Development Workflow

Activate hooks once:

```bash
git config core.hooksPath .githooks
```

Common loop:

```bash
zig build
zig build test --summary all
zig build -Doptimize=ReleaseSmall
zig fmt src/**/*.zig
```

## License

Dual-license (provisional):
- AGPL-3.0-or-later
- Commercial license

See [LICENSE](LICENSE) and [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md).
