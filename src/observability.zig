const std = @import("std");
const env_rebrand = @import("env_rebrand.zig");

/// Semantic frame types for user-facing narration events.
pub const NarrationFrameType = enum {
    thinking,
    tool_start,
    tool_done,
    waiting,
    plan_step,
    error_recovery,
    listening, // voice STT active
    speaking, // voice TTS active
};

/// Events the observer can record.
pub const ObserverEvent = union(enum) {
    agent_start: struct { provider: []const u8, model: []const u8 },
    llm_request: struct {
        provider: []const u8,
        model: []const u8,
        messages_count: usize,
        run_id: ?[]const u8 = null,
    },
    llm_response: struct {
        provider: []const u8,
        model: []const u8,
        duration_ms: u64,
        success: bool,
        error_message: ?[]const u8,
        run_id: ?[]const u8 = null,
    },
    agent_end: struct {
        duration_ms: u64,
        tokens_used: ?u64,
        run_id: ?[]const u8 = null,
        /// 2026-05-24: per-turn cost-weight summed over tools the agent
        /// dispatched this turn. Pairs with session_weight to feed the
        /// zaki-prod central usage meter. null when UsageRuntime wasn't
        /// wired (CLI / standalone test paths).
        turn_weight: ?u64 = null,
        /// 2026-05-24: cumulative cost-weight across the session so far.
        /// null when UsageRuntime wasn't wired.
        session_weight: ?u64 = null,
    },
    tool_call_start: struct {
        tool: []const u8,
        tool_use_id: ?[]const u8 = null,
        input_preview: ?[]const u8 = null,
        command: ?[]const u8 = null,
        files: ?[]const []const u8 = null,
        activity_label: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
    },
    tool_call: struct {
        tool: []const u8,
        duration_ms: u64,
        success: bool,
        tool_use_id: ?[]const u8 = null,
        output_preview: ?[]const u8 = null,
        output_truncated: bool = false,
        result_summary: ?[]const u8 = null,
        command: ?[]const u8 = null,
        files: ?[]const []const u8 = null,
        exit_code: ?i32 = null,
        run_id: ?[]const u8 = null,
    },
    tool_iterations_exhausted: struct { iterations: u32 },
    /// S5.8 — loop-detected exit is distinct from iterations-exhausted.
    /// Exhausted = the model used N iterations without finishing.
    /// Loop detected = the model called the same tools repeatedly and
    /// the loop-guard tripped early. Operators need to tell these apart:
    /// "exhausted" may mean "give it more iterations", "loop_detected"
    /// means "prompt/tool contract is steering the model in circles".
    loop_detected: struct { iteration: u32, iterations_cap: u32 },
    turn_cancelled: struct { reason: []const u8, iteration: u32 },
    turn_stage: struct {
        stage: []const u8,
        iteration: ?u32 = null,
        duration_ms: ?u64 = null,
        count: ?u32 = null,
        tool_use_id: ?[]const u8 = null,
        task_id: ?[]const u8 = null,
        group_id: ?[]const u8 = null,
        heartbeat: bool = false,
        command: ?[]const u8 = null,
        files: ?[]const []const u8 = null,
        run_id: ?[]const u8 = null,
    },
    turn_complete: void,
    /// **D1.4** — emitted just before `turn_complete` when the model
    /// produced tool/spawn calls but no post-tool assistant text. Lets
    /// the gateway/BFF render a structured frame (e.g. "[2 tools ran;
    /// subagent results may arrive on a follow-up]") instead of falling
    /// back to the historical fabricated placeholder string for the
    /// reply text. (The dead placeholder const was removed from
    /// gateway.zig at v1.14.13 Step 5.)
    ///
    /// `tool_calls_executed` is the count of tool calls fired across
    /// all tool-loop iterations of this turn (equivalent to the
    /// pre-existing `turn_tool_calls_total` counter — exposed here for
    /// SSE consumers without a separate event lookup).
    /// `spawned_task_ids` lists IDs of `spawn`/`delegate` tool calls
    /// whose results will arrive on a separate bus frame later. Empty
    /// slice means none / not yet tracked (D1.4b will populate this
    /// once the executor records the full list per turn). Each id is
    /// an unowned borrow into the agent's lifetime.
    /// `iterations_used` is the tool-loop iteration count (same as
    /// `tool_iterations_exhausted.iterations` would carry, but for the
    /// happy path).
    tool_only_turn: struct {
        tool_calls_executed: u32,
        spawned_task_ids: []const []const u8 = &.{},
        iterations_used: u32,
        run_id: ?[]const u8 = null,
    },
    channel_message: struct { channel: []const u8, direction: []const u8 },
    heartbeat_tick: void,
    err: struct { component: []const u8, message: []const u8 },
    narration_frame: struct {
        message: []const u8,
        frame_type: NarrationFrameType,
        tool_name: ?[]const u8 = null,
        step_index: ?u32 = null,
        step_total: ?u32 = null,
    },
    task_update: struct {
        task_id: []const u8,
        status: []const u8,
        description: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
    },
    /// Emitted when a supervised mutating tool needs user approval before running.
    /// Payload is intentionally non-sensitive — no raw tool arguments.
    approval_required: struct {
        tool: []const u8,
        reason: []const u8,
        risk_level: []const u8,
        run_id: ?[]const u8 = null,
    },
    /// Binding principle: no silent fallback. When nullalis degrades or has a
    /// notable internal state change the user deserves to know about, emit a
    /// system_notice. Frontend should render as chrome (badge / toast) separate
    /// from reply content. kinds: compaction | provider_fallback |
    /// connector_stale | multimodal_failure | generic.
    system_notice: struct {
        kind: []const u8,
        severity: []const u8,
        message: []const u8,
        detail: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
    },
    /// Emitted by context_engine.ingest() after each turn's memory load.
    /// Surfaces SelectionStats data through the run trace store so it
    /// appears in /api/v1/users/{user_id}/traces/{run_id} responses.
    memory_retrieval: struct {
        /// Per-bucket entry counts as a compact summary string.
        status: ?[]const u8 = null,
        /// True when memory was injected into the prompt this turn.
        success: bool = false,
        /// Total context bytes contributed by memory.
        usage_tokens: ?u64 = null,
        /// Number of candidates considered by the retrieval pipeline.
        iteration: ?u32 = null,
        /// Wall-clock duration of the memory enrichment phase.
        duration_ms: ?u64 = null,
        run_id: ?[]const u8 = null,
    },
    /// Wave 2C — canvas/artifacts side-panel notification. Emitted by
    /// the artifact_create / artifact_update tools. RunEventObserver
    /// translates this into an `artifact_event` SSE frame so the FE
    /// can refresh the side panel without polling. Slices borrowed
    /// for the duration of the call only — observers must copy if
    /// they want to retain (mirrors task_update payload lifetime).
    artifact_event: struct {
        op: []const u8,
        artifact_id: []const u8,
        title: []const u8,
        kind: []const u8,
        version: u64,
        url: []const u8,
        change_summary: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
    },
};

/// Numeric metrics.
///
/// **v1.14.23 extension (review HIGH 2.A):** the original four kinds
/// (latency / tokens / sessions / queue) covered the agent core but
/// gave the v1.14.20→22 surface (artifacts, extension WS hub, share
/// store, produce_document, trace_query, memory_doctor, Moonshot
/// uploads) zero chartable signal. The added kinds below let
/// dashboards count + histogram every operationally interesting
/// surface without re-keying through scoped logs.
///
/// **Convention:**
///   - `*_total` — monotonic counters (the value is the increment,
///     usually 1; backends are expected to sum them).
///   - `*_latency_ms` / `*_bytes` — point-in-time samples that
///     histogram-backends should bucket.
///   - `*_active` — gauges (current value, observers should track
///     the most recent sample).
///
/// `result` and `format` are short ASCII identifiers (e.g. "ok",
/// "timeout", "conn_closed", "oom", "pdf", "docx", "share_limit") —
/// observers may label-shard metric series by them. Slices are
/// borrowed for the duration of the recordMetric call only; an
/// observer that retains must dupe.
pub const ObserverMetric = union(enum) {
    request_latency_ms: u64,
    tokens_used: u64,
    active_sessions: u64,
    queue_depth: u64,

    // ── v1.14.23 added (closing v1.14.20→22 observability gap) ──

    /// Artifact lifecycle counters — every successful create/update/
    /// share/revoke increments by 1. Tenant attribution is via the
    /// active `getTenantContext()` at emit time; the metric payload
    /// itself stays single-scalar to keep the union small.
    artifact_create_total: u64,
    artifact_update_total: u64,
    artifact_share_total: u64,
    artifact_share_revoke_total: u64,

    /// Share-spam cap (D64). `share_create_429_total` fires when the
    /// per-user `MAX_LIVE_SHARES_PER_USER` cap denies a new share;
    /// `share_create_success_total` fires on every successful mint
    /// (idempotent re-mints DO NOT increment — they fold into the
    /// existing record).
    share_create_success_total: u64,
    share_create_429_total: u64,

    /// Extension WS hub.
    ///   - `extension_ws_connections_active` is a gauge — observers
    ///     should overwrite the prior sample with the new value.
    ///   - `extension_ws_command_latency_ms` is a per-command sample
    ///     (the histogram backend buckets it).
    extension_ws_connections_active: u64,
    extension_ws_command_latency_ms: u64,

    /// Extension WS command result counter. `result` is one of:
    /// "ok", "timeout", "conn_closed", "oom", "queue_drained",
    /// "command_alloc_failed", "no_conn", "registration_failed".
    /// The tool name is the optional `tool` label.
    extension_ws_command_total: struct {
        result: []const u8,
        tool: ?[]const u8 = null,
    },

    /// SSRF-defense denial in extension navigate. Operators want to
    /// see this on a chart so an extension-only deployment with a
    /// misconfigured allowlist surfaces fast.
    extension_ws_ssrf_block_total: u64,

    /// produce_document tool. `format` is "pdf|docx|pptx|xlsx|html|
    /// md". `result` is "ok|tool_missing|render_failed|invalid_input".
    produce_document_total: struct {
        format: []const u8,
        result: []const u8,
    },
    produce_document_latency_ms: struct {
        format: []const u8,
        value: u64,
    },

    /// Read-only introspection tools — usage counters.
    trace_query_total: u64,
    memory_doctor_total: u64,

    /// Moonshot Files API video upload (large-payload path).
    /// `result` is "ok|http_4xx|http_5xx|network_error|size_cap".
    moonshot_video_upload_total: struct { result: []const u8 },
    /// Bytes-on-the-wire histogram for the same upload.
    moonshot_video_upload_bytes: u64,

    // ── S5 (2026-05-29, prod-readiness) — chartable signals ──

    /// Approval lifecycle. `result` is one of:
    /// "issued" | "auto_approved" | "user_approved" | "user_denied" |
    /// "blocked" | "expired".
    approval_decision_total: struct { result: []const u8 },

    /// Artifact-export operation. `format` is "pdf|docx|pptx|xlsx|html",
    /// `result` is "ok|invalid_format|missing_artifact|state_unavailable|
    /// renderer_unavailable|cross_user_denied".
    artifact_export_total: struct { format: []const u8, result: []const u8 },
    artifact_export_latency_ms: struct { format: []const u8, value: u64 },

    /// Memory-tool operation. `op` is "store|recall|forget",
    /// `result` is "ok|err".
    memory_op_total: struct { op: []const u8, result: []const u8 },
    memory_op_latency_ms: struct { op: []const u8, value: u64 },

    /// Trace-share operation. `op` is "create|revoke|get",
    /// `result` is "ok|not_found|expired|revoked|cap|err".
    trace_share_total: struct { op: []const u8, result: []const u8 },

    /// Per-tool execution. `tool` is the canonical tool name,
    /// `result` is "ok|err|unknown_tool|invalid_args".
    tool_call_total: struct { tool: []const u8, result: []const u8 },
    tool_call_latency_ms: struct { tool: []const u8, value: u64 },

    /// Cost-tracker meter-receipt emit. `result` is "ok|err_write".
    meter_receipt_total: struct { result: []const u8 },
};

// ── Global module-level observer (v1.14.23 HIGH 2.A) ────────────────
//
// The tool-scoped observer (`current_tool_observer` in `tools/root.zig`)
// is set per-turn and only visible inside the agent's tool dispatch
// path. The newly-shipped surface emits metrics from cross-cutting
// sites (gateway HTTP handlers, extension WS hub callbacks, provider
// upload paths) that run OUTSIDE a tool execute() and have no
// turn-scoped observer to read.
//
// `global_observer` is a process-wide pointer the gateway sets at boot
// (after constructing its MultiObserver) so those cross-cutting sites
// have a single emit address. NULL is the well-defined fallback — in
// that case `recordMetricGlobal` falls through to a scoped-log line so
// operators still have *something* to grep for, per the user directive
// at v1.14.23 review-fix HIGH 2.A: "graceful degradation: if no
// observer is registered, log the event so operators have SOMETHING."
//
// Tests + standalone CLI never set it; their emits become structured
// log lines, which is the right shape for those paths anyway.
//
// Thread-safety: the pointer is set once at boot, read many. Reads use
// `@atomicLoad` to satisfy a tools-thread reading mid-init.

var global_observer: ?*Observer = null;

/// Install the process-wide observer. Called once by the gateway after
/// composing its MultiObserver. Pass null at shutdown to detach.
pub fn setGlobalObserver(obs: ?*Observer) void {
    @atomicStore(?*Observer, &global_observer, obs, .release);
}

/// Borrow the current global observer (null if none installed).
pub fn getGlobalObserver() ?*Observer {
    return @atomicLoad(?*Observer, &global_observer, .acquire);
}

const metric_log = std.log.scoped(.metric);

/// Emit a metric to the global observer if one is registered; otherwise
/// fall back to a `log.info` line so operators see the event even on
/// observer-less deployments. Safe to call from any thread.
///
/// **Cost:** when `global_observer == null`, this still produces an
/// info-level log line (one stderr write). Don't sprinkle this in a
/// hot loop; it's intended for per-tool-call / per-request emit sites.
pub fn recordMetricGlobal(metric: ObserverMetric) void {
    if (getGlobalObserver()) |obs| {
        obs.recordMetric(&metric);
        return;
    }
    // Graceful degradation: log the metric so the operator has a
    // grep target even when no observer is wired. Each variant gets
    // a stable key prefix that matches the metric name; downstream
    // log aggregators can rebuild a counter by grep+count.
    switch (metric) {
        .request_latency_ms => |v| metric_log.info("metric request_latency_ms value={d}", .{v}),
        .tokens_used => |v| metric_log.info("metric tokens_used value={d}", .{v}),
        .active_sessions => |v| metric_log.info("metric active_sessions value={d}", .{v}),
        .queue_depth => |v| metric_log.info("metric queue_depth value={d}", .{v}),
        .artifact_create_total => |v| metric_log.info("metric artifact_create_total value={d}", .{v}),
        .artifact_update_total => |v| metric_log.info("metric artifact_update_total value={d}", .{v}),
        .artifact_share_total => |v| metric_log.info("metric artifact_share_total value={d}", .{v}),
        .artifact_share_revoke_total => |v| metric_log.info("metric artifact_share_revoke_total value={d}", .{v}),
        .share_create_success_total => |v| metric_log.info("metric share_create_success_total value={d}", .{v}),
        .share_create_429_total => |v| metric_log.info("metric share_create_429_total value={d}", .{v}),
        .extension_ws_connections_active => |v| metric_log.info("metric extension_ws_connections_active value={d}", .{v}),
        .extension_ws_command_latency_ms => |v| metric_log.info("metric extension_ws_command_latency_ms value={d}", .{v}),
        .extension_ws_command_total => |e| {
            if (e.tool) |t| {
                metric_log.info("metric extension_ws_command_total result={s} tool={s}", .{ e.result, t });
            } else {
                metric_log.info("metric extension_ws_command_total result={s}", .{e.result});
            }
        },
        .extension_ws_ssrf_block_total => |v| metric_log.info("metric extension_ws_ssrf_block_total value={d}", .{v}),
        .produce_document_total => |e| metric_log.info("metric produce_document_total format={s} result={s}", .{ e.format, e.result }),
        .produce_document_latency_ms => |e| metric_log.info("metric produce_document_latency_ms format={s} value={d}", .{ e.format, e.value }),
        .trace_query_total => |v| metric_log.info("metric trace_query_total value={d}", .{v}),
        .memory_doctor_total => |v| metric_log.info("metric memory_doctor_total value={d}", .{v}),
        .moonshot_video_upload_total => |e| metric_log.info("metric moonshot_video_upload_total result={s}", .{e.result}),
        .moonshot_video_upload_bytes => |v| metric_log.info("metric moonshot_video_upload_bytes value={d}", .{v}),
        .approval_decision_total => |e| metric_log.info("metric approval_decision_total result={s}", .{e.result}),
        .artifact_export_total => |e| metric_log.info("metric artifact_export_total format={s} result={s}", .{ e.format, e.result }),
        .artifact_export_latency_ms => |e| metric_log.info("metric artifact_export_latency_ms format={s} value={d}", .{ e.format, e.value }),
        .memory_op_total => |e| metric_log.info("metric memory_op_total op={s} result={s}", .{ e.op, e.result }),
        .memory_op_latency_ms => |e| metric_log.info("metric memory_op_latency_ms op={s} value={d}", .{ e.op, e.value }),
        .trace_share_total => |e| metric_log.info("metric trace_share_total op={s} result={s}", .{ e.op, e.result }),
        .tool_call_total => |e| metric_log.info("metric tool_call_total tool={s} result={s}", .{ e.tool, e.result }),
        .tool_call_latency_ms => |e| metric_log.info("metric tool_call_latency_ms tool={s} value={d}", .{ e.tool, e.value }),
        .meter_receipt_total => |e| metric_log.info("metric meter_receipt_total result={s}", .{e.result}),
    }
}

/// Core observability interface — Zig vtable pattern.
///
/// V1.14.10 A — **THREAD-SAFETY CONTRACT** (review fix H-01):
/// Implementations of `record_event` / `record_metric` / `flush`
/// MUST be safe to call concurrently from multiple threads.
///
/// Rationale: V1.14.10 moved the lifecycle summarizer to a detached
/// async worker, so a single Observer instance can now have
/// `recordEvent` fired by both the agent's hot-path turn AND the
/// async lifecycle worker concurrently. Pre-V1.14.10 this could not
/// happen — every emit was serialized by `agent.turn()` being the
/// sole writer.
///
/// All current impls (audited 2026-05-18) satisfy the contract:
///   - `NoopObserver` — trivially safe (no state).
///   - `LogObserver` — std.log is thread-safe (libc-stderr is
///     line-buffered + lock-protected by the runtime).
///   - `VerboseObserver` — uses stack-local format buffer per call.
///   - `MultiObserver` — composes underlying observers; safe iff
///     children are safe (all current children are).
///   - `FileObserver` — POSIX `write(2)` is atomic for buffers
///     under PIPE_BUF (4KB on macOS/Linux); log lines stay under.
///   - `OtelObserver` — has its own `mutex: std.Thread.Mutex` +
///     atomic counters.
///   - `RunTraceStore` (run_trace_store.zig) — has its own mutex.
///   - `SentryObserver` (sentry_runtime.zig) — uses atomic flag.
///
/// If you add a new Observer impl: hold a mutex around any mutable
/// state, OR use atomics, OR ensure your operations are stateless
/// per-call. Don't rely on caller serialization.
pub const Observer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        record_event: *const fn (ptr: *anyopaque, event: *const ObserverEvent) void,
        record_metric: *const fn (ptr: *anyopaque, metric: *const ObserverMetric) void,
        flush: *const fn (ptr: *anyopaque) void,
        name: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn recordEvent(self: Observer, event: *const ObserverEvent) void {
        self.vtable.record_event(self.ptr, event);
    }

    pub fn recordMetric(self: Observer, metric: *const ObserverMetric) void {
        self.vtable.record_metric(self.ptr, metric);
    }

    pub fn flush(self: Observer) void {
        self.vtable.flush(self.ptr);
    }

    pub fn getName(self: Observer) []const u8 {
        return self.vtable.name(self.ptr);
    }
};

// ── NoopObserver ─────────────────────────────────────────────────────

/// Zero-overhead observer — all methods are no-ops.
pub const NoopObserver = struct {
    const vtable = Observer.VTable{
        .record_event = noopRecordEvent,
        .record_metric = noopRecordMetric,
        .flush = noopFlush,
        .name = noopName,
    };

    pub fn observer(self: *NoopObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn noopRecordEvent(_: *anyopaque, _: *const ObserverEvent) void {}
    fn noopRecordMetric(_: *anyopaque, _: *const ObserverMetric) void {}
    fn noopFlush(_: *anyopaque) void {}
    fn noopName(_: *anyopaque) []const u8 {
        return "noop";
    }
};

// ── LogObserver ──────────────────────────────────────────────────────

/// Log-based observer — uses std.log for all output.
pub const LogObserver = struct {
    const vtable = Observer.VTable{
        .record_event = logRecordEvent,
        .record_metric = logRecordMetric,
        .flush = logFlush,
        .name = logName,
    };

    pub fn observer(self: *LogObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn logRecordEvent(_: *anyopaque, event: *const ObserverEvent) void {
        switch (event.*) {
            .agent_start => |e| std.log.info("agent.start provider={s} model={s}", .{ e.provider, e.model }),
            .llm_request => |e| std.log.info("llm.request provider={s} model={s} messages={d}", .{ e.provider, e.model, e.messages_count }),
            .llm_response => |e| std.log.info("llm.response provider={s} model={s} duration_ms={d} success={}", .{ e.provider, e.model, e.duration_ms, e.success }),
            .agent_end => |e| std.log.info("agent.end duration_ms={d}", .{e.duration_ms}),
            .tool_call_start => |e| std.log.info("tool.start tool={s}", .{e.tool}),
            .tool_call => |e| std.log.info("tool.call tool={s} duration_ms={d} success={}", .{ e.tool, e.duration_ms, e.success }),
            .tool_iterations_exhausted => |e| std.log.info("tool.iterations_exhausted iterations={d}", .{e.iterations}),
            .loop_detected => |e| std.log.info("tool.loop_detected iteration={d} cap={d}", .{ e.iteration, e.iterations_cap }),
            .turn_cancelled => |e| std.log.info("turn.cancelled reason={s} iteration={d}", .{ e.reason, e.iteration }),
            .turn_stage => |e| {
                if (e.iteration) |iteration| {
                    if (e.duration_ms) |duration_ms| {
                        if (e.count) |count| {
                            std.log.info("turn.stage stage={s} iteration={d} duration_ms={d} count={d}", .{ e.stage, iteration, duration_ms, count });
                        } else {
                            std.log.info("turn.stage stage={s} iteration={d} duration_ms={d}", .{ e.stage, iteration, duration_ms });
                        }
                    } else {
                        std.log.info("turn.stage stage={s} iteration={d}", .{ e.stage, iteration });
                    }
                } else if (e.duration_ms) |duration_ms| {
                    if (e.count) |count| {
                        std.log.info("turn.stage stage={s} duration_ms={d} count={d}", .{ e.stage, duration_ms, count });
                    } else {
                        std.log.info("turn.stage stage={s} duration_ms={d}", .{ e.stage, duration_ms });
                    }
                } else if (e.count) |count| {
                    std.log.info("turn.stage stage={s} count={d}", .{ e.stage, count });
                } else {
                    std.log.info("turn.stage stage={s}", .{e.stage});
                }
            },
            .turn_complete => std.log.info("turn.complete", .{}),
            .tool_only_turn => |e| std.log.info("turn.tool_only tool_calls={d} iterations={d} spawned_tasks={d}", .{ e.tool_calls_executed, e.iterations_used, e.spawned_task_ids.len }),
            .channel_message => |e| std.log.info("channel.message channel={s} direction={s}", .{ e.channel, e.direction }),
            .heartbeat_tick => std.log.info("heartbeat.tick", .{}),
            .err => |e| std.log.info("error component={s} message={s}", .{ e.component, e.message }),
            .narration_frame => |e| std.log.info("narration type={s} message={s}", .{ @tagName(e.frame_type), e.message }),
            .task_update => |e| std.log.info("task.update task_id={s} status={s}", .{ e.task_id, e.status }),
            .approval_required => |e| std.log.info("approval.required tool={s} reason={s} risk_level={s}", .{ e.tool, e.reason, e.risk_level }),
            .system_notice => |e| std.log.info("system.notice kind={s} severity={s} message={s}", .{ e.kind, e.severity, e.message }),
            .memory_retrieval => |e| std.log.info("memory.retrieval available=true injected={} context_bytes={?d} candidates={?d} duration_ms={?d}", .{ e.success, e.usage_tokens, e.iteration, e.duration_ms }),
            .artifact_event => |e| std.log.info("artifact.event op={s} id={s} kind={s} version={d}", .{ e.op, e.artifact_id, e.kind, e.version }),
        }
    }

    fn logRecordMetric(_: *anyopaque, metric: *const ObserverMetric) void {
        switch (metric.*) {
            .request_latency_ms => |v| std.log.info("metric.request_latency latency_ms={d}", .{v}),
            .tokens_used => |v| std.log.info("metric.tokens_used tokens={d}", .{v}),
            .active_sessions => |v| std.log.info("metric.active_sessions sessions={d}", .{v}),
            .queue_depth => |v| std.log.info("metric.queue_depth depth={d}", .{v}),
            .artifact_create_total => |v| std.log.info("metric.artifact_create_total value={d}", .{v}),
            .artifact_update_total => |v| std.log.info("metric.artifact_update_total value={d}", .{v}),
            .artifact_share_total => |v| std.log.info("metric.artifact_share_total value={d}", .{v}),
            .artifact_share_revoke_total => |v| std.log.info("metric.artifact_share_revoke_total value={d}", .{v}),
            .share_create_success_total => |v| std.log.info("metric.share_create_success_total value={d}", .{v}),
            .share_create_429_total => |v| std.log.info("metric.share_create_429_total value={d}", .{v}),
            .extension_ws_connections_active => |v| std.log.info("metric.extension_ws_connections_active value={d}", .{v}),
            .extension_ws_command_latency_ms => |v| std.log.info("metric.extension_ws_command_latency_ms value={d}", .{v}),
            .extension_ws_command_total => |e| {
                if (e.tool) |t| {
                    std.log.info("metric.extension_ws_command_total result={s} tool={s}", .{ e.result, t });
                } else {
                    std.log.info("metric.extension_ws_command_total result={s}", .{e.result});
                }
            },
            .extension_ws_ssrf_block_total => |v| std.log.info("metric.extension_ws_ssrf_block_total value={d}", .{v}),
            .produce_document_total => |e| std.log.info("metric.produce_document_total format={s} result={s}", .{ e.format, e.result }),
            .produce_document_latency_ms => |e| std.log.info("metric.produce_document_latency_ms format={s} value={d}", .{ e.format, e.value }),
            .trace_query_total => |v| std.log.info("metric.trace_query_total value={d}", .{v}),
            .memory_doctor_total => |v| std.log.info("metric.memory_doctor_total value={d}", .{v}),
            .moonshot_video_upload_total => |e| std.log.info("metric.moonshot_video_upload_total result={s}", .{e.result}),
            .moonshot_video_upload_bytes => |v| std.log.info("metric.moonshot_video_upload_bytes value={d}", .{v}),
            .approval_decision_total => |e| std.log.info("metric.approval_decision_total result={s}", .{e.result}),
            .artifact_export_total => |e| std.log.info("metric.artifact_export_total format={s} result={s}", .{ e.format, e.result }),
            .artifact_export_latency_ms => |e| std.log.info("metric.artifact_export_latency_ms format={s} value={d}", .{ e.format, e.value }),
            .memory_op_total => |e| std.log.info("metric.memory_op_total op={s} result={s}", .{ e.op, e.result }),
            .memory_op_latency_ms => |e| std.log.info("metric.memory_op_latency_ms op={s} value={d}", .{ e.op, e.value }),
            .trace_share_total => |e| std.log.info("metric.trace_share_total op={s} result={s}", .{ e.op, e.result }),
            .tool_call_total => |e| std.log.info("metric.tool_call_total tool={s} result={s}", .{ e.tool, e.result }),
            .tool_call_latency_ms => |e| std.log.info("metric.tool_call_latency_ms tool={s} value={d}", .{ e.tool, e.value }),
            .meter_receipt_total => |e| std.log.info("metric.meter_receipt_total result={s}", .{e.result}),
        }
    }

    fn logFlush(_: *anyopaque) void {}
    fn logName(_: *anyopaque) []const u8 {
        return "log";
    }
};

// ── VerboseObserver ──────────────────────────────────────────────────

/// Human-readable progress observer for interactive CLI sessions.
pub const VerboseObserver = struct {
    const vtable = Observer.VTable{
        .record_event = verboseRecordEvent,
        .record_metric = verboseRecordMetric,
        .flush = verboseFlush,
        .name = verboseName,
    };

    pub fn observer(self: *VerboseObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn turnStageLabel(stage: []const u8) []const u8 {
        if (std.mem.eql(u8, stage, "turn_start")) return "Gathering context";
        if (std.mem.eql(u8, stage, "memory_enrich")) return "Retrieving memory";
        if (std.mem.eql(u8, stage, "turn_compaction") or std.mem.eql(u8, stage, "compact_trim")) return "Trimming context";
        if (std.mem.eql(u8, stage, "continuity_refresh")) return "Refreshing continuity";
        if (std.mem.eql(u8, stage, "build_provider_messages")) return "Preparing model request";
        if (std.mem.eql(u8, stage, "response_cache_hit")) return "Using cached response";
        if (std.mem.eql(u8, stage, "parse_provider_response")) return "Processing model response";
        if (std.mem.eql(u8, stage, "dispatch_tools")) return "Running tools";
        if (std.mem.eql(u8, stage, "tool_reflection")) return "Reflecting on tool results";
        if (std.mem.eql(u8, stage, "compose_final_reply")) return "Preparing final reply";
        if (std.mem.eql(u8, stage, "finalize_no_tools")) return "Finalizing reply";
        if (std.mem.eql(u8, stage, "tts_prepare")) return "Preparing audio reply";
        if (std.mem.eql(u8, stage, "llm_first_token")) return "Model started responding";
        if (std.mem.eql(u8, stage, "llm_first_token_upper_bound")) return "Waiting for model response";
        return stage;
    }

    fn verboseRecordEvent(_: *anyopaque, event: *const ObserverEvent) void {
        var buf: [4096]u8 = undefined;
        var bw = std.fs.File.stderr().writer(&buf);
        const stderr = &bw.interface;
        switch (event.*) {
            .llm_request => |e| {
                stderr.print("> Thinking\n", .{}) catch {};
                stderr.print("> Send (provider={s}, model={s}, messages={d})\n", .{ e.provider, e.model, e.messages_count }) catch {};
            },
            .llm_response => |e| {
                stderr.print("< Receive (success={}, duration_ms={d})\n", .{ e.success, e.duration_ms }) catch {};
            },
            .tool_call_start => |e| {
                stderr.print("> Tool {s}\n", .{e.tool}) catch {};
            },
            .tool_call => |e| {
                stderr.print("< Tool {s} (success={}, duration_ms={d})\n", .{ e.tool, e.success, e.duration_ms }) catch {};
            },
            .turn_stage => |e| {
                stderr.print("> {s}\n", .{turnStageLabel(e.stage)}) catch {};
            },
            .turn_complete => {
                stderr.print("< Complete\n", .{}) catch {};
            },
            else => {},
        }
    }

    fn verboseRecordMetric(_: *anyopaque, _: *const ObserverMetric) void {}
    fn verboseFlush(_: *anyopaque) void {}
    fn verboseName(_: *anyopaque) []const u8 {
        return "verbose";
    }
};

// ── MultiObserver ────────────────────────────────────────────────────

/// Fan-out observer — distributes events to multiple backends.
pub const MultiObserver = struct {
    observers: []Observer,

    const vtable = Observer.VTable{
        .record_event = multiRecordEvent,
        .record_metric = multiRecordMetric,
        .flush = multiFlush,
        .name = multiName,
    };

    pub fn observer(s: *MultiObserver) Observer {
        return .{
            .ptr = @ptrCast(s),
            .vtable = &vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *MultiObserver {
        return @ptrCast(@alignCast(ptr));
    }

    fn multiRecordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        for (resolve(ptr).observers) |obs| {
            obs.vtable.record_event(obs.ptr, event);
        }
    }

    fn multiRecordMetric(ptr: *anyopaque, metric: *const ObserverMetric) void {
        for (resolve(ptr).observers) |obs| {
            obs.vtable.record_metric(obs.ptr, metric);
        }
    }

    fn multiFlush(ptr: *anyopaque) void {
        for (resolve(ptr).observers) |obs| {
            obs.vtable.flush(obs.ptr);
        }
    }

    fn multiName(_: *anyopaque) []const u8 {
        return "multi";
    }
};

// ── FileObserver ─────────────────────────────────────────────────────

/// Appends events as JSONL to a log file.
pub const FileObserver = struct {
    path: []const u8,

    const vtable_impl = Observer.VTable{
        .record_event = fileRecordEvent,
        .record_metric = fileRecordMetric,
        .flush = fileFlush,
        .name = fileName,
    };

    pub fn observer(self: *FileObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_impl,
        };
    }

    fn resolve(ptr: *anyopaque) *FileObserver {
        return @ptrCast(@alignCast(ptr));
    }

    fn appendToFile(self: *FileObserver, line: []const u8) void {
        const file = std.fs.cwd().openFile(self.path, .{ .mode = .write_only }) catch {
            // Try creating the file if it doesn't exist
            const new_file = std.fs.cwd().createFile(self.path, .{ .truncate = false }) catch return;
            defer new_file.close();
            new_file.seekFromEnd(0) catch return;
            new_file.writeAll(line) catch {};
            new_file.writeAll("\n") catch {};
            return;
        };
        defer file.close();
        file.seekFromEnd(0) catch return;
        file.writeAll(line) catch {};
        file.writeAll("\n") catch {};
    }

    fn fileRecordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self = resolve(ptr);
        var buf: [2048]u8 = undefined;
        const line = switch (event.*) {
            .agent_start => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"agent_start\",\"provider\":\"{s}\",\"model\":\"{s}\"}}", .{ e.provider, e.model }) catch return,
            .llm_request => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"llm_request\",\"provider\":\"{s}\",\"model\":\"{s}\",\"messages_count\":{d}}}", .{ e.provider, e.model, e.messages_count }) catch return,
            .llm_response => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"llm_response\",\"provider\":\"{s}\",\"model\":\"{s}\",\"duration_ms\":{d},\"success\":{}}}", .{ e.provider, e.model, e.duration_ms, e.success }) catch return,
            .agent_end => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"agent_end\",\"duration_ms\":{d}}}", .{e.duration_ms}) catch return,
            .tool_call_start => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"tool_call_start\",\"tool\":\"{s}\"}}", .{e.tool}) catch return,
            .tool_call => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"tool_call\",\"tool\":\"{s}\",\"duration_ms\":{d},\"success\":{}}}", .{ e.tool, e.duration_ms, e.success }) catch return,
            .tool_iterations_exhausted => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"tool_iterations_exhausted\",\"iterations\":{d}}}", .{e.iterations}) catch return,
            .loop_detected => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"loop_detected\",\"iteration\":{d},\"iterations_cap\":{d}}}", .{ e.iteration, e.iterations_cap }) catch return,
            .turn_cancelled => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"turn_cancelled\",\"reason\":\"{s}\",\"iteration\":{d}}}", .{ e.reason, e.iteration }) catch return,
            .turn_stage => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"turn_stage\",\"stage\":\"{s}\"}}", .{e.stage}) catch return,
            .turn_complete => std.fmt.bufPrint(&buf, "{{\"event\":\"turn_complete\"}}", .{}) catch return,
            .tool_only_turn => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"tool_only_turn\",\"tool_calls_executed\":{d},\"iterations_used\":{d},\"spawned_task_ids_count\":{d}}}", .{ e.tool_calls_executed, e.iterations_used, e.spawned_task_ids.len }) catch return,
            .channel_message => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"channel_message\",\"channel\":\"{s}\",\"direction\":\"{s}\"}}", .{ e.channel, e.direction }) catch return,
            .heartbeat_tick => std.fmt.bufPrint(&buf, "{{\"event\":\"heartbeat_tick\"}}", .{}) catch return,
            .err => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"error\",\"component\":\"{s}\",\"message\":\"{s}\"}}", .{ e.component, e.message }) catch return,
            .narration_frame => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"narration_frame\",\"type\":\"{s}\",\"message\":\"{s}\"}}", .{ @tagName(e.frame_type), e.message }) catch return,
            .task_update => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"task_update\",\"task_id\":\"{s}\",\"status\":\"{s}\"}}", .{ e.task_id, e.status }) catch return,
            .approval_required => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"approval_required\",\"tool\":\"{s}\",\"reason\":\"{s}\",\"risk_level\":\"{s}\"}}", .{ e.tool, e.reason, e.risk_level }) catch return,
            .system_notice => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"system_notice\",\"kind\":\"{s}\",\"severity\":\"{s}\",\"message\":\"{s}\"}}", .{ e.kind, e.severity, e.message }) catch return,
            .memory_retrieval => return,
            .artifact_event => |e| std.fmt.bufPrint(&buf, "{{\"event\":\"artifact_event\",\"op\":\"{s}\",\"id\":\"{s}\",\"kind\":\"{s}\",\"version\":{d}}}", .{ e.op, e.artifact_id, e.kind, e.version }) catch return,
        };
        self.appendToFile(line);
    }

    fn fileRecordMetric(ptr: *anyopaque, metric: *const ObserverMetric) void {
        const self = resolve(ptr);
        var buf: [512]u8 = undefined;
        const line = switch (metric.*) {
            .request_latency_ms => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"request_latency_ms\",\"value\":{d}}}", .{v}) catch return,
            .tokens_used => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"tokens_used\",\"value\":{d}}}", .{v}) catch return,
            .active_sessions => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"active_sessions\",\"value\":{d}}}", .{v}) catch return,
            .queue_depth => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"queue_depth\",\"value\":{d}}}", .{v}) catch return,
            .artifact_create_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"artifact_create_total\",\"value\":{d}}}", .{v}) catch return,
            .artifact_update_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"artifact_update_total\",\"value\":{d}}}", .{v}) catch return,
            .artifact_share_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"artifact_share_total\",\"value\":{d}}}", .{v}) catch return,
            .artifact_share_revoke_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"artifact_share_revoke_total\",\"value\":{d}}}", .{v}) catch return,
            .share_create_success_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"share_create_success_total\",\"value\":{d}}}", .{v}) catch return,
            .share_create_429_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"share_create_429_total\",\"value\":{d}}}", .{v}) catch return,
            .extension_ws_connections_active => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"extension_ws_connections_active\",\"value\":{d}}}", .{v}) catch return,
            .extension_ws_command_latency_ms => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"extension_ws_command_latency_ms\",\"value\":{d}}}", .{v}) catch return,
            .extension_ws_command_total => |e| blk: {
                if (e.tool) |t| {
                    break :blk std.fmt.bufPrint(&buf, "{{\"metric\":\"extension_ws_command_total\",\"result\":\"{s}\",\"tool\":\"{s}\"}}", .{ e.result, t }) catch return;
                } else {
                    break :blk std.fmt.bufPrint(&buf, "{{\"metric\":\"extension_ws_command_total\",\"result\":\"{s}\"}}", .{e.result}) catch return;
                }
            },
            .extension_ws_ssrf_block_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"extension_ws_ssrf_block_total\",\"value\":{d}}}", .{v}) catch return,
            .produce_document_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"produce_document_total\",\"format\":\"{s}\",\"result\":\"{s}\"}}", .{ e.format, e.result }) catch return,
            .produce_document_latency_ms => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"produce_document_latency_ms\",\"format\":\"{s}\",\"value\":{d}}}", .{ e.format, e.value }) catch return,
            .trace_query_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"trace_query_total\",\"value\":{d}}}", .{v}) catch return,
            .memory_doctor_total => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"memory_doctor_total\",\"value\":{d}}}", .{v}) catch return,
            .moonshot_video_upload_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"moonshot_video_upload_total\",\"result\":\"{s}\"}}", .{e.result}) catch return,
            .moonshot_video_upload_bytes => |v| std.fmt.bufPrint(&buf, "{{\"metric\":\"moonshot_video_upload_bytes\",\"value\":{d}}}", .{v}) catch return,
            .approval_decision_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"approval_decision_total\",\"result\":\"{s}\"}}", .{e.result}) catch return,
            .artifact_export_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"artifact_export_total\",\"format\":\"{s}\",\"result\":\"{s}\"}}", .{ e.format, e.result }) catch return,
            .artifact_export_latency_ms => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"artifact_export_latency_ms\",\"format\":\"{s}\",\"value\":{d}}}", .{ e.format, e.value }) catch return,
            .memory_op_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"memory_op_total\",\"op\":\"{s}\",\"result\":\"{s}\"}}", .{ e.op, e.result }) catch return,
            .memory_op_latency_ms => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"memory_op_latency_ms\",\"op\":\"{s}\",\"value\":{d}}}", .{ e.op, e.value }) catch return,
            .trace_share_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"trace_share_total\",\"op\":\"{s}\",\"result\":\"{s}\"}}", .{ e.op, e.result }) catch return,
            .tool_call_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"tool_call_total\",\"tool\":\"{s}\",\"result\":\"{s}\"}}", .{ e.tool, e.result }) catch return,
            .tool_call_latency_ms => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"tool_call_latency_ms\",\"tool\":\"{s}\",\"value\":{d}}}", .{ e.tool, e.value }) catch return,
            .meter_receipt_total => |e| std.fmt.bufPrint(&buf, "{{\"metric\":\"meter_receipt_total\",\"result\":\"{s}\"}}", .{e.result}) catch return,
        };
        self.appendToFile(line);
    }

    fn fileFlush(_: *anyopaque) void {
        // File writes are unbuffered (each event appends directly)
    }

    fn fileName(_: *anyopaque) []const u8 {
        return "file";
    }
};

/// Factory: create observer from config backend string.
fn createObserver(backend: []const u8) []const u8 {
    if (std.mem.eql(u8, backend, "log")) return "log";
    if (std.mem.eql(u8, backend, "verbose")) return "verbose";
    if (std.mem.eql(u8, backend, "file")) return "file";
    if (std.mem.eql(u8, backend, "multi")) return "multi";
    if (std.mem.eql(u8, backend, "otel") or std.mem.eql(u8, backend, "otlp")) return "otel";
    if (std.mem.eql(u8, backend, "none") or std.mem.eql(u8, backend, "noop")) return "noop";
    return "noop"; // fallback
}

// ── OtelObserver ─────────────────────────────────────────────────────

/// OpenTelemetry key-value attribute.
pub const OtelAttribute = struct {
    key: []const u8,
    value: []const u8,
};

/// A single OTLP span with timing and attributes.
pub const OtelSpan = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    name: []const u8,
    start_ns: u64,
    end_ns: u64,
    attributes: std.ArrayListUnmanaged(OtelAttribute),

    pub fn deinit(self: *OtelSpan, allocator: std.mem.Allocator) void {
        self.attributes.deinit(allocator);
    }
};

const http_util = @import("http_util.zig");

/// OpenTelemetry OTLP/HTTP observer — batches spans and exports via JSON.
pub const OtelObserver = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    service_name: []const u8,
    spans: std.ArrayListUnmanaged(OtelSpan),
    mutex: std.Thread.Mutex,
    current_trace_id: [32]u8,
    current_start_ns: u64,
    requests_total: std.atomic.Value(u64),
    errors_total: std.atomic.Value(u64),

    const max_batch_size: usize = 10;

    const vtable_impl = Observer.VTable{
        .record_event = otelRecordEvent,
        .record_metric = otelRecordMetric,
        .flush = otelFlush,
        .name = otelName,
    };

    pub fn init(allocator: std.mem.Allocator, endpoint: ?[]const u8, service_name: ?[]const u8) OtelObserver {
        return .{
            .allocator = allocator,
            .endpoint = endpoint orelse "http://localhost:4318",
            .service_name = service_name orelse "nullalis",
            .spans = .empty,
            .mutex = .{},
            .current_trace_id = .{0} ** 32,
            .current_start_ns = 0,
            .requests_total = std.atomic.Value(u64).init(0),
            .errors_total = std.atomic.Value(u64).init(0),
        };
    }

    /// Construct from env. Returns a configured observer only when
    /// NULLALIS_OTEL_ENDPOINT is set to a non-empty value (legacy
    /// NULLCLAW_OTEL_ENDPOINT honored with a deprecation note per the
    /// rebrand chokepoint). Returns null otherwise — callers should
    /// fall back to a NoopObserver in that slot so the composition
    /// site doesn't have to rewire slot counts per-deployment.
    /// getenv returns borrowed slices, so no allocation happens at
    /// boot; the spans list is allocated lazily on first event.
    pub fn fromEnv(allocator: std.mem.Allocator) ?OtelObserver {
        const endpoint = blk: {
            if (std.posix.getenv("NULLALIS_OTEL_ENDPOINT")) |ep| {
                if (ep.len > 0) break :blk ep;
            }
            if (std.posix.getenv("NULLCLAW_OTEL_ENDPOINT")) |ep| {
                if (ep.len > 0) {
                    // S8.3 — sunset date sourced from `env_rebrand.SUNSET_DATE`
                    // so every NULLCLAW_* legacy-read warning surfaces the
                    // same date string for grep-friendly migration audits.
                    // S8.3 post-review fix (M-BANNER): also fire the
                    // shared once-per-process banner so operators with
                    // only NULLCLAW_OTEL_* set (no Sentry creds) still
                    // see the cross-cutting deprecation signal.
                    env_rebrand.fireBannerOnce();
                    std.log.warn("env NULLCLAW_OTEL_ENDPOINT is deprecated; use NULLALIS_OTEL_ENDPOINT (remove after {s})", .{env_rebrand.SUNSET_DATE});
                    break :blk ep;
                }
            }
            return null;
        };
        // S8.3 post-review fix (M-BANNER): the legacy
        // NULLCLAW_OTEL_SERVICE_NAME read used to be silent — no
        // warning, no banner. Operators using only that variable would
        // never know it was deprecated. Now we resolve primary/fallback
        // explicitly and emit the same dated warning + shared banner
        // when only the legacy name is present.
        const service_name = blk: {
            if (std.posix.getenv("NULLALIS_OTEL_SERVICE_NAME")) |sn| break :blk sn;
            if (std.posix.getenv("NULLCLAW_OTEL_SERVICE_NAME")) |sn| {
                env_rebrand.fireBannerOnce();
                std.log.warn("env NULLCLAW_OTEL_SERVICE_NAME is deprecated; use NULLALIS_OTEL_SERVICE_NAME (remove after {s})", .{env_rebrand.SUNSET_DATE});
                break :blk sn;
            }
            break :blk null;
        };
        return init(allocator, endpoint, service_name);
    }

    pub fn observer(self: *OtelObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_impl,
        };
    }

    pub fn deinit(self: *OtelObserver) void {
        for (self.spans.items) |*span| {
            span.deinit(self.allocator);
        }
        self.spans.deinit(self.allocator);
    }

    fn resolve(ptr: *anyopaque) *OtelObserver {
        return @ptrCast(@alignCast(ptr));
    }

    /// Generate random hex ID into a buffer.
    fn randomHex(buf: []u8) void {
        var raw: [16]u8 = undefined;
        const needed = buf.len / 2;
        std.crypto.random.bytes(raw[0..needed]);
        const hex = "0123456789abcdef";
        for (0..needed) |i| {
            buf[i * 2] = hex[raw[i] >> 4];
            buf[i * 2 + 1] = hex[raw[i] & 0x0f];
        }
    }

    fn nowNs() u64 {
        return @intCast(std.time.nanoTimestamp());
    }

    fn addSpan(self: *OtelObserver, name: []const u8, start_ns: u64, end_ns: u64, attrs: []const OtelAttribute) void {
        var span_id: [16]u8 = undefined;
        randomHex(&span_id);

        var attributes: std.ArrayListUnmanaged(OtelAttribute) = .empty;
        for (attrs) |attr| {
            attributes.append(self.allocator, attr) catch break;
        }

        self.spans.append(self.allocator, .{
            .trace_id = self.current_trace_id,
            .span_id = span_id,
            .name = name,
            .start_ns = start_ns,
            .end_ns = end_ns,
            .attributes = attributes,
        }) catch return;

        if (self.spans.items.len >= max_batch_size) {
            self.flushLocked();
        }
    }

    fn otelRecordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self = resolve(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = nowNs();

        switch (event.*) {
            .agent_start => |e| {
                randomHex(&self.current_trace_id);
                self.current_start_ns = now;
                self.addSpan("agent.start", now, now, &.{
                    .{ .key = "provider", .value = e.provider },
                    .{ .key = "model", .value = e.model },
                });
            },
            .agent_end => |e| {
                const start = if (self.current_start_ns > 0) self.current_start_ns else now;
                var dur_buf: [20]u8 = undefined;
                const dur_str = std.fmt.bufPrint(&dur_buf, "{d}", .{e.duration_ms}) catch "0";
                self.addSpan("agent.end", start, now, &.{
                    .{ .key = "duration_ms", .value = dur_str },
                });
            },
            .llm_request => |e| {
                _ = self.requests_total.fetchAdd(1, .monotonic);
                self.addSpan("llm.request", now, now, &.{
                    .{ .key = "provider", .value = e.provider },
                    .{ .key = "model", .value = e.model },
                });
            },
            .llm_response => |e| {
                if (!e.success) {
                    _ = self.errors_total.fetchAdd(1, .monotonic);
                }
                var dur_buf: [20]u8 = undefined;
                const dur_str = std.fmt.bufPrint(&dur_buf, "{d}", .{e.duration_ms}) catch "0";
                self.addSpan("llm.response", now -| (e.duration_ms * 1_000_000), now, &.{
                    .{ .key = "provider", .value = e.provider },
                    .{ .key = "model", .value = e.model },
                    .{ .key = "duration_ms", .value = dur_str },
                    .{ .key = "success", .value = if (e.success) "true" else "false" },
                });
            },
            .tool_call_start => |e| {
                self.addSpan("tool.start", now, now, &.{
                    .{ .key = "tool", .value = e.tool },
                });
            },
            .tool_call => |e| {
                var dur_buf: [20]u8 = undefined;
                const dur_str = std.fmt.bufPrint(&dur_buf, "{d}", .{e.duration_ms}) catch "0";
                self.addSpan("tool.call", now -| (e.duration_ms * 1_000_000), now, &.{
                    .{ .key = "tool", .value = e.tool },
                    .{ .key = "duration_ms", .value = dur_str },
                    .{ .key = "success", .value = if (e.success) "true" else "false" },
                });
            },
            .tool_iterations_exhausted => |e| {
                var iter_buf: [20]u8 = undefined;
                const iter_str = std.fmt.bufPrint(&iter_buf, "{d}", .{e.iterations}) catch "0";
                self.addSpan("tool.iterations_exhausted", now, now, &.{
                    .{ .key = "iterations", .value = iter_str },
                });
            },
            .loop_detected => |e| {
                var iter_buf: [20]u8 = undefined;
                const iter_str = std.fmt.bufPrint(&iter_buf, "{d}", .{e.iteration}) catch "0";
                var cap_buf: [20]u8 = undefined;
                const cap_str = std.fmt.bufPrint(&cap_buf, "{d}", .{e.iterations_cap}) catch "0";
                self.addSpan("tool.loop_detected", now, now, &.{
                    .{ .key = "iteration", .value = iter_str },
                    .{ .key = "cap", .value = cap_str },
                });
            },
            .turn_cancelled => |e| {
                var iter_buf: [20]u8 = undefined;
                const iter_str = std.fmt.bufPrint(&iter_buf, "{d}", .{e.iteration}) catch "0";
                self.addSpan("turn.cancelled", now, now, &.{
                    .{ .key = "reason", .value = e.reason },
                    .{ .key = "iteration", .value = iter_str },
                });
            },
            .turn_stage => |e| {
                self.addSpan("turn.stage", now, now, &.{
                    .{ .key = "stage", .value = e.stage },
                });
            },
            .turn_complete => {
                self.addSpan("turn.complete", now, now, &.{});
            },
            .tool_only_turn => |e| {
                var calls_buf: [16]u8 = undefined;
                var iter_buf: [16]u8 = undefined;
                var spawned_buf: [16]u8 = undefined;
                const calls_str = std.fmt.bufPrint(&calls_buf, "{d}", .{e.tool_calls_executed}) catch "?";
                const iter_str = std.fmt.bufPrint(&iter_buf, "{d}", .{e.iterations_used}) catch "?";
                const spawned_str = std.fmt.bufPrint(&spawned_buf, "{d}", .{e.spawned_task_ids.len}) catch "?";
                self.addSpan("turn.tool_only", now, now, &.{
                    .{ .key = "tool_calls_executed", .value = calls_str },
                    .{ .key = "iterations_used", .value = iter_str },
                    .{ .key = "spawned_task_ids_count", .value = spawned_str },
                });
            },
            .channel_message => |e| {
                self.addSpan("channel.message", now, now, &.{
                    .{ .key = "channel", .value = e.channel },
                    .{ .key = "direction", .value = e.direction },
                });
            },
            .heartbeat_tick => {
                self.addSpan("heartbeat.tick", now, now, &.{});
            },
            .err => |e| {
                _ = self.errors_total.fetchAdd(1, .monotonic);
                self.addSpan("error", now, now, &.{
                    .{ .key = "component", .value = e.component },
                    .{ .key = "message", .value = e.message },
                });
            },
            .narration_frame => |e| {
                self.addSpan("narration.frame", now, now, &.{
                    .{ .key = "type", .value = @tagName(e.frame_type) },
                    .{ .key = "message", .value = e.message },
                });
            },
            .task_update => |e| {
                self.addSpan("task.update", now, now, &.{
                    .{ .key = "task_id", .value = e.task_id },
                    .{ .key = "status", .value = e.status },
                });
            },
            .approval_required => |e| {
                self.addSpan("approval.required", now, now, &.{
                    .{ .key = "tool", .value = e.tool },
                    .{ .key = "reason", .value = e.reason },
                    .{ .key = "risk_level", .value = e.risk_level },
                });
            },
            .system_notice => |e| {
                self.addSpan("system.notice", now, now, &.{
                    .{ .key = "kind", .value = e.kind },
                    .{ .key = "severity", .value = e.severity },
                    .{ .key = "message", .value = e.message },
                });
            },
            .memory_retrieval => {},
            .artifact_event => |e| {
                self.addSpan("artifact.event", now, now, &.{
                    .{ .key = "op", .value = e.op },
                    .{ .key = "artifact_id", .value = e.artifact_id },
                    .{ .key = "kind", .value = e.kind },
                });
            },
        }
    }

    fn otelRecordMetric(ptr: *anyopaque, metric: *const ObserverMetric) void {
        const self = resolve(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = nowNs();

        switch (metric.*) {
            .request_latency_ms => |v| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
                self.addSpan("metric.request_latency_ms", now, now, &.{
                    .{ .key = "value", .value = s },
                });
            },
            .tokens_used => |v| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
                self.addSpan("metric.tokens_used", now, now, &.{
                    .{ .key = "value", .value = s },
                });
            },
            .active_sessions => |v| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
                self.addSpan("metric.active_sessions", now, now, &.{
                    .{ .key = "value", .value = s },
                });
            },
            .queue_depth => |v| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
                self.addSpan("metric.queue_depth", now, now, &.{
                    .{ .key = "value", .value = s },
                });
            },
            // ── v1.14.23 added — scalar counters/gauges/histograms ──
            // For each new metric we emit a discrete span. The Otel
            // exporter doesn't (yet) implement OTLP metrics natively;
            // span-as-metric is the existing convention in this file
            // (the four legacy metrics use the same shape). A future
            // pass can migrate to OTLP metrics without changing the
            // emit-site API.
            //
            // `@tagName(metric.*)` is a slice into the comptime-emitted
            // type-info table, which lives in .rodata — safe to store
            // as the span's borrowed `name` (same lifetime as the
            // string literals used by the legacy variants above).
            .artifact_create_total,
            .artifact_update_total,
            .artifact_share_total,
            .artifact_share_revoke_total,
            .share_create_success_total,
            .share_create_429_total,
            .extension_ws_connections_active,
            .extension_ws_command_latency_ms,
            .extension_ws_ssrf_block_total,
            .trace_query_total,
            .memory_doctor_total,
            .moonshot_video_upload_bytes,
            => |v| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
                self.addSpan(@tagName(metric.*), now, now, &.{
                    .{ .key = "value", .value = s },
                });
            },
            .extension_ws_command_total => |e| {
                if (e.tool) |t| {
                    self.addSpan("metric.extension_ws_command_total", now, now, &.{
                        .{ .key = "result", .value = e.result },
                        .{ .key = "tool", .value = t },
                    });
                } else {
                    self.addSpan("metric.extension_ws_command_total", now, now, &.{
                        .{ .key = "result", .value = e.result },
                    });
                }
            },
            .produce_document_total => |e| {
                self.addSpan("metric.produce_document_total", now, now, &.{
                    .{ .key = "format", .value = e.format },
                    .{ .key = "result", .value = e.result },
                });
            },
            .produce_document_latency_ms => |e| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{e.value}) catch return;
                self.addSpan("metric.produce_document_latency_ms", now, now, &.{
                    .{ .key = "format", .value = e.format },
                    .{ .key = "value", .value = s },
                });
            },
            .moonshot_video_upload_total => |e| {
                self.addSpan("metric.moonshot_video_upload_total", now, now, &.{
                    .{ .key = "result", .value = e.result },
                });
            },
            // ── S5 (2026-05-29) — chartable signals ──
            // Same span-as-metric convention as the legacy structs above.
            .approval_decision_total => |e| {
                self.addSpan("metric.approval_decision_total", now, now, &.{
                    .{ .key = "result", .value = e.result },
                });
            },
            .artifact_export_total => |e| {
                self.addSpan("metric.artifact_export_total", now, now, &.{
                    .{ .key = "format", .value = e.format },
                    .{ .key = "result", .value = e.result },
                });
            },
            .artifact_export_latency_ms => |e| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{e.value}) catch return;
                self.addSpan("metric.artifact_export_latency_ms", now, now, &.{
                    .{ .key = "format", .value = e.format },
                    .{ .key = "value", .value = s },
                });
            },
            .memory_op_total => |e| {
                self.addSpan("metric.memory_op_total", now, now, &.{
                    .{ .key = "op", .value = e.op },
                    .{ .key = "result", .value = e.result },
                });
            },
            .memory_op_latency_ms => |e| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{e.value}) catch return;
                self.addSpan("metric.memory_op_latency_ms", now, now, &.{
                    .{ .key = "op", .value = e.op },
                    .{ .key = "value", .value = s },
                });
            },
            .trace_share_total => |e| {
                self.addSpan("metric.trace_share_total", now, now, &.{
                    .{ .key = "op", .value = e.op },
                    .{ .key = "result", .value = e.result },
                });
            },
            .tool_call_total => |e| {
                self.addSpan("metric.tool_call_total", now, now, &.{
                    .{ .key = "tool", .value = e.tool },
                    .{ .key = "result", .value = e.result },
                });
            },
            .tool_call_latency_ms => |e| {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{e.value}) catch return;
                self.addSpan("metric.tool_call_latency_ms", now, now, &.{
                    .{ .key = "tool", .value = e.tool },
                    .{ .key = "value", .value = s },
                });
            },
            .meter_receipt_total => |e| {
                self.addSpan("metric.meter_receipt_total", now, now, &.{
                    .{ .key = "result", .value = e.result },
                });
            },
        }
    }

    /// Serialize all pending spans as OTLP/HTTP JSON payload.
    pub fn serializeSpans(self: *OtelObserver) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
        try w.writeAll(self.service_name);
        try w.writeAll("\"}}]},\"scopeSpans\":[{\"spans\":[");

        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"traceId\":\"");
            try w.writeAll(&span.trace_id);
            try w.writeAll("\",\"spanId\":\"");
            try w.writeAll(&span.span_id);
            try w.writeAll("\",\"name\":\"");
            try w.writeAll(span.name);
            try w.writeAll("\",\"startTimeUnixNano\":\"");
            try w.print("{d}", .{span.start_ns});
            try w.writeAll("\",\"endTimeUnixNano\":\"");
            try w.print("{d}", .{span.end_ns});
            try w.writeAll("\",\"attributes\":[");

            for (span.attributes.items, 0..) |attr, j| {
                if (j > 0) try w.writeByte(',');
                try w.writeAll("{\"key\":\"");
                try w.writeAll(attr.key);
                try w.writeAll("\",\"value\":{\"stringValue\":\"");
                try w.writeAll(attr.value);
                try w.writeAll("\"}}");
            }

            try w.writeAll("],\"status\":{\"code\":1}}");
        }

        try w.writeAll("]}]}]}");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Flush pending spans to the OTLP endpoint. Caller must hold the mutex.
    fn flushLocked(self: *OtelObserver) void {
        if (self.spans.items.len == 0) return;

        const payload = self.serializeSpans() catch return;
        defer self.allocator.free(payload);

        const url_buf = std.fmt.allocPrint(self.allocator, "{s}/v1/traces", .{self.endpoint}) catch return;
        defer self.allocator.free(url_buf);

        // Best-effort send; free response if successful
        if (http_util.curlPost(self.allocator, url_buf, payload, &.{})) |curl_resp| {
            self.allocator.free(curl_resp);
        } else |_| {}

        // Clear spans regardless of delivery success to prevent unbounded growth
        for (self.spans.items) |*span| {
            span.deinit(self.allocator);
        }
        self.spans.clearRetainingCapacity();
    }

    fn otelFlush(ptr: *anyopaque) void {
        const self = resolve(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushLocked();
    }

    fn otelName(_: *anyopaque) []const u8 {
        return "otel";
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "NoopObserver name" {
    var noop = NoopObserver{};
    const obs = noop.observer();
    try std.testing.expectEqualStrings("noop", obs.getName());
}

test "NoopObserver does not panic on events" {
    var noop = NoopObserver{};
    const obs = noop.observer();
    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);
    const metric = ObserverMetric{ .tokens_used = 42 };
    obs.recordMetric(&metric);
    obs.flush();
}

test "LogObserver name" {
    var log_obs = LogObserver{};
    const obs = log_obs.observer();
    try std.testing.expectEqualStrings("log", obs.getName());
}

test "LogObserver does not panic on events" {
    var log_obs = LogObserver{};
    const obs = log_obs.observer();

    const events = [_]ObserverEvent{
        .{ .agent_start = .{ .provider = "openrouter", .model = "claude" } },
        .{ .llm_request = .{ .provider = "openrouter", .model = "claude", .messages_count = 2 } },
        .{ .llm_response = .{ .provider = "openrouter", .model = "claude", .duration_ms = 250, .success = true, .error_message = null } },
        .{ .agent_end = .{ .duration_ms = 500, .tokens_used = 100 } },
        .{ .tool_call_start = .{ .tool = "shell" } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 10, .success = false } },
        .{ .turn_complete = {} },
        .{ .channel_message = .{ .channel = "telegram", .direction = "outbound" } },
        .{ .heartbeat_tick = {} },
        .{ .err = .{ .component = "provider", .message = "timeout" } },
    };

    for (&events) |*event| {
        obs.recordEvent(event);
    }

    const metrics = [_]ObserverMetric{
        .{ .request_latency_ms = 2000 },
        .{ .tokens_used = 0 },
        .{ .active_sessions = 1 },
        .{ .queue_depth = 999 },
    };
    for (&metrics) |*metric| {
        obs.recordMetric(metric);
    }
}

test "VerboseObserver name" {
    var verbose = VerboseObserver{};
    const obs = verbose.observer();
    try std.testing.expectEqualStrings("verbose", obs.getName());
}

test "MultiObserver name" {
    var multi = MultiObserver{ .observers = &.{} };
    const obs = multi.observer();
    try std.testing.expectEqualStrings("multi", obs.getName());
}

test "MultiObserver empty does not panic" {
    var multi = MultiObserver{ .observers = @constCast(&[_]Observer{}) };
    const obs = multi.observer();
    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);
    const metric = ObserverMetric{ .tokens_used = 10 };
    obs.recordMetric(&metric);
    obs.flush();
}

test "MultiObserver fans out events" {
    var noop1 = NoopObserver{};
    var noop2 = NoopObserver{};
    var observers_arr = [_]Observer{ noop1.observer(), noop2.observer() };
    var multi = MultiObserver{ .observers = &observers_arr };
    const obs = multi.observer();

    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);
    obs.recordEvent(&event);
    obs.recordEvent(&event);
    // No panic = success (NoopObserver doesn't count but we verify fan-out doesn't crash)
}

test "createObserver factory" {
    try std.testing.expectEqualStrings("log", createObserver("log"));
    try std.testing.expectEqualStrings("verbose", createObserver("verbose"));
    try std.testing.expectEqualStrings("file", createObserver("file"));
    try std.testing.expectEqualStrings("multi", createObserver("multi"));
    try std.testing.expectEqualStrings("otel", createObserver("otel"));
    try std.testing.expectEqualStrings("otel", createObserver("otlp"));
    try std.testing.expectEqualStrings("noop", createObserver("none"));
    try std.testing.expectEqualStrings("noop", createObserver("noop"));
    try std.testing.expectEqualStrings("noop", createObserver("unknown_backend"));
    try std.testing.expectEqualStrings("noop", createObserver(""));
}

test "FileObserver name" {
    var file_obs = FileObserver{ .path = "/tmp/nullalis_test_obs.jsonl" };
    const obs = file_obs.observer();
    try std.testing.expectEqualStrings("file", obs.getName());
}

test "FileObserver does not panic on events" {
    var file_obs = FileObserver{ .path = "/tmp/nullalis_test_obs.jsonl" };
    const obs = file_obs.observer();
    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);
    const metric = ObserverMetric{ .tokens_used = 42 };
    obs.recordMetric(&metric);
    obs.flush();
}

test "FileObserver handles all event types" {
    var file_obs = FileObserver{ .path = "/tmp/nullalis_test_obs2.jsonl" };
    const obs = file_obs.observer();
    const events = [_]ObserverEvent{
        .{ .agent_start = .{ .provider = "test", .model = "test" } },
        .{ .llm_request = .{ .provider = "test", .model = "test", .messages_count = 1 } },
        .{ .llm_response = .{ .provider = "test", .model = "test", .duration_ms = 100, .success = true, .error_message = null } },
        .{ .agent_end = .{ .duration_ms = 1000, .tokens_used = 500 } },
        .{ .tool_call_start = .{ .tool = "shell" } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = true } },
        .{ .turn_complete = {} },
        .{ .channel_message = .{ .channel = "cli", .direction = "inbound" } },
        .{ .heartbeat_tick = {} },
        .{ .err = .{ .component = "test", .message = "error" } },
    };
    for (&events) |*event| {
        obs.recordEvent(event);
    }
}

// ── Additional observability tests ──────────────────────────────

test "VerboseObserver does not panic on events" {
    var verbose = VerboseObserver{};
    const obs = verbose.observer();
    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);
    const metric = ObserverMetric{ .tokens_used = 42 };
    obs.recordMetric(&metric);
    obs.flush();
}

test "VerboseObserver handles all event types" {
    var verbose = VerboseObserver{};
    const obs = verbose.observer();
    const events = [_]ObserverEvent{
        .{ .llm_request = .{ .provider = "test", .model = "test", .messages_count = 1 } },
        .{ .llm_response = .{ .provider = "test", .model = "test", .duration_ms = 100, .success = true, .error_message = null } },
        .{ .tool_call_start = .{ .tool = "shell" } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = true } },
        .{ .turn_stage = .{ .stage = "turn_start" } },
        .{ .turn_complete = {} },
        .{ .agent_start = .{ .provider = "test", .model = "test" } },
        .{ .agent_end = .{ .duration_ms = 1000, .tokens_used = 500 } },
        .{ .channel_message = .{ .channel = "cli", .direction = "inbound" } },
        .{ .heartbeat_tick = {} },
        .{ .err = .{ .component = "test", .message = "error" } },
    };
    for (&events) |*event| {
        obs.recordEvent(event);
    }
}

test "VerboseObserver turnStageLabel maps user-facing labels" {
    try std.testing.expectEqualStrings("Gathering context", VerboseObserver.turnStageLabel("turn_start"));
    try std.testing.expectEqualStrings("Using cached response", VerboseObserver.turnStageLabel("response_cache_hit"));
    try std.testing.expectEqualStrings("Preparing final reply", VerboseObserver.turnStageLabel("compose_final_reply"));
    try std.testing.expectEqualStrings("unknown_stage", VerboseObserver.turnStageLabel("unknown_stage"));
}

test "MultiObserver fans out metrics" {
    var noop1 = NoopObserver{};
    var noop2 = NoopObserver{};
    var observers_arr = [_]Observer{ noop1.observer(), noop2.observer() };
    var multi = MultiObserver{ .observers = &observers_arr };
    const obs = multi.observer();

    const metric = ObserverMetric{ .request_latency_ms = 500 };
    obs.recordMetric(&metric);
    obs.recordMetric(&metric);
    // No panic = success
}

test "MultiObserver fans out flush" {
    var noop1 = NoopObserver{};
    var noop2 = NoopObserver{};
    var observers_arr = [_]Observer{ noop1.observer(), noop2.observer() };
    var multi = MultiObserver{ .observers = &observers_arr };
    const obs = multi.observer();

    obs.flush();
    obs.flush();
    // No panic = success
}

test "ObserverEvent agent_start fields" {
    const event = ObserverEvent{ .agent_start = .{ .provider = "openrouter", .model = "claude-sonnet" } };
    switch (event) {
        .agent_start => |e| {
            try std.testing.expectEqualStrings("openrouter", e.provider);
            try std.testing.expectEqualStrings("claude-sonnet", e.model);
        },
        else => unreachable,
    }
}

test "ObserverEvent agent_end fields" {
    const event = ObserverEvent{ .agent_end = .{ .duration_ms = 1500, .tokens_used = 250 } };
    switch (event) {
        .agent_end => |e| {
            try std.testing.expectEqual(@as(u64, 1500), e.duration_ms);
            try std.testing.expectEqual(@as(?u64, 250), e.tokens_used);
        },
        else => unreachable,
    }
}

test "ObserverEvent err fields" {
    const event = ObserverEvent{ .err = .{ .component = "gateway", .message = "connection refused" } };
    switch (event) {
        .err => |e| {
            try std.testing.expectEqualStrings("gateway", e.component);
            try std.testing.expectEqualStrings("connection refused", e.message);
        },
        else => unreachable,
    }
}

test "ObserverMetric variants" {
    const m1 = ObserverMetric{ .request_latency_ms = 100 };
    const m2 = ObserverMetric{ .tokens_used = 50 };
    const m3 = ObserverMetric{ .active_sessions = 3 };
    const m4 = ObserverMetric{ .queue_depth = 10 };
    switch (m1) {
        .request_latency_ms => |v| try std.testing.expectEqual(@as(u64, 100), v),
        else => unreachable,
    }
    switch (m2) {
        .tokens_used => |v| try std.testing.expectEqual(@as(u64, 50), v),
        else => unreachable,
    }
    switch (m3) {
        .active_sessions => |v| try std.testing.expectEqual(@as(u64, 3), v),
        else => unreachable,
    }
    switch (m4) {
        .queue_depth => |v| try std.testing.expectEqual(@as(u64, 10), v),
        else => unreachable,
    }
}

test "LogObserver handles failed llm_response" {
    var log_obs = LogObserver{};
    const obs = log_obs.observer();
    const event = ObserverEvent{ .llm_response = .{
        .provider = "test",
        .model = "test",
        .duration_ms = 0,
        .success = false,
        .error_message = "timeout",
    } };
    obs.recordEvent(&event);
    // No panic = success
}

test "NoopObserver all metrics no-op" {
    var noop = NoopObserver{};
    const obs = noop.observer();
    const metrics = [_]ObserverMetric{
        .{ .request_latency_ms = 0 },
        .{ .tokens_used = std.math.maxInt(u64) },
        .{ .active_sessions = 0 },
        .{ .queue_depth = 0 },
    };
    for (&metrics) |*metric| {
        obs.recordMetric(metric);
    }
}

test "MultiObserver with single observer" {
    var noop = NoopObserver{};
    var observers_arr = [_]Observer{noop.observer()};
    var multi = MultiObserver{ .observers = &observers_arr };
    const obs = multi.observer();
    try std.testing.expectEqualStrings("multi", obs.getName());
    const event = ObserverEvent{ .turn_complete = {} };
    obs.recordEvent(&event);
}

test "createObserver case sensitive" {
    try std.testing.expectEqualStrings("noop", createObserver("Log"));
    try std.testing.expectEqualStrings("noop", createObserver("VERBOSE"));
    try std.testing.expectEqualStrings("noop", createObserver("NONE"));
    try std.testing.expectEqualStrings("noop", createObserver("FILE"));
}

test "Observer interface dispatches correctly" {
    // Verify the vtable pattern works through the Observer interface
    var noop = NoopObserver{};
    var log_obs = LogObserver{};
    var verbose = VerboseObserver{};
    var file_obs = FileObserver{ .path = "/tmp/nullalis_dispatch_test.jsonl" };

    const observers = [_]Observer{ noop.observer(), log_obs.observer(), verbose.observer(), file_obs.observer() };
    const expected_names = [_][]const u8{ "noop", "log", "verbose", "file" };

    for (observers, expected_names) |obs, name| {
        try std.testing.expectEqualStrings(name, obs.getName());
    }
}

// ── OtelObserver tests ──────────────────────────────────────────

test "OtelObserver name" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();
    try std.testing.expectEqualStrings("otel", obs.getName());
}

test "OtelObserver init defaults" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    try std.testing.expectEqualStrings("http://localhost:4318", otel.endpoint);
    try std.testing.expectEqualStrings("nullalis", otel.service_name);
    try std.testing.expectEqual(@as(usize, 0), otel.spans.items.len);
}

test "OtelObserver init custom endpoint" {
    var otel = OtelObserver.init(std.testing.allocator, "http://otel:4318", "myservice");
    defer otel.deinit();
    try std.testing.expectEqualStrings("http://otel:4318", otel.endpoint);
    try std.testing.expectEqualStrings("myservice", otel.service_name);
}

test "OtelObserver span building on agent_start" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    const event = ObserverEvent{ .agent_start = .{ .provider = "openrouter", .model = "claude" } };
    obs.recordEvent(&event);

    try std.testing.expectEqual(@as(usize, 1), otel.spans.items.len);
    try std.testing.expectEqualStrings("agent.start", otel.spans.items[0].name);
    // trace_id should be set (not all zeros)
    var all_zero = true;
    for (otel.current_trace_id) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "OtelObserver span building on all event types" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    // Record 9 events (under batch threshold of 10) to verify all types produce spans
    const events = [_]ObserverEvent{
        .{ .agent_start = .{ .provider = "test", .model = "test" } },
        .{ .llm_request = .{ .provider = "test", .model = "test", .messages_count = 1 } },
        .{ .llm_response = .{ .provider = "test", .model = "test", .duration_ms = 100, .success = true, .error_message = null } },
        .{ .tool_call_start = .{ .tool = "shell" } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = true } },
        .{ .turn_complete = {} },
        .{ .channel_message = .{ .channel = "cli", .direction = "inbound" } },
        .{ .heartbeat_tick = {} },
        .{ .err = .{ .component = "test", .message = "oops" } },
    };
    for (&events) |*event| {
        obs.recordEvent(event);
    }

    try std.testing.expectEqual(@as(usize, 9), otel.spans.items.len);
    try std.testing.expectEqualStrings("agent.start", otel.spans.items[0].name);
    try std.testing.expectEqualStrings("llm.request", otel.spans.items[1].name);
    try std.testing.expectEqualStrings("llm.response", otel.spans.items[2].name);
    try std.testing.expectEqualStrings("tool.start", otel.spans.items[3].name);
    try std.testing.expectEqualStrings("tool.call", otel.spans.items[4].name);
    try std.testing.expectEqualStrings("turn.complete", otel.spans.items[5].name);
    try std.testing.expectEqualStrings("channel.message", otel.spans.items[6].name);
    try std.testing.expectEqualStrings("heartbeat.tick", otel.spans.items[7].name);
    try std.testing.expectEqualStrings("error", otel.spans.items[8].name);

    // Verify agent_end works too (10th event triggers batch flush)
    const end_event = ObserverEvent{ .agent_end = .{ .duration_ms = 1000, .tokens_used = 500 } };
    obs.recordEvent(&end_event);
    // After flush, spans are cleared
    try std.testing.expect(otel.spans.items.len < 10);
}

test "OtelObserver span attributes" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    const event = ObserverEvent{ .agent_start = .{ .provider = "openrouter", .model = "claude" } };
    obs.recordEvent(&event);

    const span = otel.spans.items[0];
    try std.testing.expectEqual(@as(usize, 2), span.attributes.items.len);
    try std.testing.expectEqualStrings("provider", span.attributes.items[0].key);
    try std.testing.expectEqualStrings("openrouter", span.attributes.items[0].value);
    try std.testing.expectEqualStrings("model", span.attributes.items[1].key);
    try std.testing.expectEqualStrings("claude", span.attributes.items[1].value);
}

test "OtelObserver JSON serialization" {
    var otel = OtelObserver.init(std.testing.allocator, null, "test-svc");
    defer otel.deinit();
    const obs = otel.observer();

    const event = ObserverEvent{ .agent_start = .{ .provider = "test", .model = "m1" } };
    obs.recordEvent(&event);

    const json = try otel.serializeSpans();
    defer std.testing.allocator.free(json);

    // Verify overall structure
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"test-svc\"}}]}"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent.start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"traceId\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"spanId\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"startTimeUnixNano\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"endTimeUnixNano\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"key\":\"provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stringValue\":\"test\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, json, "]}]}]}"));
}

test "OtelObserver JSON multiple spans" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    const e1 = ObserverEvent{ .agent_start = .{ .provider = "a", .model = "b" } };
    obs.recordEvent(&e1);
    const e2 = ObserverEvent{ .turn_complete = {} };
    obs.recordEvent(&e2);

    const json = try otel.serializeSpans();
    defer std.testing.allocator.free(json);

    // Two spans separated by comma
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent.start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"turn.complete\"") != null);
}

test "OtelObserver batch flush at 10 spans" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    // Record 9 events — should not flush
    for (0..9) |_| {
        const event = ObserverEvent{ .heartbeat_tick = {} };
        obs.recordEvent(&event);
    }
    try std.testing.expectEqual(@as(usize, 9), otel.spans.items.len);

    // 10th event triggers flush attempt (curl fails, spans get cleared anyway)
    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);
    // After flush attempt (curl fails), spans are cleared
    try std.testing.expect(otel.spans.items.len < 10);
}

test "OtelObserver metrics create spans" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    const m1 = ObserverMetric{ .request_latency_ms = 42 };
    obs.recordMetric(&m1);
    const m2 = ObserverMetric{ .tokens_used = 100 };
    obs.recordMetric(&m2);
    const m3 = ObserverMetric{ .active_sessions = 3 };
    obs.recordMetric(&m3);
    const m4 = ObserverMetric{ .queue_depth = 7 };
    obs.recordMetric(&m4);

    try std.testing.expectEqual(@as(usize, 4), otel.spans.items.len);
    try std.testing.expectEqualStrings("metric.request_latency_ms", otel.spans.items[0].name);
    try std.testing.expectEqualStrings("metric.tokens_used", otel.spans.items[1].name);
    try std.testing.expectEqualStrings("metric.active_sessions", otel.spans.items[2].name);
    try std.testing.expectEqualStrings("metric.queue_depth", otel.spans.items[3].name);
}

test "OtelObserver flush empty is noop" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();
    // Flush with no spans should not panic or leak
    obs.flush();
}

test "OtelObserver randomHex produces valid hex" {
    var buf: [32]u8 = undefined;
    OtelObserver.randomHex(&buf);
    for (buf) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "OtelObserver span timing" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);

    const span = otel.spans.items[0];
    try std.testing.expect(span.start_ns > 0);
    try std.testing.expect(span.end_ns >= span.start_ns);
}

test "OtelObserver llm_response has duration-adjusted start" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    const event = ObserverEvent{ .llm_response = .{
        .provider = "p",
        .model = "m",
        .duration_ms = 100,
        .success = true,
        .error_message = null,
    } };
    obs.recordEvent(&event);

    const span = otel.spans.items[0];
    // start should be earlier than end by ~100ms
    try std.testing.expect(span.end_ns >= span.start_ns);
    try std.testing.expect(span.end_ns - span.start_ns >= 50_000_000); // at least 50ms delta
}

test "OtelObserver vtable through Observer interface" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    // Verify it works through the generic Observer interface
    try std.testing.expectEqualStrings("otel", obs.getName());
    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);
    const metric = ObserverMetric{ .tokens_used = 10 };
    obs.recordMetric(&metric);
    obs.flush(); // flush attempt (curl fails silently)
}

test "OtelObserver requests_total counter" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    try std.testing.expectEqual(@as(u64, 0), otel.requests_total.load(.monotonic));

    const e1 = ObserverEvent{ .llm_request = .{ .provider = "p", .model = "m", .messages_count = 1 } };
    obs.recordEvent(&e1);
    try std.testing.expectEqual(@as(u64, 1), otel.requests_total.load(.monotonic));

    obs.recordEvent(&e1);
    obs.recordEvent(&e1);
    try std.testing.expectEqual(@as(u64, 3), otel.requests_total.load(.monotonic));

    // Non-request events should not increment requests_total
    const e2 = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&e2);
    try std.testing.expectEqual(@as(u64, 3), otel.requests_total.load(.monotonic));
}

test "OtelObserver errors_total counter on failed response" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    try std.testing.expectEqual(@as(u64, 0), otel.errors_total.load(.monotonic));

    // Successful response should not increment errors
    const ok = ObserverEvent{ .llm_response = .{ .provider = "p", .model = "m", .duration_ms = 50, .success = true, .error_message = null } };
    obs.recordEvent(&ok);
    try std.testing.expectEqual(@as(u64, 0), otel.errors_total.load(.monotonic));

    // Failed response should increment errors
    const fail = ObserverEvent{ .llm_response = .{ .provider = "p", .model = "m", .duration_ms = 50, .success = false, .error_message = "timeout" } };
    obs.recordEvent(&fail);
    try std.testing.expectEqual(@as(u64, 1), otel.errors_total.load(.monotonic));
}

test "OtelObserver errors_total counter on error event" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    const e1 = ObserverEvent{ .err = .{ .component = "provider", .message = "connection refused" } };
    obs.recordEvent(&e1);
    obs.recordEvent(&e1);
    try std.testing.expectEqual(@as(u64, 2), otel.errors_total.load(.monotonic));
}

test "OtelObserver JSON includes status code" {
    var otel = OtelObserver.init(std.testing.allocator, null, "svc");
    defer otel.deinit();
    const obs = otel.observer();

    const event = ObserverEvent{ .heartbeat_tick = {} };
    obs.recordEvent(&event);

    const json = try otel.serializeSpans();
    defer std.testing.allocator.free(json);

    // Each span should have status code 1 (OK)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":{\"code\":1}") != null);
}

test "OtelObserver counters combined scenario" {
    var otel = OtelObserver.init(std.testing.allocator, null, null);
    defer otel.deinit();
    const obs = otel.observer();

    // 3 requests, 1 failed response, 2 errors
    const req = ObserverEvent{ .llm_request = .{ .provider = "p", .model = "m", .messages_count = 1 } };
    obs.recordEvent(&req);
    obs.recordEvent(&req);
    obs.recordEvent(&req);

    const fail = ObserverEvent{ .llm_response = .{ .provider = "p", .model = "m", .duration_ms = 10, .success = false, .error_message = "err" } };
    obs.recordEvent(&fail);

    const err_evt = ObserverEvent{ .err = .{ .component = "net", .message = "dns" } };
    obs.recordEvent(&err_evt);
    obs.recordEvent(&err_evt);

    try std.testing.expectEqual(@as(u64, 3), otel.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), otel.errors_total.load(.monotonic)); // 1 failed response + 2 error events
}
