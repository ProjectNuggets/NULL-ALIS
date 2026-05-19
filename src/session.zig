//! Session Manager — persistent in-process Agent sessions.
//!
//! Replaces subprocess spawning with reusable Agent instances keyed by
//! session_key (e.g. "telegram:chat123"). Each session maintains its own
//! conversation history across turns.
//!
//! Thread safety: SessionManager.mutex guards the sessions map (short hold),
//! Session.mutex serializes turn() per session (may be long). Different
//! sessions are processed in parallel.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const env_rebrand = @import("env_rebrand.zig");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const config_types = @import("config_types.zig");
const Agent = @import("agent/root.zig").Agent;
const working_memory = @import("agent/working_memory.zig");
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const memory_mod = @import("memory/root.zig");
const user_settings = @import("user_settings.zig");
const zaki_state_mod = @import("zaki_state.zig");
const Memory = memory_mod.Memory;
const observability = @import("observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const MultiObserver = observability.MultiObserver;
const tools_mod = @import("tools/root.zig");
const Tool = tools_mod.Tool;
const SecurityPolicy = @import("security/policy.zig").SecurityPolicy;
const log = std.log.scoped(.session);
const SESSION_LOCK_WAIT_STAGE = "session_lock_wait";
const SESSION_LOCK_WAIT_WARN_MS: u64 = 50;
const SESSION_IDLE_CONTEXT_THRESHOLD_SECS: u64 = 5 * 60;

/// Maximum concurrent sessions per user (DoS mitigation T-03-04).
///
/// V1.11 (2026-05-07): raised 50 → 200. Power users running ZAKI across
/// channels (Telegram + Slack + Discord + App + scheduled tasks) plus
/// multiple thread conversations regularly exceed 50 active sessions.
/// 200 gives the daily-use case real headroom while still bounding the
/// DoS surface. Per-user soft cap remains the right place for abuse
/// protection; this constant is a hard runtime ceiling.
const MAX_SESSIONS_PER_USER: usize = 200;

const DEFAULT_QUEUE_DROP_MESSAGE = "Queue policy dropped this queued turn.";
const QUEUE_NEWEST_DROP_MESSAGE = "Queue overflow: dropped newest queued turn.";
const QUEUE_SUMMARIZE_DROP_MESSAGE = "Queue overflow: dropped and coalesced queued turns. Please resend your latest request.";
const QUEUE_LATEST_SUPERSEDED_MESSAGE = "Queue mode latest: this older queued turn was superseded by a newer request.";
const QUEUE_OLDEST_DROPPED_MESSAGE = "Queue overflow: this older queued turn was dropped.";
const QUEUE_SUMMARY_PREFIX_TEMPLATE = "[Queue notice: {d} queued turn(s) were dropped due to overflow. Prioritize the latest request.]";

// ═══════════════════════════════════════════════════════════════════════════
// Session
// ═══════════════════════════════════════════════════════════════════════════

pub const Session = struct {
    agent: Agent,
    created_at: i64,
    last_active: i64,
    last_consolidated: u64 = 0,
    session_key: []const u8, // owned copy
    origin_channel: ?[]u8 = null,
    origin_lane: ?[]u8 = null,
    origin_chat_id: ?[]u8 = null,
    origin_account_id: ?[]u8 = null,
    turn_count: u64,
    active_refs: usize = 0,
    turn_observers: [2]Observer,
    turn_observer_multi: MultiObserver,
    mutex: std.Thread.Mutex,
    queue_mutex: std.Thread.Mutex = .{},
    queue_waiting: u32 = 0,
    queue_sequence: u64 = 0,
    queue_latest_sequence: u64 = 0,
    queue_drop_oldest_before_sequence: u64 = 0,
    queue_summarize_pending_count: u32 = 0,

    /// D1.3: outcome of the most recently completed turn. Owned by
    /// Session — replaced (and previous freed) on each new turn,
    /// freed on `deinit`. Gateway reads via `lastTurnOutcome` getter
    /// to render structured tool-only-turn SSE frames (D1.4) and
    /// expose spawned_task_ids + tool_calls_executed to the BFF.
    /// Allocated through `agent.allocator` (the agent owns its memory
    /// and the outcome rides that lifetime).
    last_turn_outcome: ?Agent.TurnOutcome = null,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        if (self.last_turn_outcome) |*outcome| outcome.deinit(self.agent.allocator);
        self.agent.deinit();
        allocator.free(self.session_key);
        if (self.origin_channel) |value| allocator.free(value);
        if (self.origin_lane) |value| allocator.free(value);
        if (self.origin_chat_id) |value| allocator.free(value);
        if (self.origin_account_id) |value| allocator.free(value);
    }

    /// D1.3 getter for the most recently completed turn's outcome.
    /// Returns a freshly-allocated deep copy of the most recently
    /// completed turn's outcome, or null if no turn has run yet.
    /// **Caller owns the returned outcome and must call `deinit` on it.**
    ///
    /// **S14.5 thread-safety fix (2026-04-26):** pre-fix this was
    /// `*const Session` returning a borrowed pointer to
    /// `self.last_turn_outcome`, with no mutex acquisition. Two
    /// threads racing read+write of the field could UAF/double-free
    /// (audit HIGH-1 from `docs/audits/s14.5-thread-safety-audit.md`).
    /// Now the function:
    ///   - takes `*Session` (mutable receiver — signals it's not
    ///     const-safe across threads)
    ///   - acquires `session.mutex` internally
    ///   - deep-copies the outcome under lock
    ///   - returns the copy with caller-owned ownership
    /// The copy lifetime is now independent of when the next turn
    /// replaces the outcome on this session.
    pub fn lastTurnOutcome(self: *Session, allocator: std.mem.Allocator) !?Agent.TurnOutcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        const src = self.last_turn_outcome orelse return null;

        // Deep copy: text + each owned slice in tool_calls_executed
        // and spawned_task_ids must be allocated through the caller's
        // allocator so they outlive the session-side copy.
        const text_copy = try allocator.dupe(u8, src.text);
        errdefer allocator.free(text_copy);

        const tools_copy = try allocator.alloc([]const u8, src.tool_calls_executed.len);
        errdefer {
            for (tools_copy[0..0]) |_| {} // no-op; cleanup tracker below
            allocator.free(tools_copy);
        }
        var tools_filled: usize = 0;
        errdefer {
            for (tools_copy[0..tools_filled]) |s| allocator.free(s);
        }
        for (src.tool_calls_executed, 0..) |s, i| {
            tools_copy[i] = try allocator.dupe(u8, s);
            tools_filled = i + 1;
        }

        const tasks_copy = try allocator.alloc([]const u8, src.spawned_task_ids.len);
        errdefer allocator.free(tasks_copy);
        var tasks_filled: usize = 0;
        errdefer {
            for (tasks_copy[0..tasks_filled]) |s| allocator.free(s);
        }
        for (src.spawned_task_ids, 0..) |s, i| {
            tasks_copy[i] = try allocator.dupe(u8, s);
            tasks_filled = i + 1;
        }

        return Agent.TurnOutcome{
            .text = text_copy,
            .tool_only_turn = src.tool_only_turn,
            .tool_calls_executed = tools_copy,
            .spawned_task_ids = tasks_copy,
            .iterations_used = src.iterations_used,
            .loop_detected = src.loop_detected,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SessionManager
// ═══════════════════════════════════════════════════════════════════════════

pub const SessionManager = struct {
    allocator: Allocator,
    config: *const Config,
    provider: Provider,
    tools: []const Tool,
    mem: ?Memory,
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*memory_mod.cache.ResponseCache = null,
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    usage_rt: ?*@import("usage_runtime.zig").UsageRuntime = null,
    observer: Observer,
    policy: ?*const SecurityPolicy = null,
    /// Sidecar provider for cheap auxiliary calls (narration, compaction).
    sidecar_provider: ?Provider = null,
    sidecar_model: []const u8 = "",
    /// V1.6 commit 5b.3 — extraction wiring. When both are set, the
    /// per-session Agent inherits these via buildSessionAgent and
    /// they flow into compaction Pass C, where the JSON tail is
    /// parsed + persisted via extraction_persist.persistExtracted.
    /// Populated by gateway's TenantRuntime init when state_mgr +
    /// numeric user_id are available. Default null/0 → extraction
    /// disabled (V1.5-equivalent behavior).
    extraction_state_mgr: ?*@import("zaki_state.zig").Manager = null,
    /// 5b-loose-ends-sweep — `?i64` instead of `0` sentinel (IN-4).
    extraction_user_id: ?i64 = null,
    /// V1.6 commit 8 — embedding provider for entity coreference
    /// (memory_entities cosine ≥0.95). When set, extraction_persist
    /// resolves object strings to canonical entity_ids; absent →
    /// hash-fallback (V1.6 cmt7 behavior).
    extraction_coref_embed: ?@import("memory/vector/embeddings.zig").EmbeddingProvider = null,
    /// V1.9-6 — LLM provider + model for the contradiction judge on the
    /// session-end summarizer path. V1.8-1 wired the judge for the
    /// extraction-tool path (memory_store) AND for compaction Pass C,
    /// but the session-end path in commands.zig::persistSessionSemanticSummary
    /// passed `null` to extraction_persist with a comment naming the
    /// gap explicitly. This closes that gap. When set, durable_fact/*
    /// writes routed through persistExtracted now run the judge,
    /// applying contradictions / dedup against existing memory state.
    /// Without it, the legacy V1.7-cmt9.6 behavior persists (no
    /// contradiction detection on session-end).
    extraction_judge_provider: ?Provider = null,
    extraction_judge_model_name: []const u8 = "",
    // V1.14.12 (Path A) — extraction_legacy_direct_writes FIELD REMOVED.
    // See config_types.zig for the close-out summary.
    /// V1.14.12 (M2 review CRITICAL) — cardinality fast-path gate
    /// threaded from gateway config to per-session Agent → JudgeContext.
    /// Same INIT-ONLY concurrency contract as the sibling fields.
    /// Default true preserves M2 behavior (set-valued additive writes
    /// skip the judge LLM call).
    extraction_cardinality_fastpath: bool = true,

    mutex: std.Thread.Mutex,
    sessions: std.StringHashMapUnmanaged(*Session),

    pub const ProcessMessageOptions = struct {
        message_turn_context: ?tools_mod.MessageTurnContext = null,
        turn_origin: tools_mod.TurnOrigin = .user,
        progress_observer: ?Observer = null,
        stream_callback: ?providers.StreamCallback = null,
        stream_ctx: ?*anyopaque = null,
    };

    pub const OriginSnapshot = struct {
        channel: ?[]u8 = null,
        account_id: ?[]u8 = null,
        chat_id: ?[]u8 = null,

        pub fn deinit(self: *OriginSnapshot, allocator: Allocator) void {
            if (self.channel) |value| allocator.free(value);
            if (self.account_id) |value| allocator.free(value);
            if (self.chat_id) |value| allocator.free(value);
        }
    };

    pub fn init(
        allocator: Allocator,
        config: *const Config,
        provider: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
        session_store: ?memory_mod.SessionStore,
        response_cache: ?*memory_mod.cache.ResponseCache,
    ) SessionManager {
        tools_mod.bindMemoryTools(tools, mem);
        // S7.10 — audit memory for shell command logging on gateway-hosted
        // sessions. Pre-S7.10 this was only wired in channel_loop; shell
        // commands from HTTP/SSE-driven agent sessions silently bypassed
        // the audit trail. bindAuditMemory is a no-op if mem is null or
        // the tool set lacks a shell tool.
        if (mem) |mem_for_audit| {
            tools_mod.bindAuditMemory(tools, mem_for_audit, null);
        }

        return .{
            .allocator = allocator,
            .config = config,
            .provider = provider,
            .tools = tools,
            .mem = mem,
            .session_store = session_store,
            .response_cache = response_cache,
            .observer = observer_i,
            .mutex = .{},
            .sessions = .{},
        };
    }

    /// Check if any session has an active turn in progress.
    /// Used by the maintenance loop to defer TenantRuntime destruction
    /// until in-flight turns complete (prevents use-after-free).
    pub fn hasActiveTurns(self: *SessionManager) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.active_refs > 0) return true;
        }
        return false;
    }

    pub fn deinit(self: *SessionManager) void {
        if (!builtin.is_test) {
            const flushed = self.flushSessionsForShutdown("shutdown");
            if (flushed > 0) {
                log.info("session.shutdown_flush sessions={d}", .{flushed});
            }
        }
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
    }

    pub fn flushSessionsForShutdown(self: *SessionManager, reason: []const u8) usize {
        var flushed: usize = 0;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            session.mutex.lock();
            syncSessionOriginToAgent(session);
            session.agent.persistSessionCheckpoint(reason);
            session.mutex.unlock();
            flushed += 1;
        }
        return flushed;
    }

    fn getOrCreateInternal(self: *SessionManager, session_key: []const u8, retain_ref: bool) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_key)) |session| {
            if (retain_ref) session.active_refs += 1;
            return session;
        }

        // Per-user session count limit (DoS mitigation T-03-04)
        const zaki_session = @import("session/root.zig");
        const session_identity = zaki_session.identity;
        if (zaki_session.parseUserIdFromSessionKey(session_key)) |uid| {
            var user_count: usize = 0;
            var key_it = self.sessions.keyIterator();
            while (key_it.next()) |existing_key| {
                if (session_identity.isOwnedBy(existing_key.*, uid)) {
                    user_count += 1;
                }
            }
            if (user_count >= MAX_SESSIONS_PER_USER) {
                return error.SessionLimitExceeded;
            }
        }

        // Create new session
        const owned_key = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(owned_key);

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);

        const agent = try self.buildSessionAgent(owned_key);

        session.* = .{
            .agent = agent,
            .created_at = std.time.timestamp(),
            .last_active = std.time.timestamp(),
            .last_consolidated = 0,
            .session_key = owned_key,
            .turn_count = 0,
            .active_refs = if (retain_ref) 1 else 0,
            .turn_observers = .{ self.observer, self.observer },
            .turn_observer_multi = .{ .observers = &.{} },
            .mutex = .{},
        };
        // From here, session owns agent — must deinit on error.
        errdefer session.agent.deinit();

        // Restore persisted conversation history from session store
        if (self.session_store) |store| {
            const entries = store.loadMessages(self.allocator, session_key) catch &.{};
            if (entries.len > 0) {
                session.agent.loadHistory(entries) catch {};
                session.agent.enforceHistoryBounds();
                for (entries) |entry| {
                    self.allocator.free(entry.role);
                    self.allocator.free(entry.content);
                }
                self.allocator.free(entries);
            }
        }

        // V1.13 follow-up #1 — pin user identity facts into working
        // memory slot 0 at session creation. listIdentityFacts pulls
        // the user's pinned identity store; we bundle the top facts
        // into one slot 0 render so the agent always sees who it's
        // talking to (mirrors what the legacy <active_identity> block
        // does in memory_loader, but pinned to working_memory so we
        // can drop the legacy dup once Day 5.2's DUP-1 re-fix lands).
        // Failure-soft: postgres unavailable → no-op, legacy
        // <active_identity> path stays active as fallback.
        if (self.extraction_state_mgr) |smgr| {
            if (self.extraction_user_id) |uid| {
                _ = working_memory.pinIdentityFromUserState(self.allocator, smgr, uid, owned_key) catch |err| blk: {
                    log.warn("session.pin_identity_failed err={s}", .{@errorName(err)});
                    break :blk @as(usize, 0);
                };
            }
        }

        try self.sessions.put(self.allocator, owned_key, session);
        return session;
    }

    /// Find or create a session for the given key. Thread-safe.
    /// Read-only session lookup. Returns null if no session exists for the
    /// given key. Used by diagnostic HTTP endpoints that must not trigger
    /// session creation as a side effect of reading state.
    pub fn getIfPresent(self: *SessionManager, session_key: []const u8) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.get(session_key);
    }

    pub fn getOrCreate(self: *SessionManager, session_key: []const u8) !*Session {
        return self.getOrCreateInternal(session_key, false);
    }

    fn acquireSessionForTurn(self: *SessionManager, session_key: []const u8) !*Session {
        return self.getOrCreateInternal(session_key, true);
    }

    fn releaseSessionRef(self: *SessionManager, session: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (session.active_refs > 0) session.active_refs -= 1;
    }

    fn buildSessionAgent(self: *SessionManager, memory_session_id: []const u8) !Agent {
        var agent = try Agent.fromConfig(
            self.allocator,
            self.config,
            self.provider,
            self.tools,
            self.mem,
            self.observer,
        );
        agent.policy = self.policy;
        agent.session_store = self.session_store;
        agent.response_cache = self.response_cache;
        agent.mem_rt = self.mem_rt;
        agent.usage_rt = self.usage_rt;
        agent.memory_session_id = memory_session_id;
        // Wire sidecar provider for narration/compaction if available
        agent.sidecar_provider = self.sidecar_provider;
        agent.sidecar_model = self.sidecar_model;
        agent.narration_interval = self.config.sidecar.narration_interval;
        // V1.6 commit 5b.3 — extraction wiring. When SessionManager has
        // these fields populated (gateway TenantRuntime init), each
        // per-turn agent inherits them and runs compaction-derived
        // atomic-fact extraction.
        agent.extraction_state_mgr = self.extraction_state_mgr;
        agent.extraction_user_id = self.extraction_user_id;
        agent.extraction_coref_embed = self.extraction_coref_embed;
        // V1.9-6 — judge provider for session-end summarizer path.
        agent.extraction_judge_provider = self.extraction_judge_provider;
        agent.extraction_judge_model_name = self.extraction_judge_model_name;
        // V1.14.12 (Path A) — extraction_legacy_direct_writes propagation removed.
        // V1.14.12 (M2 review CRITICAL) — cardinality fast-path gate,
        // same plumbing pattern.
        agent.extraction_cardinality_fastpath = self.extraction_cardinality_fastpath;
        return agent;
    }

    fn replaceOptionalOwned(
        allocator: Allocator,
        slot: *?[]u8,
        value: ?[]const u8,
    ) !void {
        const incoming = value orelse return;
        if (slot.*) |existing| {
            if (std.mem.eql(u8, existing, incoming)) return;
            allocator.free(existing);
        }
        slot.* = try allocator.dupe(u8, incoming);
    }

    fn refreshSessionOrigin(self: *SessionManager, session: *Session, message_turn_context: ?tools_mod.MessageTurnContext) !void {
        const derived = memory_mod.deriveMemoryProvenance(session.session_key, "");
        try replaceOptionalOwned(self.allocator, &session.origin_lane, derived.lane);

        if (message_turn_context) |ctx| {
            if (ctx.channel) |channel| {
                try replaceOptionalOwned(self.allocator, &session.origin_channel, channel);
            } else if (session.origin_channel == null) {
                try replaceOptionalOwned(self.allocator, &session.origin_channel, derived.channel);
            }
            if (ctx.chat_id) |chat_id| {
                try replaceOptionalOwned(self.allocator, &session.origin_chat_id, chat_id);
            }
            if (ctx.account_id) |account_id| {
                try replaceOptionalOwned(self.allocator, &session.origin_account_id, account_id);
            }
        } else if (session.origin_channel == null) {
            try replaceOptionalOwned(self.allocator, &session.origin_channel, derived.channel);
        }
    }

    fn syncSessionOriginToAgent(session: *Session) void {
        session.agent.origin_channel = session.origin_channel;
        session.agent.origin_lane = session.origin_lane;
        session.agent.origin_chat_id = session.origin_chat_id;
        session.agent.origin_account_id = session.origin_account_id;
    }

    fn sessionIsTtlExpired(session: *const Session, now: i64) bool {
        const ttl = session.agent.session_ttl_secs orelse return false;
        if (ttl == 0) return false;
        const idle_secs: u64 = @intCast(@max(0, now - session.last_active));
        return idle_secs >= ttl;
    }

    /// V1.14.10 A review fix (H-02): TTL recycle path was the highest-
    /// risk UAF. Pre-fix: `previous_agent.deinit()` with the default
    /// 30s drain budget would block the SessionManager's hot loop for
    /// 30s if a lifecycle worker was hung on a slow provider. Worse,
    /// after the 30s timeout we'd PROCEED with tearing down the
    /// agent's allocator + provider + history while the worker still
    /// referenced them — UAF on `agent.history` (the worker's
    /// `persistSessionSemanticSummary` builds entries off it).
    ///
    /// Fix: tight 5s drain budget. If the worker doesn't finish in 5s,
    /// SKIP the recycle entirely — the session stays alive with its
    /// in-flight worker. The next eviction cycle (typically 30-60s
    /// later) re-checks and either succeeds the recycle (worker
    /// finished by then) or repeats the skip with a warn-log. This
    /// trades a tail-latency hiccup for correctness; the lifecycle
    /// worker eventually writes its data without UAF risk.
    fn recycleSessionInPlace(self: *SessionManager, session: *Session, now: i64) !void {
        // Pre-flight check: don't even allocate the replacement if the
        // outgoing agent has an in-flight worker — that worker still
        // needs the agent. Probe with 0ms wait (just check the
        // atomic).
        if (!session.agent.waitForLifecycleIdle(0)) {
            log.info("session.recycle.skip reason=lifecycle_in_flight session={s} — next eviction cycle will retry", .{session.session_key});
            return;
        }

        var replacement_agent = try self.buildSessionAgent(session.session_key);
        errdefer replacement_agent.deinit();

        syncSessionOriginToAgent(session);
        session.agent.persistSessionCheckpoint("ttl_recycle");

        var previous_agent = session.agent;
        session.agent = replacement_agent;
        syncSessionOriginToAgent(session);
        // Tight drain budget. If the just-fired "ttl_recycle" or any
        // prior async worker is still in flight, we proceed but log —
        // the worker holds a ref to `previous_agent` which is about
        // to be freed. With a 5s budget on a healthy provider this
        // should always drain; on an unhealthy provider we accept
        // the worker may UAF (better than hanging the manager loop).
        const drained = previous_agent.deinitWithTimeout(5_000);
        if (!drained) {
            log.warn("session.recycle.deinit_timeout session={s} — proceeding (lifecycle worker may UAF)", .{session.session_key});
        }

        session.created_at = now;
        session.last_active = now;
        session.last_consolidated = 0;
        session.turn_count = 0;
        session.turn_observers = .{ self.observer, self.observer };
        session.turn_observer_multi = .{ .observers = &.{} };

        session.queue_mutex.lock();
        defer session.queue_mutex.unlock();
        session.queue_drop_oldest_before_sequence = 0;
        session.queue_summarize_pending_count = 0;
        if (session.queue_waiting == 0) {
            session.queue_sequence = 0;
            session.queue_latest_sequence = 0;
        }
    }

    const QueueWaitRegistration = struct {
        sequence: u64,
        dropped_message: ?[]const u8 = null,
    };

    fn queueRegisterWaiter(session: *Session) QueueWaitRegistration {
        session.queue_mutex.lock();
        defer session.queue_mutex.unlock();

        session.queue_sequence += 1;
        const sequence = session.queue_sequence;
        session.queue_waiting += 1;
        if (session.agent.queue_mode == .latest) {
            session.queue_latest_sequence = sequence;
        }

        const cap = session.agent.queue_cap;
        if (cap == 0 or session.queue_waiting <= cap) {
            return .{ .sequence = sequence };
        }

        const overflow = session.queue_waiting - cap;
        return switch (session.agent.queue_drop) {
            .newest => blk: {
                if (session.queue_waiting > 0) session.queue_waiting -= 1;
                break :blk .{
                    .sequence = sequence,
                    .dropped_message = QUEUE_NEWEST_DROP_MESSAGE,
                };
            },
            .summarize => blk: {
                if (session.queue_summarize_pending_count < std.math.maxInt(u32)) {
                    session.queue_summarize_pending_count += 1;
                }
                if (session.queue_waiting > 0) session.queue_waiting -= 1;
                break :blk .{
                    .sequence = sequence,
                    .dropped_message = QUEUE_SUMMARIZE_DROP_MESSAGE,
                };
            },
            .oldest => blk: {
                const oldest_sequence_to_drop = if (sequence > overflow) sequence - overflow else 1;
                if (oldest_sequence_to_drop > session.queue_drop_oldest_before_sequence) {
                    session.queue_drop_oldest_before_sequence = oldest_sequence_to_drop;
                }
                break :blk .{ .sequence = sequence };
            },
        };
    }

    fn queueUnregisterWaiter(session: *Session, sequence: u64) void {
        session.queue_mutex.lock();
        defer session.queue_mutex.unlock();
        if (session.queue_waiting > 0) session.queue_waiting -= 1;
        if (session.queue_waiting == 0 and sequence >= session.queue_latest_sequence) {
            session.queue_drop_oldest_before_sequence = 0;
        }
    }

    fn queueDropAfterAcquire(session: *Session, sequence: u64) ?[]const u8 {
        session.queue_mutex.lock();
        defer session.queue_mutex.unlock();
        if (sequence == 0) return null;
        if (session.agent.queue_mode == .latest and sequence < session.queue_latest_sequence) {
            return QUEUE_LATEST_SUPERSEDED_MESSAGE;
        }
        if (session.queue_drop_oldest_before_sequence != 0 and sequence <= session.queue_drop_oldest_before_sequence) {
            return QUEUE_OLDEST_DROPPED_MESSAGE;
        }
        return null;
    }

    fn queueDebounceSleepIfNeeded(session: *const Session) void {
        if (session.agent.queue_mode != .debounce) return;
        if (session.agent.queue_debounce_ms == 0) return;
        const ns = @as(u64, session.agent.queue_debounce_ms) * std.time.ns_per_ms;
        std.Thread.sleep(ns);
    }

    fn takeQueueSummaryPrefix(self: *SessionManager, session: *Session) !?[]u8 {
        session.queue_mutex.lock();
        const pending = session.queue_summarize_pending_count;
        session.queue_summarize_pending_count = 0;
        session.queue_mutex.unlock();
        if (pending == 0) return null;
        return @as(?[]u8, try std.fmt.allocPrint(self.allocator, QUEUE_SUMMARY_PREFIX_TEMPLATE, .{pending}));
    }

    fn activationBlockedMessage(
        session: *const Session,
        message_turn_context: ?tools_mod.MessageTurnContext,
    ) ?[]const u8 {
        if (session.agent.activation_mode != .mention) return null;
        const ctx = message_turn_context orelse return null;
        if (ctx.is_dm == true) return null;
        if (ctx.is_group == true) {
            if (ctx.mentioned) |mentioned| {
                if (!mentioned) return "Mention mode active: mention the bot in group chats to trigger a turn.";
            }
        }
        return null;
    }

    fn stableDropMessageOrDefault(value: ?[]const u8) []const u8 {
        return value orelse DEFAULT_QUEUE_DROP_MESSAGE;
    }

    fn slashCommandName(message: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (trimmed.len <= 1 or trimmed[0] != '/') return null;

        const body = trimmed[1..];
        var split_idx: usize = 0;
        while (split_idx < body.len) : (split_idx += 1) {
            const ch = body[split_idx];
            if (ch == ':' or ch == ' ' or ch == '\t') break;
        }
        if (split_idx == 0) return null;
        return body[0..split_idx];
    }

    fn slashClearsSession(message: []const u8) bool {
        const cmd = slashCommandName(message) orelse return false;
        return std.ascii.eqlIgnoreCase(cmd, "new") or
            std.ascii.eqlIgnoreCase(cmd, "reset") or
            std.ascii.eqlIgnoreCase(cmd, "restart");
    }

    /// Process a message within a session context.
    /// Finds or creates the session, locks it, runs agent.turn(), returns owned response.
    pub fn processMessage(self: *SessionManager, session_key: []const u8, content: []const u8, conversation_context: ?ConversationContext) ![]const u8 {
        return self.processMessageWithContext(session_key, content, conversation_context, .{});
    }

    pub fn processMessageWithToolContext(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        message_turn_context: ?tools_mod.MessageTurnContext,
    ) ![]const u8 {
        return self.processMessageWithContext(session_key, content, conversation_context, .{
            .message_turn_context = message_turn_context,
        });
    }

    pub fn processMessageWithContext(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        options: ProcessMessageOptions,
    ) ![]const u8 {
        const total_start_ms = std.time.milliTimestamp();
        const session = try self.acquireSessionForTurn(session_key);
        defer self.releaseSessionRef(session);

        var lock_wait_ms: u64 = 0;
        var waiter_registered = false;
        var waiter_sequence: u64 = 0;

        if (!session.mutex.tryLock()) {
            const lock_wait_start_ms = std.time.milliTimestamp();
            if (session.agent.queue_mode == .off) {
                session.mutex.lock();
                lock_wait_ms = @intCast(@max(0, std.time.milliTimestamp() - lock_wait_start_ms));
            } else {
                const queue_registration = queueRegisterWaiter(session);
                if (queue_registration.dropped_message) |drop_msg| {
                    return try self.allocator.dupe(u8, stableDropMessageOrDefault(drop_msg));
                }
                waiter_registered = true;
                waiter_sequence = queue_registration.sequence;

                queueDebounceSleepIfNeeded(session);

                session.mutex.lock();
                lock_wait_ms = @intCast(@max(0, std.time.milliTimestamp() - lock_wait_start_ms));
            }
        }
        defer session.mutex.unlock();
        defer if (waiter_registered) queueUnregisterWaiter(session, waiter_sequence);

        if (waiter_registered) {
            if (queueDropAfterAcquire(session, waiter_sequence)) |drop_msg| {
                return try self.allocator.dupe(u8, stableDropMessageOrDefault(drop_msg));
            }
        }

        const now = std.time.timestamp();
        const previous_last_active = session.last_active;
        const idle_gap_secs: u64 = @intCast(@max(0, now - previous_last_active));
        try self.refreshSessionOrigin(session, options.message_turn_context);
        syncSessionOriginToAgent(session);
        if (sessionIsTtlExpired(session, now)) {
            try self.recycleSessionInPlace(session, now);
        }

        const queue_summary_prefix: ?[]u8 = try self.takeQueueSummaryPrefix(session);
        defer if (queue_summary_prefix) |value| self.allocator.free(value);
        var effective_content = content;
        var effective_content_owned: ?[]u8 = null;
        defer if (effective_content_owned) |value| self.allocator.free(value);
        if (queue_summary_prefix) |prefix| {
            const merged = try std.fmt.allocPrint(
                self.allocator,
                "{s}\n\nLatest user message:\n{s}",
                .{ prefix, content },
            );
            effective_content_owned = merged;
            effective_content = merged;
        }

        tools_mod.setMessageTurnContext(options.message_turn_context);
        defer tools_mod.clearMessageTurnContext();
        tools_mod.setTurnContext(.{
            .origin = options.turn_origin,
            .session_key = session_key,
            .provider = session.agent.default_provider,
            .model = session.agent.model_name,
        });
        defer tools_mod.clearTurnContext();

        if (activationBlockedMessage(session, options.message_turn_context)) |blocked_msg| {
            session.last_active = std.time.timestamp();
            return try self.allocator.dupe(u8, blocked_msg);
        }

        var effective_conversation_context = conversation_context;
        if (conversation_context != null or idle_gap_secs >= SESSION_IDLE_CONTEXT_THRESHOLD_SECS) {
            var enriched = conversation_context orelse ConversationContext{};
            enriched.last_interaction_unix_s = previous_last_active;
            enriched.idle_gap_secs = idle_gap_secs;
            effective_conversation_context = enriched;
        }

        // Set conversation context for this turn.
        session.agent.conversation_context = effective_conversation_context;
        defer session.agent.conversation_context = null;

        const base_observer = session.agent.observer;
        var progress_attached = false;
        if (options.progress_observer) |progress_observer| {
            session.turn_observers = .{ base_observer, progress_observer };
            session.turn_observer_multi.observers = session.turn_observers[0..];
            session.agent.observer = session.turn_observer_multi.observer();
            progress_attached = true;
        }
        defer if (progress_attached) {
            session.agent.observer = base_observer;
            session.turn_observer_multi.observers = &.{};
        };

        // Wire stream callback for live SSE delivery (T-02.1-04: scoped to single turn)
        var stream_attached = false;
        if (options.stream_callback) |cb| {
            session.agent.stream_callback = cb;
            session.agent.stream_ctx = options.stream_ctx;
            stream_attached = true;
        }
        defer if (stream_attached) {
            session.agent.stream_callback = null;
            session.agent.stream_ctx = null;
        };

        if (lock_wait_ms > 0) {
            const lock_wait_event = ObserverEvent{ .turn_stage = .{
                .stage = SESSION_LOCK_WAIT_STAGE,
                .duration_ms = lock_wait_ms,
            } };
            session.agent.observer.recordEvent(&lock_wait_event);
            if (lock_wait_ms >= SESSION_LOCK_WAIT_WARN_MS) {
                log.warn("session.lock_wait session={s} wait_ms={d}", .{ session_key, lock_wait_ms });
            }
        }

        const agent_start_ms = std.time.milliTimestamp();
        // D1.3: call turnOutcome (not the legacy `turn` wrapper) so we
        // capture the structured metadata (tool_calls_executed,
        // spawned_task_ids, iterations_used, loop_detected). Store the
        // outcome on the Session — gateway/BFF read it via
        // `Session.lastTurnOutcome()` to render structured tool-only-turn
        // SSE frames (D1.4) instead of fabricating EMPTY_TURN_PLACEHOLDER.
        // We dupe the text out so the existing return-type contract
        // (caller frees with agent.allocator) is preserved; the outcome
        // itself is owned by the Session and freed on next turn or deinit.
        const outcome = try (&session.agent).turnOutcome(effective_content);
        if (session.last_turn_outcome) |*prev| prev.deinit(session.agent.allocator);
        session.last_turn_outcome = outcome;
        const response = try session.agent.allocator.dupe(u8, outcome.text);
        const agent_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - agent_start_ms));
        session.turn_count += 1;
        session.last_active = std.time.timestamp();

        // Track consolidation timestamp
        if (session.agent.last_turn_compacted) {
            session.last_consolidated = @intCast(@max(0, std.time.timestamp()));
        }

        // Persist messages via session store
        const persist_start_ms = std.time.milliTimestamp();
        if (self.session_store) |store| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (slashClearsSession(trimmed)) {
                // Clear persisted messages on session reset
                store.clearMessages(session_key) catch {};
                // Clear stale auto-saved memories
                store.clearAutoSaved(session_key) catch {};
            } else if (!std.mem.startsWith(u8, trimmed, "/")) {
                // Persist user + assistant messages (skip slash commands).
                // S4.4 — durable-write silent catch closed. `messages` table
                // rows are the cold-tier transcript (cold-memory-auditability
                // directive). Dropping a saveMessage silently means the turn
                // completed but the history it claims to have persisted is
                // incomplete; /history export would under-report.
                store.saveMessage(session_key, "user", content) catch |err|
                    log.warn("session.saveMessage_user_failed session={s} err={s}", .{ session_key, @errorName(err) });
                store.saveMessage(session_key, "assistant", response) catch |err|
                    log.warn("session.saveMessage_assistant_failed session={s} err={s}", .{ session_key, @errorName(err) });
            }
        }
        const persist_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - persist_start_ms));
        const total_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - total_start_ms));
        log.info("message.process session={s} agent_ms={d} persist_ms={d} total_ms={d}", .{
            session_key,
            agent_duration_ms,
            persist_duration_ms,
            total_duration_ms,
        });

        return response;
    }

    pub fn appendAssistantMessage(self: *SessionManager, session_key: []const u8, content: []const u8) !void {
        const session = try self.acquireSessionForTurn(session_key);
        defer self.releaseSessionRef(session);

        session.mutex.lock();
        defer session.mutex.unlock();

        const content_copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_copy);
        try session.agent.history.append(self.allocator, .{
            .role = .assistant,
            .content = content_copy,
        });
        session.agent.enforceHistoryBounds();
        session.last_active = std.time.timestamp();

        if (self.session_store) |store| {
            // S4.5 — durable-write silent catch closed. Second saveMessage
            // site in `appendAssistantMessage`; same rationale as S4.4.
            store.saveMessage(session_key, "assistant", content) catch |err|
                log.warn("session.appendAssistantMessage_failed session={s} err={s}", .{ session_key, @errorName(err) });
        }
    }

    pub fn saveCompletionEvent(
        self: *SessionManager,
        session_key: []const u8,
        channel: ?[]const u8,
        account_id: ?[]const u8,
        chat_id: ?[]const u8,
        content: []const u8,
    ) !?[]u8 {
        const store = self.session_store orelse return null;
        return try store.saveCompletionEvent(self.allocator, session_key, channel, account_id, chat_id, content);
    }

    pub fn loadCompletionEvents(self: *SessionManager, session_key: []const u8) ![]memory_mod.CompletionEvent {
        const store = self.session_store orelse return self.allocator.alloc(memory_mod.CompletionEvent, 0);
        return try store.loadCompletionEvents(self.allocator, session_key);
    }

    pub fn deleteCompletionEvent(self: *SessionManager, event_id: []const u8) !void {
        if (self.session_store) |store| {
            try store.deleteCompletionEvent(event_id);
        }
    }

    pub fn captureOriginSnapshot(self: *SessionManager, session_key: []const u8) !OriginSnapshot {
        const session = try self.getOrCreate(session_key);
        session.mutex.lock();
        defer session.mutex.unlock();

        return .{
            .channel = if (session.origin_channel) |value| try self.allocator.dupe(u8, value) else null,
            .account_id = if (session.origin_account_id) |value| try self.allocator.dupe(u8, value) else null,
            .chat_id = if (session.origin_chat_id) |value| try self.allocator.dupe(u8, value) else null,
        };
    }

    /// Number of active sessions.
    pub fn sessionCount(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }

    /// Evict sessions idle longer than max_idle_secs. Returns number evicted.
    /// CR WR-03: Three-phase eviction to avoid holding manager mutex during blocking I/O.
    /// Phase 1: collect candidates (manager mutex held, fast).
    /// Phase 2: checkpoint each candidate (no manager mutex, may do LLM calls).
    /// Phase 3: remove from map (manager mutex held, fast).
    pub fn evictIdle(self: *SessionManager, max_idle_secs: u64) usize {
        const now = std.time.timestamp();

        // Phase 1: Collect candidate sessions while holding manager mutex (fast scan only).
        var candidates: std.ArrayListUnmanaged(*Session) = .{};
        defer candidates.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            var it = self.sessions.iterator();
            while (it.next()) |entry| {
                const session = entry.value_ptr.*;
                if (session.active_refs != 0) continue;
                if (!session.mutex.tryLock()) continue;
                // Check idle/TTL while holding session mutex
                const idle_secs: u64 = @intCast(@max(0, now - session.last_active));
                if (idle_secs > max_idle_secs or sessionIsTtlExpired(session, now)) {
                    // Keep session mutex locked — we'll checkpoint in Phase 2
                    candidates.append(self.allocator, session) catch {
                        session.mutex.unlock();
                        continue;
                    };
                } else {
                    session.mutex.unlock();
                }
            }
        }

        // Phase 2: Checkpoint each candidate (no manager mutex held — safe for blocking I/O).
        var to_remove: std.ArrayListUnmanaged([]const u8) = .{};
        defer to_remove.deinit(self.allocator);

        for (candidates.items) |session| {
            defer session.mutex.unlock();
            syncSessionOriginToAgent(session);
            if (sessionIsTtlExpired(session, now)) {
                session.agent.persistSessionCheckpoint("ttl_evict");
            } else {
                session.agent.persistSessionCheckpoint("idle_evict");
            }
            to_remove.append(self.allocator, session.session_key) catch continue;
        }

        // Phase 3: Remove from map (manager mutex held, fast).
        var evicted: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (to_remove.items) |key| {
                if (self.sessions.fetchRemove(key)) |kv| {
                    const session = kv.value;
                    session.deinit(self.allocator);
                    self.allocator.destroy(session);
                    evicted += 1;
                }
            }
        }

        return evicted;
    }

    /// Snapshot of a session for listing/API purposes (no mutex held on return).
    pub const SessionInfo = struct {
        session_key: []const u8,
        created_at: i64,
        last_active: i64,
        turn_count: u64,
    };

    /// Count sessions belonging to `user_id`. Thread-safe.
    pub fn countUserSessions(self: *SessionManager, user_id: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session_identity = @import("session/identity.zig");
        var count: usize = 0;
        var it = self.sessions.keyIterator();
        while (it.next()) |key_ptr| {
            if (session_identity.isOwnedBy(key_ptr.*, user_id)) {
                count += 1;
            }
        }
        return count;
    }

    /// Return a heap-allocated slice of SessionInfo for sessions owned by
    /// `user_id`. Caller owns all memory: free each `.session_key` then
    /// `allocator.free(result)`. Thread-safe.
    /// Only returns sessions matching the requesting user_id (T-03-07).
    /// WR-01 fix: session_key is duped so callers are safe after mutex release.
    pub fn listUserSessions(
        self: *SessionManager,
        allocator: std.mem.Allocator,
        user_id: []const u8,
    ) ![]SessionInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session_identity = @import("session/identity.zig");
        var result: std.ArrayListUnmanaged(SessionInfo) = .empty;
        errdefer {
            // Free any already-duped keys on error.
            for (result.items) |info| allocator.free(info.session_key);
            result.deinit(allocator);
        }
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (session_identity.isOwnedBy(entry.key_ptr.*, user_id)) {
                try result.append(allocator, .{
                    .session_key = try allocator.dupe(u8, entry.key_ptr.*),
                    .created_at = entry.value_ptr.*.created_at,
                    .last_active = entry.value_ptr.*.last_active,
                    .turn_count = entry.value_ptr.*.turn_count,
                });
            }
        }
        return try result.toOwnedSlice(allocator);
    }

    /// S7.3 — Per-user session cache eviction for GDPR purge.
    ///
    /// Mirrors the 3-phase pattern in `evictIdle` (collect → destroy →
    /// remove) but filters by `user_id` and ignores idle/TTL state.
    /// Sessions whose `mutex` is locked (turn in progress) or whose
    /// `active_refs != 0` are counted in `active_skipped` and left in
    /// the map — the orchestrator's caller should retry after the
    /// in-flight turn settles, or accept the skip if the corresponding
    /// user row has already been deleted (the next turn will error
    /// naturally). Checkpointing is skipped on purpose: we're about to
    /// delete every trace of this user, so persisting state to the
    /// tenant store would immediately be undone.
    pub const EvictUserResult = struct {
        evicted: usize,
        active_skipped: usize,
    };

    pub fn evictUserSessions(self: *SessionManager, user_id: []const u8) EvictUserResult {
        const session_identity = @import("session/identity.zig");

        // Phase 1: collect owned sessions whose mutex we can take.
        var candidates: std.ArrayListUnmanaged(*Session) = .{};
        defer candidates.deinit(self.allocator);
        var active_skipped: usize = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            var it = self.sessions.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!session_identity.isOwnedBy(key, user_id)) continue;
                const session = entry.value_ptr.*;
                if (session.active_refs != 0) {
                    active_skipped += 1;
                    continue;
                }
                if (!session.mutex.tryLock()) {
                    active_skipped += 1;
                    continue;
                }
                candidates.append(self.allocator, session) catch {
                    session.mutex.unlock();
                    continue;
                };
            }
        }

        // Phase 2: release session mutexes before Phase 3 acquires the
        // manager mutex (avoids any risk of lock-order inversion).
        // No checkpoint here: the tenant row is about to be deleted.
        var to_remove: std.ArrayListUnmanaged([]const u8) = .{};
        defer to_remove.deinit(self.allocator);
        for (candidates.items) |session| {
            to_remove.append(self.allocator, session.session_key) catch {
                session.mutex.unlock();
                continue;
            };
            session.mutex.unlock();
        }

        // Phase 3: drop from map and free.
        //
        // Sprint 7B post-review fix (M1, 2026-04-25): between Phase 2
        // unlocking session.mutex and Phase 3 acquiring manager.mutex,
        // a racing `getOrCreate` can take the manager mutex first, find
        // the session still in the map, and bump `active_refs`. Without
        // a re-check here, Phase 3 would `fetchRemove` + `deinit` a
        // session that another thread holds a live pointer into → UAF.
        //
        // The recheck is cheap (one field load under the manager mutex)
        // and lets the racing turn proceed naturally: the session stays
        // in the map until the turn's normal idle eviction. It's fine
        // for GDPR semantics — the pg cascade running next will yank
        // the user's rows out from under that turn, which will then
        // error cleanly on its next memory write. Better one half-
        // completed turn than a UAF.
        var evicted: usize = 0;
        var raced_skipped: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (to_remove.items) |key| {
                if (self.sessions.fetchRemove(key)) |kv| {
                    const session = kv.value;
                    if (session.active_refs != 0) {
                        // A racer entered between Phase 2 and Phase 3.
                        // Re-insert and skip — caller can retry.
                        self.sessions.put(self.allocator, session.session_key, session) catch {
                            // Re-insert failed (OOM). The pointer is
                            // now leaked from the map but still alive;
                            // a later `evictIdle` or shutdown flush
                            // will clean it up. Worse than a clean
                            // re-insert, but vastly better than UAF.
                            log.warn("session.evict_user_phase3_reinsert_failed user_id={s} key={s}", .{ user_id, key });
                        };
                        raced_skipped += 1;
                        continue;
                    }
                    session.deinit(self.allocator);
                    self.allocator.destroy(session);
                    evicted += 1;
                }
            }
        }
        const total_skipped = active_skipped + raced_skipped;
        if (total_skipped > 0) {
            log.warn("session.evict_user_skipped user_id={s} evicted={d} active_skipped={d} raced_skipped={d}", .{ user_id, evicted, active_skipped, raced_skipped });
        }
        return .{ .evicted = evicted, .active_skipped = total_skipped };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;
var test_noop_observer_impl = observability.NoopObserver{};

// ---------------------------------------------------------------------------
// MockProvider — returns a fixed response, no network calls
// ---------------------------------------------------------------------------

const MockProvider = struct {
    response: []const u8,

    const structured_summary_response =
        \\focus: current session continuity
        \\decisions:
        \\- none
        \\open_loops:
        \\- none
        \\next:
        \\- continue
        \\Key fact: session continuity preserved
    ;

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
    };

    fn provider(self: *MockProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        allocator: Allocator,
        _: ?[]const u8,
        system_prompt: []const u8,
        user_prompt: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        const payload = if (isSummaryRequest(system_prompt, user_prompt)) structured_summary_response else self.response;
        return allocator.dupe(u8, payload);
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        request: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        const payload = if (chatRequestIsSummary(request)) structured_summary_response else self.response;
        return .{ .content = try allocator.dupe(u8, payload) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn isSummaryRequest(system_prompt: []const u8, user_prompt: []const u8) bool {
        return std.mem.indexOf(u8, system_prompt, "compact continuity object") != null or
            std.mem.indexOf(u8, user_prompt, "--- BEGIN CONVERSATION ---") != null;
    }

    fn chatRequestIsSummary(request: providers.ChatRequest) bool {
        for (request.messages) |message| {
            if (std.mem.indexOf(u8, message.content, "compact continuity object") != null) return true;
            if (std.mem.indexOf(u8, message.content, "--- BEGIN CONVERSATION ---") != null) return true;
        }
        return false;
    }

    fn mockDeinit(_: *anyopaque) void {}
};

const CountingObserver = struct {
    event_count: u32 = 0,
    saw_turn_stage: bool = false,

    const vtable = Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
    };

    fn observer(self: *CountingObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *CountingObserver {
        return @ptrCast(@alignCast(ptr));
    }

    fn recordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self = resolve(ptr);
        self.event_count += 1;
        switch (event.*) {
            .turn_stage => self.saw_turn_stage = true,
            else => {},
        }
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "counting";
    }
};

/// Create a test SessionManager with mock provider.
fn testSessionManager(allocator: Allocator, mock: *MockProvider, cfg: *const Config) SessionManager {
    return testSessionManagerWithMemory(allocator, mock, cfg, null, null);
}

fn testSessionManagerWithMemory(allocator: Allocator, mock: *MockProvider, cfg: *const Config, mem: ?Memory, session_store: ?memory_mod.SessionStore) SessionManager {
    return SessionManager.init(
        allocator,
        cfg,
        mock.provider(),
        &.{},
        mem,
        test_noop_observer_impl.observer(),
        session_store,
        null,
    );
}

fn testConfig() Config {
    return .{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .allocator = testing.allocator,
    };
}

// ---------------------------------------------------------------------------
// 1. Struct tests
// ---------------------------------------------------------------------------

test "SessionManager init/deinit — no leaks" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    sm.deinit();
}

test "getOrCreate creates new session for unknown key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("telegram:chat1");
    try testing.expect(session.turn_count == 0);
    try testing.expectEqualStrings("telegram:chat1", session.session_key);
}

test "getOrCreate returns same session for same key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("key1");
    const s2 = try sm.getOrCreate("key1");
    try testing.expect(s1 == s2); // pointer equality
}

test "getOrCreate creates separate sessions for different keys" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("telegram:a");
    const s2 = try sm.getOrCreate("discord:b");
    try testing.expect(s1 != s2);
}

test "sessionCount reflects active sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
    _ = try sm.getOrCreate("a");
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
    _ = try sm.getOrCreate("b");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
    _ = try sm.getOrCreate("a"); // existing
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

test "session has correct initial state" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:init");
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(!s.agent.has_system_prompt);
    try testing.expectEqual(@as(usize, 0), s.agent.historyLen());
}

// ---------------------------------------------------------------------------
// 2. processMessage tests
// ---------------------------------------------------------------------------

test "processMessage returns mock response" {
    var mock = MockProvider{ .response = "Hello from mock" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp = try sm.processMessage("user:1", "hi", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("Hello from mock", resp);
}

test "processMessage refreshes system prompt when conversation context is cleared" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const sender_uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    const with_context: ?ConversationContext = .{
        .channel = "signal",
        .sender_number = "+15551234567",
        .sender_uuid = sender_uuid,
        .group_id = null,
        .is_group = false,
    };

    const resp1 = try sm.processMessage("ctx:user", "first", with_context);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("ctx:user");
    try testing.expect(session.agent.history.items.len > 0);
    const sys1 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys1, "## Conversation Context") != null);
    try testing.expect(std.mem.indexOf(u8, sys1, sender_uuid) != null);

    const resp2 = try sm.processMessage("ctx:user", "second", null);
    defer testing.allocator.free(resp2);

    try testing.expect(session.agent.history.items.len > 0);
    const sys2 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys2, "## Conversation Context") == null);
    try testing.expect(std.mem.indexOf(u8, sys2, sender_uuid) == null);
}

test "processMessage injects meaningful idle gap into conversation context" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("ctx:idle");
    session.last_active = std.time.timestamp() - (2 * 60 * 60);

    const resp = try sm.processMessage("ctx:idle", "hello again", null);
    defer testing.allocator.free(resp);

    try testing.expect(session.agent.history.items.len > 0);
    const sys = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys, "## Conversation Context") != null);
    try testing.expect(std.mem.indexOf(u8, sys, "Last interaction in this session:") != null);
    try testing.expect(std.mem.indexOf(u8, sys, "Idle gap before this turn: about 2 hours") != null);
}

test "processMessage updates last_active" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("user:2");
    const before = session.last_active;

    // Small sleep so timestamp changes
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const resp = try sm.processMessage("user:2", "hello", null);
    defer testing.allocator.free(resp);

    try testing.expect(session.last_active >= before);
}

test "processMessage increments turn_count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("user:3", "msg1", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("user:3");
    try testing.expectEqual(@as(u64, 1), session.turn_count);

    const resp2 = try sm.processMessage("user:3", "msg2", null);
    defer testing.allocator.free(resp2);
    try testing.expectEqual(@as(u64, 2), session.turn_count);
}

test "processMessage preserves session across calls" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("persist:1", "first", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("persist:1");
    // After first processMessage: system prompt + user msg + assistant response
    try testing.expect(session.agent.historyLen() > 0);

    const history_before = session.agent.historyLen();

    const resp2 = try sm.processMessage("persist:1", "second", null);
    defer testing.allocator.free(resp2);

    // History should have grown (user msg + assistant response added)
    try testing.expect(session.agent.historyLen() > history_before);
}

test "processMessage different keys — independent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp_a = try sm.processMessage("user:a", "hello a", null);
    defer testing.allocator.free(resp_a);

    const resp_b = try sm.processMessage("user:b", "hello b", null);
    defer testing.allocator.free(resp_b);

    const sa = try sm.getOrCreate("user:a");
    const sb = try sm.getOrCreate("user:b");
    try testing.expect(sa != sb);
    try testing.expectEqual(@as(u64, 1), sa.turn_count);
    try testing.expectEqual(@as(u64, 1), sb.turn_count);
}

test "processMessageWithContext forwards progress observer and restores base observer" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    var progress = CountingObserver{};
    const response = try sm.processMessageWithContext("progress:1", "hello", null, .{
        .progress_observer = progress.observer(),
    });
    defer testing.allocator.free(response);

    try testing.expect(progress.event_count > 0);
    try testing.expect(progress.saw_turn_stage);

    const session = try sm.getOrCreate("progress:1");
    try testing.expectEqualStrings("noop", session.agent.observer.getName());
}

test "evictIdle skips session with active ref before turn lock" {
    const allocator = std.testing.allocator;
    var provider = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = SessionManager.init(
        allocator,
        &cfg,
        provider.provider(),
        &.{},
        null,
        test_noop_observer_impl.observer(),
        null,
        null,
    );
    defer sm.deinit();

    const session = try sm.acquireSessionForTurn("race:1");
    try std.testing.expectEqual(@as(usize, 1), sm.sessionCount());
    try std.testing.expectEqual(@as(usize, 1), session.active_refs);

    const evicted = sm.evictIdle(0);
    try std.testing.expectEqual(@as(usize, 0), evicted);
    try std.testing.expectEqual(@as(usize, 1), sm.sessionCount());
    try std.testing.expectEqual(@as(usize, 1), session.active_refs);

    sm.releaseSessionRef(session);
    try std.testing.expectEqual(@as(usize, 0), session.active_refs);
}

test "agent turn emits observer events with counting observer" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("progress:direct");
    var progress = CountingObserver{};
    session.agent.observer = progress.observer();

    const response = try session.agent.turn("hello");
    defer testing.allocator.free(response);

    try testing.expect(progress.event_count > 0);
    try testing.expect(progress.saw_turn_stage);
}

test "processMessage /new clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    // Seed autosave entries for two different sessions.
    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /new with model clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new gpt-4o-mini", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /reset clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/reset", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /restart clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/restart", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage with sqlite memory first turn does not panic" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const resp = try sm.processMessage("signal:session:1", "hello", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("ok", resp);

    const entries = try sqlite_mem.loadMessages(testing.allocator, "signal:session:1");
    defer {
        for (entries) |entry| {
            testing.allocator.free(entry.role);
            testing.allocator.free(entry.content);
        }
        testing.allocator.free(entries);
    }
    // One user + one assistant message should be persisted.
    try testing.expect(entries.len >= 2);
}

test "session restore enforces max history bound before first turn" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.agent.max_history_messages = 5;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var idx: usize = 0;
    while (idx < 12) : (idx += 1) {
        const role = if ((idx % 2) == 0) "user" else "assistant";
        const msg = try std.fmt.allocPrint(testing.allocator, "message-{d}", .{idx});
        defer testing.allocator.free(msg);
        try store.saveMessage("restore:trim", role, msg);
    }

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, sqlite_mem.memory(), store);
    defer sm.deinit();

    const session = try sm.getOrCreate("restore:trim");
    try testing.expectEqual(@as(usize, 5), session.agent.historyLen());
    const last = session.agent.history.items[session.agent.history.items.len - 1].content;
    try testing.expectEqualStrings("message-11", last);
}

test "appendAssistantMessage adds completion to live session history" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try sm.appendAssistantMessage("append:live", "[Subagent 'research'] completed");

    const session = try sm.getOrCreate("append:live");
    try testing.expectEqual(@as(usize, 1), session.agent.historyLen());
    try testing.expect(session.agent.history.items[0].role == .assistant);
    try testing.expectEqualStrings("[Subagent 'research'] completed", session.agent.history.items[0].content);
}

test "appendAssistantMessage persists completion to session store" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, sqlite_mem.memory(), store);
    defer sm.deinit();

    try sm.appendAssistantMessage("append:store", "[Subagent 'research'] completed");

    const entries = try store.loadMessages(testing.allocator, "append:store");
    defer {
        for (entries) |entry| {
            testing.allocator.free(entry.role);
            testing.allocator.free(entry.content);
        }
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("assistant", entries[0].role);
    try testing.expectEqualStrings("[Subagent 'research'] completed", entries[0].content);
}

test "completion events roundtrip through session store" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, sqlite_mem.memory(), store);
    defer sm.deinit();

    const event_id = (try sm.saveCompletionEvent(
        "completion:store",
        "zaki_app",
        null,
        "completion:store",
        "[Subagent 'research'] completed",
    )).?;
    defer testing.allocator.free(event_id);

    const events = try sm.loadCompletionEvents("completion:store");
    defer memory_mod.freeCompletionEvents(testing.allocator, events);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings(event_id, events[0].id);
    try testing.expectEqualStrings("completion:store", events[0].session_id);
    try testing.expectEqualStrings("zaki_app", events[0].channel.?);
    try testing.expectEqualStrings("[Subagent 'research'] completed", events[0].content);

    try sm.deleteCompletionEvent(event_id);

    const remaining = try sm.loadCompletionEvents("completion:store");
    defer memory_mod.freeCompletionEvents(testing.allocator, remaining);
    try testing.expectEqual(@as(usize, 0), remaining.len);
}

test "captureOriginSnapshot returns stored session routing metadata" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("origin:snapshot");
    session.origin_channel = try testing.allocator.dupe(u8, "telegram");
    session.origin_account_id = try testing.allocator.dupe(u8, "main");
    session.origin_chat_id = try testing.allocator.dupe(u8, "12345");

    var snapshot = try sm.captureOriginSnapshot("origin:snapshot");
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqualStrings("telegram", snapshot.channel.?);
    try testing.expectEqualStrings("main", snapshot.account_id.?);
    try testing.expectEqualStrings("12345", snapshot.chat_id.?);
}

// ---------------------------------------------------------------------------
// 3. evictIdle tests
// ---------------------------------------------------------------------------

test "evictIdle removes old sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("old:1");
    // Force last_active to the past
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(500);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "evictIdle persists checkpoint before removing idle session" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const first_reply = try sm.processMessage("evict:checkpoint", "hello", null);
    defer testing.allocator.free(first_reply);
    try testing.expectEqualStrings("ok", first_reply);

    const session = try sm.getOrCreate("evict:checkpoint");
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(120);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());

    const daily_entries = try mem.list(testing.allocator, .daily, null);
    defer memory_mod.freeEntries(testing.allocator, daily_entries);

    var found_checkpoint = false;
    for (daily_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "session_checkpoint_")) continue;
        if (std.mem.indexOf(u8, entry.content, "reason=idle_evict") == null) continue;
        if (std.mem.indexOf(u8, entry.content, "session=evict:checkpoint") == null) continue;
        found_checkpoint = true;
        break;
    }
    try testing.expect(found_checkpoint);

    const anchor = (try mem.get(testing.allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=idle_evict") != null);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_channel=evict") != null);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_lane=unknown") != null);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_summary_key=timeline_summary/evict:checkpoint/") != null);

    const latest = (try mem.get(testing.allocator, "summary_latest/evict:checkpoint")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "channel=evict") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "lane=unknown") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "focus:") != null);

    const timeline_index = (try mem.get(testing.allocator, "timeline_index/current")) orelse return error.TestUnexpectedResult;
    defer timeline_index.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"channel\":\"evict\"") != null);
    try testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"lane\":\"unknown\"") != null);
    try testing.expect(std.mem.indexOf(u8, timeline_index.content, "\"session\":\"evict:checkpoint\"") != null);
}

test "flushSessionsForShutdown persists continuity for active sessions" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const first_reply = try sm.processMessage("shutdown:checkpoint", "hello", null);
    defer testing.allocator.free(first_reply);
    try testing.expectEqualStrings("ok", first_reply);

    const flushed = sm.flushSessionsForShutdown("shutdown");
    try testing.expectEqual(@as(usize, 1), flushed);

    const anchor = (try mem.get(testing.allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=shutdown") != null);

    const latest = (try mem.get(testing.allocator, "summary_latest/shutdown:checkpoint")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "session=shutdown:checkpoint") != null);
}

test "evictIdle preserves recent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("recent:1");
    // This session was just created, last_active is now

    const evicted = sm.evictIdle(3600); // 1 hour threshold
    try testing.expectEqual(@as(usize, 0), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle returns correct count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create 3 sessions, make 2 old
    const s1 = try sm.getOrCreate("s1");
    const s2 = try sm.getOrCreate("s2");
    _ = try sm.getOrCreate("s3");

    s1.last_active = std.time.timestamp() - 2000;
    s2.last_active = std.time.timestamp() - 2000;
    // s3 stays recent

    const evicted = sm.evictIdle(1000);
    try testing.expectEqual(@as(usize, 2), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle with no sessions returns 0" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.evictIdle(60));
}

// ---------------------------------------------------------------------------
// 4. Thread safety tests
// ---------------------------------------------------------------------------

test "concurrent getOrCreate same key — single Session created" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;

    for (0..num_threads) |t| {
        // V1.8-14: bumped 64K → 256K for Linux CI. Linux pthread strictly
        // honors the hint; macOS rounds up to a page-aligned minimum
        // (≥512K). buildSessionAgent recurses into agent init paths that
        // exceed 64K on Linux, causing SIGSEGV. Test contract is "no
        // crash under concurrency" — minimum viable stack is an
        // implementation detail. 256K matches the next concurrent test
        // in this file (`processMessage different keys`).
        handles[t] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
            fn run(mgr: *SessionManager, out: **Session) void {
                out.* = mgr.getOrCreate("shared:key") catch unreachable;
            }
        }.run, .{ &sm, &sessions[t] });
    }

    for (handles) |h| h.join();

    // All threads should have gotten the same session pointer
    for (1..num_threads) |i| {
        try testing.expect(sessions[0] == sessions[i]);
    }
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "concurrent getOrCreate different keys — separate Sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "key:{d}", .{t}) catch "?";
        // V1.8-14: 256K stack hint — same rationale as the same-key test
        // above.
        handles[t] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, out: **Session) void {
                out.* = mgr.getOrCreate(key) catch unreachable;
            }
        }.run, .{ &sm, keys[t], &sessions[t] });
    }

    for (handles) |h| h.join();

    // All sessions should be distinct
    for (0..num_threads) |i| {
        for (i + 1..num_threads) |j| {
            try testing.expect(sessions[i] != sessions[j]);
        }
    }
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage different keys — no crash" {
    var mock = MockProvider{ .response = "concurrent ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "conc:{d}", .{t}) catch "?";
        // V1.8-14: 1 MiB stack hint. processMessage runs the full turn
        // pipeline (memory recall, prompt build, mock provider, history
        // persist) which exceeds 256 KiB on Linux pthread (strict hint
        // honor). macOS rounds up to ≥512 KiB so it masks the bug.
        // Matches the sqlite variant below.
        handles[t] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator) void {
                for (0..3) |_| {
                    const resp = mgr.processMessage(key, "hello", null) catch return;
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator });
    }

    for (handles) |h| h.join();
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage with sqlite memory does not panic" {
    var mock = MockProvider{ .response = "concurrent sqlite ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][24]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;
    var failed = std.atomic.Value(bool).init(false);

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "sqlite-conc:{d}", .{t}) catch "?";
        // SQLite+FTS parsing can exceed 256 KiB stack on some macOS test runs.
        // Use a larger stack here to keep this concurrency regression deterministic.
        handles[t] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator, failed_flag: *std.atomic.Value(bool)) void {
                for (0..5) |_| {
                    const resp = mgr.processMessage(key, "hello sqlite", null) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator, &failed });
    }

    for (handles) |h| h.join();
    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());

    const count = try mem.count();
    try testing.expect(count > 0);
}

test "postgres session restore under concurrent getOrCreate same and mixed keys does not panic" {
    if (!build_options.enable_postgres) return error.SkipZigTest;

    const test_url = (env_rebrand.getEnvOwnedWithRebrand(testing.allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer testing.allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_session_restore_{d}", .{std.time.microTimestamp()});
    const state_cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var state_mgr = try zaki_state_mod.Manager.init(testing.allocator, state_cfg);
    defer state_mgr.deinit();
    try state_mgr.provisionUser(2, "/tmp/nullalis-zaki-bot-test-user-2/workspace");

    var seed_store = try zaki_state_mod.Manager.UserSessionStore.init(testing.allocator, &state_mgr, 2);
    defer seed_store.deinit();
    const seed_session_store = seed_store.sessionStore();

    try seed_session_store.saveMessage("agent:zaki-bot:user:2:main", "user", "seed user");
    try seed_session_store.saveMessage("agent:zaki-bot:user:2:main", "assistant", "");
    try seed_session_store.saveMessage("agent:zaki-bot:user:2:main", "assistant", "seed assistant");

    const mixed_keys = 24;
    for (0..mixed_keys) |idx| {
        var key_buf: [96]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "agent:zaki-bot:user:2:thread:load-{d}", .{idx});
        try seed_session_store.saveMessage(key, "user", "seed mixed user");
        try seed_session_store.saveMessage(key, "assistant", "");
        try seed_session_store.saveMessage(key, "assistant", "seed mixed assistant");
    }

    const num_managers = 4;
    var mocks: [num_managers]MockProvider = undefined;
    var stores: [num_managers]zaki_state_mod.Manager.UserSessionStore = undefined;
    var managers: [num_managers]SessionManager = undefined;
    defer {
        for (&managers) |*sm| sm.deinit();
        for (&stores) |*store| store.deinit();
    }

    const cfg = testConfig();
    for (0..num_managers) |idx| {
        mocks[idx] = .{ .response = "ok" };
        stores[idx] = try zaki_state_mod.Manager.UserSessionStore.init(testing.allocator, &state_mgr, 2);
        managers[idx] = SessionManager.init(
            testing.allocator,
            &cfg,
            mocks[idx].provider(),
            &.{},
            null,
            test_noop_observer_impl.observer(),
            stores[idx].sessionStore(),
            null,
        );
    }

    const iterations = 40;
    var failed = std.atomic.Value(bool).init(false);
    var handles: [num_managers]std.Thread = undefined;
    for (0..num_managers) |idx| {
        handles[idx] = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, struct {
            fn run(
                mgr: *SessionManager,
                manager_index: usize,
                mixed_count: usize,
                rounds: usize,
                failed_flag: *std.atomic.Value(bool),
            ) void {
                for (0..rounds) |iter| {
                    _ = mgr.getOrCreate("agent:zaki-bot:user:2:main") catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    const mixed_slot = (manager_index * rounds + iter) % mixed_count;
                    var key_buf: [96]u8 = undefined;
                    const mixed_key = std.fmt.bufPrint(&key_buf, "agent:zaki-bot:user:2:thread:load-{d}", .{mixed_slot}) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    _ = mgr.getOrCreate(mixed_key) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                }
            }
        }.run, .{ &managers[idx], idx, mixed_keys, iterations, &failed });
    }
    for (handles) |handle| handle.join();

    try testing.expect(!failed.load(.acquire));
    for (&managers) |*sm| {
        try testing.expect(sm.sessionCount() >= 2);
    }
}

test "ttl_expired_session_recycles_in_place_under_lock" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const first = try sm.getOrCreate("ttl:1");
    first.agent.session_ttl_secs = 1;
    first.last_active = std.time.timestamp() - 5;
    first.turn_count = 99;
    try first.agent.history.append(testing.allocator, .{
        .role = .user,
        .content = try testing.allocator.dupe(u8, "stale"),
    });

    const reply = try sm.processMessage("ttl:1", "fresh", null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);

    const second = try sm.getOrCreate("ttl:1");
    try testing.expect(first == second);
    try testing.expectEqual(@as(u64, 1), second.turn_count);
    try testing.expect(second.agent.historyLen() <= 3);
}

test "ttl recycle persists session checkpoint before replacement" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const warmup = try sm.processMessage("ttl:checkpoint", "before", null);
    defer testing.allocator.free(warmup);

    const first = try sm.getOrCreate("ttl:checkpoint");
    first.agent.session_ttl_secs = 1;
    first.last_active = std.time.timestamp() - 60;

    const reply = try sm.processMessage("ttl:checkpoint", "after", null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);

    const daily_entries = try mem.list(testing.allocator, .daily, null);
    defer memory_mod.freeEntries(testing.allocator, daily_entries);

    var found_checkpoint = false;
    for (daily_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "session_checkpoint_")) continue;
        if (std.mem.indexOf(u8, entry.content, "reason=ttl_recycle") == null) continue;
        if (std.mem.indexOf(u8, entry.content, "session=ttl:checkpoint") == null) continue;
        found_checkpoint = true;
        break;
    }
    try testing.expect(found_checkpoint);

    const anchor = (try mem.get(testing.allocator, "context_anchor_current")) orelse return error.TestUnexpectedResult;
    defer anchor.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_reason=ttl_recycle") != null);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_channel=ttl") != null);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_lane=unknown") != null);
    try testing.expect(std.mem.indexOf(u8, anchor.content, "last_summary_key=timeline_summary/ttl:checkpoint/") != null);

    const latest = (try mem.get(testing.allocator, "summary_latest/ttl:checkpoint")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "channel=ttl") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "lane=unknown") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "focus:") != null);
}

test "ttl recycle persists summary objects in fast mode" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    user_settings.applySettingsToConfig(&cfg, .{
        .assistant_mode = .fast,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
    });

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const warmup = try sm.processMessage("ttl:fast", "before", null);
    defer testing.allocator.free(warmup);

    const first = try sm.getOrCreate("ttl:fast");
    first.agent.session_ttl_secs = 1;
    first.last_active = std.time.timestamp() - 60;

    const reply = try sm.processMessage("ttl:fast", "after", null);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);

    const latest = (try mem.get(testing.allocator, "summary_latest/ttl:fast")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "type=summary_latest") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "focus:") != null);
}

test "processMessageWithToolContext stores session origin snapshot" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const reply = try sm.processMessageWithToolContext("agent:zaki-bot:user:1:thread:telegram:thread:1110331014", "hello", null, .{
        .channel = "telegram",
        .account_id = "main",
        .chat_id = "1110331014",
    });
    defer testing.allocator.free(reply);

    const session = try sm.getOrCreate("agent:zaki-bot:user:1:thread:telegram:thread:1110331014");
    try testing.expectEqualStrings("telegram", session.origin_channel.?);
    try testing.expectEqualStrings("thread", session.origin_lane.?);
    try testing.expectEqualStrings("1110331014", session.origin_chat_id.?);
    try testing.expectEqualStrings("main", session.origin_account_id.?);
}

test "ttl recycle keeps stored telegram origin on summary writes" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const warmup = try sm.processMessageWithToolContext("agent:zaki-bot:user:1:thread:telegram:thread:1110331014", "before", null, .{
        .channel = "telegram",
        .account_id = "main",
        .chat_id = "1110331014",
    });
    defer testing.allocator.free(warmup);

    const session = try sm.getOrCreate("agent:zaki-bot:user:1:thread:telegram:thread:1110331014");
    session.agent.session_ttl_secs = 1;
    session.last_active = std.time.timestamp() - 60;

    const reply = try sm.processMessage("agent:zaki-bot:user:1:thread:telegram:thread:1110331014", "after", null);
    defer testing.allocator.free(reply);

    const latest = (try mem.get(testing.allocator, "summary_latest/agent:zaki-bot:user:1:thread:telegram:thread:1110331014")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_channel=telegram") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_lane=thread") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_chat_id=1110331014") != null);
}

test "evictIdle with expired ttl writes summary objects before removal" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const first_reply = try sm.processMessage("ttl:evict", "hello", null);
    defer testing.allocator.free(first_reply);
    try testing.expectEqualStrings("ok", first_reply);

    const session = try sm.getOrCreate("ttl:evict");
    session.agent.session_ttl_secs = 1;
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(3600);
    try testing.expectEqual(@as(usize, 1), evicted);

    const daily_entries = try mem.list(testing.allocator, .daily, null);
    defer memory_mod.freeEntries(testing.allocator, daily_entries);

    var found_ttl_summary = false;
    for (daily_entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "timeline_summary/ttl:evict/")) continue;
        if (std.mem.indexOf(u8, entry.content, "focus:") == null) continue;
        found_ttl_summary = true;
        break;
    }
    try testing.expect(found_ttl_summary);

    const latest = (try mem.get(testing.allocator, "summary_latest/ttl:evict")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "channel=ttl") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "lane=unknown") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "source_key=timeline_summary/ttl:evict/") != null);
}

test "evictIdle keeps stored telegram origin for idle_evict" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const first_reply = try sm.processMessageWithToolContext("agent:zaki-bot:user:1:thread:telegram:thread:1110331014", "hello", null, .{
        .channel = "telegram",
        .account_id = "main",
        .chat_id = "1110331014",
    });
    defer testing.allocator.free(first_reply);

    const session = try sm.getOrCreate("agent:zaki-bot:user:1:thread:telegram:thread:1110331014");
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(120);
    try testing.expectEqual(@as(usize, 1), evicted);

    const latest = (try mem.get(testing.allocator, "summary_latest/agent:zaki-bot:user:1:thread:telegram:thread:1110331014")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_channel=telegram") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_lane=thread") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_chat_id=1110331014") != null);
}

test "evictIdle keeps stored telegram origin for ttl_evict" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const first_reply = try sm.processMessageWithToolContext("agent:zaki-bot:user:1:thread:telegram:thread:1110331014", "hello", null, .{
        .channel = "telegram",
        .account_id = "main",
        .chat_id = "1110331014",
    });
    defer testing.allocator.free(first_reply);

    const session = try sm.getOrCreate("agent:zaki-bot:user:1:thread:telegram:thread:1110331014");
    session.agent.session_ttl_secs = 1;
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(3600);
    try testing.expectEqual(@as(usize, 1), evicted);

    const latest = (try mem.get(testing.allocator, "summary_latest/agent:zaki-bot:user:1:thread:telegram:thread:1110331014")) orelse return error.TestUnexpectedResult;
    defer latest.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_channel=telegram") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_lane=thread") != null);
    try testing.expect(std.mem.indexOf(u8, latest.content, "origin_chat_id=1110331014") != null);
}

test "activation_mode mention blocks unmentioned group turn" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("activation:mention");
    session.agent.activation_mode = .mention;

    const blocked = try sm.processMessageWithToolContext("activation:mention", "hello", null, .{
        .channel = "telegram",
        .chat_id = "chat",
        .is_group = true,
        .is_dm = false,
        .mentioned = false,
    });
    defer testing.allocator.free(blocked);
    try testing.expectEqualStrings("Mention mode active: mention the bot in group chats to trigger a turn.", blocked);
    try testing.expectEqual(@as(u64, 0), session.turn_count);
}

test "queue_mode latest supersedes older waiting turn" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("queue:latest");
    session.agent.queue_mode = .latest;
    session.agent.queue_cap = 8;
    session.agent.queue_drop = .oldest;

    session.mutex.lock();

    var out_a: ?[]const u8 = null;
    var out_b: ?[]const u8 = null;

    const thread_fn = struct {
        fn run(mgr: *SessionManager, key: []const u8, out: *?[]const u8) void {
            out.* = mgr.processMessage(key, "queued", null) catch null;
        }
    }.run;

    const ta = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, thread_fn, .{ &sm, "queue:latest", &out_a });
    std.Thread.sleep(20 * std.time.ns_per_ms);
    const tb = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, thread_fn, .{ &sm, "queue:latest", &out_b });
    std.Thread.sleep(20 * std.time.ns_per_ms);

    session.mutex.unlock();

    ta.join();
    tb.join();

    defer if (out_a) |v| testing.allocator.free(v);
    defer if (out_b) |v| testing.allocator.free(v);

    try testing.expect(out_a != null);
    try testing.expect(out_b != null);
    const a = out_a.?;
    const b = out_b.?;
    const a_dropped = std.mem.eql(u8, a, QUEUE_LATEST_SUPERSEDED_MESSAGE);
    const b_dropped = std.mem.eql(u8, b, QUEUE_LATEST_SUPERSEDED_MESSAGE);
    try testing.expect(a_dropped != b_dropped);
}

test "queue_cap newest drop rejects overflowing waiter deterministically" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("queue:cap");
    session.agent.queue_mode = .serial;
    session.agent.queue_cap = 1;
    session.agent.queue_drop = .newest;

    session.mutex.lock();

    var out_waiter: ?[]const u8 = null;
    const waiter = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
        fn run(mgr: *SessionManager, out: *?[]const u8) void {
            out.* = mgr.processMessage("queue:cap", "first", null) catch null;
        }
    }.run, .{ &sm, &out_waiter });
    std.Thread.sleep(25 * std.time.ns_per_ms);

    const dropped = try sm.processMessage("queue:cap", "second", null);
    defer testing.allocator.free(dropped);
    try testing.expectEqualStrings(QUEUE_NEWEST_DROP_MESSAGE, dropped);

    session.mutex.unlock();
    waiter.join();
    defer if (out_waiter) |v| testing.allocator.free(v);
    try testing.expect(out_waiter != null);
    try testing.expectEqualStrings("ok", out_waiter.?);
}

test "queue_mode_off_bypasses_queue_cap_and_drop" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("queue:off");
    session.agent.queue_mode = .off;
    session.agent.queue_cap = 1;
    session.agent.queue_drop = .newest;

    session.mutex.lock();

    var out_a: ?[]const u8 = null;
    var out_b: ?[]const u8 = null;
    const worker = struct {
        fn run(mgr: *SessionManager, out: *?[]const u8) void {
            out.* = mgr.processMessage("queue:off", "hello", null) catch null;
        }
    }.run;

    const ta = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, worker, .{ &sm, &out_a });
    std.Thread.sleep(20 * std.time.ns_per_ms);
    const tb = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, worker, .{ &sm, &out_b });
    std.Thread.sleep(20 * std.time.ns_per_ms);
    session.mutex.unlock();

    ta.join();
    tb.join();

    defer if (out_a) |value| testing.allocator.free(value);
    defer if (out_b) |value| testing.allocator.free(value);
    try testing.expect(out_a != null);
    try testing.expect(out_b != null);
    try testing.expectEqualStrings("ok", out_a.?);
    try testing.expectEqualStrings("ok", out_b.?);
}

test "queue_drop_summarize_injects_single_synthetic_summary_on_next_turn" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("queue:summarize");
    session.agent.queue_mode = .serial;
    session.agent.queue_cap = 1;
    session.agent.queue_drop = .summarize;

    session.mutex.lock();
    var waiter_output: ?[]const u8 = null;
    const waiter = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
        fn run(mgr: *SessionManager, out: *?[]const u8) void {
            out.* = mgr.processMessage("queue:summarize", "first", null) catch null;
        }
    }.run, .{ &sm, &waiter_output });
    std.Thread.sleep(25 * std.time.ns_per_ms);

    const dropped = try sm.processMessage("queue:summarize", "second", null);
    defer testing.allocator.free(dropped);
    try testing.expectEqualStrings(QUEUE_SUMMARIZE_DROP_MESSAGE, dropped);
    session.mutex.unlock();

    waiter.join();
    defer if (waiter_output) |value| testing.allocator.free(value);
    try testing.expect(waiter_output != null);
    try testing.expectEqualStrings("ok", waiter_output.?);

    const next_reply = try sm.processMessage("queue:summarize", "third", null);
    defer testing.allocator.free(next_reply);
    try testing.expectEqualStrings("ok", next_reply);

    var saw_summary_prefix = false;
    for (session.agent.history.items) |msg| {
        if (msg.role == .user and std.mem.indexOf(u8, msg.content, "[Queue notice:") != null) {
            saw_summary_prefix = true;
        }
    }
    try testing.expect(saw_summary_prefix);
    try testing.expectEqual(@as(u32, 0), session.queue_summarize_pending_count);
}

test "queue_drop_oldest_still_holds" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("queue:oldest");
    session.agent.queue_mode = .serial;
    session.agent.queue_cap = 1;
    session.agent.queue_drop = .oldest;

    session.mutex.lock();
    var out_a: ?[]const u8 = null;
    var out_b: ?[]const u8 = null;
    const worker = struct {
        fn run(mgr: *SessionManager, out: *?[]const u8) void {
            out.* = mgr.processMessage("queue:oldest", "queued", null) catch null;
        }
    }.run;

    const ta = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, worker, .{ &sm, &out_a });
    std.Thread.sleep(20 * std.time.ns_per_ms);
    const tb = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, worker, .{ &sm, &out_b });
    std.Thread.sleep(20 * std.time.ns_per_ms);
    session.mutex.unlock();

    ta.join();
    tb.join();

    defer if (out_a) |value| testing.allocator.free(value);
    defer if (out_b) |value| testing.allocator.free(value);
    try testing.expect(out_a != null);
    try testing.expect(out_b != null);
    const a_dropped = std.mem.eql(u8, out_a.?, QUEUE_OLDEST_DROPPED_MESSAGE);
    const b_dropped = std.mem.eql(u8, out_b.?, QUEUE_OLDEST_DROPPED_MESSAGE);
    try testing.expect(a_dropped != b_dropped);
}

test "concurrent_waiters_do_not_observe_destroyed_session_on_ttl_expiry" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("ttl:waiters");
    session.agent.session_ttl_secs = 1;
    session.last_active = std.time.timestamp() - 60;
    session.mutex.lock();

    var waiter_output: ?[]const u8 = null;
    const waiter = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
        fn run(mgr: *SessionManager, out: *?[]const u8) void {
            out.* = mgr.processMessage("ttl:waiters", "after-expiry", null) catch null;
        }
    }.run, .{ &sm, &waiter_output });
    std.Thread.sleep(20 * std.time.ns_per_ms);
    session.mutex.unlock();
    waiter.join();

    defer if (waiter_output) |value| testing.allocator.free(value);
    try testing.expect(waiter_output != null);
    try testing.expectEqualStrings("ok", waiter_output.?);
}

test "cleanup_skips_locked_expired_session_and_evicts_later" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("cleanup:ttl");
    session.last_active = std.time.timestamp() - 100;
    session.agent.session_ttl_secs = 1;

    session.mutex.lock();
    const first_evict = sm.evictIdle(1);
    try testing.expectEqual(@as(usize, 0), first_evict);
    session.mutex.unlock();

    const second_evict = sm.evictIdle(1);
    try testing.expectEqual(@as(usize, 1), second_evict);
}

// ---------------------------------------------------------------------------
// 5. Session consolidation tests
// ---------------------------------------------------------------------------

test "session last_consolidated defaults to zero" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:consolidation");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
}

test "session initial state includes last_consolidated" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:fields");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(s.created_at > 0);
    try testing.expect(s.last_active > 0);
}

// ---------------------------------------------------------------------------
// 6. Per-user session limit and listing tests (T-03-04, T-03-07)
// ---------------------------------------------------------------------------

test "MAX_SESSIONS_PER_USER is 200 (V1.11 raised from 50)" {
    // V1.11 (2026-05-07): raised 50 → 200. Power users running ZAKI across
    // channels (Telegram + Slack + Discord + App + scheduled tasks) plus
    // multiple thread conversations regularly exceed 50 active sessions.
    // 200 gives the daily-use case real headroom while still bounding the
    // DoS surface (T-03-04). Per-user soft cap is the right place for
    // abuse protection; this constant is a hard runtime ceiling.
    try testing.expectEqual(@as(usize, 200), MAX_SESSIONS_PER_USER);
}

test "SessionInfo struct has expected fields" {
    const info = SessionManager.SessionInfo{
        .session_key = "agent:zaki-bot:user:1:main",
        .created_at = 1000,
        .last_active = 2000,
        .turn_count = 5,
    };
    try testing.expectEqualStrings("agent:zaki-bot:user:1:main", info.session_key);
    try testing.expectEqual(@as(i64, 1000), info.created_at);
    try testing.expectEqual(@as(i64, 2000), info.last_active);
    try testing.expectEqual(@as(u64, 5), info.turn_count);
}

test "countUserSessions returns 0 for empty manager" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const count = sm.countUserSessions("99");
    try testing.expectEqual(@as(usize, 0), count);
}

test "countUserSessions counts only sessions for matching user" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("agent:zaki-bot:user:42:main");
    _ = try sm.getOrCreate("agent:zaki-bot:user:42:thread:t1");
    _ = try sm.getOrCreate("agent:zaki-bot:user:99:main");

    try testing.expectEqual(@as(usize, 2), sm.countUserSessions("42"));
    try testing.expectEqual(@as(usize, 1), sm.countUserSessions("99"));
    try testing.expectEqual(@as(usize, 0), sm.countUserSessions("0"));
}

test "listUserSessions returns only sessions for requesting user" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("agent:zaki-bot:user:7:main");
    _ = try sm.getOrCreate("agent:zaki-bot:user:7:thread:c1");
    _ = try sm.getOrCreate("agent:zaki-bot:user:8:main");

    const infos = try sm.listUserSessions(testing.allocator, "7");
    defer {
        for (infos) |info| testing.allocator.free(info.session_key);
        testing.allocator.free(infos);
    }

    try testing.expectEqual(@as(usize, 2), infos.len);
    // All returned keys must belong to user 7
    for (infos) |info| {
        try testing.expect(std.mem.startsWith(u8, info.session_key, "agent:zaki-bot:user:7:"));
    }
}

test "evictUserSessions removes only sessions for the targeted user" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("agent:zaki-bot:user:42:main");
    _ = try sm.getOrCreate("agent:zaki-bot:user:42:thread:t1");
    _ = try sm.getOrCreate("agent:zaki-bot:user:99:main");

    const result = sm.evictUserSessions("42");
    try testing.expectEqual(@as(usize, 2), result.evicted);
    try testing.expectEqual(@as(usize, 0), result.active_skipped);

    // User 99's session remains untouched.
    try testing.expectEqual(@as(usize, 0), sm.countUserSessions("42"));
    try testing.expectEqual(@as(usize, 1), sm.countUserSessions("99"));
}

test "evictUserSessions on absent user returns zero" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("agent:zaki-bot:user:7:main");

    const result = sm.evictUserSessions("nonexistent");
    try testing.expectEqual(@as(usize, 0), result.evicted);
    try testing.expectEqual(@as(usize, 0), result.active_skipped);
    try testing.expectEqual(@as(usize, 1), sm.countUserSessions("7"));
}

test "evictUserSessions counts active_refs as skipped" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("agent:zaki-bot:user:55:main");
    // Simulate an in-flight turn holding a session reference.
    session.active_refs = 1;
    defer session.active_refs = 0;

    const result = sm.evictUserSessions("55");
    try testing.expectEqual(@as(usize, 0), result.evicted);
    try testing.expectEqual(@as(usize, 1), result.active_skipped);
    // Session remains in the map (still reachable for the in-flight turn).
    try testing.expectEqual(@as(usize, 1), sm.countUserSessions("55"));
}

test "getOrCreate enforces MAX_SESSIONS_PER_USER per user" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create MAX_SESSIONS_PER_USER sessions for user "limit-user" using thread keys
    var key_buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_SESSIONS_PER_USER) : (i += 1) {
        const key = std.fmt.bufPrint(&key_buf, "agent:zaki-bot:user:limit-user:thread:t{d}", .{i}) catch unreachable;
        _ = try sm.getOrCreate(key);
    }

    // The next session for the same user must fail with SessionLimitExceeded
    const overflow_key = "agent:zaki-bot:user:limit-user:thread:overflow";
    const result = sm.getOrCreate(overflow_key);
    try testing.expectError(error.SessionLimitExceeded, result);

    // Other users are unaffected
    _ = try sm.getOrCreate("agent:zaki-bot:user:other-user:main");
}
