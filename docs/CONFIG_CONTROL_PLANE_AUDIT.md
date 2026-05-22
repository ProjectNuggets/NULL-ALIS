# Config / Control-Plane Audit — nullalis

**Date:** 2026-05-22
**Branch:** chore/v11418B-dispatch-and-1410-addendum
**Scope:** config_types.zig, config_parse.zig, config.zig, user_settings.zig, gateway.zig (TenantRuntime), providers/runtime_bundle.zig, agent/model_capabilities.zig
**Status:** read-only audit. No code modified. This document is the deliverable.

## Why this audit exists

A debugging session found FOUR stacked config regressions in the memory pipeline. The through-line: **a config surface that exists but is not enforced.** Findings #1–#4 are already fixed (commits 6a824d12, 31bc40c3, b66f11a8, cd6888c9). This audit finds every *other* instance of the same four failure classes:

- **Class A (finding #1):** a struct default silently flipped, no test pins it.
- **Class B (finding #2):** two config fields that must agree, nothing checks the pair.
- **Class C (finding #3):** a config block not in the operator-ownership allowlist — deny-by-omission leak.
- **Class D (finding #4):** a config struct + field + ownership wiring + docstrings, but **NO PARSER** — decorative config.

---

## A. Unified config map

Every config key, by struct path. `Parsed?` = does `config_parse.zig` read it from JSON. **`NO` entries are Class-D bugs.** Owner: O=operator, T=tenant-preference, U=UI-changeable (subset of T via `product_settings`), D=derived/computed.

### Top-level `Config` (config.zig:83)

| Key | Type | Default | Parsed? | Owner | Runtime read |
|---|---|---|---|---|---|
| `workspace_dir` | `[]const u8` | resolved | n/a (computed) | D | everywhere |
| `config_path` | `[]const u8` | resolved | n/a (computed) | D | save(), gateway |
| `profile` | `[]const u8` | `"standard"` | yes (`profile`) | O | applyProfileDefaults, validate |
| `providers` | `[]ProviderEntry` | `&.{}` | yes (`models.providers`) | O | runtime_bundle, getProviderKey |
| `audio_media` | `AudioMediaConfig` | `.{}` | yes (`tools.media.audio` / `audio_media`) | O | multimodal/voice |
| `default_provider` | `[]const u8` | `"openrouter"` | yes (`agents.defaults.model.primary`) | O | runtime_bundle |
| `default_model` | `?[]const u8` | `null` | yes (`agents.defaults.model.primary`) | O | runtime_bundle, root.zig |
| `legacy_default_provider_detected` | `bool` | `false` | yes (set-only on legacy key) | D | validate (rejects) |
| `legacy_default_model_detected` | `bool` | `false` | yes (set-only on legacy key) | D | validate (rejects) |
| `default_temperature` | `f64` | `0.7` | yes (`default_temperature`) | O | agent build |
| `reasoning_effort` | `?[]const u8` | `null` | yes (`reasoning_effort`) | O / U | applySettingsToConfig, agent |
| `model_routes` | `[]ModelRouteConfig` | `&.{}` | yes (`model_routes`) | O | router |
| `agents` | `[]NamedAgentConfig` | `&.{}` | yes (`agents.list`) | O | subagent |
| `agent_bindings` | `[]AgentBinding` | `&.{}` | yes (`bindings` ONLY — see B) | O | agent_routing |
| `mcp_servers` | `[]McpServerConfig` | `&.{}` | yes (`mcp_servers`) | O | mcp.zig |
| `diagnostics` | `DiagnosticsConfig` | `.{}` | yes (`diagnostics`) | O | observability |
| `autonomy` | `AutonomyConfig` | `.{}` | partial (see below) | O (+ `.level` is U) | security/policy |
| `runtime` | `RuntimeConfig` | `.{}` | yes (`runtime`) | O | runtime.zig (beta, deferred) |
| **`network`** | `NetworkConfig` | `.{}` | **NO** | O | — **CLASS D BUG** |
| `reliability` | `ReliabilityConfig` | `.{}` | partial (see below) | O | reliability layer |
| `scheduler` | `SchedulerConfig` | `.{}` | yes (`scheduler`) | O | cron/tasks |
| `agent` | `AgentConfig` | `.{}` | partial (see below) | O (+ a few U) | agent/* |
| `sidecar` | `SidecarConfig` | `.{}` | yes — **fixed finding #4** | O | runtime_bundle, session |
| `heartbeat` | `HeartbeatConfig` | `.{}` | yes (`agents.defaults.heartbeat`) | O | heartbeat.zig |
| `cron` | `CronConfig` | `.{}` | yes (`cron`) | O | cron.zig |
| `channels` | `ChannelsConfig` | `.{}` | yes (`channels`) | O | channel_manager |
| `memory` | `MemoryConfig` | `.{}` | partial (see below) | O | memory/* |
| `tunnel` | `TunnelConfig` | `.{}` | yes (`tunnel`) | O | tunnel.zig (beta, deferred) |
| `gateway` | `GatewayConfig` | `.{}` | yes (`gateway`) | O | gateway.zig |
| `tenant` | `TenantConfig` | `.{}` | yes (`tenant`) | O | gateway/tenant_runtime |
| `state` | `StateConfig` | `.{}` | yes (`state`) | O | state.zig |
| `composio` | `ComposioConfig` | `.{}` | yes (`composio`) | O | integrations |
| `secrets` | `SecretsConfig` | `.{}` | yes (`secrets`) | O | security/secrets |
| `browser` | `BrowserConfig` | `.{}` | yes (`browser`) | O | tools/browser |
| `http_request` | `HttpRequestConfig` | `.{}` | yes (`http_request`) | O | tools/http |
| `identity` | `IdentityConfig` | `.{}` | yes (`identity`) | O | identity.zig |
| `cost` | `CostConfig` | `.{}` | yes (`cost`) | O | cost.zig |
| `peripherals` | `PeripheralsConfig` | `.{}` | yes (`peripherals`) | O | peripherals |
| `security` | `SecurityConfig` | `.{}` | yes (`security`) | O | security/* |
| `tools` | `ToolsConfig` | `.{}` | yes (`tools`) | O | tools/* |
| `session` | `SessionConfig` | `.{}` | yes (`session`) | O | session.zig |
| `temperature` | `f64` | `0.7` | n/a (syncFlatFields) | D | flat alias |
| `max_tokens` | `?u32` | `null` | yes (`max_tokens`) | O | root.zig:824 resolveMaxTokens |
| `memory_backend` | `[]const u8` | `"markdown"` | n/a (syncFlatFields) | D | flat alias |
| `memory_auto_save` | `bool` | `true` | n/a (syncFlatFields) | D | flat alias |
| `heartbeat_enabled` | `bool` | `false` | n/a (syncFlatFields) | D | flat alias |
| `heartbeat_interval_minutes` | `u32` | `60` | n/a (syncFlatFields) | D | flat alias |
| `gateway_host` | `[]const u8` | `"127.0.0.1"` | n/a (syncFlatFields) | D | flat alias |
| `gateway_port` | `u16` | `3000` | n/a (syncFlatFields) | D | flat alias |
| `workspace_only` | `bool` | `true` | n/a (syncFlatFields) | D | flat alias |
| `max_actions_per_hour` | `u32` | `100` | n/a (syncFlatFields) | D | flat alias |

### NetworkConfig (config_types.zig:99) — **DECORATIVE, CLASS-D BUG**

| Key | Type | Default | Parsed? | Notes |
|---|---|---|---|---|
| `network.transport` | `TransportConfig` | `.{}` | **NO** | `config_parse.zig` has no `root.get("network")` branch. `network` is in `operator_owned_top_level_config_keys` (user_settings.zig:151) — same posture as the pre-fix sidecar bug. `Config.network` is permanently the struct default. The only `network` string in config_parse.zig (line 623) is `runtime.docker.network`, unrelated. **Identical to finding #4.** Impact is lower than sidecar only because `TransportConfig` defaults are sane; but a `"network": {...}` block in config.json is silently ignored. |

### AutonomyConfig (config_types.zig:59) — partially parsed

| Key | Type | Default | Parsed? | Owner |
|---|---|---|---|---|
| `level` | `AutonomyLevel` | `.full` | yes | O + U (via `product_settings.autonomy`) |
| `workspace_only` | `bool` | `true` | yes | O |
| `max_actions_per_hour` | `u32` | `100` | yes | O |
| `require_approval_for_medium_risk` | `bool` | `true` | yes | O |
| `block_high_risk_commands` | `bool` | `true` | yes | O |
| `allowed_commands` | `[][]const u8` | `&.{}` | yes | O |
| `allowed_paths` | `[][]const u8` | `&.{}` | yes | O |

All `AutonomyConfig` fields are parsed. Clean.

### ReliabilityConfig (config_types.zig:124) — partially parsed

| Key | Type | Default | Parsed? | Notes |
|---|---|---|---|---|
| `provider_retries` | `u32` | `2` | yes | |
| `provider_backoff_ms` | `u64` | `500` | yes | |
| `channel_initial_backoff_secs` | `u64` | `2` | yes | |
| `channel_max_backoff_secs` | `u64` | `60` | yes | |
| `scheduler_poll_secs` | `u64` | `15` | yes | |
| `scheduler_retries` | `u32` | `2` | yes | |
| `fallback_providers` | `[][]const u8` | `&.{}` | yes | |
| `api_keys` | `[][]const u8` | `&.{}` | yes | |
| `model_fallbacks` | `[]ModelFallbackEntry` | `&.{}` | yes | |
| **`vision_fallback`** | `VisionFallbackConfig` | `.{}` | **NO** | `config_parse.zig` reliability block (lines 646–712) has no `vision_fallback` branch. The field's own docstring (config_types.zig:135–142) says "Set this to route those turns through a cheap vision-capable model" — but **there is no parser, so it cannot be set.** `VisionFallbackConfig.provider`/`.model` are permanently `""`. **CLASS-D BUG** — exactly finding #4: a field whose docstring promises configurability with no parser behind it. The docstring even calls the current empty-default a "current regression." |

### VisionFallbackConfig (config_types.zig:145) — **DECORATIVE, CLASS-D BUG**

| Key | Type | Default | Parsed? |
|---|---|---|---|
| `vision_fallback.provider` | `[]const u8` | `""` | **NO** |
| `vision_fallback.model` | `[]const u8` | `""` | **NO** |

### AgentConfig (config_types.zig:225) — partially parsed; several Class-D fields

| Key | Type | Default | Parsed? | Owner | Notes |
|---|---|---|---|---|---|
| `compact_context` | `bool` | `true` | yes | O | **finding #1 — default restored false→true. No test pins the default.** See C. |
| `max_tool_iterations` | `u32` | `500` | yes | O | |
| **`max_history_messages`** | `u32` | `0` | **NO (deliberately stripped)** | O | Parser removed (SwissWatch 2026-04-28, config_parse.zig:781). Field is permanently `0`. This is *intentional* dead config — but the field still exists and is read at agent/context_builder. A reader who sets it in config.json gets silent no-op. Class-D-adjacent: decorative but documented as such. |
| `parallel_tools` | `bool` | `true` | yes | O | |
| `parallel_tools_rollout_percent` | `u8` | `100` | yes (clamped) | O | |
| `tool_dispatcher` | `[]const u8` | `"auto"` | yes | O | |
| `token_limit` | `u64` | `12_000` | yes | O | |
| `token_limit_explicit` | `bool` | `false` | yes (set as side effect) | D | internal marker |
| `session_idle_timeout_secs` | `u64` | `1800` | yes | O / U | overwritten by `applySettingsToConfig` from `product_settings.session_timeout_minutes` |
| `extraction_judge_model` | `[]const u8` | `""` | yes | O | finding #2 context — now only a fallback when no sidecar |
| `extraction_cardinality_fastpath` | `bool` | `true` | yes | O | |
| `extraction_coverage_filter_enabled` | `bool` | `true` | yes | O | |
| `compaction_keep_recent` | `u32` | `20` | yes | O | |
| `compaction_max_summary_chars` | `u32` | `16_000` | yes | O | |
| `compaction_max_source_chars` | `u32` | `80_000` | yes | O | |
| `message_timeout_secs` | `u64` | `300` | yes | O | |
| `session_ttl_secs` | `?u64` | `null` | yes | O | hard TTL — operator-only by design |
| `activation_mode` | `[]const u8` | `"mention"` | yes | O / U | overwritten by `applySettingsToConfig` from `group_activation` |
| `send_mode` | `[]const u8` | `"inherit"` | yes | O / U | overwritten by `applySettingsToConfig` from `proactive_updates` |
| `queue_mode` | `[]const u8` | `"off"` | yes | O | |
| `queue_debounce_ms` | `u32` | `0` | yes | O | |
| `queue_cap` | `u32` | `0` | yes | O | |
| `queue_drop` | `[]const u8` | `"summarize"` | yes | O | |
| `tts_mode` | `[]const u8` | `"off"` | yes | O / U | overwritten by `applySettingsToConfig` from `voice_replies` |
| `tts_provider` | `?[]const u8` | `null` | yes | O | |
| `tts_limit_chars` | `u32` | `0` | yes | O | |
| `tts_summary` | `bool` | `false` | yes | O | |
| `tts_audio` | `bool` | `false` | yes | O / U | overwritten by `applySettingsToConfig` from `voice_replies` |
| `extraction.per_turn_enqueue_enabled` | `bool` | `false` | **NO** | O | `ExtractionConfig` (config_types.zig:191) — `AgentConfig.extraction` field exists, no `agent.extraction` branch in config_parse.zig. **CLASS-D**: docstring (config_types.zig:188–190) explicitly says "Operators wanting the legacy V1.14.6 behavior can flip any gate back to true via TOML" — but there is NO parser. The gates are unreachable from config. |
| `extraction.memory_nudge_enabled` | `bool` | `false` | **NO** | O | same — Class-D |
| `extraction.skills_nudge_enabled` | `bool` | `false` | **NO** | O | same — Class-D |

### ExtractionConfig (config_types.zig:191) — **DECORATIVE, CLASS-D BUG**

All three fields (`per_turn_enqueue_enabled`, `memory_nudge_enabled`, `skills_nudge_enabled`) are unparsed. The docstring promises operator override "via TOML"; no parser exists. Mitigating note: the C3 commit deleted the *trigger sites*, so flipping these to `true` would be inert anyway — but that makes the fields doubly decorative (no parser AND no consumer). Recommend deletion (see F).

### SidecarConfig (config_types.zig:210) — parsed (finding #4 fixed)

| Key | Type | Default | Parsed? | Owner |
|---|---|---|---|---|
| `enabled` | `bool` | `true` | yes | O |
| `provider` | `[]const u8` | `"groq"` | yes | O |
| `model` | `[]const u8` | `"llama-3.1-8b-instant"` | yes | O |
| `narration_interval` | `u32` | `3` | yes | O |

Residual footgun: the struct default `groq/llama-3.1-8b-instant` is the exact value finding #4 was about. A fresh deploy with no `sidecar` block re-hits the original symptom (extraction routed through Groq free tier). See F.

### MemoryConfig (config_types.zig:739) — large, fully parsed

All `MemoryConfig` sub-structs (`search`, `qmd`, `lifecycle`, `response_cache`, `semantic_cache`, `reliability`, `postgres`, `redis`, `api`, `retrieval_stages`, `summarizer`) are parsed field-by-field in config_parse.zig:948–1465. Spot-checked every sub-struct: **no unparsed memory fields found.** This is the most thoroughly wired section of the config. One nuance: `MemorySearchConfig.store.qdrant_collection` IS parsed; `MemoryChunkingConfig.CHARS_PER_TOKEN` is a comptime const, not a field. Clean.

### ProductSettings (user_settings.zig:48) — the tenant/UI surface

| Key | Type | Default | Owner |
|---|---|---|---|
| `assistant_mode` | `AssistantMode` | `.balanced` | T/U |
| `group_activation` | `GroupActivation` | `.mention` | T/U |
| `proactive_updates` | `bool` | `true` | T/U |
| `voice_replies` | `bool` | `false` | T/U |
| `session_timeout_minutes` | `u32` | `30` | T/U |
| `autonomy` | `AutonomyLevel` | `.full` | T/U |

### Summary of Class-D (unparsed) bugs found

1. **`network` / `NetworkConfig.transport`** — top-level block, in operator allowlist, **no parser**. (config_types.zig:99, missing from config_parse.zig)
2. **`reliability.vision_fallback`** (`VisionFallbackConfig.provider` + `.model`) — docstring promises configurability, **no parser**. (config_types.zig:142–154)
3. **`agent.extraction`** (`ExtractionConfig` ×3 fields) — docstring promises TOML override, **no parser**. (config_types.zig:191–202, AgentConfig.extraction at :342)
4. `agent.max_history_messages` — parser *deliberately* removed; field retained for forward-compat. Documented dead config, not a bug, but a reader trap.

---

## B. Weak spots — "configs rewritten silently"

Every place a config value is set/overridden AFTER the initial `parseJson`. For each: is the rewrite intentional+visible, or silent/surprising?

### B1. `Config.applyProfileDefaults` — profile `zaki_bot` (config.zig:258–340)

Runs at the END of `parseJson` (config_parse.zig:1950) AND again in the gateway tenant path. Under `profile = "zaki_bot"` it rewrites:

| Key | Rewritten to | Guard | Verdict |
|---|---|---|---|
| `default_model` | `"kimi-k2.6"` | only if `== null` | Intentional, guarded. OK. |
| `default_provider` | `"moonshot"` | only if `== "openrouter"` sentinel AND model was null | Intentional but **subtle**: treats the struct default `"openrouter"` as "unset". An operator who *deliberately* wants openrouter+kimi cannot — the sentinel collision is silent. Surprising. |
| `reasoning_effort` | `"medium"` | only if `== null` | Intentional, guarded. OK. |
| `reliability.fallback_providers` | `&.{"together/moonshotai/Kimi-K2.6"}` | only if empty AND model is kimi-k2.6 | Intentional, guarded. OK. |
| `memory.profile` | `"postgres_hybrid"` | only if `== "markdown_only"` | Intentional but **silent**: `"markdown_only"` is also the struct default, so a zaki_bot operator who explicitly wants markdown gets postgres_hybrid with no warning. Same sentinel-collision class as `default_provider`. |
| `memory.search.provider` | `"together"` | only if `== "none"` | Sentinel collision again (`"none"` is the default). |
| `memory.search.query.hybrid.mmr.enabled` | `true` | only if `false` | `false` is the default — flips silently for zaki_bot. |
| `memory.search.query.hybrid.temporal_decay.enabled` | `true` | only if `false` | same |
| `memory.retrieval_stages.adaptive_retrieval_enabled` | `true` | only if `false` | same |
| `http_request.enabled` | `true` | only if no `http_request` key in JSON (config_parse.zig:1946) | Intentional. OK. |

**Pattern of concern:** every "only if at default" guard cannot distinguish *explicitly set to the default value* from *never set*. This is the exact mechanism of finding #1 — a default value doubling as a sentinel. For booleans (`mmr.enabled`, `temporal_decay.enabled`, `adaptive_retrieval_enabled`) an operator literally cannot set `false` under zaki_bot. **This is a silent, surprising rewrite.** Recommend `*_explicit` markers (the `token_limit_explicit` pattern already in AgentConfig) or moving these to profile-applied-only-when-key-absent semantics.

### B2. `MemoryConfig.applyProfileDefaults` (config_types.zig:761–795)

Called from `Config.applyProfileDefaults` (config.zig:325), from `parseJson` (config_parse.zig:1463), AND directly in the gateway tenant path (gateway.zig:1279, 1307, 1323, 6815). Rewrites `backend`, `search.provider`, `search.query.hybrid.enabled`, `search.store.kind`, `reliability.rollout_mode`, `auto_save` — all guarded by "still at default" checks. **Same sentinel-collision class as B1.** Also: it is invoked *redundantly* (once inside `parseJson`'s memory branch, once inside `Config.applyProfileDefaults`) — idempotent because all guards re-check defaults, but the double-call is confusing and a refactor hazard.

### B3. `normalizeTenantConfigJson` — operator-key strip (user_settings.zig:368–406)

Strips every key in `operator_owned_top_level_config_keys` (37 keys) from the tenant config JSON, counts removals into `ignored_override_count`, then re-writes a canonical `product_settings` block. **Intentional and visible** (the count is surfaced as `ignored_tenant_override_count`). BUT — this is **deny-by-omission** (Class C): a top-level key NOT in the list leaks through to the tenant. That is exactly how finding #3 happened (`sidecar` was missing). See section E for the inversion design. Current residual risk: any *new* top-level config block added to `config_types.zig` + `Config` that the author forgets to also add to `operator_owned_top_level_config_keys` immediately becomes tenant-shadowable. There is **no compile-time or test check** binding the two lists.

### B4. `applySettingsToConfig` (user_settings.zig:408–458)

Runs LAST in the tenant build path (gateway.zig:1280, 1308, 6816), after parse + profile defaults. Unconditionally overwrites:

| Field | Source | Verdict |
|---|---|---|
| `cfg.reasoning_effort` | `assistant_mode` → low/medium/high | only if `== null` — guarded, OK |
| `cfg.agent.activation_mode` | `group_activation` | **unconditional overwrite** of whatever parse/profile set |
| `cfg.agent.send_mode` | `proactive_updates` | unconditional |
| `cfg.agent.tts_mode` | `voice_replies` | unconditional |
| `cfg.agent.tts_audio` | `voice_replies` | unconditional |
| `cfg.agent.session_idle_timeout_secs` | `session_timeout_minutes × 60` | unconditional |
| `cfg.session.cross_channel_shared_main` | hard-coded `false` | unconditional — **surprising**: silently ignores any operator `session.cross_channel_shared_main: true` for tenant runtimes |
| `cfg.autonomy.level` | `product_settings.autonomy` | unconditional |

The unconditional overwrites are **intentional** (these six `agent.*` fields are the tenant-preference projection) but they mean the operator's raw `agent.activation_mode` etc. in config.json is **dead for tenant runtimes** — only `product_settings` controls them. This is correct by design but under-documented; an operator editing `agent.activation_mode` directly will see no effect in multi-tenant mode. `cross_channel_shared_main = false` hard-coded is the most surprising line — it is not derived from any `ProductSettings` field.

### B5. `applySecretRuntimeOverrides` (config.zig:243–254)

`applyEnvOverrides` → injects `INTERNAL_SERVICE_TOKEN` env into `gateway.internal_service_tokens` and `POSTGRES_CONNECTION_STRING` env into `state.postgres.connection_string`. Intentional, env-precedence, standard. OK.

### B6. `applyEnvOverrides` (config.zig:614–685)

Env vars override `default_provider`, `default_model`, `default_temperature`, `gateway.port`, `gateway.host`, `workspace_dir`, `gateway.allow_public_bind`. Intentional, documented precedence (env beats file). OK. Note: env overrides run in `Config.load` but **NOT** in the gateway tenant path (gateway.zig builds `runtime.config = base_config.*` then re-parses — env overrides were already applied to `base_config`, so they survive the copy; tenant-overlay parse can then re-overwrite them, which is intended).

### B7. Layering order in the gateway tenant build (gateway.zig:1222–1316, 6787–6816)

The precedence chain for a tenant runtime is:

```
runtime.config = base_config.*            (struct copy — includes env overrides already applied to base)
  → normalizeTenantConfigJson(tenant_json)  (strips operator keys, B3)
  → parseJson(snapshot.json)                (tenant overlay — only product_settings + non-operator keys survive)
  → applyProfileDefaults()                  (B1 — profile rewrites)
  → memory.applyProfileDefaults()           (B2 — redundant, called again)
  → applySettingsToConfig(resolved_settings) (B4 — product_settings projection wins last)
  → (if state.backend == postgres) memory.backend = "markdown"  (gateway.zig:1323 — another silent rewrite)
```

**Order verdict:** base → tenant-overlay → profile → product_settings is coherent. Two concerns:
- `memory.applyProfileDefaults()` is called *both* inside `parseJson` and again explicitly (gateway.zig:1279) — harmless but redundant.
- gateway.zig:1323 silently forces `memory.backend = "markdown"` when `state.backend == "postgres"`. This overrides whatever the profile just set (`postgres_hybrid` profile sets `backend = "postgres"`). It is intentional (zaki_bot uses a bespoke memory table shape) but it is a **fourth silent rewrite** in the chain and is not obvious from reading config.zig alone.

### B8. `setInternalServiceToken` (config.zig:237–241)

Replaces the entire `gateway.internal_service_tokens` slice with a single env-derived token. Intentional. OK.

---

## C. Defaults with no test coverage

The compact_context regression happened because no test asserted the **default**. The "json parse agent section" test (config.zig:2069) passes `compact_context: true` *explicitly* — so it pins the *parse path* but NOT the default. "json parse empty object uses defaults" (config.zig:2199) asserts only `default_provider`, `default_temperature`, `secrets.encrypt` — it does **not** touch `agent.*`.

Load-bearing defaults with **NO test pinning them**:

| Default | Value | Risk if silently flipped | Test exists? |
|---|---|---|---|
| `AgentConfig.compact_context` | `true` | **Compaction globally off** (the finding-#1 outcome) | **NO** — finding #1's root cause is still uncovered |
| `AgentConfig.max_tool_iterations` | `500` | runaway or premature tool loop cutoff | only via explicit-value parse test |
| `AgentConfig.extraction_cardinality_fastpath` | `true` | covered — config.zig:1132 "all three new gate flags default to true" | YES (one of the few) |
| `AgentConfig.extraction_coverage_filter_enabled` | `true` | covered — config.zig:1132 | YES |
| `SidecarConfig.enabled` | `true` | sidecar off → no narration/extraction | **NO** |
| `SidecarConfig.provider` / `.model` | `groq` / `llama-3.1-8b-instant` | finding #4 footgun re-armed on fresh deploy | **NO** |
| `AutonomyConfig.level` | `.full` | auto-approve everything | partially — user_settings.zig:875 pins `ProductSettings.autonomy` default `.full`, not `AutonomyConfig.level` |
| `MemoryConfig.auto_save` | `true` | memory writes silently stop | **NO** |
| `MemoryConfig.profile` | `"markdown_only"` | wrong backend selected | **NO** |
| `SecurityConfig.sandbox.enabled` | `null` (auto) | sandbox posture change | **NO** direct default test |
| `SecurityConfig.sandbox.fail_open_on_dev` | `false` (fail-closed) | **silent unsandboxed shell in prod** if flipped | **NO** |
| `GatewayConfig.require_pairing` | `true` | covered — config.zig:1948 | YES |
| `GatewayConfig.allow_public_bind` | `false` | covered — config.zig:1953 | YES |
| `GatewayConfig.require_explicit_chat_stream_session_key` | `true` | covered — config.zig:1172 | YES |
| `MemoryConfig.lifecycle.purge_after_days` | `30` | data retention | **NO** |
| `ReliabilityConfig.provider_retries` | `2` | covered indirectly by validation bounds tests | partial |

**Highest priority untested defaults** (a silent flip is a production incident): `compact_context`, `sidecar.enabled`, `sidecar.provider/model`, `security.sandbox.fail_open_on_dev`, `memory.auto_save`. The gateway-security defaults ARE well covered — the *agent/memory/sidecar* defaults are the gap, which is precisely where findings #1 and #4 landed.

---

## D. Operator vs tenant vs UI ownership

### What the operator controls (config.json, not tenant-overridable)

All 37 keys in `operator_owned_top_level_config_keys` (user_settings.zig:136–185): providers/API keys, models, model routes, sub-agents, MCP servers, `agent` (compaction, tool iteration, queueing), `sidecar` (extraction/narration model), `reliability`, `memory`, `gateway`, `tenant`, `state`, `security` (sandbox, autonomy *bounds*), `channels`, `cost`, `tools`, `session`, `browser`, etc. Plus env-var overrides (B6) and the secret-injection path (B5). **Note one stale entry:** `product_presets` is still in the list (user_settings.zig:184) although the preset machinery was deleted (config_types.zig:204–207 confirms `ProductPresetsConfig` is gone). Harmless — it just means a stray `product_presets` block gets stripped — but it is dead allowlist surface.

### What a tenant / end-user can change from the UI

Exactly the six `ProductSettings` fields (user_settings.zig:187–194): `assistant_mode`, `group_activation`, `proactive_updates`, `voice_replies`, `session_timeout_minutes`, `autonomy`. The UI writes them via `applyPatchToSettingsJson` → `mergeSettingsIntoConfigJson`; they project onto config via `applySettingsToConfig` (B4). The tenant's `autonomy` choice is bounded — it can only pick a *level*, never the operator's `workspace_only` / `allowed_commands` / `allowed_paths`.

### Is `product_settings` the COMPLETE legitimate tenant surface?

**Yes, with one ambiguity and one caveat:**

- **Ambiguity — `brave_api_key` / `exa_api_key` / `web_search_brave_api_key` / `web_search_exa_api_key`.** These are NOT top-level operator-owned keys in the deny list (`exa_api_key` and `brave_api_key` are legacy top-level aliases, config_parse.zig:936–945; the canonical forms live under `tools`). Under the current deny-by-omission allowlist, legacy `brave_api_key` / `exa_api_key` at the top level **leak through to the tenant** — a tenant could supply their own search API key. Whether that is *legitimate* is a product call: per-tenant BYO-search-key is a plausible feature, but it is currently *accidental* (not deliberate), and the canonical `tools.*` forms are correctly operator-owned. This is an inconsistency: the same setting is operator-owned in one spelling and tenant-leakable in another.
- **Caveat — anything not in the 37-key deny list leaks.** Today the only top-level keys a real config uses outside the list are `product_settings` (tenant), the two legacy search-key aliases, and any typo'd/unknown key. So `product_settings` *is* the complete *intended* tenant surface — but the enforcement is by omission, not by allowlist, so the boundary is one forgotten list entry away from breaking (finding #3).

**Conclusion:** `product_settings` is the complete legitimate tenant/UI surface. The legacy `brave_api_key`/`exa_api_key` top-level aliases are an ambiguous edge that section E resolves (they should be stripped — operators set keys via `tools` or `models.providers`).

---

## E. Allowlist-inversion design

### Current (broken) design

`normalizeTenantConfigJson` (user_settings.zig:381–385) iterates `operator_owned_top_level_config_keys` and strips each one it finds. **A key not in the list is kept.** This is deny-by-omission: the safe default is "leak". Finding #3 = `sidecar` was not in the list, so it leaked.

### Inverted design — strict tenant allowlist

`normalizeTenantConfigJson` should **keep only** keys in an explicit tenant-allowlist and **strip everything else** (including unknown/typo'd keys). The safe default becomes "strip".

**The inverted allowlist permits exactly:**

```
tenant_allowed_top_level_keys = [
    "product_settings",   // the canonical tenant surface
]
```

That is it — one key. Everything else at the top level is operator-owned and must be stripped from a tenant config.

### Precise change to `normalizeTenantConfigJson` (user_settings.zig:368–406)

Replace the strip loop (lines 381–385):

```zig
var ignored_override_count: usize = 0;
inline for (operator_owned_top_level_config_keys) |key| {
    if (topLevelKeyOwnership(key) == .operator) {
        if (root_obj.swapRemove(key)) ignored_override_count += 1;
    }
}
```

with an iterate-and-strip-non-allowlisted pass:

```zig
const tenant_allowed_top_level_keys = [_][]const u8{ "product_settings" };

var ignored_override_count: usize = 0;
// Collect keys first — cannot swapRemove while iterating the map.
var keys_to_strip: std.ArrayListUnmanaged([]const u8) = .empty;
defer keys_to_strip.deinit(a);
var it = root_obj.iterator();
while (it.next()) |entry| {
    const key = entry.key_ptr.*;
    var allowed = false;
    inline for (tenant_allowed_top_level_keys) |ak| {
        if (std.mem.eql(u8, key, ak)) allowed = true;
    }
    if (!allowed) try keys_to_strip.append(a, key);
}
for (keys_to_strip.items) |key| {
    if (root_obj.swapRemove(key)) ignored_override_count += 1;
}
```

`operator_owned_top_level_config_keys` and `topLevelKeyOwnership` can stay for `OwnershipPlane` classification (diagnostics still use them), but they are no longer the *enforcement* mechanism — the allowlist is.

### What breaks under the inversion (and whether that is correct)

- **A tenant `brave_api_key` / `exa_api_key` would now be stripped.** **Correct.** Search API keys are operator infrastructure (cost-bearing, rate-limited). The canonical `tools.web_search_*` and `models.providers` forms are already operator-owned; stripping the legacy top-level aliases closes the inconsistency noted in D. If per-tenant BYO-search-key is ever a wanted feature, it should be a *deliberate* field inside `product_settings`, not a leaked top-level key.
- **A tenant `sidecar` / `network` / `agent` / `memory` / any operator block would be stripped.** Correct — that is the whole point; deny-by-default.
- **Unknown / typo'd keys are stripped.** Correct and a strict improvement: today a typo leaks; under the inversion it is removed and counted.
- **Nothing legitimate breaks** — the only key a real tenant config carries that must survive is `product_settings`, and it is on the allowlist.

This is a one-commit follow-up: ~15 lines in `normalizeTenantConfigJson`, plus the new test in F. The existing test "normalizeTenantConfigJson strips operator-owned overrides" (user_settings.zig:841) keeps passing — it asserts `agent`/`memory`/`default_provider`/`models`/`product_presets` are stripped and `product_settings` survives; under the inversion all of those are still stripped (now by omission from the allowlist) and `product_settings` still survives. Note `ignored_override_count` would change: that test seeds `foo:"bar"` which is currently *kept* (unknown key, leaks) but would be *stripped* under the inversion — the expected count goes from `5` to `6`, and the assertion `parsed.value.object.get("foo")` would flip from `"bar"` to `null`. **That test must be updated as part of the inversion commit** (it currently encodes the leaky behavior as correct).

---

## F. Hardening recommendations (ranked)

### Rank 1 — The four enforcement tests that would have caught findings #1/#3/#4

Add to `src/config.zig` / `src/user_settings.zig` test blocks:

1. **`compact_context` default is `true`** (catches finding #1):
   ```zig
   test "agent compact_context defaults to true" {
       var cfg = Config{ .workspace_dir = "/tmp/x", .config_path = "/tmp/x/c.json", .allocator = std.testing.allocator };
       try cfg.parseJson("{}");
       try std.testing.expect(cfg.agent.compact_context);
   }
   ```
2. **`sidecar` block round-trips through parse** (catches finding #4):
   ```zig
   test "sidecar block parses provider/model/enabled/narration_interval" {
       var cfg = Config{ ... };
       try cfg.parseJson(
           \\{"sidecar":{"enabled":false,"provider":"together","model":"meta-llama/Llama-3.3-70B-Instruct-Turbo","narration_interval":7}}
       );
       try std.testing.expect(!cfg.sidecar.enabled);
       try std.testing.expectEqualStrings("together", cfg.sidecar.provider);
       try std.testing.expectEqualStrings("meta-llama/Llama-3.3-70B-Instruct-Turbo", cfg.sidecar.model);
       try std.testing.expectEqual(@as(u32,7), cfg.sidecar.narration_interval);
   }
   ```
3. **Tenant config strips operator keys** (catches finding #3) — extend the existing test, or add one asserting a `sidecar` block in a tenant config is removed by `normalizeTenantConfigJson` and counted. Under the section-E inversion this becomes "strips everything except `product_settings`".
4. **Extraction provider/model agree** (catches finding #2) — an integration-level assert in the gateway extraction-wire path (gateway.zig:1583–1595): when a sidecar is configured, `extract_provider_i` and `extract_model_i` come from the *same* `SidecarConfig` block. A unit test on a helper that resolves the pair from `Config` would pin it.

### Rank 2 — Struct-field ↔ parser consistency check

The Class-D bugs (sidecar pre-fix, `network`, `vision_fallback`, `agent.extraction`) all share one root cause: a field exists in `config_types.zig` with no corresponding `root.get(...)` in `config_parse.zig`, and nothing detects the gap. Two options:

- **Compile-time (preferred):** a `comptime` block in `config_parse.zig` that walks `std.meta.fields(Config)` and, for each top-level field, requires either a registered parser or an explicit `// DECORATIVE: <reason>` allowlist entry. Zig's `@typeInfo` makes the top-level walk feasible; nested structs are harder but the top-level check alone would have caught `network`.
- **Test-based (cheaper):** a round-trip test — `save()` a non-default `Config`, `parseJson()` it back, assert every field survives. Any field that `save` writes but `parseJson` drops (or vice versa) fails the test. This is the highest-leverage single test: it catches *every* Class-D bug at once. Note `save()` itself currently does NOT serialize `sidecar` or `network` (config.zig:825–907) — so the round-trip test must be paired with a `save`-completeness fix, or the test should diff against a hand-built expected JSON.

### Rank 3 — Fix the three Class-D bugs found

- **`network`** — add a `root.get("network")` branch parsing `network.transport` (mirror the `runtime.docker` branch), OR delete `NetworkConfig`/`Config.network` if transport is genuinely not config-surfaced. Decide intentionally.
- **`reliability.vision_fallback`** — the docstring calls the unset state a "current regression." Either add the parser (`reliability.vision_fallback.provider` + `.model`) or delete the field. Do not leave a docstring promising a knob that does not exist.
- **`agent.extraction`** (`ExtractionConfig`) — the trigger sites were deleted in V1.14.7 C3, so these flags have neither a parser nor a consumer. **Delete `ExtractionConfig` and `AgentConfig.extraction`** per the repo's §14.5 no-loose-ends discipline; keep the migration history in a comment.

### Rank 4 — Allowlist inversion (section E)

Implement the strict tenant-allowlist in `normalizeTenantConfigJson`. One commit. Update the existing `normalizeTenantConfigJson` test (the `foo:"bar"` expectation flips, count `5`→`6`).

### Rank 5 — `SidecarConfig` struct-default footgun

The struct default is still `groq` / `llama-3.1-8b-instant` (config_types.zig:217, 220). A fresh deploy with **no `sidecar` block** re-hits finding #4: extraction routed through Groq's free tier, compaction call-burst exhausts the TPM budget, every boundary extraction past the first fails — silently. Recommend: in `Config.applyProfileDefaults` under `.zaki_bot`, default the sidecar to a capable provider/model when the operator did not set one (same guarded-default pattern as `default_model`). E.g. `together` + `meta-llama/Llama-3.3-70B-Instruct-Turbo` (the model `extraction_judge_model`'s own docstring already recommends, config_types.zig:267–269). This makes the *correct* extraction sidecar the zaki_bot default rather than relying on every operator to remember the `sidecar` block.

### Rank 6 — Eliminate the sentinel-collision rewrites (B1/B2)

The `if (x == default) x = profile_value` pattern cannot distinguish "explicitly set to default" from "unset", so under `zaki_bot` an operator literally cannot set `memory.search.query.hybrid.mmr.enabled = false`, `memory.profile = "markdown_only"`, `default_provider = "openrouter"`, etc. Adopt the `*_explicit` marker pattern already proven by `AgentConfig.token_limit_explicit` (config_types.zig:259) for the profile-overridden keys, OR have the parser record which keys were present in the JSON and pass that set to `applyProfileDefaults`. Lower urgency than 1–5 (no active incident) but it is the same *class* of latent bug as finding #1.

### Rank 7 — Documentation / minor cleanup

- Remove the stale `"product_presets"` entry from `operator_owned_top_level_config_keys` (user_settings.zig:184) — the preset machinery is deleted.
- Document in `applySettingsToConfig` (or AGENTS.md) that for tenant runtimes the operator's raw `agent.activation_mode` / `send_mode` / `tts_mode` / `tts_audio` / `session_idle_timeout_secs` are **dead** — only `product_settings` controls them (B4).
- Document the gateway.zig:1323 `memory.backend = "markdown"` postgres override — it is invisible from config.zig.
- The redundant double `memory.applyProfileDefaults()` call (parseJson + Config.applyProfileDefaults) is harmless but should be de-duplicated.

---

## Verification — scope coverage

| Scope item | Coverage | Notes |
|---|---|---|
| 1. config_types.zig — every struct/field default | **Full.** Read all 1316 lines. Every struct and default catalogued in section A. |
| 2. config_parse.zig — every parser, field-by-field | **Full.** Read all 1951 lines. Cross-checked every `config_types` field against a `root.get` / sub-object branch. Found 3 unparsed surfaces (`network`, `reliability.vision_fallback`, `agent.extraction`) + 1 deliberately-removed (`max_history_messages`). |
| 3. config.zig — load, applyProfileDefaults, mutators | **Full.** Read load(), applyProfileDefaults, applyEnvOverrides, applySecretRuntimeOverrides, syncFlatFields, save(), the agent-write block, validate(). Memory profile defaults read in config_types.zig. All post-parse rewrites mapped in section B. |
| 4. user_settings.zig — ownership boundary | **Full.** Read all 1013 lines incl. all tests. `operator_owned_top_level_config_keys`, `topLevelKeyOwnership`, `normalizeTenantConfigJson`, `applySettingsToConfig`, `resolveSettingsFromConfigJson`, `ProductSettings` all analysed. |
| 5. gateway.zig TenantRuntime build path | **Full.** Read TenantRuntime.init (1205–1340) and the builder path (6787–6816) plus the extraction-wire block (1560–1720). Layering order documented (B7). |
| 6. Other readers — model_capabilities, runtime_bundle | **Full.** Confirmed `providers/runtime_bundle.zig` reads `sidecar` (57–73); `agent/model_capabilities.zig` MODEL_TABLE is a static per-model context-window table, not config-derived (no config coupling — clean). `compact_context` runtime readers in `agent/context_*` confirmed. Verified `model_capabilities.zig` lives at `src/agent/`, not `src/`. |

**Residual gaps not chased to the bottom:** (a) the *nested-struct* parser-completeness walk in section A was spot-checked, not exhaustively diffed for every leaf of `MemoryConfig`'s 11 sub-structs — memory was sampled at every sub-struct and found complete, but a mechanical `save→parse` round-trip test (Rank 2) is the real proof. (b) `save()` completeness was noted (it omits `sidecar` and `network`) but not fully audited field-by-field — flagged for the Rank 2 test. (c) Channel-config parsing uses a generic `std.json.parseFromValueLeaky` path (`parseTypedValue`, config_parse.zig:228) which auto-covers all channel struct fields — so channels are NOT at Class-D risk, but the generic path also means a renamed field silently stops parsing with no error; out of this audit's finding-class scope but worth a note.
