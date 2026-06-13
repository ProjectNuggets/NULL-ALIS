//! SubagentResult — structured value object returned by a subagent on completion.
//!
//! Phase 2 of the Subagent Pass replaces the text-only `result: ?[]const u8`
//! on `TaskState` with this struct so the parent agent receives metadata
//! (status, token/turn counts, tools used, duration) alongside the final
//! answer text. The struct serializes to/from the durable outbox row's
//! `result_json` column (no table change — same column the Phase-1 minimal
//! `{status,text}` payload used).
//!
//! Ownership: a `SubagentResult` stored in `TaskState.result` is owned by the
//! SubagentManager's allocator (its `text` and every slice it points at). The
//! manager dupes the incoming result's slices on `completeTask` and frees them
//! via `freeSubagentResult` (in subagent.zig). A `Parsed` returned by
//! `fromJsonAlloc` owns its memory via an arena — call `deinit` to free it.

const std = @import("std");
const observability = @import("observability.zig");

test "ArtifactCollector captures artifact_event into ArtifactRef" {
    const a = std.testing.allocator;
    var collector = ArtifactCollector.init(a);
    defer collector.deinit();
    const obs = collector.observer();
    const evt = observability.ObserverEvent{ .artifact_event = .{
        .op = "created",
        .artifact_id = "art_9",
        .title = "Doc",
        .kind = "markdown",
        .version = 1,
        .url = "/api/v1/artifacts/art_9",
    } };
    obs.recordEvent(&evt);
    const refs = collector.refs();
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("art_9", refs[0].id);
    try std.testing.expectEqualStrings("markdown", refs[0].kind);
    try std.testing.expectEqualStrings("Doc", refs[0].title);
    try std.testing.expectEqualStrings("/api/v1/artifacts/art_9", refs[0].url);
    try std.testing.expectEqual(@as(u64, 1), refs[0].version);
}

test "ArtifactCollector ignores non-create/update ops and other events" {
    const a = std.testing.allocator;
    var collector = ArtifactCollector.init(a);
    defer collector.deinit();
    const obs = collector.observer();
    // A delete op must NOT be captured (only created/updated surface artifacts).
    const del = observability.ObserverEvent{ .artifact_event = .{
        .op = "deleted",
        .artifact_id = "art_x",
        .title = "Gone",
        .kind = "markdown",
        .version = 2,
        .url = "/api/v1/artifacts/art_x",
    } };
    obs.recordEvent(&del);
    try std.testing.expectEqual(@as(usize, 0), collector.refs().len);
    // An updated op IS captured.
    const upd = observability.ObserverEvent{ .artifact_event = .{
        .op = "updated",
        .artifact_id = "art_y",
        .title = "V2",
        .kind = "html",
        .version = 2,
        .url = "/api/v1/artifacts/art_y",
    } };
    obs.recordEvent(&upd);
    try std.testing.expectEqual(@as(usize, 1), collector.refs().len);
    try std.testing.expectEqual(@as(u64, 2), collector.refs()[0].version);
}

/// Test-only observer that counts artifact_events and remembers the last id.
const CountingArtifactObserver = struct {
    count: usize = 0,
    last_id_buf: [64]u8 = undefined,
    last_id_len: usize = 0,

    const vt = observability.Observer.VTable{
        .record_event = rec,
        .record_metric = noMetric,
        .flush = noFlush,
        .name = nm,
    };
    fn observer(self: *CountingArtifactObserver) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vt };
    }
    fn rec(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *CountingArtifactObserver = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .artifact_event => |ae| {
                self.count += 1;
                const n = @min(ae.artifact_id.len, self.last_id_buf.len);
                @memcpy(self.last_id_buf[0..n], ae.artifact_id[0..n]);
                self.last_id_len = n;
            },
            else => {},
        }
    }
    fn noMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn noFlush(_: *anyopaque) void {}
    fn nm(_: *anyopaque) []const u8 {
        return "counting-artifact";
    }
    fn lastId(self: *CountingArtifactObserver) []const u8 {
        return self.last_id_buf[0..self.last_id_len];
    }
};

test "resurfaceArtifacts re-emits one artifact_event per ArtifactRef" {
    var counter = CountingArtifactObserver{};
    const obs = counter.observer();
    const result = SubagentResult{
        .status = .completed,
        .text = "done",
        .artifacts = &.{
            .{ .id = "art_1", .kind = "markdown", .title = "Report", .url = "/api/v1/artifacts/art_1", .version = 1 },
            .{ .id = "art_2", .kind = "html", .title = "Page", .url = "/api/v1/artifacts/art_2", .version = 2 },
        },
    };
    resurfaceArtifacts(obs, result);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
    try std.testing.expectEqualStrings("art_2", counter.lastId());
}

test "resurfaceArtifacts on an empty artifacts slice emits nothing" {
    var counter = CountingArtifactObserver{};
    const obs = counter.observer();
    const result = SubagentResult{ .status = .completed, .text = "no artifacts" };
    resurfaceArtifacts(obs, result);
    try std.testing.expectEqual(@as(usize, 0), counter.count);
}

test "SubagentResult round-trips through JSON" {
    const a = std.testing.allocator;
    const original = SubagentResult{
        .status = .completed,
        .text = "the answer",
        .artifacts = &.{.{ .id = "art_1", .kind = "markdown", .title = "Report", .url = "/api/v1/artifacts/art_1", .version = 1 }},
        .tokens = 1234,
        .turns = 3,
        .tools_used = &.{ "shell", "produce_document" },
        .err = null,
        .duration_ms = 4200,
    };
    const json = try original.toJsonAlloc(a);
    defer a.free(json);

    // The Status enum MUST serialize as its tag name, not an integer.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"completed\"") != null);

    var parsed = try SubagentResult.fromJsonAlloc(a, json);
    defer parsed.deinit(a);
    try std.testing.expectEqual(Status.completed, parsed.value.status);
    try std.testing.expectEqualStrings("the answer", parsed.value.text);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.artifacts.len);
    try std.testing.expectEqualStrings("art_1", parsed.value.artifacts[0].id);
    try std.testing.expectEqualStrings("markdown", parsed.value.artifacts[0].kind);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.artifacts[0].version);
    try std.testing.expectEqual(@as(u64, 1234), parsed.value.tokens);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.turns);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tools_used.len);
    try std.testing.expectEqualStrings("shell", parsed.value.tools_used[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.err);
    try std.testing.expectEqual(@as(u64, 4200), parsed.value.duration_ms);
}

test "SubagentResult round-trips a failed status with err and defaults" {
    const a = std.testing.allocator;
    const original = SubagentResult{
        .status = .failed,
        .text = "",
        .err = "boom",
    };
    const json = try original.toJsonAlloc(a);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"failed\"") != null);

    var parsed = try SubagentResult.fromJsonAlloc(a, json);
    defer parsed.deinit(a);
    try std.testing.expectEqual(Status.failed, parsed.value.status);
    try std.testing.expectEqualStrings("", parsed.value.text);
    try std.testing.expect(parsed.value.err != null);
    try std.testing.expectEqualStrings("boom", parsed.value.err.?);
    // Defaulted fields round-trip to their zero values.
    try std.testing.expectEqual(@as(usize, 0), parsed.value.artifacts.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tools_used.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.tokens);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.turns);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.duration_ms);
}

/// Terminal disposition of a subagent run. Serializes to its tag name
/// ("completed" / "failed" / "timeout") — verified by the round-trip test.
pub const Status = enum { completed, failed, timeout };

/// A reference to a user-visible artifact a subagent produced. Phase 3
/// populates `SubagentResult.artifacts` with these; in Phase 2 the field
/// stays empty but the type exists so the JSON shape is stable.
pub const ArtifactRef = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    url: []const u8,
    version: u64 = 1,
};

pub const SubagentResult = struct {
    status: Status,
    text: []const u8,
    artifacts: []const ArtifactRef = &.{},
    tokens: u64 = 0,
    turns: u32 = 0,
    tools_used: []const []const u8 = &.{},
    err: ?[]const u8 = null,
    duration_ms: u64 = 0,

    /// Serialize to a freshly allocated JSON string (caller frees). Mirrors
    /// the `std.json.Stringify.valueAlloc` idiom used throughout this tree
    /// (e.g. completeTask's Phase-1 persist, user_settings.zig). In Zig
    /// 0.15.2 std this renders a plain `enum` as its tag-name string, so
    /// `Status.completed` becomes `"completed"` (asserted in the round-trip
    /// test) — no custom `jsonStringify` needed.
    pub fn toJsonAlloc(self: SubagentResult, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    /// Arena-backed parse result. `value` points into `arena`; call `deinit`
    /// (which frees the arena and destroys it) to release everything.
    pub const Parsed = struct {
        value: SubagentResult,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };

    /// Parse a JSON string (as produced by `toJsonAlloc`) into an owned
    /// `Parsed`. Uses `parseFromSliceLeaky` into an arena so the nested
    /// slices (`text`, `artifacts`, `tools_used`, `err`) all live in one
    /// arena freed by `Parsed.deinit`. `ignore_unknown_fields` keeps forward
    /// compatibility if a future phase adds fields to the payload.
    pub fn fromJsonAlloc(allocator: std.mem.Allocator, json: []const u8) !Parsed {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const value = try std.json.parseFromSliceLeaky(
            SubagentResult,
            arena.allocator(),
            json,
            .{ .ignore_unknown_fields = true },
        );
        return .{ .value = value, .arena = arena };
    }
};

/// ArtifactCollector — thread-local observer installed for a subagent's agent
/// loop (Phase 3, Subagent Pass). It captures every `artifact_event` the
/// subagent's `artifact_create`/`artifact_update` tools emit and accumulates
/// them as owned `ArtifactRef`s. At completion, `refs()` is handed to the
/// `SubagentResult` built for `completeTask`, which deep-copies the slice into
/// the manager allocator (`dupeSubagentResult`) — so the collector can `deinit`
/// safely after the handoff with no use-after-free across the thread→manager
/// boundary.
///
/// Observer contract: this implements the real four-function `Observer.VTable`
/// from observability.zig (`record_event` / `record_metric` / `flush` /
/// `name`), exposed through the `.vtable` pointer form (NOT the simplified
/// `{ ptr, record_event }` the plan sketched). `recordEvent` must be safe to
/// call from multiple threads per the Observer contract — the internal
/// `mutex` guards the list (the subagent agent loop can fan out to parallel
/// workers that share this observer).
///
/// Chaining: if a previous tool observer is already installed when the
/// collector goes in, pass it as `next` so each event is forwarded after
/// capture and nothing that already worked (e.g. an SSE forwarder) breaks. In
/// the common subagent case the previous observer is the runtime's noop, so
/// `next` is typically null.
pub const ArtifactCollector = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(ArtifactRef) = .{},
    mutex: std.Thread.Mutex = .{},
    /// Optional downstream observer to forward events to after capturing.
    next: ?observability.Observer = null,

    const vtable = observability.Observer.VTable{
        .record_event = recordEventThunk,
        .record_metric = recordMetricThunk,
        .flush = flushThunk,
        .name = nameThunk,
    };

    pub fn init(allocator: std.mem.Allocator) ArtifactCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ArtifactCollector) void {
        for (self.list.items) |r| {
            self.allocator.free(r.id);
            self.allocator.free(r.kind);
            self.allocator.free(r.title);
            self.allocator.free(r.url);
        }
        self.list.deinit(self.allocator);
        self.list = .{};
    }

    pub fn observer(self: *ArtifactCollector) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Borrowed view of the captured refs. Valid until `deinit`. The caller
    /// (completeTask) deep-copies these into the manager allocator.
    pub fn refs(self: *ArtifactCollector) []const ArtifactRef {
        return self.list.items;
    }

    fn recordEventThunk(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *ArtifactCollector = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .artifact_event => |ae| {
                // Only created/updated surface a user-visible artifact; ignore
                // any other op (e.g. delete) so the parent never re-surfaces a
                // removed artifact.
                if (std.mem.eql(u8, ae.op, "created") or std.mem.eql(u8, ae.op, "updated")) {
                    self.captureLocked(ae);
                }
            },
            else => {},
        }
        // Chain: forward the untouched event downstream after capture so an
        // already-installed observer keeps working.
        if (self.next) |n| n.recordEvent(event);
    }

    fn captureLocked(self: *ArtifactCollector, ae: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Dupe every borrowed slice — the ObserverEvent payload is only valid
        // for the duration of recordEvent (mirrors artifact_event lifetime).
        // captureLocked returns void (never error-returns), so cleanup on an
        // allocation/append failure is done explicitly on each path — every
        // slice already duped is freed before bailing, so there is no leak and
        // no partial ArtifactRef in the list.
        const ref = buildOwnedRef(self.allocator, ae) orelse return;
        self.list.append(self.allocator, ref) catch {
            self.allocator.free(ref.id);
            self.allocator.free(ref.kind);
            self.allocator.free(ref.title);
            self.allocator.free(ref.url);
        };
    }

    /// Dupe the four borrowed slices into owned memory, returning a complete
    /// ArtifactRef or null on the first allocation failure (freeing whatever
    /// was already duped). Keeps captureLocked's success path linear.
    fn buildOwnedRef(allocator: std.mem.Allocator, ae: anytype) ?ArtifactRef {
        const id = allocator.dupe(u8, ae.artifact_id) catch return null;
        const kind = allocator.dupe(u8, ae.kind) catch {
            allocator.free(id);
            return null;
        };
        const title = allocator.dupe(u8, ae.title) catch {
            allocator.free(id);
            allocator.free(kind);
            return null;
        };
        const url = allocator.dupe(u8, ae.url) catch {
            allocator.free(id);
            allocator.free(kind);
            allocator.free(title);
            return null;
        };
        return .{ .id = id, .kind = kind, .title = title, .url = url, .version = ae.version };
    }

    fn recordMetricThunk(ptr: *anyopaque, metric: *const observability.ObserverMetric) void {
        const self: *ArtifactCollector = @ptrCast(@alignCast(ptr));
        if (self.next) |n| n.recordMetric(metric);
    }

    fn flushThunk(ptr: *anyopaque) void {
        const self: *ArtifactCollector = @ptrCast(@alignCast(ptr));
        if (self.next) |n| n.flush();
    }

    fn nameThunk(_: *anyopaque) []const u8 {
        return "subagent-artifact-collector";
    }
};

/// Re-emit each `ArtifactRef` from a completed `SubagentResult` as an
/// `artifact_event` (op "created") on the parent's LIVE observer, so the FE
/// side panel surfaces the subagent's deliverables when the completion reaches
/// the parent (Phase 3, Subagent Pass). The artifacts were already persisted by
/// the subagent's `artifact_create` under the SAME tenant schema/user, so this
/// re-emits only the EVENT — no content re-upload. Read-only over `result`; the
/// borrowed slices live for the duration of each `recordEvent` call (mirrors
/// the artifact_event payload lifetime), which is exactly the producer
/// contract `RunEventObserver` and the FE SSE bridge already honor.
pub fn resurfaceArtifacts(obs: observability.Observer, result: SubagentResult) void {
    for (result.artifacts) |ref| {
        const evt = observability.ObserverEvent{ .artifact_event = .{
            .op = "created",
            .artifact_id = ref.id,
            .title = ref.title,
            .kind = ref.kind,
            .version = ref.version,
            .url = ref.url,
        } };
        obs.recordEvent(&evt);
    }
}
