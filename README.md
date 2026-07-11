# nullALIS

<p align="center">
  <img src="docs/assets/nullalis-logo.svg" alt="nullALIS logo" width="420" />
</p>

<p align="center">
  A Zig-first, single-binary autonomous-agent runtime — the engine behind productized digital-twin assistants.
</p>

---

**nullALIS** (binary + config path `nullalis` / `~/.nullalis/`) is a **Zig-first, single-binary
autonomous-agent runtime** — the engine behind productized digital-twin assistants such as
**ZAKI BOT**. It runs a persistent per-user agent as a **bounded ReAct-style tool-call loop**
with streaming, over a **vtable-driven, factory-registered** plugin core (providers · channels ·
tools · memory · observers · runtime adapters). Its defining feature is a **durable memory +
retrieval pipeline** backed by tenant Postgres (pgvector), plus a learning loop, background
subagents, cron/proactive autonomy, a browser-extension control plane, and MCP (client and
server). It is deliberately a **second-brain / digital-twin runtime, not an embedded-device
runtime** — the hardware surface was removed in 2026-04. Hard product constraints: minimal binary
size (`ReleaseSmall` < 30 MB) and low RSS (< 80 MB test peak; current ~66–72 MB).

**Naming:** brand `nullALIS`; runtime/CLI/config path `nullalis` (binary), `~/.nullalis/`.

**Scale at HEAD (`c05bcac2`):** 366 Zig files under `src/`, ~349K LoC, ~7,700 test blocks
(canonical `-Dengines=base,sqlite,postgres` suite: **7,679 pass / 24 skip / 0 fail**). Zig 0.15.2.

> **Doc-truth rule:** code truth beats doc truth. When a doc disagrees with `src/`, the code wins —
> fix or archive the doc in the same change.

---

## Quick start

```bash
# Toolchain: Zig 0.15.2 (pinned in .zigversion). CI installs it via mlugg/setup-zig@v2.

zig build                                  # dev build (engines: base,sqlite · channels: cli,telegram)
./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000
curl http://127.0.0.1:3000/health
```

Noise-filtered launcher for high-signal ops logs: `scripts/gateway-clean.sh --host 127.0.0.1 --port 3000`
(`--profile ops` default · `--profile debug` · `--raw`).

## Build & test

```bash
# Dev build (default engines base,sqlite · default channels cli,telegram)
zig build

# Release — ReleaseSmall is THE release target (< 30 MB)
zig build -Doptimize=ReleaseSmall

# Tests — DEFAULT profile.  ⚠️ ships enable_postgres=false — see the gotcha below.
zig build test --summary all

# CANONICAL PRODUCTION PROFILE — the only profile that actually exercises PG/state/memory/trace.
zig build test --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram

# …with a LIVE Postgres (also runs the PG-gated live lane)
NULLALIS_POSTGRES_TEST_URL=postgres://<user>@localhost:5432/postgres \
  zig build test -Dengines=base,sqlite,postgres

# Focused: substring filter · single integration lanes
zig build test -Dengines=base,sqlite,postgres -Dtest-filter="PPR hub"

# Format gate (pre-commit hook runs this)
zig fmt --check src/
```

> ### ⚠️ The one gotcha every contributor must know
> A bare `zig build` / `zig build test` ships **`enable_postgres=false`**, which compiles a **stub**
> `Manager` — so the **entire Postgres / state / memory / trace layer is a silent no-op** and its
> tests `SkipZigTest`. **Never trust a green default `zig build test` for a change touching
> PG/state/memory/trace — run `-Dengines=base,sqlite,postgres`.** Two corollaries: (1) the
> *comptime false-clean trap* — the real `ManagerImpl` isn't semantically analyzed on the default
> build, so a type error inside a PG body compiles green until you add the postgres engine; (2)
> *stub parity* — a new `Manager` method must also be added to the stub struct or the default build
> fails comptime. `docs/` and `AGENTS.md` cover this in depth.

**Build flags:** `-Dengines=` (`base|minimal|all|none|markdown|memory|api|sqlite|lucid|redis|lancedb|postgres`,
default `base,sqlite`) · `-Dchannels=` (`cli|telegram|…|teams|nostr`, default `cli,telegram`) ·
`-Doptimize=` · `-Dversion=`. Providers are **not** a build flag — all compile in, selected at config/runtime.

**Git hooks:** activate once per clone — `git config core.hooksPath .githooks`
(`pre-commit`→`zig fmt --check src/`; `pre-push`→default test suite). There is ~10 files of
pre-existing fmt debt; format only the files your change touches — do **not** `zig fmt src/`.

## Architecture at a glance

**Entry point:** `src/main.zig` → `parseCommand` → `switch (cmd)`. Top-level CLI commands:
`agent` (local REPL), **`gateway`** (the production multitenant HTTP/SSE server), `controller`,
`service`, `mcp` (nullalis *as* an MCP server), plus `status`/`doctor`/`cron`/`channel`/`skills`/
`migrate`/`memory`/`models`/`auth`/`onboard`.

**Gateway topology** — `broker`/`user_cell`/`shared` are **`--role` values on `gateway`**, not
separate commands: `shared` (default, all-in-one) · `broker` (front door, routes to cells) ·
`user_cell` (per-user execution cell, the k8s "cell per user" topology).

**Request → turn lifecycle:** ingress (`POST /api/v1/chat/stream` SSE — user identity via the
`X-Zaki-User-Id` header, not a path segment — or channel polling loops normalized via
`inbound_canonicalizer.zig`) → tenant + **lane** resolution (`main`/`thread`/`task`/`cron`) →
`SessionManager.processMessage` → a **bounded ReAct loop** in `src/agent/root.zig`
(`DEFAULT_MAX_TOOL_ITERATIONS=25`): build prompt+context → stream `chat_with_tools` → parse tool calls →
execute → append → repeat → egress SSE with per-turn `usage_tokens`/`cost_usd` on the `done` frame →
persist via `zaki_state.zig`.

**Six vtable extension points** — an interface is a fat pointer `{ ptr, vtable }`; a concrete struct
exposes a constructor and registers in a factory; the caller owns the implementing struct:

| Extension point | Interface | Where | Register in |
|---|---|---|---|
| AI providers | `Provider` | `src/providers/root.zig` | `src/providers/factory.zig` (`core_providers`) |
| Messaging channels | `Channel` | `src/channels/root.zig` | `src/channels/dispatch.zig` + `channels/*.zig` |
| Agent tools | `Tool` | `src/tools/root.zig` | `allTools` + `DEFAULT_TOOL_METADATA` (both in `tools/root.zig`; the `ToolMetadata` type is in `tools/metadata.zig`) |
| Memory backends | `Memory` | `src/memory/root.zig` | `src/memory/engines/registry.zig` |
| Observability | `Observer` | `src/observability.zig` | in-file (Noop/Log/File/Otel); Sentry in `sentry_runtime.zig` |
| Runtime environments | `RuntimeAdapter` | `src/runtime.zig` | in-file (Native/Docker) |

**Subsystems:**
- **Memory + retrieval** — `src/memory/` (engines, `retrieval/` rrf·mmr·rerank, `vector/` pgvector·qdrant); canonical tenant state is `src/zaki_state.zig` (pgvector in `zaki_bot.memory_embeddings`).
- **Learning loop** — `src/agent/learning.zig` (durable behavioral facts), miner `trace_mining.zig`, nightly `dream.zig`, stages `extraction/` · `promotion.zig` · `reflection.zig`.
- **Subagents** — `src/subagent.zig` (`SubagentManager`, background OS-thread agents, restricted tool profile); tools `spawn`/`spawn_many`/`subagent_batch_result`/`delegate`.
- **TELOS** — a curated always-on user model (mission/goals/values), a governed view over `durable_fact/telos/*` (opt-in, `agent.telos_in_prompt` default OFF).
- **Gateway** — `src/gateway.zig`; extension WS control plane under `extension_ws/`.
- **Config** — `src/config*.zig`; the `zaki_bot` profile (Moonshot `kimi-k2.6` primary + Together fallback) **hard-fails startup without Postgres**.

## Contract-first governance

Three subsystems are governed by a **normative doc paired with an executable test** — you edit
**both together**, and the test is compiled into the build:

| Contract | Doc | Executable test |
|---|---|---|
| Memory | `docs/memory-contract.md` | `src/memory/contract_test.zig` |
| Learning | `docs/learning-contract.md` | `src/agent/learning_contract_test.zig` |
| TELOS | `docs/telos-contract.md` | `src/agent/telos_contract_test.zig` |

Each test asserts code against the contract (e.g. the memory contract test fails `DenylistDrift` if
the extraction denylist diverges from the tool registry). See `AGENTS.md` for the full protocol.

## Configuration

Default path `~/.nullalis/config.json` (see [`config.example.json`](config.example.json)). The
`zaki_bot` production profile hard-fails startup without Postgres. **The deployed config
(which primary model, secrets, replica count) is owned by `zaki-infra`, not this repo** — see
[`docs/config-authority-map.md`](docs/config-authority-map.md).

CLI diagnostics: `nullalis doctor` (alias `arzt`) · `nullalis status` · backend-aware
`nullalis cron list --backend postgres --user-id 1`.

## Where nullALIS sits (the spoke model)

nullALIS is **one spoke** of a hub-and-spoke platform (the agent, productized as ZAKI BOT):
- **Hub** = the ZAKI platform + its `zaki_bot` Postgres **"brain"** (memory in `zaki_bot.memory_embeddings`, secrets in `zaki_bot.user_secrets`, config in `zaki_bot.user_config`).
- **`zaki-infra`** = deployment authority (rendered production config, k8s/Helm/ArgoCD).
- **`zaki-prod`** = the hub frontend + BFF that proxies to this agent over `/api/v1/chat/stream`.

Sibling chat/design/learning spokes have their own engines and isolated stores; the brain currently
serves the agent spoke only.

## API

OpenAPI: [`docs/openapi-v1.yaml`](docs/openapi-v1.yaml). Key surfaces: `/health` · `/ready` ·
`/metrics` · `/internal/diagnostics` · `/api/v1/chat/stream` · `/api/v1/users/*` (usage, tasks,
traces, brain). SSE run-event contract (`status`/`progress`/`tool_start`/`tool_result`/
`approval_required`/`task_update`/`token`/`done`, with `run_id`/`tool_use_id` correlation):
[`docs/online-agent-contract.md`](docs/online-agent-contract.md).

## Contributing

Read **[`AGENTS.md`](AGENTS.md)** first — it is the engineering protocol for both human and AI
contributors (architecture, risk tiers, change playbooks, the contract-first rule, the `-Dengines`
discipline, review + worktree conventions). Then [`CONTRIBUTING.md`](CONTRIBUTING.md). Activate the
git hooks (`git config core.hooksPath .githooks`) and format only the files you touch.

## Production ownership

- **`NULL-ALIS`** (this repo) owns provider integrations, agent code, tests, and published images.
- **`zaki-infra`** owns live k8s manifests, secrets references, and ArgoCD/Helm rollout.
- **`zaki-prod`** owns the hub frontend/BFF. The legacy `deploy/k8s/zaki-bot/` pack is reference-only.

## Status & roadmap

Live status and forward plan live in **[`STATUS.md`](STATUS.md)** and
[`docs/ROADMAP.md`](docs/ROADMAP.md). The living docs index is [`docs/README.md`](docs/README.md).

## License

Dual-license (provisional): AGPL-3.0-or-later, or a commercial license.
See [`LICENSE`](LICENSE) and [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md).
