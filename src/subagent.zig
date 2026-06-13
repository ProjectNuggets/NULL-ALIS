//! SubagentManager — background task execution via isolated agent instances.
//!
//! Spawns subagents in separate OS threads. Each subagent runs a full
//! ChannelRuntime agent loop (tool access, memory, multi-turn) in an isolated
//! task session. Subagent runtimes use a dedicated tool profile that excludes
//! recursive spawn/delegate/message tools, and the event bus is not wired so
//! they cannot emit proactive messages directly. Task results are routed back
//! to the caller via the event bus as system InboundMessages once the agent
//! loop completes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus_mod = @import("bus.zig");
const config_mod = @import("config.zig");
const channel_loop = @import("channel_loop.zig");
const tools_mod = @import("tools/root.zig");
const json_util = @import("json_util.zig");
const observability = @import("observability.zig");
const tasks_mod = @import("tasks/root.zig");
const zaki_session = @import("session/root.zig");
const zaki_state = @import("zaki_state.zig");
const subagent_result = @import("subagent_result.zig");
const SubagentResult = subagent_result.SubagentResult;
/// Re-export the Phase-2 result value types so callers that already import the
/// subagent module (gateway, agent/commands) can reference
/// `subagent.SubagentResult` / `subagent.SubagentStatus` without a second
/// import of subagent_result.zig.
pub const SubagentResultType = SubagentResult;
pub const SubagentStatus = subagent_result.Status;
const heartbeat_wake = @import("heartbeat_wake.zig");
const build_options = @import("build_options");
const env_rebrand = @import("env_rebrand.zig");
const config_types = @import("config_types.zig");
const subagent_batch = @import("subagent_batch.zig");
pub const BatchTracker = subagent_batch.BatchTracker;

const log = std.log.scoped(.subagent);
const TASK_LEDGER_FILE_NAME = "subagent_tasks.jsonl";
const RECOVERY_FAILURE_REASON = "process_restarted_before_completion";

// ── Task types ──────────────────────────────────────────────────

pub const TaskStatus = enum {
    queued,
    running,
    completed,
    failed,
    /// Task was cancelled before it started running (WP2.4). Live
    /// interruption of a running subagent is not supported — cancellation
    /// applies to queued tasks only. See SubagentManager.cancelQueued.
    cancelled,
};

pub const TaskState = struct {
    status: TaskStatus,
    label: []const u8,
    task_summary: []const u8,
    task_prompt: []const u8,
    session_key: ?[]const u8 = null,
    runtime_session_key: ?[]const u8 = null,
    origin_channel: ?[]const u8 = null,
    origin_chat_id: ?[]const u8 = null,
    /// Phase 2: structured completion value (manager-allocator-owned slices).
    /// Freed via freeSubagentResult. Phase 1 stored only `?[]const u8` text;
    /// the text now lives in `result.?.text` and rides alongside metadata.
    result: ?SubagentResult = null,
    error_msg: ?[]const u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,
    thread: ?std.Thread = null,
    /// Phase 4 — batch membership tag. Non-null iff this task was spawned as
    /// part of a multi-subagent fan-out batch. Manager-allocator-owned; freed
    /// by freeTaskState / clearTasksLocked alongside `label` and `session_key`.
    batch_id: ?[]const u8 = null,
};

pub const SubagentConfig = struct {
    /// Maximum agent loop iterations per subagent (passed to ChannelRuntime).
    ///
    /// V1.11 (2026-05-07): raised 15 → 50.
    /// 2026-05-24 (v1.14.20): commercial-cap removal — subagents are
    /// long-horizon delegate workers; the per-loop iteration ceiling is no
    /// longer the right governor. goal_loop.GoalState in the parent +
    /// loop-detected on byte-identical repeats + the cheap-sidecar
    /// goal_status=met exit catch pathological cases. Default lifted to
    /// maxInt(u32). Operators can still set a finite override at
    /// SubagentManager construction.
    max_iterations: u32 = std.math.maxInt(u32),
    /// Maximum concurrent subagents per SubagentManager.
    ///
    /// 2026-05-23 raised 4 → 8 for the v1 commercial baseline.
    /// 2026-05-24 (v1.14.20): raised 8 → 64 alongside the central-meter
    /// shift. This cap is now ONLY a host-RAM safety ceiling (each subagent
    /// ≈ 50-100 MB resident; 64 × ≈ 3-6 GB worst case, fits on any modern
    /// host) — NOT a commercial gate. Provider rate-limits + central usage
    /// meter govern the actual fan-out. 64 matches the Manus "Wide Research"
    /// shape (their 100 is per-task VM; ours is per-runtime). Operators on
    /// thinner hosts (e.g. dev laptop) can lower via SubagentConfig
    /// override.
    max_concurrent: u32 = 64,
};

// ── ThreadContext — passed to each spawned thread ────────────────

const ThreadContext = struct {
    manager: *SubagentManager,
    task_id: u64,
    task: []const u8,
    label: []const u8,
    request_session_key: []const u8,
    origin_channel: []const u8,
    origin_chat_id: []const u8,
};

// ── SubagentManager ─────────────────────────────────────────────

pub const SubagentManager = struct {
    pub const CompletionRunnerFn = *const fn (
        ctx: ?*anyopaque,
        allocator: Allocator,
        system_prompt: []const u8,
        task: []const u8,
    ) anyerror![]const u8;
    pub const CompletionDeliveryFn = *const fn (
        ctx: ?*anyopaque,
        session_key: []const u8,
        content: []const u8,
    ) anyerror!void;

    /// Outcome of an atomic queued-only cancel attempt against the
    /// subagent-owned task map (WP2.4). See cancelQueued. Semantics mirror
    /// TaskDelivery.CancelOutcome so callers can translate easily when
    /// both ledgers are wired.
    pub const CancelOutcome = enum {
        /// Task was queued and has been transitioned to cancelled. The
        /// spawned thread will observe the cancelled status on its next
        /// markTaskRunning attempt and exit before executing any work.
        cancelled,
        /// Task exists but is already running. Live interruption is not
        /// supported — the task is left untouched.
        running,
        /// Task exists but is already in a terminal state (completed,
        /// failed, cancelled).
        terminal,
        /// No task with the given id is tracked by this manager.
        not_found,
    };

    allocator: Allocator,
    tasks: std.AutoHashMapUnmanaged(u64, *TaskState),
    next_id: u64,
    mutex: std.Thread.Mutex,
    config: SubagentConfig,
    bus: ?*bus_mod.Bus,
    config_ref: *const config_mod.Config,
    ledger_path: []const u8,
    ledger_state_mgr: ?*zaki_state.Manager = null,
    ledger_user_id: ?i64 = null,
    ledger_recovery_pending: bool,
    /// Phase 4 — in-memory fan-out batch registry. Tracks which task_ids belong
    /// to each batch, their terminal status, the parent session_key, and the
    /// deadline. All access is under `mutex` (the tracker is NOT self-locked —
    /// see subagent_batch.zig LOCK INVARIANT).
    batches: subagent_batch.BatchTracker = undefined,

    completion_runner: ?CompletionRunnerFn = null,
    completion_runner_ctx: ?*anyopaque = null,
    completion_delivery: ?CompletionDeliveryFn = null,
    completion_delivery_ctx: ?*anyopaque = null,

    /// Canonical-ledger bridge (WP2.1): subagent lifecycle transitions are
    /// mirrored into a TaskLedger via TaskDelivery so clients observing
    /// task_update events see real subagent state.
    ///
    /// v1.14.18 Step 7 (V4) — this is now **default-on**. `init` seeds it
    /// with a manager-owned `OwnedFallback` (heap-allocated in-memory
    /// ledger + noop observer + delivery) so even standalone CLI /
    /// channel-loop managers are bridged; the gateway path overrides it
    /// with the real per-tenant delivery via `attachTaskDelivery` and the
    /// owned fallback remains allocated-but-unused for the manager's
    /// lifetime (freed by `deinit`). Two managers in the same process
    /// never share a ledger, so canonical task IDs (which restart at 1
    /// per manager) cannot collide.
    ///
    /// The field keeps its `?` type only because the one-time fallback
    /// allocation can fail under extreme pressure; in v1.15+ the bridge
    /// becomes infallible and `?` is dropped (V4 follow-up).
    task_delivery: ?*tasks_mod.TaskDelivery = null,

    /// V4 — owned-by-manager fallback bundle, freed in `deinit`. Non-null
    /// when no explicit `attachTaskDelivery` has been called; an attached
    /// delivery still leaves this allocated (its destructor runs anyway).
    _owned_fallback: ?tasks_mod.delivery.OwnedFallback = null,

    pub fn init(
        allocator: Allocator,
        cfg: *const config_mod.Config,
        bus: ?*bus_mod.Bus,
        subagent_config: SubagentConfig,
    ) SubagentManager {
        const ledger_path = std.fs.path.join(allocator, &.{ cfg.workspace_dir, "state", TASK_LEDGER_FILE_NAME }) catch "";
        // V4 — default-on ledger bridge. A null here only happens if the
        // fallback allocation failed; warn loudly so the operator knows
        // task_list/task_get will be blind for this manager.
        const owned = tasks_mod.delivery.createOwnedFallback(allocator);
        if (owned == null) {
            log.warn("subagent: task-delivery fallback unavailable — subagent lifecycle will NOT be mirrored to the task ledger for this manager", .{});
        }
        var manager = SubagentManager{
            .allocator = allocator,
            .tasks = .{},
            .next_id = 1,
            .mutex = .{},
            .config = subagent_config,
            .bus = bus,
            .config_ref = cfg,
            .ledger_path = ledger_path,
            .ledger_recovery_pending = cfg.tenant.enabled and std.mem.eql(u8, cfg.state.backend, "postgres"),
            .task_delivery = if (owned) |o| o.delivery else null,
            ._owned_fallback = owned,
            .batches = subagent_batch.BatchTracker.init(allocator),
        };
        if (!manager.ledger_recovery_pending) {
            manager.recoverDurableState() catch |err| {
                log.warn("subagent: failed to recover file ledger: {}", .{err});
            };
        }
        return manager;
    }

    pub fn deinit(self: *SubagentManager) void {
        // Join all running threads and free task states
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.thread) |thread| {
                thread.join();
            }
            if (state.result) |*r| freeSubagentResult(self.allocator, r);
            if (state.error_msg) |e| self.allocator.free(e);
            if (state.session_key) |sk| self.allocator.free(sk);
            if (state.runtime_session_key) |sk| self.allocator.free(sk);
            if (state.origin_channel) |channel| self.allocator.free(channel);
            if (state.origin_chat_id) |chat| self.allocator.free(chat);
            if (state.batch_id) |bid| self.allocator.free(bid); // Phase 4
            self.allocator.free(state.label);
            self.allocator.free(state.task_summary);
            self.allocator.free(state.task_prompt);
            self.allocator.destroy(state);
        }
        self.tasks.deinit(self.allocator);
        if (self.ledger_path.len > 0) self.allocator.free(self.ledger_path);
        // V4 — free the owned-fallback bundle (lifetime tied to the
        // manager). Safe even if an `attachTaskDelivery` override pointed
        // `task_delivery` elsewhere; we never freed the override, only
        // the manager's own allocation.
        if (self._owned_fallback) |*owned| {
            owned.deinit();
            self._owned_fallback = null;
        }
        // Phase 4 — free all batch state.
        self.batches.deinit();
    }

    pub fn attachPostgresLedger(self: *SubagentManager, state_mgr: *zaki_state.Manager, user_id: i64) void {
        self.mutex.lock();
        self.ledger_state_mgr = state_mgr;
        self.ledger_user_id = user_id;
        self.ledger_recovery_pending = false;
        self.clearTasksLocked();
        self.mutex.unlock();

        self.recoverDurableState() catch |err| {
            log.warn("subagent: failed to recover postgres ledger user_id={d}: {}", .{ user_id, err });
        };
    }

    pub fn attachCompletionDelivery(
        self: *SubagentManager,
        ctx: ?*anyopaque,
        delivery: CompletionDeliveryFn,
    ) void {
        self.mutex.lock();
        self.completion_delivery_ctx = ctx;
        self.completion_delivery = delivery;
        self.mutex.unlock();

        // Startup recovery: re-deliver any completions that were persisted
        // but not confirmed-delivered before the previous pod restart.
        // Only runs when both the PG ledger AND the delivery callback are
        // wired — mirrors the gateway.zig wiring order where
        // attachPostgresLedger is called first, attachCompletionDelivery
        // second (Task 1.6).
        if (self.ledger_user_id) |uid| {
            self.recoverPendingSubagentResults(uid);
        }
    }

    /// Re-deliver completions that were persisted but not confirmed-delivered
    /// before a restart. Idempotent: each row is marked delivered after waking
    /// so a second restart won't re-fire the same completion. Best-effort:
    /// logs and continues on any error. Frees every row (deinit + free slice).
    ///
    /// Phase 2 (Task 2.3): the durable row's `result_json` now holds a full
    /// `SubagentResult`. We parse it and re-deliver the REAL answer text (with
    /// the task_id in the header for parent-side correlation), so a recovered
    /// turn carries the actual answer — not just a marker. If parsing fails
    /// (legacy/minimal row, corrupt JSON), we fall back to the marker-only
    /// content so recovery still wakes the parent.
    pub fn recoverPendingSubagentResults(self: *SubagentManager, user_id: i64) void {
        const sm = self.ledger_state_mgr orelse return;
        const rows = sm.loadPendingSubagentResults(self.allocator, user_id) catch |err| {
            log.warn("subagent: recovery load failed user_id={d}: {}", .{ user_id, err });
            return;
        };
        defer {
            for (rows) |*r| r.deinit(self.allocator);
            self.allocator.free(rows);
        }
        for (rows) |row| {
            // Re-deliver to the parent session history. Rehydrate the full text
            // from result_json; the parsed arena is freed by `defer` before the
            // next iteration.
            if (self.completion_delivery) |delivery| {
                const content: ?[]u8 = blk: {
                    if (SubagentResult.fromJsonAlloc(self.allocator, row.result_json)) |parsed_const| {
                        var parsed = parsed_const;
                        defer parsed.deinit(self.allocator);
                        break :blk std.fmt.allocPrint(
                            self.allocator,
                            "[Subagent task_id={d} completed — recovered after restart]\n{s}",
                            .{ row.task_id, parsed.value.text },
                        ) catch null;
                    } else |err| {
                        // Parse failure — fall back to the marker-only content.
                        log.warn("subagent: recovery result_json parse failed task_id={d}: {} — delivering marker", .{ row.task_id, err });
                        break :blk std.fmt.allocPrint(
                            self.allocator,
                            "[Subagent task_id={d} completed — recovered after restart]",
                            .{row.task_id},
                        ) catch null;
                    }
                };
                if (content) |c| {
                    defer self.allocator.free(c);
                    delivery(self.completion_delivery_ctx, row.session_key, c) catch {};
                }
            }
            // Wake the parent's heartbeat turn so the recovery is processed.
            var ubuf: [32]u8 = undefined;
            const uid_s: ?[]const u8 = std.fmt.bufPrint(&ubuf, "{d}", .{user_id}) catch null;
            heartbeat_wake.enqueue(uid_s, "subagent_completion:recovered") catch {};
            // Mark delivered so a subsequent restart doesn't re-fire this row.
            sm.markSubagentResultDelivered(row.result_id) catch {};
        }
    }

    /// Attach a canonical TaskDelivery so subagent lifecycle transitions
    /// mirror into the TaskLedger. Detached (null) behavior is unchanged.
    pub fn attachTaskDelivery(self: *SubagentManager, delivery: *tasks_mod.TaskDelivery) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.task_delivery = delivery;
    }

    fn formatCanonicalTaskId(buf: *[tasks_mod.ledger.TASK_ID_LEN]u8, task_id: u64) ?[]const u8 {
        const formatted = std.fmt.bufPrint(buf, "task_{x:0>11}", .{task_id}) catch return null;
        if (formatted.len != tasks_mod.ledger.TASK_ID_LEN) return null;
        return formatted;
    }


    // ── Phase 4 G2 types ────────────────────────────────────────────────────────

    /// A single spec passed to spawnMany. The task and label slices are borrowed
    /// from the caller and must remain valid until spawnMany returns.
    pub const SpawnSpec = struct {
        task: []const u8,
        label: []const u8,
    };

    /// Return value of spawnMany. The caller owns batch_id and task_ids (both
    /// allocator-owned) and must free them via the manager's allocator.
    /// `requested` = len(specs) supplied; `task_ids.len` = how many actually
    /// spawned (H8: may be < requested if a mid-loop failure occurred).
    pub const BatchHandle = struct {
        batch_id: []const u8,
        task_ids: []u64,
        requested: usize,
    };

    // ── Spawn implementation ─────────────────────────────────────────────────

    /// H3 — Inner locked spawn. Assumes `self.mutex` is ALREADY HELD by the
    /// caller; does NOT lock and does NOT check capacity (capacity must be
    /// pre-checked before entering the batch loop). Sets `state.batch_id` to
    /// a dupe of `batch_id` if non-null.
    ///
    /// `std.Thread.spawn` is safe to call under the lock: it does not touch
    /// `self.mutex`; the spawned thread blocks in `markTaskRunning` trying to
    /// acquire the same mutex, so it is parked until the caller releases it.
    fn spawnInBatchLocked(
        self: *SubagentManager,
        task: []const u8,
        label: []const u8,
        request_session_key: []const u8,
        origin_channel: []const u8,
        origin_chat_id: []const u8,
        batch_id: ?[]const u8,
    ) !u64 {
        const task_id = self.next_id;
        self.next_id += 1;

        const state = try self.allocator.create(TaskState);
        errdefer self.allocator.destroy(state);
        const state_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(state_label);
        const state_task_summary = try summarizeTaskForDisplay(self.allocator, task);
        errdefer self.allocator.free(state_task_summary);
        const state_prompt = try self.allocator.dupe(u8, task);
        errdefer self.allocator.free(state_prompt);
        const state_session = try self.allocator.dupe(u8, request_session_key);
        errdefer self.allocator.free(state_session);
        var runtime_session_buf: [128]u8 = undefined;
        const runtime_session_text = deriveTaskRuntimeSessionKey(&runtime_session_buf, request_session_key, task_id);
        const state_runtime_session = try self.allocator.dupe(u8, runtime_session_text);
        errdefer self.allocator.free(state_runtime_session);
        const state_channel = try self.allocator.dupe(u8, origin_channel);
        errdefer self.allocator.free(state_channel);
        const state_chat = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(state_chat);
        // Phase 4 — tag with batch membership if this is a fan-out task.
        const state_batch_id: ?[]const u8 = if (batch_id) |b| try self.allocator.dupe(u8, b) else null;
        errdefer if (state_batch_id) |b| self.allocator.free(b);

        const created_at = std.time.milliTimestamp();
        state.* = .{
            .status = .queued,
            .label = state_label,
            .task_summary = state_task_summary,
            .task_prompt = state_prompt,
            .session_key = state_session,
            .runtime_session_key = state_runtime_session,
            .origin_channel = state_channel,
            .origin_chat_id = state_chat,
            .started_at = created_at,
            .batch_id = state_batch_id,
        };

        try self.tasks.put(self.allocator, task_id, state);
        errdefer {
            if (self.tasks.fetchRemove(task_id)) |removed| {
                freeTaskState(self.allocator, removed.value);
            }
        }
        self.persistTaskSnapshotLocked(task_id, state);

        const task_copy = try self.allocator.dupe(u8, task);
        errdefer self.allocator.free(task_copy);
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);
        const request_session_copy = try self.allocator.dupe(u8, request_session_key);
        errdefer self.allocator.free(request_session_copy);
        const origin_channel_copy = try self.allocator.dupe(u8, origin_channel);
        errdefer self.allocator.free(origin_channel_copy);
        const origin_chat_copy = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(origin_chat_copy);

        const ctx = try self.allocator.create(ThreadContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{
            .manager = self,
            .task_id = task_id,
            .task = task_copy,
            .label = label_copy,
            .request_session_key = request_session_copy,
            .origin_channel = origin_channel_copy,
            .origin_chat_id = origin_chat_copy,
        };

        state.thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, subagentThreadFn, .{ctx}) catch |err| {
            const owned_err = self.allocator.dupe(u8, @errorName(err)) catch null;
            state.status = .failed;
            state.error_msg = owned_err;
            state.completed_at = std.time.milliTimestamp();
            self.persistTaskSnapshotLocked(task_id, state);
            self.allocator.free(task_copy);
            self.allocator.free(label_copy);
            self.allocator.free(request_session_copy);
            self.allocator.free(origin_channel_copy);
            self.allocator.free(origin_chat_copy);
            self.allocator.destroy(ctx);
            return err;
        };

        // Mirror the new task into the canonical ledger (WP2.1). The thread
        // will block on markTaskRunning until we release the mutex, so the
        // queued → running transition order is preserved.
        if (self.task_delivery) |td| {
            const owner = state.session_key orelse "subagent";
            _ = td.createTaskWithNumericId(state.task_summary, owner, task_id) catch |err| {
                log.warn("subagent: failed to mirror task #{d} to delivery: {}", .{ task_id, err });
            };
        }

        return task_id;
    }

    /// Return remaining subagent capacity for this manager (max_concurrent minus
    /// currently queued/running). Clamped to 0 — never wraps. Caller must hold
    /// `self.mutex`.
    fn remainingCapacityLocked(self: *SubagentManager) u32 {
        const running = self.getRunningCountLocked();
        if (running >= self.config.max_concurrent) return 0;
        return self.config.max_concurrent - running;
    }

    /// Spawn a background subagent. Returns task_id immediately.
    /// Single-spawn public API — unchanged signature; delegates to
    /// spawnInBatchLocked with null batch_id under a single lock acquisition.
    pub fn spawn(
        self: *SubagentManager,
        task: []const u8,
        label: []const u8,
        request_session_key: []const u8,
        origin_channel: []const u8,
        origin_chat_id: []const u8,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.getRunningCountLocked() >= self.config.max_concurrent)
            return error.TooManyConcurrentSubagents;
        return self.spawnInBatchLocked(task, label, request_session_key, origin_channel, origin_chat_id, null);
    }

    /// H3 — Fan out N subagents under a single batch.
    ///
    /// All-or-nothing capacity check: if specs.len > remainingCapacityLocked()
    /// at the moment we enter the lock, we return error.TooManyConcurrentSubagents
    /// and spawn NOTHING. The capacity check, the entire spawn loop, AND the
    /// batch registration all run under ONE continuous mutex hold so no concurrent
    /// spawnMany or spawn call can slip tasks in between the check and the spawns.
    ///
    /// H8 — partial-spawn note: if a mid-loop spawnInBatchLocked fails (OOM,
    /// thread limit), we break and register the batch with however many tasks DID
    /// spawn; BatchHandle.requested vs task_ids.len tells the caller how many were
    /// actually created. On zero spawned we return error.SpawnFailed.
    ///
    /// Caller owns handle.batch_id and handle.task_ids; free both via the manager
    /// allocator.
    pub fn spawnMany(
        self: *SubagentManager,
        specs: []const SpawnSpec,
        request_session_key: []const u8,
        origin_channel: []const u8,
        origin_chat_id: []const u8,
        budget_ms: i64,
    ) !BatchHandle {
        if (specs.len == 0) return error.EmptyBatch;

        const now = std.time.milliTimestamp();
        var ids = std.ArrayListUnmanaged(u64){};
        errdefer ids.deinit(self.allocator);

        // batch_id is formatted into a stack buffer then duped into the allocator
        // after the lock section to avoid holding a pointer into stack memory past
        // the lock scope.
        var idbuf: [64]u8 = undefined;
        var batch_id_len: usize = 0;

        {
            // H3 — single lock: capacity check + spawn loop + batch register.
            self.mutex.lock();
            defer self.mutex.unlock();

            if (specs.len > self.remainingCapacityLocked())
                return error.TooManyConcurrentSubagents;

            // Use next_id (the monotonic spawn counter) as the sequence component
            // so the batch_id is stable and unique within this manager's lifetime.
            const seq = self.next_id;
            const batch_id_local = try std.fmt.bufPrint(&idbuf, "batch:{d}:{d}", .{ seq, now });
            batch_id_len = batch_id_local.len;

            for (specs) |spec| {
                const tid = self.spawnInBatchLocked(
                    spec.task,
                    spec.label,
                    request_session_key,
                    origin_channel,
                    origin_chat_id,
                    batch_id_local,
                ) catch break; // H8: partial failure — register what did spawn
                ids.append(self.allocator, tid) catch break;
            }

            if (ids.items.len > 0) {
                // Register the batch in the tracker while still under the lock.
                // On failure (OOM), log and continue — the tasks are spawned and
                // will complete; the barrier just won't fire.
                self.batches.register(
                    batch_id_local,
                    ids.items,
                    request_session_key,
                    now,
                    now + budget_ms,
                ) catch |err| log.warn("subagent: batch register failed: {}", .{err});
            }
        }

        if (ids.items.len == 0) return error.SpawnFailed;

        // Dupe the batch_id out of the stack buffer now that the lock is released.
        const owned_batch_id = try self.allocator.dupe(u8, idbuf[0..batch_id_len]);
        return BatchHandle{
            .batch_id = owned_batch_id,
            .task_ids = try ids.toOwnedSlice(self.allocator),
            .requested = specs.len,
        };
    }

    pub fn getTaskStatus(self: *SubagentManager, task_id: u64) ?TaskStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.status;
        }
        return null;
    }

    /// Return the full structured result for a task (Phase 2). The returned
    /// `SubagentResult` borrows manager-owned slices guarded by the manager
    /// lifetime — copy out anything you need to retain past the next mutation.
    pub fn getTaskResult(self: *SubagentManager, task_id: u64) ?SubagentResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.result;
        }
        return null;
    }

    /// Return just the final-answer text for a task — the manual query path
    /// (`task_get` tool, callers that only relay the answer). Borrowed slice,
    /// manager-lifetime; copy if retaining. Null when the task is unknown or
    /// produced no result.
    pub fn getTaskResultText(self: *SubagentManager, task_id: u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            if (state.result) |r| return r.text;
        }
        return null;
    }

    pub fn getRunningCount(self: *SubagentManager) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getRunningCountLocked();
    }

    fn getRunningCountLocked(self: *SubagentManager) u32 {
        var count: u32 = 0;
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.status == .queued or entry.value_ptr.*.status == .running) count += 1;
        }
        return count;
    }

    fn clearTasksLocked(self: *SubagentManager) void {
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.thread) |thread| thread.join();
            if (state.result) |*value| freeSubagentResult(self.allocator, value);
            if (state.error_msg) |value| self.allocator.free(value);
            if (state.session_key) |value| self.allocator.free(value);
            if (state.runtime_session_key) |value| self.allocator.free(value);
            if (state.origin_channel) |value| self.allocator.free(value);
            if (state.origin_chat_id) |value| self.allocator.free(value);
            if (state.batch_id) |value| self.allocator.free(value); // Phase 4
            self.allocator.free(state.label);
            self.allocator.free(state.task_summary);
            self.allocator.free(state.task_prompt);
            self.allocator.destroy(state);
        }
        self.tasks.clearRetainingCapacity();
        self.next_id = 1;
    }

    fn recoverDurableState(self: *SubagentManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.ledger_state_mgr != null and self.ledger_user_id != null) {
            try self.recoverFromPostgresLocked();
        } else if (self.ledger_path.len > 0) {
            try self.recoverFromFileLocked();
        }
        self.finalizeRecoveredInFlightLocked();
    }

    fn recoverFromPostgresLocked(self: *SubagentManager) !void {
        const state_mgr = self.ledger_state_mgr orelse return;
        const user_id = self.ledger_user_id orelse return;
        const snapshots = try state_mgr.listTaskSnapshots(self.allocator, user_id);
        defer {
            for (snapshots) |*entry| entry.deinit(self.allocator);
            self.allocator.free(snapshots);
        }

        var max_id: u64 = 0;
        for (snapshots) |*snapshot| {
            const task_id = std.fmt.parseInt(u64, snapshot.id, 10) catch continue;
            max_id = @max(max_id, task_id);
            const state = try self.taskStateFromSnapshot(snapshot);
            try self.tasks.put(self.allocator, task_id, state);
        }
        self.next_id = max_id + 1;
    }

    fn recoverFromFileLocked(self: *SubagentManager) !void {
        if (self.ledger_path.len == 0) return;
        const file = openLedgerFileRead(self.ledger_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const raw = try file.readToEndAlloc(self.allocator, 4 * 1024 * 1024);
        defer self.allocator.free(raw);

        var lines = std.mem.splitScalar(u8, raw, '\n');
        var max_id: u64 = 0;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            var snapshot = try parseLedgerSnapshot(self.allocator, trimmed);
            defer snapshot.deinit(self.allocator);
            max_id = @max(max_id, snapshot.id);
            if (self.tasks.fetchRemove(snapshot.id)) |existing| {
                freeTaskState(self.allocator, existing.value);
            }
            const state = try self.taskStateFromLedger(&snapshot);
            try self.tasks.put(self.allocator, snapshot.id, state);
        }
        self.next_id = max_id + 1;
    }

    fn finalizeRecoveredInFlightLocked(self: *SubagentManager) void {
        const recovered_at = std.time.milliTimestamp();
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task_id = entry.key_ptr.*;
            const state = entry.value_ptr.*;
            if (state.status != .queued and state.status != .running) continue;
            if (state.error_msg) |value| self.allocator.free(value);
            state.status = .failed;
            state.error_msg = self.allocator.dupe(u8, RECOVERY_FAILURE_REASON) catch null;
            state.completed_at = recovered_at;
            self.persistTaskSnapshotLocked(task_id, state);
        }
    }

    fn taskStateFromSnapshot(self: *SubagentManager, snapshot: *const zaki_state.TaskSnapshot) !*TaskState {
        const label = try self.allocator.dupe(u8, snapshot.label);
        errdefer self.allocator.free(label);
        const task_summary = try summarizeTaskForDisplay(self.allocator, snapshot.prompt);
        errdefer self.allocator.free(task_summary);
        const task_prompt = try self.allocator.dupe(u8, snapshot.prompt);
        errdefer self.allocator.free(task_prompt);
        const task_id = std.fmt.parseInt(u64, snapshot.id, 10) catch 0;
        const session_key = if (snapshot.request_session_id) |value|
            try self.allocator.dupe(u8, value)
        else if (snapshot.session_id) |value|
            if (!isTaskSessionKey(value)) try self.allocator.dupe(u8, value) else null
        else
            null;
        errdefer if (session_key) |value| self.allocator.free(value);
        const runtime_session_key = if (snapshot.session_id) |value|
            if (snapshot.request_session_id == null and !isTaskSessionKey(value)) blk: {
                var session_buf: [128]u8 = undefined;
                break :blk try self.allocator.dupe(u8, deriveTaskRuntimeSessionKey(&session_buf, value, task_id));
            } else try self.allocator.dupe(u8, value)
        else blk: {
            if (session_key) |value| {
                var session_buf: [128]u8 = undefined;
                break :blk try self.allocator.dupe(u8, deriveTaskRuntimeSessionKey(&session_buf, value, task_id));
            }
            break :blk null;
        };
        errdefer if (runtime_session_key) |value| self.allocator.free(value);
        // Phase 2: the durable task-snapshot row carries only the text result;
        // wrap it into a minimal SubagentResult (status inferred from the row).
        const result: ?SubagentResult = if (snapshot.result) |value|
            try subagentResultFromText(self.allocator, parseTaskStatus(snapshot.status), value)
        else
            null;
        errdefer if (result) |*value| freeSubagentResult(self.allocator, value);
        const error_msg = if (snapshot.error_msg) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (error_msg) |value| self.allocator.free(value);

        const state = try self.allocator.create(TaskState);
        state.* = .{
            .status = parseTaskStatus(snapshot.status),
            .label = label,
            .task_summary = task_summary,
            .task_prompt = task_prompt,
            .session_key = session_key,
            .runtime_session_key = runtime_session_key,
            .result = result,
            .error_msg = error_msg,
            .started_at = if (snapshot.started_at_ms) |value| value else snapshot.created_at_ms,
            .completed_at = snapshot.completed_at_ms,
            .thread = null,
        };
        return state;
    }

    fn taskStateFromLedger(self: *SubagentManager, snapshot: *const LedgerSnapshot) !*TaskState {
        const label = try self.allocator.dupe(u8, snapshot.label);
        errdefer self.allocator.free(label);
        const task_summary = try self.allocator.dupe(u8, snapshot.task_summary);
        errdefer self.allocator.free(task_summary);
        const task_prompt = try self.allocator.dupe(u8, snapshot.task_prompt);
        errdefer self.allocator.free(task_prompt);
        const session_key = if (snapshot.session_key) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (session_key) |value| self.allocator.free(value);
        const runtime_session_key = if (snapshot.runtime_session_key) |value| try self.allocator.dupe(u8, value) else blk: {
            if (session_key) |value| {
                var session_buf: [128]u8 = undefined;
                break :blk try self.allocator.dupe(u8, deriveTaskRuntimeSessionKey(&session_buf, value, snapshot.id));
            }
            break :blk null;
        };
        errdefer if (runtime_session_key) |value| self.allocator.free(value);
        const origin_channel = if (snapshot.origin_channel) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (origin_channel) |value| self.allocator.free(value);
        const origin_chat_id = if (snapshot.origin_chat_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (origin_chat_id) |value| self.allocator.free(value);
        // Phase 2: the file-ledger snapshot stores only the text result; wrap
        // it into a minimal SubagentResult (status inferred from the row).
        const result: ?SubagentResult = if (snapshot.result) |value|
            try subagentResultFromText(self.allocator, snapshot.status, value)
        else
            null;
        errdefer if (result) |*value| freeSubagentResult(self.allocator, value);
        const error_msg = if (snapshot.error_msg) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (error_msg) |value| self.allocator.free(value);

        const state = try self.allocator.create(TaskState);
        state.* = .{
            .status = snapshot.status,
            .label = label,
            .task_summary = task_summary,
            .task_prompt = task_prompt,
            .session_key = session_key,
            .runtime_session_key = runtime_session_key,
            .origin_channel = origin_channel,
            .origin_chat_id = origin_chat_id,
            .result = result,
            .error_msg = error_msg,
            .started_at = snapshot.started_at,
            .completed_at = snapshot.completed_at,
            .thread = null,
        };
        return state;
    }

    fn persistTaskSnapshotLocked(self: *SubagentManager, task_id: u64, state: *const TaskState) void {
        self.persistTaskSnapshot(task_id, state) catch |err| {
            log.warn("subagent: failed to persist task #{d}: {}", .{ task_id, err });
        };
    }

    fn persistTaskSnapshot(self: *SubagentManager, task_id: u64, state: *const TaskState) !void {
        if (self.ledger_state_mgr) |state_mgr| {
            if (self.ledger_user_id) |user_id| {
                var task_id_buf: [32]u8 = undefined;
                const task_id_text = try std.fmt.bufPrint(&task_id_buf, "{d}", .{task_id});
                try state_mgr.upsertTaskSnapshot(
                    user_id,
                    task_id_text,
                    state.runtime_session_key,
                    state.session_key,
                    state.label,
                    state.task_prompt,
                    taskStatusText(state.status),
                    // Phase 2: the task-snapshot row stores the text only; the
                    // full structured result lives in the durable outbox
                    // (subagent_results.result_json) via completeTask.
                    if (state.result) |r| r.text else null,
                    state.error_msg,
                    state.started_at,
                    if (state.status == .queued) null else state.started_at,
                    state.completed_at,
                );
                return;
            }
        }
        if (self.ledger_path.len == 0) return;
        try appendLedgerSnapshot(self.allocator, self.ledger_path, task_id, state);
    }

    /// Mark a task as completed or failed. Thread-safe.
    ///
    /// Phase 2: `result` is the structured `SubagentResult` the subagent
    /// produced (success path). The early-failure callers (runtime init / model
    /// errors) pass `result == null` and an `err_msg` string instead; in that
    /// case a minimal failed result is synthesized for the durable row and the
    /// delivery. The incoming result's slices are duped into the manager
    /// allocator (via dupeSubagentResult) so they outlive the subagent thread's
    /// arena; freeSubagentResult releases them.
    fn completeTask(self: *SubagentManager, task_id: u64, result: ?SubagentResult, err_msg: ?[]const u8) void {
        // Dupe result/error into manager's allocator (source may be arena-backed)
        const owned_result: ?SubagentResult = if (result) |r| (dupeSubagentResult(self.allocator, r) catch null) else null;
        const owned_err = if (err_msg) |e| self.allocator.dupe(u8, e) catch null else null;

        // HI-01 fix (2026-05-07): if the task entry was removed from the
        // map between thread spawn and completion (e.g., clearTasksLocked
        // during attachPostgresLedger, future cancel-during-run paths),
        // the dupes above would leak — neither owned_result nor owned_err
        // gets transferred into state.{result,error_msg} below. Track
        // transfer explicitly and free on the failure path.
        var transferred = false;
        defer if (!transferred) {
            if (owned_result) |*r| freeSubagentResult(self.allocator, r);
            if (owned_err) |e| self.allocator.free(e);
        };

        var label: []const u8 = "subagent";
        var origin_channel: []const u8 = "system";
        var origin_chat_id: []const u8 = "agent";
        var request_session_key: []const u8 = "agent";
        // result_id buffer hoisted here so it's available after the lock
        // for the durable gate (subagentResultStatusIsDelivered) and
        // mark-after-deliver (markSubagentResultDelivered).
        var result_id_buf: [40]u8 = undefined;
        var result_id_slice: ?[]const u8 = null;
        // ── In-memory idempotency gate + first-completion (single lock) ─────
        // Layer A (terminal check) and the first-completion mutation are now
        // combined into ONE lock acquisition to eliminate the TOCTOU gap that
        // existed when they were two separate acquisitions (review I-B1).
        // On the already-terminal path `transferred` stays false, so the
        // `defer if (!transferred)` above frees owned_result/owned_err exactly
        // once — no leak, no double-free.
        var should_deliver = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tasks.get(task_id)) |state| {
                if (state.status == .completed or state.status == .failed or state.status == .cancelled) {
                    // Already terminal — idempotent skip.
                    // owned_result/owned_err are freed by the `defer if (!transferred)` above.
                } else {
                    if (state.result) |*value| freeSubagentResult(self.allocator, value);
                    if (state.error_msg) |value| self.allocator.free(value);
                    state.status = if (owned_err != null) .failed else .completed;
                    state.result = owned_result;
                    state.error_msg = owned_err;
                    transferred = true;
                    state.completed_at = std.time.milliTimestamp();
                    self.persistTaskSnapshotLocked(task_id, state);
                    label = state.label;
                    origin_channel = state.origin_channel orelse "system";
                    origin_chat_id = state.origin_chat_id orelse "agent";
                    request_session_key = state.session_key orelse origin_chat_id;

                    // ── Durable outbox persist (Phase 1) ─────────────────────
                    // Write the completion BEFORE we deliver/wake so a crash
                    // between persist and deliver is recovered by
                    // loadPendingSubagentResults on boot (Task 1.6).
                    // Best-effort: PG failure is warned but does NOT block delivery.
                    // Fill result_id_slice using the hoisted buffer; available
                    // after the lock for the durable gate and mark-delivered.
                    result_id_slice = formatSubagentResultId(&result_id_buf, task_id) catch null;

                    if (self.ledger_state_mgr) |sm| {
                        if (state.session_key) |skey| {
                            if (zaki_session.parseUserIdFromSessionKey(skey)) |uid_str| {
                                const uid_num = std.fmt.parseInt(i64, uid_str, 10) catch null;
                                if (uid_num) |user_id| {
                                    if (result_id_slice) |result_id| {
                                        // Phase 2 payload: the FULL SubagentResult JSON (status,
                                        // text, artifacts, tokens, turns, tools_used, err,
                                        // duration_ms) — replacing the Phase-1 minimal
                                        // {status,text}. Recovery (Task 2.3) re-hydrates the real
                                        // text from this. When the task failed before producing a
                                        // structured result, synthesize a minimal failed result
                                        // from the error string so the row is still well-formed.
                                        const persist_result: SubagentResult = state.result orelse .{
                                            .status = .failed,
                                            .text = state.error_msg orelse "",
                                            .err = state.error_msg,
                                        };
                                        const payload = persist_result.toJsonAlloc(self.allocator) catch null;
                                        if (payload) |pj| {
                                            defer self.allocator.free(pj);
                                            sm.upsertSubagentResult(.{
                                                .result_id = result_id,
                                                .user_id = user_id,
                                                .session_key = skey,
                                                .task_id = @intCast(task_id),
                                                .result_json = pj,
                                            }) catch |err| log.warn("subagent: durable persist failed task_id={d}: {}", .{ task_id, err });
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Mirror terminal transition into the canonical ledger
                    // (WP2.1). Result/error strings are owned by the subagent
                    // state; we pass null here to avoid cross-owning a pointer
                    // into the ledger, which does not manage string lifetimes.
                    if (self.task_delivery) |td| {
                        var id_buf: [tasks_mod.ledger.TASK_ID_LEN]u8 = undefined;
                        if (formatCanonicalTaskId(&id_buf, task_id)) |id_slice| {
                            if (state.status == .failed) {
                                td.markFailed(id_slice, null) catch |err| {
                                    log.warn("subagent: failed to mirror failed status for task #{d}: {}", .{ task_id, err });
                                };
                            } else {
                                td.markSucceeded(id_slice, null) catch |err| {
                                    log.warn("subagent: failed to mirror succeeded status for task #{d}: {}", .{ task_id, err });
                                };
                            }
                        }
                    }
                    should_deliver = true;
                } // end else (not already terminal)
            }
        }
        if (!should_deliver) {
            log.info("subagent: idempotent completion skipped task_id={d} (already terminal)", .{task_id});
            return;
        }

        // ── Layer B: durable idempotency gate (cross-restart) ────────────
        // If PG is attached, check whether this result_id has already been
        // marked 'delivered' in the durable outbox. This fires on restart
        // recovery: a pod crash AFTER persist but BEFORE mark-delivered
        // correctly re-delivers (status is still 'pending'); a pod crash
        // AFTER mark-delivered skips (status is 'delivered'). Layer A
        // (in-memory) already handles the same-process duplicate path.
        if (self.ledger_state_mgr) |sm| {
            if (result_id_slice) |rid| {
                const already_delivered = sm.subagentResultStatusIsDelivered(rid) catch false;
                if (already_delivered) {
                    log.info("subagent: idempotent delivery skipped task_id={d} (durable status=delivered)", .{task_id});
                    return;
                }
            }
        }

        // ── Route result (outside lock) ──────────────────────────────
        // PRECEDENCE: direct completion_delivery callback FIRST, bus SECOND.
        //
        // Rationale: when a caller has attached a direct callback (tenant
        // mode: gateway.zig:1372 attaches appendSubagentCompletionToGateway
        // Session), it is the semantically correct delivery — it writes to
        // the parent's session history AND pushes SSE to live app clients.
        // The bus path is a broadcast to an inbound queue that is only
        // consumed by daemon.run() in shared mode (daemon.zig:1850). In
        // tenant mode (gateway.runWithRole with role=.user_cell), the bus
        // inbound queue has NO consumer — results vanish.
        //
        // The prior order (`if bus else if completion_delivery`) meant the
        // tenant path was dead code since both fields are populated in
        // production. Fixed by flipping precedence. Bus remains the path
        // for shared/daemon deployments.
        // **D1.6** — defense-in-depth from the W0.5 plan in
        // project_subagent_received_bug.md. Pre-fix: an empty-but-non-
        // null `owned_result` (subagent ran, produced no text) entered
        // the "completed" branch and emitted "[Subagent 'X'
        // completed]\n" — a trailing-newline empty content the
        // frontend can't render as anything useful, contributing to
        // the user-visible "received"-style confusion. Now empty
        // results route to a distinct "completed-no-output" message
        // so the frontend knows the run succeeded but produced no
        // text, and can show a check-mark / "task done" badge instead
        // of an empty bubble.
        // S-tier hardening (2026-05-23): include task_id in every delivered
        // message so the parent agent can correlate this delivery with the
        // task_id it received from `spawn`'s return value, and so the
        // parent's later `task_get(task_id)` lookup is unambiguous. The
        // "no output" framing is also rewritten so the parent has a clear
        // recovery path ("re-run with a more specific task, or compute
        // directly") instead of silently relaying an empty bubble.
        const has_real_result = if (owned_result) |r| r.text.len > 0 else false;
        const content = if (has_real_result)
            // Phase 2: deliver the result text plus a one-line metadata footer
            // so the parent agent sees structured signal (tokens/turns/duration),
            // not just text. The footer is intentionally compact and machine-
            // greppable. Zero-valued metrics are still emitted for shape
            // stability (a subagent that produced no measurable usage shows 0s).
            std.fmt.allocPrint(
                self.allocator,
                "[Subagent '{s}' task_id={d} completed]\n{s}\n[tokens={d} turns={d} duration_ms={d}]",
                .{ label, task_id, owned_result.?.text, owned_result.?.tokens, owned_result.?.turns, owned_result.?.duration_ms },
            ) catch return
        else if (owned_err) |e|
            std.fmt.allocPrint(
                self.allocator,
                "[Subagent '{s}' task_id={d} failed]\n{s}",
                .{ label, task_id, e },
            ) catch return
        else if (owned_result) |_|
            // Non-null but empty — subagent ran cleanly, no text output.
            // Tell the parent agent what to do next so the user doesn't
            // see an empty bubble.
            std.fmt.allocPrint(
                self.allocator,
                "[Subagent '{s}' task_id={d} completed with no output]\n" ++
                    "The subagent finished without emitting a plain-text final answer. " ++
                    "Options for the parent agent: (a) re-spawn with a more specific task brief, " ++
                    "(b) compute or answer directly without the subagent.",
                .{ label, task_id },
            ) catch return
        else
            std.fmt.allocPrint(
                self.allocator,
                "[Subagent '{s}' task_id={d} finished — no result captured]",
                .{ label, task_id },
            ) catch return;

        if (self.completion_delivery) |delivery| {
            defer self.allocator.free(content);
            log.info("subagent.delivery path=direct task_id={d} session_key={s}", .{ task_id, request_session_key });
            delivery(self.completion_delivery_ctx, request_session_key, content) catch |err| {
                log.err("subagent: failed to append local completion: {}", .{err});
            };
        } else if (self.bus) |b| {
            log.info("subagent.delivery path=bus task_id={d} session_key={s}", .{ task_id, request_session_key });
            const msg = bus_mod.makeInbound(
                self.allocator,
                origin_channel,
                "subagent",
                origin_chat_id,
                content,
                request_session_key,
            ) catch {
                self.allocator.free(content);
                return;
            };
            self.allocator.free(content);

            b.publishInbound(msg) catch |err| {
                msg.deinit(self.allocator);
                log.err("subagent: failed to publish result to bus: {}", .{err});
            };
        } else {
            // V1.14.4 (booth-readiness, subagent "received" bug fix).
            //
            // Pre-V1.14.4 this branch silently discarded the subagent's
            // result. Symptom: parent agent's reply contained "received"
            // or a generic completion fragment with NO subagent output —
            // the user-visible bug from `project_subagent_received_bug`.
            //
            // V1.14.4 closes ONE of the production paths that hit here
            // and partially mitigates the others:
            //
            //   - gateway.zig tenant init OOM on SubagentCompletionRouter
            //     allocation: PREVIOUSLY `catch null` silently degraded
            //     to bus-only delivery (and tenant bus has no consumer).
            //     V1.14.4 propagates the OOM as hard error so tenant
            //     init fails loudly rather than running with broken
            //     subagent delivery. This closes the OOM-at-init class.
            //
            //   - main.zig standalone CLI (line 2760, 3083): SubagentManager
            //     created with bus=null and no completion_delivery
            //     attached. NOT FIXED in V1.14.4 — the dispatch site
            //     never wires a delivery callback. Mitigation in this
            //     branch: Debug + ReleaseSafe builds (where
            //     std.debug.runtime_safety = true) dump the content to
            //     stderr so test runs and dev sessions surface it. CLI
            //     is rare for booth (gateway tenant is the demo path);
            //     full dispatch-site wiring tracked as F-2 for V1.14.5.
            //
            //   - gateway.zig:18485 (standalone-mode router create) STILL
            //     uses `catch null`. Same fix as the tenant path applies
            //     and is queued; V1.14.4 review HI-02 honest disclosure.
            //
            // ReleaseFast (production booth build) has runtime_safety=false:
            // stderr fallback does NOT fire, only the log.warn lands.
            // That's UX-degraded but not new behavior — same as pre-V1.14.4
            // on this branch. Release-build users still don't see the
            // result. Booth-week acceptable because the path that ships
            // (gateway tenant) is now closed.
            log.warn("subagent.delivery path=none task_id={d} — no bus or completion_delivery attached", .{task_id});
            if (std.debug.runtime_safety) {
                std.debug.print(
                    "[subagent fallback — task_id={d}]\n{s}\n",
                    .{ task_id, content },
                );
            }
            self.allocator.free(content);
        }

        // ── Mark durable row delivered (idempotency: first deliver wins) ──
        // Flip the outbox row from 'pending' to 'delivered' NOW that we
        // have successfully routed the result. If we crash here (after
        // delivery, before mark), recovery re-delivers once more — safe
        // because the parent's session dedup on task_id prevents a visible
        // duplicate. The mark is best-effort: a PG failure is logged but
        // does not block the wake.
        if (self.ledger_state_mgr) |sm| {
            if (result_id_slice) |rid| {
                sm.markSubagentResultDelivered(rid) catch |err|
                    log.warn("subagent: mark-delivered failed task_id={d}: {}", .{ task_id, err });
            }
        }

        // ── Wake parent turn (push, not poll) ──────────────────────────────
        // Enqueue a heartbeat wake for the parent's user so the daemon's
        // heartbeat thread drains it and fires a forced turn via
        // processMessageWithContext. This replaces any polling job.
        // Safe to call from the subagent thread: heartbeat_wake.enqueue()
        // is mutex-guarded and uses c_allocator internally.
        // Do NOT call processMessageWithContext directly from this thread.
        if (zaki_session.parseUserIdFromSessionKey(request_session_key)) |uid_str| {
            var rbuf: [64]u8 = undefined;
            const reason = std.fmt.bufPrint(&rbuf, "subagent_completion:{d}", .{task_id}) catch "subagent_completion";
            heartbeat_wake.enqueue(uid_str, reason) catch |err|
                log.warn("subagent: wake enqueue failed task_id={d}: {}", .{ task_id, err });
        }
    }

    /// Transition a queued task to running. Returns true if the
    /// transition happened. Returns false when the task is missing, has
    /// already been started, or was cancelled before the spawned thread
    /// got a chance to enter its run body (WP2.4). The thread path uses
    /// the return value to honor pre-execution cancellation without
    /// racing with cancelQueued.
    fn markTaskRunning(self: *SubagentManager, task_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            if (state.status == .queued) {
                state.status = .running;
                self.persistTaskSnapshotLocked(task_id, state);
                if (self.task_delivery) |td| {
                    var id_buf: [tasks_mod.ledger.TASK_ID_LEN]u8 = undefined;
                    if (formatCanonicalTaskId(&id_buf, task_id)) |id_slice| {
                        td.markRunning(id_slice) catch |err| {
                            log.warn("subagent: failed to mirror running status for task #{d}: {}", .{ task_id, err });
                        };
                    }
                }
                return true;
            }
        }
        return false;
    }

    /// Cancel a queued subagent task atomically (WP2.4). This is the only
    /// cancellation path supported in v0.1 — running tasks cannot be
    /// interrupted because the subagent thread owns the `ChannelRuntime`
    /// lifecycle and there is no cooperative interrupt point. Terminal
    /// tasks are not mutated. See CancelOutcome for the full result
    /// semantics.
    ///
    /// Concurrency: the manager mutex is held just long enough to flip
    /// the local status and persist the snapshot. The canonical ledger
    /// mirror happens outside the manager mutex via TaskDelivery's own
    /// lock — matching the lock order established elsewhere in this file
    /// (manager.mutex → td.mutex is always released-then-reacquired to
    /// keep the surface symmetric).
    pub fn cancelQueued(self: *SubagentManager, task_id: u64) CancelOutcome {
        var delivery_ref: ?*tasks_mod.TaskDelivery = null;
        const outcome = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const state = self.tasks.get(task_id) orelse break :blk CancelOutcome.not_found;
            switch (state.status) {
                .queued => {
                    state.status = .cancelled;
                    state.completed_at = std.time.milliTimestamp();
                    self.persistTaskSnapshotLocked(task_id, state);
                    delivery_ref = self.task_delivery;
                    break :blk CancelOutcome.cancelled;
                },
                .running => break :blk CancelOutcome.running,
                .completed, .failed, .cancelled => break :blk CancelOutcome.terminal,
            }
        };
        if (outcome == .cancelled) {
            if (delivery_ref) |td| {
                var id_buf: [tasks_mod.ledger.TASK_ID_LEN]u8 = undefined;
                if (formatCanonicalTaskId(&id_buf, task_id)) |id_slice| {
                    // cancelQueued on the canonical ledger is idempotent
                    // and returns a parallel outcome; we rely on the
                    // subagent-side decision as the source of truth and
                    // simply propagate the state.
                    _ = td.cancelQueued(id_slice);
                }
            }
        }
        return outcome;
    }
};

// ── Thread function ─────────────────────────────────────────────

fn subagentThreadFn(ctx: *ThreadContext) void {
    defer {
        ctx.manager.allocator.free(ctx.task);
        ctx.manager.allocator.free(ctx.label);
        ctx.manager.allocator.free(ctx.request_session_key);
        ctx.manager.allocator.free(ctx.origin_channel);
        ctx.manager.allocator.free(ctx.origin_chat_id);
        ctx.manager.allocator.destroy(ctx);
    }

    // WP2.4: honor pre-execution cancellation. If the task was cancelled
    // between spawn() and the thread's entry here, markTaskRunning will
    // decline the queued→running transition. In that case we must not
    // execute the injected runner or the full ChannelRuntime — just let
    // the thread exit so the cancelled state is observable by callers.
    if (!ctx.manager.markTaskRunning(ctx.task_id)) return;

    // Phase 2: measure wall-clock run duration (mark-running → completion) so
    // the SubagentResult carries `duration_ms`. This is the one piece of
    // metadata we can capture WITHOUT touching the agent-loop control flow.
    // turns/tokens/tools_used are NOT exposed by processMessageWithContext's
    // text-only return and the subagent's isolated ChannelRuntime carries no
    // usage_rt (that is gateway-wired only), so they stay at their zero
    // defaults here — Phase 3 may surface them if the loop is taught to.
    const run_started_at = std.time.milliTimestamp();

    // Test path: injected runner bypasses the full runtime (used in unit tests).
    if (ctx.manager.completion_runner) |runner| {
        const system_prompt = "You are a background subagent. Complete the assigned task concisely and accurately.";
        var test_arena = std.heap.ArenaAllocator.init(ctx.manager.allocator);
        defer test_arena.deinit();
        const result = runner(
            ctx.manager.completion_runner_ctx,
            test_arena.allocator(),
            system_prompt,
            ctx.task,
        ) catch |err| {
            ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
            return;
        };
        const dur_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - run_started_at));
        ctx.manager.completeTask(ctx.task_id, .{
            .status = .completed,
            .text = result,
            .duration_ms = dur_ms,
        }, null);
        return;
    }

    // Production path: full ChannelRuntime agent loop in an isolated task lane.
    // The subagent tool profile removes recursive spawn/delegate/message tools.
    var runtime = channel_loop.ChannelRuntime.initWithProfile(
        ctx.manager.allocator,
        ctx.manager.config_ref,
        null, // event_bus — deliberately omitted for proactive-message isolation
        .subagent,
    ) catch |err| {
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
        return;
    };
    defer runtime.deinit();

    // Phase 3 (Subagent Pass) — make the subagent's artifact_create functional
    // and capture what it produces.
    //
    // (1) The subagent runtime is built via allTools(.subagent), which registers
    //     artifact_create but leaves its state_mgr/user_id UNBOUND (the parent
    //     gateway binds those via bindStateMgrTenant; this isolated runtime never
    //     was). Bind them from the manager's ledger handles so the subagent
    //     persists artifacts to the SAME tenant schema/user as the parent —
    //     otherwise artifact_create returns "state manager not bound".
    if (ctx.manager.ledger_state_mgr) |sm| {
        if (ctx.manager.ledger_user_id) |uid| {
            tools_mod.bindStateMgrTenant(runtime.tools, sm, uid);
        }
    }

    // (2) Install an ArtifactCollector for this turn. We pass it as the
    //     `progress_observer` to processMessageWithContext (NOT via the
    //     thread-local setToolObserver, which the inner agent loop overwrites
    //     and then clears). The session combines base+progress into the turn's
    //     agent.observer, which the loop installs as the tool observer — so the
    //     artifact_create tool's emitted `artifact_event`s reach the collector.
    //     The collector owns its duped refs until deinit; completeTask
    //     deep-copies them into the manager allocator (dupeSubagentResult), so
    //     deinit after the handoff is UAF-free.
    var artifact_collector = subagent_result.ArtifactCollector.init(ctx.manager.allocator);
    defer artifact_collector.deinit();

    var session_buf: [128]u8 = undefined;
    const session_key = deriveTaskRuntimeSessionKey(&session_buf, ctx.request_session_key, ctx.task_id);

    // Subagent framing (S-tier hardening, 2026-05-23).
    //
    // The runtime here is a generic ChannelRuntime — without an explicit
    // subagent system-prompt override, the subagent inherits the full
    // parent-agent persona and tries to act as the main agent. In
    // practice this produced two failure modes (QA3 / QA4):
    //   1. The subagent loops on tool calls and ends without emitting a
    //      plain-text final answer → `[Subagent 'X' completed with no
    //      output]` reaches the parent, which can't relay anything useful.
    //   2. The subagent's "final reply" is a thinking trace ("I will…")
    //      not a self-contained answer the parent can paste.
    //
    // The fix: prepend a SUBAGENT TASK header to the user message that
    // tells the model exactly what role it's playing and what shape its
    // final answer must take. This works regardless of which system
    // prompt the runtime defaults to, doesn't require touching every
    // ChannelRuntime caller, and gives the parent agent a reliable
    // "answer-ready" string back. Bounded allocation, freed alongside
    // the result via the outer arena.
    const framed_task = std.fmt.allocPrint(
        ctx.manager.allocator,
        "[SUBAGENT TASK — task_id={d}]\n" ++
            "You are a background subagent. Do the work below in this single session, " ++
            "then close with a CLEAR, SELF-CONTAINED final-answer message in plain text " ++
            "(no thinking-trace, no `<tool_call>` markup). The parent agent will receive " ++
            "your final reply verbatim as a system message — write it so it can be relayed " ++
            "to the user without further editing. If you cannot complete the task, end with " ++
            "a one-line plain-text explanation starting with \"Could not complete: \".\n\n" ++
            "TASK:\n{s}",
        .{ ctx.task_id, ctx.task },
    ) catch |err| {
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
        return;
    };
    defer ctx.manager.allocator.free(framed_task);

    const result = runtime.session_mgr.processMessageWithContext(
        session_key,
        framed_task,
        null,
        .{
            .turn_origin = .proactive,
            // Phase 3: capture artifact_event emissions from the subagent's
            // tools into artifact_collector for the SubagentResult.
            .progress_observer = artifact_collector.observer(),
        },
    ) catch |err| {
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
        return;
    };
    defer ctx.manager.allocator.free(result);

    const dur_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - run_started_at));
    // Phase 3: hand the captured artifacts to completeTask, which deep-copies
    // them into the manager allocator (dupeSubagentResult) so they ride back to
    // the parent in the durable result_json + delivery. refs() is a borrowed
    // view valid until artifact_collector.deinit() (deferred above) — safe
    // because completeTask copies before this function returns.
    ctx.manager.completeTask(ctx.task_id, .{
        .status = .completed,
        .text = result,
        .duration_ms = dur_ms,
        .artifacts = artifact_collector.refs(),
    }, null);
}

fn summarizeTaskForDisplay(allocator: Allocator, task: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, task, " \t\r\n");
    const first_line = std.mem.sliceTo(trimmed, '\n');
    const clipped = if (first_line.len > 80) first_line[0..80] else first_line;
    return allocator.dupe(u8, clipped);
}

const LedgerSnapshot = struct {
    id: u64,
    status: TaskStatus,
    label: []u8,
    task_summary: []u8,
    task_prompt: []u8,
    session_key: ?[]u8 = null,
    runtime_session_key: ?[]u8 = null,
    origin_channel: ?[]u8 = null,
    origin_chat_id: ?[]u8 = null,
    result: ?[]u8 = null,
    error_msg: ?[]u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,

    fn deinit(self: *LedgerSnapshot, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.task_summary);
        allocator.free(self.task_prompt);
        if (self.session_key) |value| allocator.free(value);
        if (self.runtime_session_key) |value| allocator.free(value);
        if (self.origin_channel) |value| allocator.free(value);
        if (self.origin_chat_id) |value| allocator.free(value);
        if (self.result) |value| allocator.free(value);
        if (self.error_msg) |value| allocator.free(value);
    }
};

fn freeTaskState(allocator: Allocator, state: *TaskState) void {
    if (state.thread) |thread| thread.join();
    if (state.result) |*value| freeSubagentResult(allocator, value);
    if (state.error_msg) |value| allocator.free(value);
    if (state.session_key) |value| allocator.free(value);
    if (state.runtime_session_key) |value| allocator.free(value);
    if (state.origin_channel) |value| allocator.free(value);
    if (state.origin_chat_id) |value| allocator.free(value);
    if (state.batch_id) |value| allocator.free(value); // Phase 4
    allocator.free(state.label);
    allocator.free(state.task_summary);
    allocator.free(state.task_prompt);
    allocator.destroy(state);
}

pub fn taskStatusText(status: TaskStatus) []const u8 {
    return switch (status) {
        .queued => "queued",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

pub fn parseTaskStatus(raw: []const u8) TaskStatus {
    if (std.mem.eql(u8, raw, "queued")) return .queued;
    if (std.mem.eql(u8, raw, "running")) return .running;
    if (std.mem.eql(u8, raw, "completed")) return .completed;
    if (std.mem.eql(u8, raw, "cancelled")) return .cancelled;
    return .failed;
}

/// Format the durable outbox result_id for a given task_id.
/// Result is always "subagent:<task_id>" — stable, human-readable, unique per manager.
fn formatSubagentResultId(buf: []u8, task_id: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "subagent:{d}", .{task_id});
}

/// Free every slice owned by a `SubagentResult` stored in `TaskState.result`.
/// The result and all its slices (`text`, each `ArtifactRef`'s strings, every
/// `tools_used` entry plus the outer arrays, and `err`) are allocated in the
/// manager allocator by `dupeSubagentResult`. Call this everywhere the old
/// `state.result` text was freed. Idempotent only in the sense that it must be
/// called exactly once per stored result (no double-free): callers null the
/// field or replace it immediately after.
pub fn freeSubagentResult(allocator: Allocator, result: *const SubagentResult) void {
    allocator.free(result.text);
    for (result.artifacts) |art| {
        allocator.free(art.id);
        allocator.free(art.kind);
        allocator.free(art.title);
        allocator.free(art.url);
    }
    allocator.free(result.artifacts);
    for (result.tools_used) |name| allocator.free(name);
    allocator.free(result.tools_used);
    if (result.err) |e| allocator.free(e);
}

/// Deep-copy a `SubagentResult` into `allocator` so it outlives the source
/// (which is typically the subagent thread's arena). Mirrors how Phase 1 duped
/// the text result into the manager allocator. On any allocation failure the
/// partial copy is rolled back (no leak) and the error is propagated.
fn dupeSubagentResult(allocator: Allocator, src: SubagentResult) !SubagentResult {
    const text = try allocator.dupe(u8, src.text);
    errdefer allocator.free(text);

    const artifacts = try allocator.alloc(subagent_result.ArtifactRef, src.artifacts.len);
    var arts_done: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < arts_done) : (i += 1) {
            allocator.free(artifacts[i].id);
            allocator.free(artifacts[i].kind);
            allocator.free(artifacts[i].title);
            allocator.free(artifacts[i].url);
        }
        allocator.free(artifacts);
    }
    for (src.artifacts, 0..) |art, i| {
        const id = try allocator.dupe(u8, art.id);
        errdefer allocator.free(id);
        const kind = try allocator.dupe(u8, art.kind);
        errdefer allocator.free(kind);
        const title = try allocator.dupe(u8, art.title);
        errdefer allocator.free(title);
        const url = try allocator.dupe(u8, art.url);
        artifacts[i] = .{ .id = id, .kind = kind, .title = title, .url = url, .version = art.version };
        arts_done = i + 1;
    }

    const tools = try allocator.alloc([]const u8, src.tools_used.len);
    var tools_done: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < tools_done) : (i += 1) allocator.free(tools[i]);
        allocator.free(tools);
    }
    for (src.tools_used, 0..) |name, i| {
        tools[i] = try allocator.dupe(u8, name);
        tools_done = i + 1;
    }

    const err = if (src.err) |e| try allocator.dupe(u8, e) else null;

    return .{
        .status = src.status,
        .text = text,
        .artifacts = artifacts,
        .tokens = src.tokens,
        .turns = src.turns,
        .tools_used = tools,
        .err = err,
        .duration_ms = src.duration_ms,
    };
}

/// Build a minimal manager-owned `SubagentResult` from a recovered text
/// snapshot (file ledger / PG task-snapshot rows that only carry the text).
/// Used by the snapshot→TaskState rehydration paths, which historically stored
/// just the text. Status is inferred from the snapshot's task status.
fn subagentResultFromText(allocator: Allocator, status: TaskStatus, text: []const u8) !SubagentResult {
    const owned = try allocator.dupe(u8, text);
    return .{
        .status = if (status == .failed) .failed else .completed,
        .text = owned,
    };
}

fn isTaskSessionKey(session_key: []const u8) bool {
    return std.mem.startsWith(u8, session_key, "task:") or std.mem.indexOf(u8, session_key, ":task:") != null;
}

fn deriveTaskRuntimeSessionKey(buf: []u8, request_session_key: []const u8, task_id: u64) []const u8 {
    const user_id = zaki_session.parseUserIdFromSessionKey(request_session_key) orelse
        return std.fmt.bufPrint(buf, "subagent:{d}", .{task_id}) catch "subagent:bg";
    var task_id_buf: [32]u8 = undefined;
    const task_id_text = std.fmt.bufPrint(&task_id_buf, "{d}", .{task_id}) catch "0";
    return zaki_session.userTaskSessionKey(buf, user_id, task_id_text);
}

fn appendOptionalJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: ?[]const u8) !void {
    if (value) |resolved| {
        try json_util.appendJsonString(buf, allocator, resolved);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendLedgerSnapshot(allocator: Allocator, path: []const u8, task_id: u64, state: *const TaskState) !void {
    if (path.len == 0) return;
    try ensureLedgerParent(path);
    var file = openLedgerFileAppend(path) catch return;
    defer file.close();
    try file.seekFromEnd(0);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{");
    try buf.writer(allocator).print("\"id\":{d},", .{task_id});
    try buf.appendSlice(allocator, "\"status\":");
    try json_util.appendJsonString(&buf, allocator, taskStatusText(state.status));
    try buf.appendSlice(allocator, ",\"label\":");
    try json_util.appendJsonString(&buf, allocator, state.label);
    try buf.appendSlice(allocator, ",\"task_summary\":");
    try json_util.appendJsonString(&buf, allocator, state.task_summary);
    try buf.appendSlice(allocator, ",\"task_prompt\":");
    try json_util.appendJsonString(&buf, allocator, state.task_prompt);
    try buf.appendSlice(allocator, ",\"session_key\":");
    try appendOptionalJsonString(&buf, allocator, state.runtime_session_key orelse state.session_key);
    try buf.appendSlice(allocator, ",\"request_session_key\":");
    try appendOptionalJsonString(&buf, allocator, state.session_key);
    try buf.appendSlice(allocator, ",\"runtime_session_key\":");
    try appendOptionalJsonString(&buf, allocator, state.runtime_session_key);
    try buf.appendSlice(allocator, ",\"origin_channel\":");
    try appendOptionalJsonString(&buf, allocator, state.origin_channel);
    try buf.appendSlice(allocator, ",\"origin_chat_id\":");
    try appendOptionalJsonString(&buf, allocator, state.origin_chat_id);
    try buf.appendSlice(allocator, ",\"result\":");
    // Phase 2: the file ledger persists the text only (legacy recovery path);
    // the structured result rides in the PG durable outbox via completeTask.
    try appendOptionalJsonString(&buf, allocator, if (state.result) |r| r.text else null);
    try buf.appendSlice(allocator, ",\"error\":");
    try appendOptionalJsonString(&buf, allocator, state.error_msg);
    try buf.writer(allocator).print(",\"started_at\":{d},\"completed_at\":", .{state.started_at});
    if (state.completed_at) |value| {
        try buf.writer(allocator).print("{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}\n");
    _ = try file.write(buf.items);
}

fn parseLedgerSnapshot(allocator: Allocator, raw: []const u8) !LedgerSnapshot {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTaskLedgerEntry;
    const obj = parsed.value.object;
    const id_value = obj.get("id") orelse return error.InvalidTaskLedgerEntry;
    if (id_value != .integer) return error.InvalidTaskLedgerEntry;
    const label = objectString(obj, "label") orelse return error.InvalidTaskLedgerEntry;
    const task_summary = objectString(obj, "task_summary") orelse label;
    const task_prompt = objectString(obj, "task_prompt") orelse task_summary;
    const status_text = objectString(obj, "status") orelse return error.InvalidTaskLedgerEntry;
    const started_value = obj.get("started_at") orelse return error.InvalidTaskLedgerEntry;
    if (started_value != .integer) return error.InvalidTaskLedgerEntry;
    const request_session_value = objectString(obj, "request_session_key") orelse objectString(obj, "session_key");
    const runtime_session_value = blk: {
        if (objectString(obj, "runtime_session_key")) |value| break :blk value;
        if (objectString(obj, "request_session_key")) |request_value| {
            var session_buf: [128]u8 = undefined;
            break :blk deriveTaskRuntimeSessionKey(&session_buf, request_value, @intCast(id_value.integer));
        }
        break :blk null;
    };

    return .{
        .id = @intCast(id_value.integer),
        .status = parseTaskStatus(status_text),
        .label = try allocator.dupe(u8, label),
        .task_summary = try allocator.dupe(u8, task_summary),
        .task_prompt = try allocator.dupe(u8, task_prompt),
        .session_key = if (request_session_value) |value| try allocator.dupe(u8, value) else null,
        .runtime_session_key = if (runtime_session_value) |value| try allocator.dupe(u8, value) else null,
        .origin_channel = if (objectString(obj, "origin_channel")) |value| try allocator.dupe(u8, value) else null,
        .origin_chat_id = if (objectString(obj, "origin_chat_id")) |value| try allocator.dupe(u8, value) else null,
        .result = if (objectString(obj, "result")) |value| try allocator.dupe(u8, value) else null,
        .error_msg = if (objectString(obj, "error")) |value| try allocator.dupe(u8, value) else null,
        .started_at = started_value.integer,
        .completed_at = if (obj.get("completed_at")) |value| switch (value) {
            .integer => value.integer,
            else => null,
        } else null,
    };
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn ensureLedgerParent(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (std.fs.path.isAbsolute(dir)) {
        try makeAbsolutePath(dir);
    } else {
        try std.fs.cwd().makePath(dir);
    }
}

fn makeAbsolutePath(path: []const u8) !void {
    if (path.len == 0) return;
    if (std.fs.openDirAbsolute(path, .{})) |opened_dir| {
        var dir = opened_dir;
        dir.close();
        return;
    } else |_| {}
    if (std.fs.path.dirname(path)) |parent| {
        if (!std.mem.eql(u8, parent, path)) try makeAbsolutePath(parent);
    }
    try std.fs.makeDirAbsolute(path);
}

fn openLedgerFileAppend(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = false, .read = true });
    return std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
}

fn openLedgerFileRead(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

// ── Tests ───────────────────────────────────────────────────────

test "SubagentManager init and deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u64, 1), mgr.next_id);
    try std.testing.expect(mgr.bus == null);
}

test "SubagentConfig defaults" {
    // 2026-05-24 (v1.14.20): commercial caps removed. max_iterations is now
    // maxInt(u32) — goal_loop + loop-detected handle pathological cases.
    // max_concurrent is 64 — a pure host-RAM ceiling, not a commercial gate.
    // See SubagentConfig field docs for full rationale.
    const sc = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), sc.max_iterations);
    try std.testing.expectEqual(@as(u32, 64), sc.max_concurrent);
}

test "TaskStatus enum values" {
    try std.testing.expect(@intFromEnum(TaskStatus.queued) != @intFromEnum(TaskStatus.running));
    try std.testing.expect(@intFromEnum(TaskStatus.running) != @intFromEnum(TaskStatus.completed));
    try std.testing.expect(@intFromEnum(TaskStatus.completed) != @intFromEnum(TaskStatus.failed));
}

test "TaskState initial defaults" {
    const state = TaskState{
        .status = .queued,
        .label = "test",
        .task_summary = "do test work",
        .task_prompt = "do test work",
        .started_at = 0,
    };
    try std.testing.expect(state.result == null);
    try std.testing.expect(state.error_msg == null);
    try std.testing.expect(state.completed_at == null);
    try std.testing.expect(state.thread == null);
}

test "SubagentManager getRunningCount empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

test "SubagentManager getTaskStatus unknown id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskStatus(999) == null);
}

test "SubagentManager getTaskResult unknown id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskResult(999) == null);
}

test "SubagentManager completeTask updates state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    // Manually insert a task state to test completeTask
    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "test-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "do test work"),
        .task_prompt = try std.testing.allocator.dupe(u8, "do test work"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    _ = mgr.markTaskRunning(1);
    try std.testing.expectEqual(TaskStatus.running, mgr.getTaskStatus(1).?);
    mgr.completeTask(1, .{ .status = .completed, .text = "done!" }, null);

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(1).?);
    // getTaskResultText returns the text (the manual-query/task_get path).
    try std.testing.expectEqualStrings("done!", mgr.getTaskResultText(1).?);
    // getTaskResult returns the full structured value.
    try std.testing.expectEqual(subagent_result.Status.completed, mgr.getTaskResult(1).?.status);
}

// ── Task 2.2 test: a completed task's stored SubagentResult carries metadata ──

test "completeTask stores structured SubagentResult metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "meta-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "carry metadata"),
        .task_prompt = try std.testing.allocator.dupe(u8, "carry metadata"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);
    _ = mgr.markTaskRunning(1);

    // Drive completeTask with a fully-populated SubagentResult (slices live in
    // test memory; completeTask dupes them into the manager allocator).
    const tools = [_][]const u8{ "shell", "produce_document" };
    mgr.completeTask(1, .{
        .status = .completed,
        .text = "structured answer",
        .tokens = 4321,
        .turns = 5,
        .tools_used = &tools,
        .duration_ms = 999,
    }, null);

    // Read it back via getTaskResult and assert every field survived the dupe.
    const got = mgr.getTaskResult(1).?;
    try std.testing.expectEqual(subagent_result.Status.completed, got.status);
    try std.testing.expectEqualStrings("structured answer", got.text);
    try std.testing.expectEqual(@as(u64, 4321), got.tokens);
    try std.testing.expectEqual(@as(u32, 5), got.turns);
    try std.testing.expectEqual(@as(u64, 999), got.duration_ms);
    try std.testing.expectEqual(@as(usize, 2), got.tools_used.len);
    try std.testing.expectEqualStrings("shell", got.tools_used[0]);
    try std.testing.expectEqualStrings("produce_document", got.tools_used[1]);
    // The stored slices must be manager-owned copies, NOT the test's stack slice.
    try std.testing.expect(got.tools_used.ptr != &tools);
}

test "SubagentManager completeTask with error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "fail-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "will fail"),
        .task_prompt = try std.testing.allocator.dupe(u8, "will fail"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    _ = mgr.markTaskRunning(1);
    mgr.completeTask(1, null, "timeout");

    try std.testing.expectEqual(TaskStatus.failed, mgr.getTaskStatus(1).?);
    try std.testing.expect(mgr.getTaskResult(1) == null);
}

test "SubagentManager completeTask routes via bus" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "bus-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "publish result"),
        .task_prompt = try std.testing.allocator.dupe(u8, "publish result"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .origin_channel = try std.testing.allocator.dupe(u8, "telegram"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "12345"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    _ = mgr.markTaskRunning(1);
    mgr.completeTask(1, .{ .status = .completed, .text = "result text" }, null);

    // Check bus received the message — verify depth increased
    var msg = try waitForInboundMessage(&bus, 50);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("12345", msg.chat_id);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", msg.session_key);
}

test "SubagentManager completeTask falls back to local completion delivery without bus" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "local-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "publish local result"),
        .task_prompt = try std.testing.allocator.dupe(u8, "publish local result"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:thread:main"),
        .origin_channel = try std.testing.allocator.dupe(u8, "agent"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "chat-1"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    _ = mgr.markTaskRunning(1);
    mgr.completeTask(1, .{ .status = .completed, .text = "result text" }, null);

    try std.testing.expect(recorder.session_key != null);
    try std.testing.expect(recorder.content != null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:thread:main", recorder.session_key.?);
    try std.testing.expect(std.mem.indexOf(u8, recorder.content.?, "result text") != null);
}

// ── TENANT-MODE REGRESSION TEST ─────────────────────────────────────
//
// When BOTH bus AND completion_delivery are attached (production tenant
// mode: gateway.zig:1274 sets bus, :1372 attaches completion_delivery),
// the direct callback MUST fire, not the bus publish. The bus inbound
// queue has no consumer in tenant mode (daemon.run() does not run);
// bus-only delivery meant sub-agent results vanished.
//
// This test locks in the precedence: completion_delivery wins over bus
// when both are set. See .planning/DELEGATION-DIAGNOSIS.md for full trace.
test "SubagentManager completeTask prefers completion_delivery over bus when both attached (tenant mode)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    // Mirror tenant runtime wiring: bus AND completion_delivery both attached.
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "tenant-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "tenant delivery check"),
        .task_prompt = try std.testing.allocator.dupe(u8, "tenant delivery check"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:7:main"),
        .origin_channel = try std.testing.allocator.dupe(u8, "zaki_app"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "chat-app-7"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    _ = mgr.markTaskRunning(1);
    mgr.completeTask(1, .{ .status = .completed, .text = "tenant result payload" }, null);

    // completion_delivery recorder must have received the content.
    try std.testing.expect(recorder.session_key != null);
    try std.testing.expect(recorder.content != null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:7:main", recorder.session_key.?);
    try std.testing.expect(std.mem.indexOf(u8, recorder.content.?, "tenant result payload") != null);

    // Bus must NOT have received the inbound message (precedence enforced).
    // Note: consumeInbound() blocks on empty-open queue; close first so it
    // returns null on drained instead of deadlocking the test.
    bus.close();
    try std.testing.expect(bus.consumeInbound() == null);
}

test "SubagentManager spawn stores session key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const task_id = try mgr.spawn("quick task", "session-check", "session:42", "agent", "session:42");
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const state = mgr.tasks.get(task_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.session_key != null);
    try std.testing.expect(state.runtime_session_key != null);
    try std.testing.expectEqualStrings("session:42", state.session_key.?);
    try std.testing.expectEqualStrings("subagent:1", state.runtime_session_key.?);
    try std.testing.expect(state.task_summary.len > 0);
}

test "SubagentManager spawn derives canonical user task runtime session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const task_id = try mgr.spawn("ship fix", "canonical-lane", "agent:zaki-bot:user:42:main", "agent", "session:42");
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const state = mgr.tasks.get(task_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", state.session_key.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:task:1", state.runtime_session_key.?);
}

test "SubagentManager spawn falls back to local runtime session when requester is non-canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const task_id = try mgr.spawn("ship fix", "fallback-lane", "session:ephemeral", "agent", "session:ephemeral");
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const state = mgr.tasks.get(task_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("session:ephemeral", state.session_key.?);
    try std.testing.expectEqualStrings("subagent:1", state.runtime_session_key.?);
}

test "taskStateFromSnapshot derives runtime lane for legacy requester-only snapshot" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    var snapshot = zaki_state.TaskSnapshot{
        .id = try std.testing.allocator.dupe(u8, "7"),
        .session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .request_session_id = null,
        .label = try std.testing.allocator.dupe(u8, "legacy"),
        .prompt = try std.testing.allocator.dupe(u8, "repair legacy"),
        .status = try std.testing.allocator.dupe(u8, "completed"),
        .result = null,
        .error_msg = null,
        .created_at_ms = 42,
        .started_at_ms = 42,
        .completed_at_ms = 84,
    };
    defer snapshot.deinit(std.testing.allocator);

    const state = try mgr.taskStateFromSnapshot(&snapshot);
    defer freeTaskState(std.testing.allocator, state);

    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", state.session_key.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:task:7", state.runtime_session_key.?);
}

test "taskStateFromSnapshot preserves explicit requester and runtime lanes" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    var snapshot = zaki_state.TaskSnapshot{
        .id = try std.testing.allocator.dupe(u8, "9"),
        .session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:task:9"),
        .request_session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .label = try std.testing.allocator.dupe(u8, "modern"),
        .prompt = try std.testing.allocator.dupe(u8, "preserve split"),
        .status = try std.testing.allocator.dupe(u8, "completed"),
        .result = null,
        .error_msg = null,
        .created_at_ms = 42,
        .started_at_ms = 42,
        .completed_at_ms = 84,
    };
    defer snapshot.deinit(std.testing.allocator);

    const state = try mgr.taskStateFromSnapshot(&snapshot);
    defer freeTaskState(std.testing.allocator, state);

    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", state.session_key.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:task:9", state.runtime_session_key.?);
}

test "summarizeTaskForDisplay clips first line for founder-readable task truth" {
    const summary = try summarizeTaskForDisplay(std.testing.allocator, "first line task\nsecond line detail");
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings("first line task", summary);
}

test "SubagentManager recovers completed task from file ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    {
        var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
        mgr.completion_runner = immediateCompletionRunner;
        defer mgr.deinit();

        const task_id = try mgr.spawn("recover me", "recover", "agent:zaki-bot:user:1:main", "agent", "session:recover");
        try waitForTaskTerminal(&mgr, task_id, 2_000);
    }

    var recovered = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer recovered.deinit();

    try std.testing.expectEqual(@as(u64, 2), recovered.next_id);
    try std.testing.expectEqual(TaskStatus.completed, recovered.getTaskStatus(1).?);
    try std.testing.expectEqualStrings("completed: recover me", recovered.getTaskResultText(1).?);
}

test "SubagentManager recovery marks in-flight task as failed explicitly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ workspace, "state", TASK_LEDGER_FILE_NAME });
    defer std.testing.allocator.free(ledger_path);
    try ensureLedgerParent(ledger_path);

    const state = TaskState{
        .status = .running,
        .label = "recover",
        .task_summary = "recover",
        .task_prompt = "recover prompt",
        .session_key = "agent:zaki-bot:user:1:main",
        .started_at = 42,
    };
    try appendLedgerSnapshot(std.testing.allocator, ledger_path, 7, &state);

    var recovered = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer recovered.deinit();

    try std.testing.expectEqual(TaskStatus.failed, recovered.getTaskStatus(7).?);
    const task_state = recovered.tasks.get(7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(RECOVERY_FAILURE_REASON, task_state.error_msg.?);
}

test "SubagentManager spawn rollback removes task on out-of-memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = alloc,
    };
    var mgr = SubagentManager.init(alloc, &cfg, null, .{});
    defer mgr.deinit();

    try mgr.tasks.ensureTotalCapacity(alloc, 1);
    failing.fail_index = failing.alloc_index + 4;

    try std.testing.expectError(
        error.OutOfMemory,
        mgr.spawn("oom-task", "oom-label", "session:oom", "agent", "session:oom"),
    );
    try std.testing.expectEqual(@as(usize, 0), mgr.tasks.count());
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

fn waitForTaskTerminal(mgr: *SubagentManager, task_id: u64, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        const status = mgr.getTaskStatus(task_id) orelse return error.TestUnexpectedResult;
        if (status == .completed or status == .failed or status == .cancelled) return;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn waitForInboundMessage(bus: *bus_mod.Bus, timeout_ms: u64) !bus_mod.InboundMessage {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (bus.consumeInbound()) |msg| return msg;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn waitForActiveRunnerCount(runner: *BlockingCompletionRunner, expected_active: usize, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        runner.mutex.lock();
        const active = runner.active;
        runner.mutex.unlock();
        if (active >= expected_active) return;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn immediateCompletionRunner(_: ?*anyopaque, allocator: Allocator, system_prompt: []const u8, task: []const u8) ![]const u8 {
    try std.testing.expect(system_prompt.len > 0);
    return std.fmt.allocPrint(allocator, "completed: {s}", .{task});
}

fn failingCompletionRunner(_: ?*anyopaque, _: Allocator, _: []const u8, _: []const u8) ![]const u8 {
    return error.SubagentRunnerFailure;
}

const BlockingCompletionRunner = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    release: bool = false,
    active: usize = 0,
    peak_active: usize = 0,

    fn run(ctx: ?*anyopaque, allocator: Allocator, _: []const u8, task: []const u8) ![]const u8 {
        const self: *BlockingCompletionRunner = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        self.active += 1;
        if (self.active > self.peak_active) self.peak_active = self.active;
        while (!self.release) {
            self.cond.wait(&self.mutex);
        }
        self.active -= 1;
        self.mutex.unlock();
        return std.fmt.allocPrint(allocator, "released: {s}", .{task});
    }

    fn releaseAll(self: *BlockingCompletionRunner) void {
        self.mutex.lock();
        self.release = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }
};

// ── Task 1.6 tests: startup recovery ─────────────────────────────────

// Non-PG unit test: calling recoverPendingSubagentResults on a manager
// with ledger_state_mgr=null is a clean no-op — no crash, no wake enqueued.
// This runs locally (no Postgres required) and must be GREEN.
test "recoverPendingSubagentResults with null ledger_state_mgr is a no-op" {
    heartbeat_wake.clearForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);
    defer mgr.deinit();

    // ledger_state_mgr is null — must return immediately with no side effects.
    mgr.recoverPendingSubagentResults(42);

    // No wake must have been enqueued.
    try std.testing.expectEqual(@as(usize, 0), heartbeat_wake.pendingCount());
    // No delivery must have happened.
    try std.testing.expect(recorder.content == null);
}

// PG-guarded recovery test: seed a pending row, call recovery, assert a wake
// was enqueued for the user and the row is now marked delivered.
// Skips cleanly when Postgres is not configured (local / CI without DB).
test "recoverPendingSubagentResults re-delivers and wakes for pending rows" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(
        allocator,
        "NULLALIS_POSTGRES_TEST_URL",
        "NULLCLAW_POSTGRES_TEST_URL",
    ) catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    heartbeat_wake.clearForTest();

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}_recover", .{std.time.microTimestamp()});
    const state_cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var state_mgr = try zaki_state.Manager.init(allocator, state_cfg);
    defer state_mgr.deinit();

    // Cleanup on exit.
    {
        const pg_helpers = @import("memory/engines/postgres.zig");
        const schema_q = try pg_helpers.quoteIdentifier(allocator, state_mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const res = try state_mgr.exec(drop_q);
        _ = res;
    }
    try state_mgr.migrate();

    // Seed one pending row for user_id=42, session_key contains "user:42".
    try state_mgr.upsertSubagentResult(.{
        .result_id = "subagent:77",
        .user_id = 42,
        .session_key = "agent:zaki-bot:user:42:main",
        .task_id = 77,
        .result_json = "{\"status\":\"completed\",\"text\":\"recovered answer\"}",
    });

    // Build a manager with the PG ledger and a recording delivery.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    var mgr = SubagentManager.init(allocator, &cfg, null, .{});
    defer mgr.deinit();
    // Attach ledger FIRST (mirrors gateway.zig wiring order).
    mgr.attachPostgresLedger(&state_mgr, 42);
    // Attach delivery SECOND — triggers recovery.
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);

    // A wake must have been enqueued for user "42".
    const req = heartbeat_wake.dequeue();
    try std.testing.expect(req != null);
    var mutable_req = req.?;
    defer mutable_req.deinit();
    try std.testing.expectEqualStrings("42", mutable_req.user_id.?);
    try std.testing.expect(std.mem.indexOf(u8, mutable_req.reason, "subagent_completion:recovered") != null);

    // The delivery callback must have been called — with the task_id in the
    // header AND (Phase 2, Task 2.3) the rehydrated result text from the row.
    try std.testing.expect(recorder.content != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.content.?, "77") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.content.?, "recovered answer") != null);

    // The row must now be marked delivered (not pending).
    const rows = try state_mgr.loadPendingSubagentResults(allocator, 42);
    defer {
        for (rows) |r| r.deinit(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 0), rows.len);

    // Drop test schema.
    {
        const pg_helpers = @import("memory/engines/postgres.zig");
        const schema_q = try pg_helpers.quoteIdentifier(allocator, state_mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        const res = try state_mgr.exec(drop_q);
        _ = res;
    }
}

// ── Task 2.3 test: recovery re-hydrates the FULL result text ──────────
// Seed a pending row whose result_json is a complete SubagentResult (status,
// text, metadata) — exactly what Phase-2 completeTask now writes — and assert
// recovery delivers the actual ANSWER TEXT (not a bare marker). PG-guarded;
// skips cleanly without a test Postgres.
test "recoverPendingSubagentResults re-hydrates full result text from durable row" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(
        allocator,
        "NULLALIS_POSTGRES_TEST_URL",
        "NULLCLAW_POSTGRES_TEST_URL",
    ) catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    heartbeat_wake.clearForTest();

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}_rehydrate", .{std.time.microTimestamp()});
    const state_cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var state_mgr = try zaki_state.Manager.init(allocator, state_cfg);
    defer state_mgr.deinit();

    {
        const pg_helpers = @import("memory/engines/postgres.zig");
        const schema_q = try pg_helpers.quoteIdentifier(allocator, state_mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        _ = try state_mgr.exec(drop_q);
    }
    try state_mgr.migrate();

    // Build the durable payload exactly the way Phase-2 completeTask does:
    // serialize a full SubagentResult via toJsonAlloc.
    const seeded = SubagentResult{
        .status = .completed,
        .text = "the fully rehydrated answer body",
        .tokens = 2048,
        .turns = 4,
        .duration_ms = 1234,
    };
    const seeded_json = try seeded.toJsonAlloc(allocator);
    defer allocator.free(seeded_json);

    try state_mgr.upsertSubagentResult(.{
        .result_id = "subagent:91",
        .user_id = 42,
        .session_key = "agent:zaki-bot:user:42:main",
        .task_id = 91,
        .result_json = seeded_json,
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    var mgr = SubagentManager.init(allocator, &cfg, null, .{});
    defer mgr.deinit();
    mgr.attachPostgresLedger(&state_mgr, 42);
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);

    // Wake enqueued for the user.
    const req = heartbeat_wake.dequeue();
    try std.testing.expect(req != null);
    var mutable_req = req.?;
    defer mutable_req.deinit();
    try std.testing.expectEqualStrings("42", mutable_req.user_id.?);

    // The delivered content must carry the ACTUAL answer text (rehydrated from
    // the full SubagentResult JSON), plus the task_id for correlation.
    try std.testing.expect(recorder.content != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.content.?, "the fully rehydrated answer body") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.content.?, "91") != null);

    // Row marked delivered.
    const rows = try state_mgr.loadPendingSubagentResults(allocator, 42);
    defer {
        for (rows) |r| r.deinit(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 0), rows.len);

    {
        const pg_helpers = @import("memory/engines/postgres.zig");
        const schema_q = try pg_helpers.quoteIdentifier(allocator, state_mgr.schemaRaw());
        defer allocator.free(schema_q);
        const drop_q = try std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_q});
        defer allocator.free(drop_q);
        _ = try state_mgr.exec(drop_q);
    }
}

// ── Task 1.5 test: duplicate completion is idempotent ─────────────────

test "duplicate completion of same task_id is idempotent (no double wake)" {
    heartbeat_wake.clearForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "idem-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "idempotency check"),
        .task_prompt = try std.testing.allocator.dupe(u8, "idempotency check"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:42:main"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 7, state);

    _ = mgr.markTaskRunning(7);
    // First completion: delivers + enqueues one wake
    mgr.completeTask(7, .{ .status = .completed, .text = "first result" }, null);

    // Second completion for the same task_id: task is already terminal.
    // Drain the queue BEFORE the second call so coalescing can't mask double-enqueue
    {
        const first_req = heartbeat_wake.dequeue();
        try std.testing.expect(first_req != null);
        var mutable_first = first_req.?;
        defer mutable_first.deinit();
    }
    // Queue must now be empty
    try std.testing.expectEqual(@as(usize, 0), heartbeat_wake.pendingCount());

    // Remember what the recorder captured from the first delivery
    const first_content_len = if (recorder.content) |c| c.len else @as(usize, 0);

    // In-memory guard: completeTask sees state.status==.completed → skips deliver+wake entirely.
    mgr.completeTask(7, .{ .status = .completed, .text = "second result — must be ignored" }, null);

    // No additional wake must have been enqueued
    try std.testing.expectEqual(@as(usize, 0), heartbeat_wake.pendingCount());

    // The recorder content must NOT have changed (no second delivery)
    const second_content_len = if (recorder.content) |c| c.len else @as(usize, 0);
    try std.testing.expectEqual(first_content_len, second_content_len);
}

// ── Task 1.4 test: completeTask enqueues a heartbeat wake ─────────────

test "completeTask enqueues a heartbeat wake for the parent user" {
    heartbeat_wake.clearForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "wake-test-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "test wake enqueue"),
        .task_prompt = try std.testing.allocator.dupe(u8, "test wake enqueue"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:42:main"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 7, state);

    _ = mgr.markTaskRunning(7);
    mgr.completeTask(7, .{ .status = .completed, .text = "wake result" }, null);

    const req = heartbeat_wake.dequeue();
    try std.testing.expect(req != null);
    var mutable_req = req.?;
    defer mutable_req.deinit();
    try std.testing.expect(std.mem.indexOf(u8, mutable_req.reason, "subagent_completion") != null);
    // user_id "42" must be present so the daemon wakes the right user
    try std.testing.expectEqualStrings("42", mutable_req.user_id.?);
}

// ── Task 1.3 test: formatSubagentResultId ─────────────────────────────

test "formatSubagentResultId formats stable id" {
    var buf: [40]u8 = undefined;
    const id = try formatSubagentResultId(&buf, 7);
    try std.testing.expectEqualStrings("subagent:7", id);
}

test "formatSubagentResultId handles large task_id" {
    var buf: [40]u8 = undefined;
    const id = try formatSubagentResultId(&buf, 123456789);
    try std.testing.expectEqualStrings("subagent:123456789", id);
}

const RecordingCompletionDelivery = struct {
    session_key: ?[]const u8 = null,
    content: ?[]const u8 = null,

    fn run(ctx: ?*anyopaque, session_key: []const u8, content: []const u8) !void {
        const self: *RecordingCompletionDelivery = @ptrCast(@alignCast(ctx.?));
        if (self.session_key) |value| std.testing.allocator.free(value);
        if (self.content) |value| std.testing.allocator.free(value);
        self.session_key = try std.testing.allocator.dupe(u8, session_key);
        self.content = try std.testing.allocator.dupe(u8, content);
    }

    fn deinit(self: *RecordingCompletionDelivery) void {
        if (self.session_key) |value| std.testing.allocator.free(value);
        if (self.content) |value| std.testing.allocator.free(value);
    }
};

test "SubagentManager spawn e2e completes and publishes bus message" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    mgr.completion_runner = immediateCompletionRunner;
    defer mgr.deinit();

    const task_id = try mgr.spawn("summarize this", "e2e", "session:e2e", "agent", "session:e2e");
    try waitForTaskTerminal(&mgr, task_id, 2_000);

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(task_id).?);
    try std.testing.expectEqualStrings("completed: summarize this", mgr.getTaskResultText(task_id).?);
    var msg = try waitForInboundMessage(&bus, 250);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("agent", msg.channel);
    try std.testing.expectEqualStrings("session:e2e", msg.chat_id);
    try std.testing.expectEqualStrings("session:e2e", msg.session_key);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "completed: summarize this") != null);
}

// ── Baseline characterization tests (Phase 00-01) ───────────────

test "baseline: SubagentConfig max_iterations is uncapped (v1.14.20 central-meter shift)" {
    // 2026-05-24 (v1.14.20): commercial-cap removal. goal_loop's ReAct
    // reflection + loop-detected on byte-identical repeats are the real
    // governors; per-loop iteration count is no longer.
    const cfg = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), cfg.max_iterations);
}

test "baseline: SubagentConfig max_concurrent defaults to 64 (host-RAM ceiling)" {
    // 2026-05-24 (v1.14.20): raised 8 → 64. This is a host-RAM safety
    // ceiling (each subagent ≈ 50-100 MB; 64 × ≈ 3-6 GB), not a commercial
    // gate. Provider rate-limits + central usage meter govern actual
    // fan-out. Matches Manus Wide Research shape (their 100 is per-task VM;
    // ours is per-runtime).
    const cfg = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, 64), cfg.max_concurrent);
}

test "baseline: TaskStatus has exactly 5 states" {
    // Characterize the complete set of task states: queued, running, completed, failed, cancelled (WP2.4)
    const info = @typeInfo(TaskStatus);
    try std.testing.expectEqual(@as(usize, 5), info.@"enum".fields.len);
    // Verify each state exists and has expected ordinal
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(TaskStatus.queued));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(TaskStatus.running));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(TaskStatus.completed));
    try std.testing.expectEqual(@as(u3, 3), @intFromEnum(TaskStatus.failed));
    try std.testing.expectEqual(@as(u3, 4), @intFromEnum(TaskStatus.cancelled));
}

test "baseline: TaskState tracks required lifecycle fields" {
    // Use @hasField instead of runtime iteration (comptime-safe in Zig 0.15).
    try std.testing.expect(@hasField(TaskState, "status"));
    try std.testing.expect(@hasField(TaskState, "label"));
    try std.testing.expect(@hasField(TaskState, "session_key"));
    try std.testing.expect(@hasField(TaskState, "runtime_session_key"));
    try std.testing.expect(@hasField(TaskState, "result"));
    try std.testing.expect(@hasField(TaskState, "started_at"));
    try std.testing.expect(@hasField(TaskState, "completed_at"));
}

test "baseline: SubagentManager init respects custom config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{
        .max_concurrent = 8,
        .max_iterations = 30,
    });
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u32, 8), mgr.config.max_concurrent);
    try std.testing.expectEqual(@as(u32, 30), mgr.config.max_iterations);
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

test "baseline: SubagentManager getTaskStatus returns null for unknown task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskStatus(99999) == null);
    try std.testing.expect(mgr.getTaskResult(99999) == null);
}

test "baseline: TASK_LEDGER_FILE_NAME is subagent_tasks.jsonl" {
    try std.testing.expectEqualStrings("subagent_tasks.jsonl", TASK_LEDGER_FILE_NAME);
}

test "SubagentManager spawn stress enforces live concurrency limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const concurrency_cap: u32 = 8;
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var runner = BlockingCompletionRunner{};
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{
        .max_concurrent = concurrency_cap,
    });
    mgr.completion_runner = BlockingCompletionRunner.run;
    mgr.completion_runner_ctx = @ptrCast(&runner);
    defer mgr.deinit();

    var task_ids: [8]u64 = undefined;
    for (&task_ids, 0..) |*task_id, i| {
        task_id.* = try mgr.spawn("stress task", "stress", "session:stress", "agent", "session:stress");
        _ = i;
    }

    const extra = mgr.spawn("overflow", "stress", "session:stress", "agent", "session:stress");
    try std.testing.expectError(error.TooManyConcurrentSubagents, extra);
    try waitForActiveRunnerCount(&runner, concurrency_cap, 2_000);

    runner.releaseAll();

    for (task_ids) |task_id| {
        try waitForTaskTerminal(&mgr, task_id, 2_000);
        try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(task_id).?);
    }

    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
    try std.testing.expectEqual(@as(usize, concurrency_cap), runner.peak_active);
}

// ── WP2.1: TaskDelivery bridge ─────────────────────────────────────

test "SubagentManager attached TaskDelivery mirrors queued/running/succeeded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    var ledger_inst = tasks_mod.TaskLedger.init(std.testing.allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = tasks_mod.TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = immediateCompletionRunner;
    mgr.attachTaskDelivery(&delivery);
    defer mgr.deinit();

    const task_id = try mgr.spawn("bridge me", "bridge", "session:bridge", "agent", "session:bridge");
    try waitForTaskTerminal(&mgr, task_id, 2_000);

    var id_buf: [tasks_mod.ledger.TASK_ID_LEN]u8 = undefined;
    const id_slice = try std.fmt.bufPrint(&id_buf, "task_{x:0>11}", .{task_id});
    const entry = ledger_inst.getTask(id_slice) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tasks_mod.TaskStatus.succeeded, entry.status);
    try std.testing.expectEqualStrings("session:bridge", entry.owner_session);
}

test "SubagentManager attached TaskDelivery mirrors failed status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    var ledger_inst = tasks_mod.TaskLedger.init(std.testing.allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = tasks_mod.TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = failingCompletionRunner;
    mgr.attachTaskDelivery(&delivery);
    defer mgr.deinit();

    const task_id = try mgr.spawn("fail me", "bridge", "session:bridge", "agent", "session:bridge");
    try waitForTaskTerminal(&mgr, task_id, 2_000);

    var id_buf: [tasks_mod.ledger.TASK_ID_LEN]u8 = undefined;
    const id_slice = try std.fmt.bufPrint(&id_buf, "task_{x:0>11}", .{task_id});
    const entry = ledger_inst.getTask(id_slice) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tasks_mod.TaskStatus.failed, entry.status);
}

test "V4: SubagentManager defaults to the owned ledger bridge (default-on)" {
    // v1.14.18 Step 7 (V4) — a manager built without an explicit
    // `attachTaskDelivery` is no longer detached: `init` seeds
    // `task_delivery` from a manager-owned in-memory fallback so its
    // subagent lifecycle IS mirrored to a real TaskLedger.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = immediateCompletionRunner;
    defer mgr.deinit();

    // The bridge is wired by default, pointing at the manager's owned fallback.
    const delivery = mgr.task_delivery orelse return error.TestUnexpectedResult;
    try std.testing.expect(mgr._owned_fallback != null);
    try std.testing.expectEqual(mgr._owned_fallback.?.delivery, delivery);

    const task_id = try mgr.spawn("default bridge", "solo", "session:solo", "agent", "session:solo");
    try waitForTaskTerminal(&mgr, task_id, 2_000);
    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(task_id).?);

    // The task landed in the owned ledger.
    var id_buf: [tasks_mod.ledger.TASK_ID_LEN]u8 = undefined;
    const id_slice = try std.fmt.bufPrint(&id_buf, "task_{x:0>11}", .{task_id});
    const entry = delivery.ledger.getTask(id_slice) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tasks_mod.TaskStatus.succeeded, entry.status);
}

// ── WP2.4: honest queued-only cancellation ─────────────────────────

test "taskStatusText round-trips cancelled" {
    try std.testing.expectEqualStrings("cancelled", taskStatusText(TaskStatus.cancelled));
    try std.testing.expectEqual(TaskStatus.cancelled, parseTaskStatus("cancelled"));
}

test "SubagentManager cancelQueued transitions queued task to cancelled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    // Use a blocking runner so the task stays queued/running long enough
    // for us to observe state — but insert directly to avoid the thread.
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "cancel-me"),
        .task_summary = try std.testing.allocator.dupe(u8, "cancel summary"),
        .task_prompt = try std.testing.allocator.dupe(u8, "cancel prompt"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    try std.testing.expectEqual(SubagentManager.CancelOutcome.cancelled, mgr.cancelQueued(1));
    try std.testing.expectEqual(TaskStatus.cancelled, mgr.getTaskStatus(1).?);
}

test "SubagentManager cancelQueued refuses running task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "running"),
        .task_summary = try std.testing.allocator.dupe(u8, "running summary"),
        .task_prompt = try std.testing.allocator.dupe(u8, "running prompt"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    try std.testing.expectEqual(SubagentManager.CancelOutcome.running, mgr.cancelQueued(1));
    try std.testing.expectEqual(TaskStatus.running, mgr.getTaskStatus(1).?);
}

test "SubagentManager cancelQueued refuses terminal task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .completed,
        .label = try std.testing.allocator.dupe(u8, "done"),
        .task_summary = try std.testing.allocator.dupe(u8, "done summary"),
        .task_prompt = try std.testing.allocator.dupe(u8, "done prompt"),
        .result = .{ .status = .completed, .text = try std.testing.allocator.dupe(u8, "ok") },
        .started_at = std.time.milliTimestamp(),
        .completed_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    try std.testing.expectEqual(SubagentManager.CancelOutcome.terminal, mgr.cancelQueued(1));
    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(1).?);
}

test "SubagentManager cancelQueued returns not_found for unknown id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    try std.testing.expectEqual(SubagentManager.CancelOutcome.not_found, mgr.cancelQueued(999));
}

test "SubagentManager cancelQueued mirrors canonical cancelled outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    var ledger_inst = tasks_mod.TaskLedger.init(std.testing.allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = tasks_mod.TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    // Block the runner so the task stays queued until we cancel it.
    var runner = BlockingCompletionRunner{};
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = BlockingCompletionRunner.run;
    mgr.completion_runner_ctx = @ptrCast(&runner);
    mgr.attachTaskDelivery(&delivery);
    defer mgr.deinit();

    // Insert a queued task directly — no thread spawned — so we can prove
    // the mirror path without racing with markTaskRunning.
    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "mirror-cancel"),
        .task_summary = try std.testing.allocator.dupe(u8, "mirror cancel summary"),
        .task_prompt = try std.testing.allocator.dupe(u8, "mirror cancel prompt"),
        .session_key = try std.testing.allocator.dupe(u8, "session:mirror"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 42, state);
    _ = try delivery.createTaskWithNumericId(state.task_summary, state.session_key.?, 42);

    try std.testing.expectEqual(SubagentManager.CancelOutcome.cancelled, mgr.cancelQueued(42));
    try std.testing.expectEqual(TaskStatus.cancelled, mgr.getTaskStatus(42).?);

    var id_buf: [tasks_mod.ledger.TASK_ID_LEN]u8 = undefined;
    const id_slice = try std.fmt.bufPrint(&id_buf, "task_{x:0>11}", .{@as(u64, 42)});
    const entry = ledger_inst.getTask(id_slice) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tasks_mod.TaskStatus.cancelled, entry.status);
}

test "SubagentManager cancelled queued task does not execute completion_runner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    const TrackingRunner = struct {
        var invocations: std.atomic.Value(u32) = .{ .raw = 0 };

        fn reset() void {
            invocations.store(0, .monotonic);
        }

        fn run(_: ?*anyopaque, allocator: Allocator, _: []const u8, task: []const u8) ![]const u8 {
            _ = invocations.fetchAdd(1, .monotonic);
            return std.fmt.allocPrint(allocator, "ran: {s}", .{task});
        }
    };
    TrackingRunner.reset();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = TrackingRunner.run;
    defer mgr.deinit();

    // Hold the manager mutex so the just-spawned thread is blocked
    // trying to enter markTaskRunning. While it waits, we flip the task
    // to cancelled. When we release the mutex, the thread observes
    // cancelled via markTaskRunning returning false and bails out.
    mgr.mutex.lock();
    const task_id = try spawnWhileLocked(&mgr, "cancel-before-run", "bg", "session:cbr", "agent", "session:cbr");
    try std.testing.expect(mgr.tasks.get(task_id) != null);
    // Directly flip the state — cancelQueued would try to take the
    // mutex we already hold, deadlocking. The end result is the same
    // transition cancelQueued would perform.
    const state = mgr.tasks.get(task_id).?;
    state.status = .cancelled;
    state.completed_at = std.time.milliTimestamp();
    mgr.mutex.unlock();

    try waitForTaskTerminal(&mgr, task_id, 2_000);
    try std.testing.expectEqual(TaskStatus.cancelled, mgr.getTaskStatus(task_id).?);
    try std.testing.expectEqual(@as(u32, 0), TrackingRunner.invocations.load(.monotonic));
}

// Lock-aware variant of SubagentManager.spawn used only in the
// cancel-before-run test: spawn acquires the manager mutex, which is
// already held by the test. This helper is a thin duplicate that skips
// the initial lock so the test can race cancellation against thread
// startup without deadlocking.
fn spawnWhileLocked(
    mgr: *SubagentManager,
    task: []const u8,
    label: []const u8,
    request_session_key: []const u8,
    origin_channel: []const u8,
    origin_chat_id: []const u8,
) !u64 {
    if (mgr.getRunningCountLocked() >= mgr.config.max_concurrent)
        return error.TooManyConcurrentSubagents;

    const task_id = mgr.next_id;
    mgr.next_id += 1;

    const state = try mgr.allocator.create(TaskState);
    const state_label = try mgr.allocator.dupe(u8, label);
    const state_task_summary = try summarizeTaskForDisplay(mgr.allocator, task);
    const state_prompt = try mgr.allocator.dupe(u8, task);
    const state_session = try mgr.allocator.dupe(u8, request_session_key);
    var runtime_session_buf: [128]u8 = undefined;
    const runtime_session_text = deriveTaskRuntimeSessionKey(&runtime_session_buf, request_session_key, task_id);
    const state_runtime_session = try mgr.allocator.dupe(u8, runtime_session_text);
    const state_channel = try mgr.allocator.dupe(u8, origin_channel);
    const state_chat = try mgr.allocator.dupe(u8, origin_chat_id);
    state.* = .{
        .status = .queued,
        .label = state_label,
        .task_summary = state_task_summary,
        .task_prompt = state_prompt,
        .session_key = state_session,
        .runtime_session_key = state_runtime_session,
        .origin_channel = state_channel,
        .origin_chat_id = state_chat,
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(mgr.allocator, task_id, state);

    const task_copy = try mgr.allocator.dupe(u8, task);
    const label_copy = try mgr.allocator.dupe(u8, label);
    const request_session_copy = try mgr.allocator.dupe(u8, request_session_key);
    const origin_channel_copy = try mgr.allocator.dupe(u8, origin_channel);
    const origin_chat_copy = try mgr.allocator.dupe(u8, origin_chat_id);

    const ctx = try mgr.allocator.create(ThreadContext);
    ctx.* = .{
        .manager = mgr,
        .task_id = task_id,
        .task = task_copy,
        .label = label_copy,
        .request_session_key = request_session_copy,
        .origin_channel = origin_channel_copy,
        .origin_chat_id = origin_chat_copy,
    };

    state.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, subagentThreadFn, .{ctx});
    return task_id;
}

// ── Phase 4 Group 2 tests (TDD — written before implementation) ───────────────

test "spawnInBatch tags task with batch_id and registers" {
    // spawnMany 1 spec → the task's TaskState.batch_id == the returned batch_id
    // AND mgr.batches.batchOf(tid) == batch_id.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = immediateCompletionRunner;
    defer mgr.deinit();

    const specs = [_]SubagentManager.SpawnSpec{.{ .task = "research topic A", .label = "la" }};
    const handle = try mgr.spawnMany(&specs, "agent:zaki-bot:user:1:main", "agent", "chat:1", 60_000);
    defer {
        std.testing.allocator.free(handle.batch_id);
        std.testing.allocator.free(handle.task_ids);
    }

    try std.testing.expectEqual(@as(usize, 1), handle.task_ids.len);
    try std.testing.expectEqual(@as(usize, 1), handle.requested);
    const tid = handle.task_ids[0];

    // task's batch_id field matches
    mgr.mutex.lock();
    const state = mgr.tasks.get(tid) orelse {
        mgr.mutex.unlock();
        return error.TestUnexpectedResult;
    };
    const task_bid = state.batch_id orelse {
        mgr.mutex.unlock();
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(handle.batch_id, task_bid);

    // tracker index also maps tid → batch_id
    const tracker_bid = mgr.batches.batchOf(tid) orelse {
        mgr.mutex.unlock();
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(handle.batch_id, tracker_bid);
    mgr.mutex.unlock();
}

test "spawnMany fans out N under one batch within capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{ .max_concurrent = 8 });
    mgr.completion_runner = immediateCompletionRunner;
    defer mgr.deinit();

    const specs = [_]SubagentManager.SpawnSpec{
        .{ .task = "research A", .label = "la" },
        .{ .task = "research B", .label = "lb" },
        .{ .task = "research C", .label = "lc" },
    };
    const handle = try mgr.spawnMany(&specs, "agent:zaki-bot:user:2:main", "agent", "chat:2", 60_000);
    defer {
        std.testing.allocator.free(handle.batch_id);
        std.testing.allocator.free(handle.task_ids);
    }

    try std.testing.expectEqual(@as(usize, 3), handle.task_ids.len);
    try std.testing.expectEqual(@as(usize, 3), handle.requested);

    // All task_ids share the same batch_id; tracker knows all 3
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const tracker_tids = mgr.batches.taskIds(handle.batch_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), tracker_tids.len);

    for (handle.task_ids) |tid| {
        const st = mgr.tasks.get(tid) orelse return error.TestUnexpectedResult;
        const bid = st.batch_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(handle.batch_id, bid);
    }
}

test "spawnMany rejects when N > remaining capacity (all-or-nothing, no partial)" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{ .max_concurrent = 2 });
    mgr.completion_runner = immediateCompletionRunner;
    defer mgr.deinit();

    const specs = [_]SubagentManager.SpawnSpec{
        .{ .task = "A", .label = "la" },
        .{ .task = "B", .label = "lb" },
        .{ .task = "C", .label = "lc" }, // exceeds max_concurrent=2
    };
    const result = mgr.spawnMany(&specs, "agent:zaki-bot:user:3:main", "agent", "chat:3", 60_000);
    try std.testing.expectError(error.TooManyConcurrentSubagents, result);

    // No tasks should have been spawned (running count unchanged = 0)
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}
