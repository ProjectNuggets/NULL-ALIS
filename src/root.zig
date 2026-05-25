//! nullalis — The smallest AI assistant. Zig-powered.
//!
//! Module hierarchy mirrors ZeroClaw's Rust architecture:
//!   agent, channels, config, cron, daemon, doctor, gateway,
//!   health, heartbeat, memory, observability, onboard,
//!   providers, security, skills, tools
//!
//! (Hardware module dropped from this list D19 / 2026-04-25 along
//! with the rest of the hardware surface — V1 is a second-brain
//! runtime, not an embedded-device runtime.)

// Shared utilities
pub const json_util = @import("json_util.zig");
pub const http_util = @import("http_util.zig");
pub const http_native = @import("http_native/root.zig");
pub const net_security = @import("net_security.zig");
pub const websocket = @import("websocket.zig");
/// Wave 3B — gateway-side WebSocket server for the browser
/// extension. Three sub-modules (server / hub / auth) split along
/// testability boundaries; the gateway dispatch routes
/// `/api/v1/extension/ws` into `extension_ws.server.handleUpgrade`.
pub const extension_ws = struct {
    pub const server = @import("extension_ws/server.zig");
    pub const hub = @import("extension_ws/hub.zig");
    pub const auth = @import("extension_ws/auth.zig");
};

// Phase 1: Core
pub const bus = @import("bus.zig");
pub const config = @import("config.zig");
pub const util = @import("util.zig");
pub const platform = @import("platform.zig");
pub const version = @import("version.zig");
// v1.14.18 Step 8 (V6) — `state.zig` deleted. The legacy file-backed
// runtime-state helper (`~/.nullalis/state.json`) had zero production
// callers at audit time; everything tenant-Postgres reads/writes goes
// through `zaki_state` (re-exported below). The audit's prescriptive
// deprecation steps (warnings, migration script, --allow-legacy-state
// gate) were predicated on live callers — with none, there is nothing
// to deprecate. An operator with a stale `~/.nullalis/state.json` on
// disk can safely delete it; no current code reads it.
/// **S10.1** versioned schema-migrations framework. Replaces the
/// boot-time `for (statements) |s| exec(s)` pattern in
/// `zaki_state.zig::migrate`. See `src/migrations.zig` header for
/// the full design rationale + how to add a new migration.
pub const migrations = @import("migrations.zig");
pub const status = @import("status.zig");
pub const onboard = @import("onboard.zig");
pub const doctor = @import("doctor.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const capabilities = @import("capabilities.zig");
pub const config_mutator = @import("config_mutator.zig");
pub const service = @import("service.zig");
pub const daemon = @import("daemon.zig");
pub const sentry_runtime = @import("sentry_runtime.zig");
pub const env_rebrand = @import("env_rebrand.zig");
pub const entitlement = @import("entitlement.zig");
pub const channel_loop = @import("channel_loop.zig");
pub const channel_manager = @import("channel_manager.zig");
pub const channel_catalog = @import("channel_catalog.zig");
pub const migration = @import("migration.zig");
pub const sse_client = @import("sse_client.zig");
pub const update = @import("update.zig");

// Phase 2: Agent core
pub const agent = @import("agent.zig");
pub const session = @import("session.zig");
pub const session_types = @import("session/root.zig");
pub const user = @import("user.zig");
pub const gdpr = @import("gdpr.zig");
pub const providers = @import("providers/root.zig");
pub const memory = @import("memory/root.zig");
pub const bootstrap = @import("bootstrap/root.zig");

// Phase 3: Networking
pub const gateway = @import("gateway.zig");
pub const gateway_run_events = @import("gateway_run_events.zig");
pub const gateway_secret_vault = @import("gateway/secret_vault.zig");
pub const controller = @import("controller.zig");
pub const cell_spec = @import("cell_spec.zig");
pub const cell_k8s_api = @import("cell_k8s_api.zig");
pub const channels = @import("channels/root.zig");

// Phase 4: Extensions
pub const security = @import("security/root.zig");
pub const cron = @import("cron.zig");
pub const health = @import("health.zig");
pub const skills = @import("skills.zig");
pub const tools = @import("tools/root.zig");
pub const tasks = @import("tasks/root.zig");
/// Wave 2C — canvas/artifacts backend. Types + diff + sanitizer +
/// share-code helper; storage CRUD lives on `zaki_state.Manager`.
pub const artifacts = @import("artifacts/root.zig");
pub const identity = @import("identity.zig");
pub const cost = @import("cost.zig");
pub const usage_runtime = @import("usage_runtime.zig");
pub const observability = @import("observability.zig");
pub const run_trace_store = @import("run_trace_store.zig");
pub const heartbeat = @import("heartbeat.zig");
pub const runtime = @import("runtime.zig");

// Phase 4b: MCP (Model Context Protocol)
pub const mcp = @import("mcp.zig");
/// Sprint 2 — nullalis AS an MCP server: exposes the tool registry over
/// JSON-RPC 2.0 stdio so external clients can use nullalis as a tool
/// provider. The inverse of `mcp` (the client). Entry: `nullalis mcp serve`.
pub const mcp_server = @import("mcp_server.zig");
pub const subagent = @import("subagent.zig");

// Phase 4c: Auth
pub const auth = @import("auth.zig");

// Phase 4d: Multimodal
pub const multimodal = @import("multimodal.zig");
pub const model_capabilities = @import("agent/model_capabilities.zig");
pub const user_settings = @import("user_settings.zig");

// Phase 4e: Agent Routing
pub const agent_routing = @import("agent_routing.zig");

// Phase 5: Integrations.
// V1 convergence history (kept as a tombstone trail so future maintainers
// understand the absences):
//   • S6.1 — rag.zig (datasheet-RAG, hardware-adjacent) deleted; no consumers.
//   • D19  — hardware CLI command + `HardwareConfig` struct + parser branch +
//     status display + capabilities entries + tools/root.zig boards stub
//     all removed (2026-04-25). The "hardware" command surface is gone.
//   • Peripherals struct still present but inert; revisit if a fork ever
//     reintroduces embedded-device support.
pub const integrations = @import("integrations.zig");
pub const tunnel = @import("tunnel.zig");
pub const voice = @import("voice.zig");
pub const zaki_state = @import("zaki_state.zig");
pub const channel_identity_key = @import("channel_identity_key.zig");
pub const inbound_canonicalizer = @import("inbound_canonicalizer.zig");

// Phase 02.1: Streaming, Voice & Channel Polish
pub const channel_health = @import("channel_health.zig");
pub const security_review = @import("security_review.zig");

test {
    // Run tests from all imported modules
    @import("std").testing.refAllDecls(@This());
}
