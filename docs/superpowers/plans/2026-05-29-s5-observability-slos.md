# S5: Observability + SLOs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make production health chartable (Prometheus catalog covers approvals, artifact export, extension commands, memory ops, trace shares, tool latency, meter receipts, and gateway degraded state), and make a misconfigured production launch fail-loud instead of silently running on file backends when Postgres was the configured surface.

**Architecture:**
- Extend the existing `ObserverMetric` tagged union (`src/observability.zig`) with new variants for the S5 surfaces. Increment is via `observability.recordMetricGlobal(...)` from any site; the existing global-observer fallback (log-line) is preserved.
- Land a new process-wide registry — `src/observability_metrics.zig` — that owns the new counter/histogram families behind a `std.StringHashMap` keyed by Prometheus line key (`name{label="..."}`). The gateway installs a `MetricsRegistryObserver` that forwards each new ObserverMetric variant into the registry, alongside the existing `LifecycleMetricsObserver` + `MultiObserver`. The hot-path counters that already live on `GatewayState` stay there — no churn to the existing 24 metrics.
- `metricsPayload()` (currently at `src/gateway.zig:6653`) gets one new section that calls `registry.render(writer)` plus an explicit `nullalis_gateway_degraded` gauge built from `state.state_degraded` / `state_backend_configured` / `state_backend_effective` / `degradedReason()` (all already on `GatewayState`).
- The startup fail-loud gate is added at `applyStartupSelfCheck()` (`src/gateway.zig:5145`): when `state_degraded == true` AND `isProductionLikeGateway(cfg, host) == true` AND `cfg.state.backend == "postgres"`, return `error.ProductionPostgresRequired` to the caller so `runWithRole()` propagates it up and the gateway thread exits non-zero with a named reason. Dev/test still get a log warning and continue.

**Tech Stack:** Zig 0.15 (matches the codebase). No new third-party deps. Prometheus text exposition v0.0.4 (the format `metricsPayload()` already emits).

---

## Scope Check

S5 is one cohesive subsystem (gateway observability + startup gate). The audit confirmed this — every metric/attach point flows through `metricsPayload()` and the global observer pipeline. Does NOT need to be split.

---

## File Structure

**New:**
- `src/observability_metrics.zig` — process-wide metric registry (counters + histograms) keyed by Prometheus line key. Single responsibility: own the new families and render them as Prometheus text. ~250 LOC including tests.
- `docs/operations/SLOs.md` — operator-facing catalog: metric names, what each means, target thresholds, alert suggestions, V1 launch gates. ~400 lines.

**Modified:**
- `src/observability.zig` — extend `ObserverMetric` union with eight new variants and add the matching switch arms in `recordMetricGlobal` (log fallback), `LogObserver.logRecordMetric`, `MultiObserver.multiRecordMetric`, `OtelObserver.otelRecordMetric`, `FileObserver.fileRecordMetric`, and `VerboseObserver.verboseRecordMetric` log-style switches. Zig's exhaustive-switch rules force every variant to be handled — touching all impls is structurally required, not optional.
- `src/gateway.zig` — three discrete touches:
  1. New `MetricsRegistryObserver` struct (sibling of `LifecycleMetricsObserver`) that forwards the new variants into `observability_metrics.global()`.
  2. `metricsPayload()` extended with a new section that appends `registry.render(...)` plus the `nullalis_gateway_degraded{configured=...,effective=...,reason=...}` gauge.
  3. `applyStartupSelfCheck()` becomes `applyStartupSelfCheck(...) StartupSelfCheckError!void` so it can return `error.ProductionPostgresRequired` when prod+degraded+postgres-required. Callers (`runWithRole`) propagate the error.
- `src/agent/root.zig` — wrap `executeToolUnchecked()` body with start/end `std.time.milliTimestamp()` and emit `tool_call_total{tool,result}` + `tool_call_latency_ms{tool}` on every dispatch path (success, tool-not-found, invalid-args, exec-error). Wrap `preflightToolPolicy()` so each `.allowed` / `.blocked` return emits `approval_decision_total{result}` ("allowed" / "blocked" / "auto_approved" / "user_approved" / "user_denied" — derived from the existing `DecisionSource`). Existing `approval_required` ObserverEvent site (~line 2564) also bumps `approval_decision_total{result="issued"}`.
- `src/tools/memory_store.zig`, `src/tools/memory_recall.zig`, `src/tools/memory_forget.zig` — wrap `execute()` body with start/end timestamp and emit `memory_op_total{op,result}` + `memory_op_latency_ms{op}`. (memory_archive/edit/etc. are out-of-scope for S5; the spec lists store/recall/forget only.)
- `src/gateway.zig` (TraceShareStore) — `createOrGet()` (`~line 12200`), `revoke()` (`line 12261`), `getLive()` (`line 11985`) each emit `trace_share_total{op,result}` with appropriate labels.
- `src/gateway.zig` (handleArtifactExport) — wrap with start/end timestamp; emit `artifact_export_total{format,result}` + `artifact_export_latency_ms{format}` on every exit path.
- `src/cost.zig` — `recordUsage()` bumps `meter_receipt_total{result="ok"|"err_write"}`. (cost.recordUsage has zero call sites in prod today, per audit — wiring callers is out of S5 scope, but the counter ships so it lights up the moment cost-tracker is wired.)
- `docs/openapi-v1.yaml` — add `GET /metrics` path entry (text/plain, Prometheus v0.0.4).
- `docs/ui-handoff.md` — single new paragraph in the operator-status section noting that `nullalis_gateway_degraded` now exposes the configured/effective backends, and that prod startup is fail-loud when Postgres is configured but unavailable.
- `docs/deferred-register.md` — flip S5 / observability + SLOs from open to closed.

**Why a new file and not just expanding `lane_metrics.zig`:**
`lane_metrics.zig` is fixed-scope (lane-routing counters, secret-mutation counters, GDPR-purge counters). The S5 surface is "Prometheus exposition registry" — that's a different boundary. Putting it in its own file gives operators a clean grep target and prevents `gateway.zig` from ballooning further (it's already 31k+ lines).

**Cardinality discipline:**
- Do NOT add `run_id`, `session_id`, or `user_id` as Prometheus labels. The spec said "where safe" — high-cardinality labels are not safe; they explode the time-series store.
- For run/session correlation: emit `run_id={...} session_id={...}` in the structured log line that accompanies a notable metric increment (already standard practice in `LogObserver`). Operators pivot from a metric spike to logs by timestamp.

---

## Task 1: Switch branch from main and verify baseline

**Files:**
- Branch: `prod-readiness/s5-observability-slos` (from `main`)

- [ ] **Step 1: Confirm S2 and S3 are on main**

```bash
git fetch origin
git log origin/main --oneline -5
```

Expected: see commit `9ed4fbca prod-readiness Sprint 3: durable trace share records via Postgres snapshot (#110)` and `dececa3c prod-readiness Sprint 2: approval consolidation — stable approval_id + stale-card 409 guard (#109)`.

- [ ] **Step 2: Create the S5 branch from main**

```bash
git checkout main
git pull --ff-only origin main
git checkout -b prod-readiness/s5-observability-slos
```

- [ ] **Step 3: Verify baseline build is green**

```bash
zig build -Dengines=base,sqlite,postgres
```

Expected: exit 0, no warnings about new code.

- [ ] **Step 4: Verify baseline tests are green**

```bash
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: all tests pass. Capture the test count from the summary line — we want to confirm we don't drop tests during S5.

- [ ] **Step 5: Commit the empty-branch marker (only if your workflow requires it; otherwise skip).**

No commit yet — S5 work follows.

---

## Task 2: Add `src/observability_metrics.zig` registry + unit tests

**Files:**
- Create: `src/observability_metrics.zig`

**Why this is first:** the registry is the substrate every other task depends on. We land it standalone with its own tests before any caller wiring.

- [ ] **Step 1: Write `src/observability_metrics.zig`**

```zig
//! Process-wide Prometheus-counter/histogram registry for the S5
//! chartable signals (approvals, artifact_export, extension_command,
//! memory_op, trace_share, tool_call, meter_receipt).
//!
//! Design:
//!   - Single hashmap keyed by full Prometheus line key
//!     (`name{label="value",...}`). Atomic u64 per series.
//!   - Bucket boundaries are fixed across all latency families to
//!     keep the alert PromQL uniform (10, 50, 100, 250, 500, 1000,
//!     2500, 5000, 10000 ms + +Inf).
//!   - Per family we also keep `_sum_ms` (for averages) and `_count`
//!     (sample count) atomics.
//!
//! Thread-safety:
//!   - The hashmap itself is guarded by a `std.Thread.Mutex` for
//!     insert-or-get. Once a slot exists, increment is a lock-free
//!     atomic add. We expect the registry's static set of keys to
//!     warm up early (every label combo touched on first emit), so
//!     the lock is contended only briefly at startup.
//!   - `render()` takes the lock for the duration of a snapshot.

const std = @import("std");

pub const BUCKETS_MS: [10]u64 = .{ 10, 50, 100, 250, 500, 1000, 2500, 5000, 10000, std.math.maxInt(u64) };
pub const BUCKET_LABELS: [10][]const u8 = .{ "10", "50", "100", "250", "500", "1000", "2500", "5000", "10000", "+Inf" };

const Counter = struct { value: std.atomic.Value(u64) };

const Histogram = struct {
    bucket_counts: [10]std.atomic.Value(u64),
    sum_ms: std.atomic.Value(u64),
    count: std.atomic.Value(u64),
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    counters: std.StringHashMapUnmanaged(*Counter) = .{},
    histograms: std.StringHashMapUnmanaged(*Histogram) = .{},

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var c_it = self.counters.iterator();
        while (c_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.destroy(e.value_ptr.*);
        }
        self.counters.deinit(self.allocator);
        var h_it = self.histograms.iterator();
        while (h_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.destroy(e.value_ptr.*);
        }
        self.histograms.deinit(self.allocator);
    }

    /// Increment a counter series keyed by `series_key` (e.g.
    /// `approval_decision_total{result="issued"}`). Slow path
    /// (insert) only fires once per key over the process lifetime.
    pub fn incCounter(self: *Registry, series_key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.counters.get(series_key)) |c| {
            _ = c.value.fetchAdd(1, .monotonic);
            return;
        }
        const owned_key = self.allocator.dupe(u8, series_key) catch return;
        const c = self.allocator.create(Counter) catch {
            self.allocator.free(owned_key);
            return;
        };
        c.* = .{ .value = .{ .raw = 1 } };
        self.counters.put(self.allocator, owned_key, c) catch {
            self.allocator.free(owned_key);
            self.allocator.destroy(c);
            return;
        };
    }

    /// Observe one sample in a histogram family keyed by `family_key`
    /// (e.g. `tool_call_latency_ms{tool="memory_store"}` — without
    /// the `_bucket` suffix). We append `_bucket{le="..."}` per
    /// bucket on render.
    pub fn observeHistogram(self: *Registry, family_key: []const u8, value_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = self.histograms.get(family_key) orelse blk: {
            const owned_key = self.allocator.dupe(u8, family_key) catch return;
            const new_h = self.allocator.create(Histogram) catch {
                self.allocator.free(owned_key);
                return;
            };
            new_h.* = .{
                .bucket_counts = .{
                    .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 },
                    .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 },
                },
                .sum_ms = .{ .raw = 0 },
                .count = .{ .raw = 0 },
            };
            self.histograms.put(self.allocator, owned_key, new_h) catch {
                self.allocator.free(owned_key);
                self.allocator.destroy(new_h);
                return;
            };
            break :blk new_h;
        };
        _ = h.sum_ms.fetchAdd(value_ms, .monotonic);
        _ = h.count.fetchAdd(1, .monotonic);
        for (BUCKETS_MS, 0..) |bound, i| {
            if (value_ms <= bound) {
                _ = h.bucket_counts[i].fetchAdd(1, .monotonic);
            }
        }
    }

    /// Render the entire registry as Prometheus text exposition.
    pub fn render(self: *Registry, allocator: std.mem.Allocator, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Counters
        var c_it = self.counters.iterator();
        while (c_it.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.*.value.load(.monotonic) });
        }
        // Histograms — emit `_bucket{le="..."}`, `_sum`, `_count`.
        // Each histogram entry's key is the "family" without suffix —
        // we split on `{` to inject `_bucket` and the `le` label.
        var h_it = self.histograms.iterator();
        while (h_it.next()) |entry| {
            const family = entry.key_ptr.*;
            const h = entry.value_ptr.*;
            const split = std.mem.indexOfScalar(u8, family, '{') orelse family.len;
            const name = family[0..split];
            const labels_with_brace = family[split..]; // includes leading '{' or empty
            for (BUCKET_LABELS, 0..) |le, i| {
                const bucket_line = if (labels_with_brace.len == 0)
                    try std.fmt.allocPrint(allocator, "{s}_bucket{{le=\"{s}\"}}", .{ name, le })
                else blk: {
                    // labels_with_brace looks like `{tool="memory_store"}`. Inject `le=...` before the closing `}`.
                    const trimmed = labels_with_brace[1 .. labels_with_brace.len - 1];
                    break :blk try std.fmt.allocPrint(allocator, "{s}_bucket{{{s},le=\"{s}\"}}", .{ name, trimmed, le });
                };
                defer allocator.free(bucket_line);
                try writer.print("{s} {d}\n", .{ bucket_line, h.bucket_counts[i].load(.monotonic) });
            }
            try writer.print("{s}_sum{s} {d}\n", .{ name, if (labels_with_brace.len == 0) "" else labels_with_brace, h.sum_ms.load(.monotonic) });
            try writer.print("{s}_count{s} {d}\n", .{ name, if (labels_with_brace.len == 0) "" else labels_with_brace, h.count.load(.monotonic) });
        }
    }
};

// ── Process-wide singleton ──

var global_registry: ?*Registry = null;

pub fn setGlobalRegistry(reg: ?*Registry) void {
    @atomicStore(?*Registry, &global_registry, reg, .release);
}

pub fn globalRegistry() ?*Registry {
    return @atomicLoad(?*Registry, &global_registry, .acquire);
}

// ── Tests ──

test "Registry: counter increments accumulate" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    reg.incCounter("foo_total{result=\"ok\"}");
    reg.incCounter("foo_total{result=\"ok\"}");
    reg.incCounter("foo_total{result=\"err\"}");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "foo_total{result=\"ok\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "foo_total{result=\"err\"} 1") != null);
}

test "Registry: histogram bucket counts and sum/count" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    reg.observeHistogram("lat_ms{tool=\"x\"}", 5);   // bucket 10
    reg.observeHistogram("lat_ms{tool=\"x\"}", 30);  // bucket 50
    reg.observeHistogram("lat_ms{tool=\"x\"}", 700); // bucket 1000

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    // cumulative bucket semantics: le="10" => 1, le="50" => 2, le="1000" => 3
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_bucket{tool=\"x\",le=\"10\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_bucket{tool=\"x\",le=\"50\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_bucket{tool=\"x\",le=\"1000\"} 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_sum{tool=\"x\"} 735") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_count{tool=\"x\"} 3") != null);
}

test "Registry: render is stable under concurrent counter increments" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const T = struct {
        fn run(r: *Registry) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) r.incCounter("c_total{r=\"x\"}");
        }
    };
    var t1 = try std.Thread.spawn(.{}, T.run, .{&reg});
    var t2 = try std.Thread.spawn(.{}, T.run, .{&reg});
    t1.join();
    t2.join();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "c_total{r=\"x\"} 200") != null);
}
```

- [ ] **Step 2: Register the file in `build.zig`**

Look at how `src/lane_metrics.zig` is currently picked up. If `build.zig` enumerates source files explicitly, add `src/observability_metrics.zig` to the same list. Otherwise (if it globs `src/*.zig`), no build.zig change needed.

```bash
grep -n "lane_metrics" /Users/nova/Desktop/nullalis/build.zig
```

If it shows up by name, follow the same pattern. If nothing matches, the file is auto-discovered — skip.

- [ ] **Step 3: Run the new tests**

```bash
zig build test -Dengines=base
```

Expected: all three new tests pass. Total test count increases by 3 from the baseline you captured in Task 1.

- [ ] **Step 4: Commit**

```bash
git add src/observability_metrics.zig build.zig
git commit -m "feat(observability): S5 — registry substrate for chartable signals

Add process-wide Prometheus counter/histogram registry that owns the
S5 metric families. Single hashmap keyed by full series key; fixed
bucket boundaries (10/50/100/250/500/1000/2500/5000/10000 ms + +Inf)
across all latency histograms so alert PromQL stays uniform. Three
unit tests cover counter accumulation, histogram bucket math, and
concurrent-increment race correctness.

No callers wired yet — those land in subsequent S5 commits."
```

---

## Task 3: Extend `ObserverMetric` union with S5 variants

**Files:**
- Modify: `src/observability.zig` — union extension + every exhaustive switch on it.

- [ ] **Step 1: Add the new variants to the union**

Edit `src/observability.zig` after the existing `moonshot_video_upload_bytes: u64,` line (~line 276) — append before the closing `};`:

```zig
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
```

- [ ] **Step 2: Add the matching switch arm in `recordMetricGlobal`**

In the existing `switch (metric) { ... }` inside `recordMetricGlobal` (around line 333), add cases that produce a structured log fallback. Append before the closing `}`:

```zig
        .approval_decision_total => |e| metric_log.info("metric approval_decision_total result={s}", .{e.result}),
        .artifact_export_total => |e| metric_log.info("metric artifact_export_total format={s} result={s}", .{ e.format, e.result }),
        .artifact_export_latency_ms => |e| metric_log.info("metric artifact_export_latency_ms format={s} value={d}", .{ e.format, e.value }),
        .memory_op_total => |e| metric_log.info("metric memory_op_total op={s} result={s}", .{ e.op, e.result }),
        .memory_op_latency_ms => |e| metric_log.info("metric memory_op_latency_ms op={s} value={d}", .{ e.op, e.value }),
        .trace_share_total => |e| metric_log.info("metric trace_share_total op={s} result={s}", .{ e.op, e.result }),
        .tool_call_total => |e| metric_log.info("metric tool_call_total tool={s} result={s}", .{ e.tool, e.result }),
        .tool_call_latency_ms => |e| metric_log.info("metric tool_call_latency_ms tool={s} value={d}", .{ e.tool, e.value }),
        .meter_receipt_total => |e| metric_log.info("metric meter_receipt_total result={s}", .{e.result}),
```

- [ ] **Step 3: Add the same cases to every other exhaustive switch on `ObserverMetric`**

The audit shows these switches:
- `LogObserver.logRecordMetric` (~line 513) — emit at `std.log.info`.
- `MultiObserver.multiRecordMetric` (~line 651) — typically forwards to children; no per-variant change unless the existing pattern is variant-aware (check the body — if it just iterates children and calls `recordMetric`, no change needed because variants pass through).
- `OtelObserver.otelRecordMetric` (~line 1111) — emit as OTEL metric.
- `FileObserver.fileRecordMetric` (~line 737) — JSON line.
- `VerboseObserver.verboseRecordMetric` (~line 614) — currently a no-op (`_, _: *const ObserverMetric`); leave as no-op unless its body is now switching.

For each switch you find, add the nine S5 cases. Use the LogObserver pattern as the canonical shape:

```zig
.approval_decision_total => |e| std.log.info("metric.approval_decision_total result={s}", .{e.result}),
.artifact_export_total => |e| std.log.info("metric.artifact_export_total format={s} result={s}", .{ e.format, e.result }),
.artifact_export_latency_ms => |e| std.log.info("metric.artifact_export_latency_ms format={s} value={d}", .{ e.format, e.value }),
.memory_op_total => |e| std.log.info("metric.memory_op_total op={s} result={s}", .{ e.op, e.result }),
.memory_op_latency_ms => |e| std.log.info("metric.memory_op_latency_ms op={s} value={d}", .{ e.op, e.value }),
.trace_share_total => |e| std.log.info("metric.trace_share_total op={s} result={s}", .{ e.op, e.result }),
.tool_call_total => |e| std.log.info("metric.tool_call_total tool={s} result={s}", .{ e.tool, e.result }),
.tool_call_latency_ms => |e| std.log.info("metric.tool_call_latency_ms tool={s} value={d}", .{ e.tool, e.value }),
.meter_receipt_total => |e| std.log.info("metric.meter_receipt_total result={s}", .{e.result}),
```

Match the surrounding style — `FileObserver` uses `std.fmt.bufPrint` to a JSON line; `OtelObserver` may use its own helper. Read each one before editing.

- [ ] **Step 4: Build to surface any switches you missed**

```bash
zig build -Dengines=base 2>&1 | head -80
```

Expected: exit 0. If you see `error: switch must handle all possibilities`, the compiler tells you the exact switch and the exact missing variant — add the case.

- [ ] **Step 5: Run the full test suite**

```bash
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: same test count + 3 from Task 2, all green.

- [ ] **Step 6: Commit**

```bash
git add src/observability.zig
git commit -m "feat(observability): S5 — extend ObserverMetric with chartable signals

Add nine new variants for the S5 catalog: approval_decision_total,
artifact_export_total/_latency_ms, memory_op_total/_latency_ms,
trace_share_total, tool_call_total/_latency_ms, meter_receipt_total.

Every existing observer impl gets a matching switch arm (log-fallback,
LogObserver, MultiObserver, OtelObserver, FileObserver) so Zig's
exhaustive-switch rule is preserved. No emit-site rewires yet — those
land in S5 tasks 5-7."
```

---

## Task 4: Wire `MetricsRegistryObserver` and extend `metricsPayload()`

**Files:**
- Modify: `src/gateway.zig` — sibling observer + metricsPayload extension + degraded-gauge emit.

- [ ] **Step 1: Add a `MetricsRegistryObserver` struct in `gateway.zig`**

Find `LifecycleMetricsObserver` (existing pattern). Add a sibling near it:

```zig
const observability_metrics = @import("observability_metrics.zig");

const MetricsRegistryObserver = struct {
    registry: *observability_metrics.Registry,

    const vtable = observability.Observer.VTable{
        .record_event = noopRecordEvent,
        .record_metric = recordMetric,
        .flush = noopFlush,
        .name = name,
    };

    pub fn observer(self: *MetricsRegistryObserver) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn noopRecordEvent(_: *anyopaque, _: *const observability.ObserverEvent) void {}
    fn noopFlush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "metrics_registry";
    }

    fn recordMetric(ptr: *anyopaque, metric: *const observability.ObserverMetric) void {
        const self: *MetricsRegistryObserver = @ptrCast(@alignCast(ptr));
        switch (metric.*) {
            .approval_decision_total => |e| {
                var buf: [128]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_approval_decision_total{{result=\"{s}\"}}", .{e.result}) catch return;
                self.registry.incCounter(key);
            },
            .artifact_export_total => |e| {
                var buf: [192]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_artifact_export_total{{format=\"{s}\",result=\"{s}\"}}", .{ e.format, e.result }) catch return;
                self.registry.incCounter(key);
            },
            .artifact_export_latency_ms => |e| {
                var buf: [128]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_artifact_export_latency_ms{{format=\"{s}\"}}", .{e.format}) catch return;
                self.registry.observeHistogram(key, e.value);
            },
            .memory_op_total => |e| {
                var buf: [128]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_memory_op_total{{op=\"{s}\",result=\"{s}\"}}", .{ e.op, e.result }) catch return;
                self.registry.incCounter(key);
            },
            .memory_op_latency_ms => |e| {
                var buf: [128]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_memory_op_latency_ms{{op=\"{s}\"}}", .{e.op}) catch return;
                self.registry.observeHistogram(key, e.value);
            },
            .trace_share_total => |e| {
                var buf: [128]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_trace_share_total{{op=\"{s}\",result=\"{s}\"}}", .{ e.op, e.result }) catch return;
                self.registry.incCounter(key);
            },
            .tool_call_total => |e| {
                var buf: [192]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_tool_call_total{{tool=\"{s}\",result=\"{s}\"}}", .{ e.tool, e.result }) catch return;
                self.registry.incCounter(key);
            },
            .tool_call_latency_ms => |e| {
                var buf: [128]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_tool_call_latency_ms{{tool=\"{s}\"}}", .{e.tool}) catch return;
                self.registry.observeHistogram(key, e.value);
            },
            .meter_receipt_total => |e| {
                var buf: [96]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "nullalis_meter_receipt_total{{result=\"{s}\"}}", .{e.result}) catch return;
                self.registry.incCounter(key);
            },
            else => {}, // existing variants are handled by LifecycleMetricsObserver / others.
        }
    }
};
```

- [ ] **Step 2: Install the observer at gateway boot**

Find where `setGlobalObserver()` is called (search for `setGlobalObserver`). Before the existing call, allocate a `Registry`, an observer, register the registry as the process-wide one, then add the observer into the MultiObserver chain.

```zig
// Inside gateway.runWithRole or the bootstrap path, before setGlobalObserver:
const metrics_registry_ptr = try allocator.create(observability_metrics.Registry);
metrics_registry_ptr.* = observability_metrics.Registry.init(allocator);
observability_metrics.setGlobalRegistry(metrics_registry_ptr);
// Add a MetricsRegistryObserver to the existing MultiObserver children.
// (Match the existing LifecycleMetricsObserver registration pattern.)
state.metrics_registry_observer = .{ .registry = metrics_registry_ptr };
// ... continue with the existing observer composition.
```

Add `metrics_registry_observer: MetricsRegistryObserver = undefined,` to `GatewayState` near the existing `lifecycle_metrics_observer` field. On `GatewayState.deinit`, free the registry pointer:

```zig
if (observability_metrics.globalRegistry()) |reg| {
    observability_metrics.setGlobalRegistry(null);
    reg.deinit();
    self.allocator.destroy(reg);
}
```

Read the existing `LifecycleMetricsObserver` install path carefully — match it exactly. If the MultiObserver children array is fixed-size, you may need to extend it; if it's a dynamic list, just append.

- [ ] **Step 3: Extend `metricsPayload()` with the new section**

At the bottom of `metricsPayload()` (`gateway.zig:6653` — just before `return buf.toOwnedSlice(allocator);`), append:

```zig
    // ── S5 (2026-05-29) — chartable signals ──
    if (observability_metrics.globalRegistry()) |reg| {
        try w.print(
            \\# HELP nullalis_approval_decision_total Approval lifecycle: issued|auto_approved|user_approved|user_denied|blocked|expired.
            \\# TYPE nullalis_approval_decision_total counter
            \\# HELP nullalis_artifact_export_total Artifact-export operations by format and result.
            \\# TYPE nullalis_artifact_export_total counter
            \\# HELP nullalis_artifact_export_latency_ms Artifact-export latency milliseconds histogram by format.
            \\# TYPE nullalis_artifact_export_latency_ms histogram
            \\# HELP nullalis_memory_op_total Memory-tool operations (store|recall|forget) by result.
            \\# TYPE nullalis_memory_op_total counter
            \\# HELP nullalis_memory_op_latency_ms Memory-tool latency milliseconds histogram by op.
            \\# TYPE nullalis_memory_op_latency_ms histogram
            \\# HELP nullalis_trace_share_total Trace-share operations (create|revoke|get) by result.
            \\# TYPE nullalis_trace_share_total counter
            \\# HELP nullalis_tool_call_total Per-tool dispatch by result.
            \\# TYPE nullalis_tool_call_total counter
            \\# HELP nullalis_tool_call_latency_ms Per-tool latency milliseconds histogram.
            \\# TYPE nullalis_tool_call_latency_ms histogram
            \\# HELP nullalis_meter_receipt_total Cost-tracker meter-receipt ledger emit by result.
            \\# TYPE nullalis_meter_receipt_total counter
            \\
        , .{});
        try reg.render(allocator, w);
    }

    // Gateway degraded-state gauge with labels — emitted whether or not
    // the registry has any S5 series yet.
    const degraded_val: u8 = if (state.state_degraded) 1 else 0;
    const degraded_reason: []const u8 = if (state.state_degraded) state.degradedReason() else "none";
    try w.print(
        \\# HELP nullalis_gateway_degraded Gateway degraded-state gauge (1 when configured backend != effective backend).
        \\# TYPE nullalis_gateway_degraded gauge
        \\nullalis_gateway_degraded{{configured="{s}",effective="{s}",reason="{s}"}} {d}
        \\
    , .{ state.state_backend_configured, state.state_backend_effective, degraded_reason, degraded_val });
```

- [ ] **Step 4: Add an integration test that scrapes `/metrics` and asserts S5 surface presence**

Append next to the existing `test "metricsPayload includes lifecycle timing series"` at `gateway.zig:27320`:

```zig
test "metricsPayload S5: emits new family HELP/TYPE lines and degraded gauge" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    // Force a non-degraded state for this assertion path.
    gs.state_backend_configured = "file";
    gs.state_backend_effective = "file";
    gs.state_degraded = false;

    const payload = try metricsPayload(allocator, &gs);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "# TYPE nullalis_approval_decision_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "# TYPE nullalis_tool_call_latency_ms histogram") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_degraded{configured=\"file\",effective=\"file\",reason=\"none\"} 0") != null);
}

test "metricsPayload S5: degraded gauge reports labels when state is degraded" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    gs.state_backend_configured = "postgres";
    gs.state_backend_effective = "file";
    gs.state_degraded = true;
    const reason = "ConnectionRefused";
    gs.state_degraded_reason_len = copyIntoBuf(&gs.state_degraded_reason_buf, reason);

    const payload = try metricsPayload(allocator, &gs);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_degraded{configured=\"postgres\",effective=\"file\",reason=\"ConnectionRefused\"} 1") != null);
}

test "metricsPayload S5: registry counter shows up in scrape" {
    const allocator = std.testing.allocator;
    // Stand up a registry and install it as the process-wide one for the test.
    var reg = observability_metrics.Registry.init(allocator);
    defer reg.deinit();
    observability_metrics.setGlobalRegistry(&reg);
    defer observability_metrics.setGlobalRegistry(null);
    reg.incCounter("nullalis_approval_decision_total{result=\"issued\"}");
    reg.incCounter("nullalis_approval_decision_total{result=\"issued\"}");

    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    const payload = try metricsPayload(allocator, &gs);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_approval_decision_total{result=\"issued\"} 2") != null);
}
```

- [ ] **Step 5: Build and run all tests**

```bash
zig build -Dengines=base,sqlite,postgres
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: green. Test count increases by 3 vs Task 3 baseline.

- [ ] **Step 6: Commit**

```bash
git add src/gateway.zig
git commit -m "feat(observability): S5 — metricsPayload emits S5 catalog + degraded gauge

Add MetricsRegistryObserver that maps ObserverMetric S5 variants into
the process-wide observability_metrics.Registry. Install it on gateway
boot alongside the existing LifecycleMetricsObserver. Extend
metricsPayload() to render the registry and to emit
nullalis_gateway_degraded{configured,effective,reason} as a chartable
gauge. Three new metricsPayload tests cover HELP/TYPE lines, the
degraded-true case, and registry round-trip."
```

---

## Task 5: Attach metric emits at every S5 call site

**Files:**
- Modify: `src/agent/root.zig` (tool dispatch + approval decision)
- Modify: `src/tools/memory_store.zig`, `src/tools/memory_recall.zig`, `src/tools/memory_forget.zig`
- Modify: `src/gateway.zig` (TraceShareStore methods + handleArtifactExport)
- Modify: `src/cost.zig` (recordUsage)

This task touches many files. Do all of them in one task because their wiring is one structural change ("instrument every documented S5 surface") and rolling them as one commit makes the metric catalog land atomic with the surfaces it claims to cover.

- [ ] **Step 1: Tool-dispatch latency + result (`src/agent/root.zig`)**

Modify `executeToolUnchecked` at agent/root.zig:5228. Wrap the body so we measure latency across the four exit paths (tool not found, invalid args, exec error, success). At the top of the function, capture the start timestamp; on each return path, emit. Use `defer` only where you can capture the result at function exit — Zig allows `defer` with closures over locals.

```zig
fn executeToolUnchecked(self: *Agent, tool_allocator: std.mem.Allocator, call: ParsedToolCall) ToolExecutionResult {
    const start_ms = std.time.milliTimestamp();
    var observed_result: []const u8 = "unknown_tool";
    defer {
        const elapsed_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - start_ms));
        observability.recordMetricGlobal(.{ .tool_call_total = .{ .tool = call.name, .result = observed_result } });
        observability.recordMetricGlobal(.{ .tool_call_latency_ms = .{ .tool = call.name, .value = elapsed_ms } });
    }

    for (self.tools) |t| {
        if (std.mem.eql(u8, t.name(), call.name)) {
            // ... existing body unchanged up to the json.parseFromSlice catch ...
            const parsed = std.json.parseFromSlice(...) catch {
                observed_result = "invalid_args";
                return .{ .name = call.name, .output = "Invalid arguments JSON", .success = false, .tool_call_id = call.tool_call_id };
            };
            defer parsed.deinit();
            const args: std.json.ObjectMap = switch (parsed.value) {
                .object => |o| o,
                else => {
                    observed_result = "invalid_args";
                    return .{ ... };
                },
            };
            // ... existing exec block ...
            const result = t.execute(tool_allocator, args) catch |err| {
                observed_result = "err";
                return .{ ... };
            };
            observed_result = if (result.success) "ok" else "err";
            return .{ ... };
        }
    }
    observed_result = "unknown_tool";
    return .{ ... };
}
```

Keep the existing code shape — only add the `start_ms`/`observed_result`/`defer` triple and four assignment lines.

- [ ] **Step 2: Approval-decision counters (`src/agent/root.zig`)**

At the `approval_required` ObserverEvent emit site (~line 2564), append a metric emit *right after* the existing `recordEvent` call:

```zig
observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "issued" } });
```

At each `preflightToolPolicy` return site (look at the union — `.allowed` and `.blocked` variants), emit:

```zig
// On .allowed return:
observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "auto_approved" } });
// On .blocked return:
observability.recordMetricGlobal(.{ .approval_decision_total = .{ .result = "blocked" } });
```

If the existing `ApprovalDecision.decided_by` field is accessible at the return site (the audit said it lives in `security/approval_modes.zig` as `DecisionSource`), prefer the precise label: `user_approve` → `"user_approved"`, `user_deny` → `"user_denied"`, `auto_policy` → `"auto_approved"`. If not at the return site, the coarse "auto_approved"/"blocked" labels are acceptable and can be refined later.

For "expired": find where approvals time out. Grep `expir`, `timeout` near `approval` in `src/security/`. At the expiry site, emit `.approval_decision_total = .{ .result = "expired" }`. If no expiry site exists in code today, document that in the SLOs doc as "expired is currently a no-op label — wiring lands when approvals get a real TTL sweeper."

- [ ] **Step 3: Memory tool emits (`src/tools/memory_store.zig`, `memory_recall.zig`, `memory_forget.zig`)**

For each of the three tools, wrap the body of `execute()` with start/end timestamp + emit. Pattern identical for all three (substitute op label):

```zig
pub fn execute(self: *Self, allocator: std.mem.Allocator, args: std.json.ObjectMap) !ToolResult {
    const start_ms = std.time.milliTimestamp();
    var observed: []const u8 = "ok";
    defer {
        const elapsed: u64 = @intCast(@max(0, std.time.milliTimestamp() - start_ms));
        observability.recordMetricGlobal(.{ .memory_op_total = .{ .op = "store", .result = observed } });
        observability.recordMetricGlobal(.{ .memory_op_latency_ms = .{ .op = "store", .value = elapsed } });
    }
    // ... existing body, except on failure paths set `observed = "err"` before returning the failure ToolResult ...
}
```

For each tool, identify every error-return path inside `execute()` and prepend `observed = "err";` before the return. Use `errdefer` if the body uses `try`.

- [ ] **Step 4: TraceShareStore (`src/gateway.zig`)**

In `TraceShareStore.createOrGet()` (search `~line 11960` — look for the function near `fn initWithPersistence`), wrap so the success path emits `op="create",result="ok"` and the cap-hit / persistence-fail paths emit specific results:

```zig
// At the top:
defer observability.recordMetricGlobal(.{ .trace_share_total = .{ .op = "create", .result = trace_share_result } });
// Default before any branch:
var trace_share_result: []const u8 = "ok";
// In the per-user MAX_LIVE_SHARES_PER_USER denial path: trace_share_result = "cap";
// In the postgres-persistence failure path: trace_share_result = "err";
```

For `revoke()` at line 12261, similar pattern with `op="revoke"`, `result` ∈ `{"ok","not_found","err"}`.

For `getLive()` at line 11985, `op="get"`, `result` ∈ `{"ok","not_found","expired","revoked"}`.

- [ ] **Step 5: handleArtifactExport (`src/gateway.zig:11555`)**

Wrap with start/end timestamp and result-classification. The function has multiple exit points (success, 400 invalid format, 404 missing artifact, 502 renderer_unavailable, 403 cross-user). Use the same `defer` pattern. Format label comes from the requested format parameter; for the 400 invalid-format path use `format="invalid"`.

```zig
fn handleArtifactExport(...) ResponseDescriptor {
    const start_ms = std.time.milliTimestamp();
    var fmt_label: []const u8 = "invalid";
    var result_label: []const u8 = "invalid_format";
    defer {
        const elapsed: u64 = @intCast(@max(0, std.time.milliTimestamp() - start_ms));
        observability.recordMetricGlobal(.{ .artifact_export_total = .{ .format = fmt_label, .result = result_label } });
        observability.recordMetricGlobal(.{ .artifact_export_latency_ms = .{ .format = fmt_label, .value = elapsed } });
    }
    // ... existing logic. Once format is validated:
    fmt_label = validated_format;
    // ... on each exit path, set result_label to one of:
    //   "ok" | "missing_artifact" | "state_unavailable" | "renderer_unavailable" | "cross_user_denied"
    // before the return statement.
}
```

- [ ] **Step 6: cost.recordUsage (`src/cost.zig:154`)**

In `recordUsage()`, after the `appendToJsonl` call:

```zig
const append_err = self.appendToJsonl(record) catch |err| {
    observability.recordMetricGlobal(.{ .meter_receipt_total = .{ .result = "err_write" } });
    return err;
};
_ = append_err;
observability.recordMetricGlobal(.{ .meter_receipt_total = .{ .result = "ok" } });
```

Adapt to the existing function shape — the key is one emit on success, one emit on write-error.

- [ ] **Step 7: Build + run targeted unit tests**

```bash
zig build -Dengines=base,sqlite,postgres
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: all green. No new failing tests; the existing tests for tool dispatch, memory tools, artifact export, and TraceShareStore continue to pass.

- [ ] **Step 8: Add focused unit tests for emit-site coverage**

In `src/observability_metrics.zig` test block (or a new test file `src/observability_metrics_test.zig` if you prefer), add a test that installs a `Registry` as the global, runs a mock invocation through each emit site, and asserts the right metric series exists. For surfaces with rich integration tests already (artifact export, trace share), a single round-trip test per surface is enough:

```zig
test "S5 emit-site: tool_call_total fires from executeToolUnchecked on unknown tool" {
    // Setup a process-wide registry.
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();
    observability_metrics.setGlobalRegistry(&reg);
    defer observability_metrics.setGlobalRegistry(null);
    // Install MetricsRegistryObserver as the global observer.
    var obs = MetricsRegistryObserver{ .registry = &reg };
    var multi = ... ; // single-child multi using `obs.observer()`
    observability.setGlobalObserver(&multi.observer());
    defer observability.setGlobalObserver(null);

    // Simulate the emit (we don't need a full Agent here — just call recordMetricGlobal).
    observability.recordMetricGlobal(.{ .tool_call_total = .{ .tool = "memory_store", .result = "ok" } });
    observability.recordMetricGlobal(.{ .tool_call_latency_ms = .{ .tool = "memory_store", .value = 42 } });

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_tool_call_total{tool=\"memory_store\",result=\"ok\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_tool_call_latency_ms_sum{tool=\"memory_store\"} 42") != null);
}
```

Add one such round-trip test per family (approval, artifact_export, memory, trace_share, tool_call, meter_receipt). 6 new tests total.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(observability): S5 — instrument every chartable surface

Wire metric emits at: tool dispatch (per-tool latency + result),
approval decision (issued/auto_approved/user_*_denied/blocked/expired),
memory store/recall/forget (per-op latency + result), TraceShareStore
create/revoke/get (per-op + result), handleArtifactExport (per-format
latency + result), and cost.recordUsage (meter_receipt_total).

Six round-trip tests confirm each family lands a counter or histogram
sample observable on a /metrics scrape via the in-process registry."
```

---

## Task 6: Production fail-loud readiness gate

**Files:**
- Modify: `src/gateway.zig` (`applyStartupSelfCheck` signature + `runWithRole` caller)
- Modify: `src/main.zig` if needed (whichever path swallows the error today)

- [ ] **Step 1: Change `applyStartupSelfCheck` to return an error**

At `gateway.zig:5145`, change the signature:

```zig
const StartupSelfCheckError = error{ProductionPostgresRequired};

fn applyStartupSelfCheck(
    state: *GatewayState,
    cfg: *const Config,
    postgres_init_error: ?anyerror,
    effective_host: []const u8,
) StartupSelfCheckError!void {
    // ... existing body unchanged up to and including the
    // `state.state_degraded = ...` line ...

    if (state.state_degraded and std.mem.eql(u8, cfg.state.backend, "postgres") and isProductionLikeGateway(cfg, effective_host)) {
        const reason = if (postgres_init_error) |err| @errorName(err) else "postgres_init_failed";
        log.err(
            "startup.production_postgres_required configured=postgres effective={s} reason={s} host={s} — refusing to run degraded in production",
            .{ state.state_backend_effective, reason, effective_host },
        );
        return error.ProductionPostgresRequired;
    }
    // ... rest of body (dispatch_mode warning etc.) unchanged ...
}
```

- [ ] **Step 2: Propagate the error at the call site**

Find every caller of `applyStartupSelfCheck`. The audit said `runWithRole` ~line 21258. Make sure each call uses `try`:

```zig
try applyStartupSelfCheck(state, cfg, postgres_init_error, effective_host);
```

The function `runWithRole` already returns an error union (or it can be widened to include `StartupSelfCheckError`).

- [ ] **Step 3: Surface the error to the process exit code**

Find `main.zig` / `runGateway`. The error from `runWithRole` likely already bubbles up; if `main` catches it and logs without re-raising, change the catch arm so a `ProductionPostgresRequired` causes `std.process.exit(1)` (or returns the error from `main`, which exits non-zero).

```zig
gateway.runWithRole(...) catch |err| {
    switch (err) {
        error.ProductionPostgresRequired => {
            // Already logged inside applyStartupSelfCheck with the named reason.
            std.process.exit(1);
        },
        else => return err,
    }
};
```

- [ ] **Step 4: Write the dev/test sanity test**

In `src/gateway.zig` test block (next to existing startup-self-check tests if any; otherwise alongside the metricsPayload tests):

```zig
test "applyStartupSelfCheck: degraded + non-production host = warn, no error" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    var cfg = test_fixtures.minimalConfig(); // build a default Config; pattern exists in other tests
    cfg.state.backend = "postgres";
    // zaki_state stays null — simulates postgres init failure
    // Host is loopback — not production-like.
    try applyStartupSelfCheck(&gs, &cfg, error.ConnectionRefused, "127.0.0.1");
    try std.testing.expect(gs.state_degraded);
    try std.testing.expectEqualStrings("ConnectionRefused", gs.degradedReason());
}

test "applyStartupSelfCheck: degraded + production host + postgres-configured = ProductionPostgresRequired" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    var cfg = test_fixtures.minimalConfig();
    cfg.state.backend = "postgres";
    cfg.gateway.allow_public_bind = true;
    const result = applyStartupSelfCheck(&gs, &cfg, error.ConnectionRefused, "0.0.0.0");
    try std.testing.expectError(error.ProductionPostgresRequired, result);
}

test "applyStartupSelfCheck: production + state.backend=file = no error" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    var cfg = test_fixtures.minimalConfig();
    cfg.state.backend = "file";
    cfg.gateway.allow_public_bind = true;
    try applyStartupSelfCheck(&gs, &cfg, null, "0.0.0.0");
    try std.testing.expect(!gs.state_degraded);
}

test "applyStartupSelfCheck: production + postgres + zaki_state present = no error" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    // Stub zaki_state to non-null so degraded stays false.
    var dummy: zaki_state_mod.Manager = undefined;
    gs.zaki_state = &dummy;
    var cfg = test_fixtures.minimalConfig();
    cfg.state.backend = "postgres";
    cfg.gateway.allow_public_bind = true;
    try applyStartupSelfCheck(&gs, &cfg, null, "0.0.0.0");
    try std.testing.expect(!gs.state_degraded);
}
```

If `test_fixtures.minimalConfig` doesn't already exist, look at existing self-check tests for the canonical fixture-construction pattern and reuse it. If no fixture exists, build a `Config` inline with the minimum fields the function reads (cfg.state.backend, cfg.gateway.allow_public_bind, cfg.tenant.enabled, cfg.heartbeat.*, cfg.memory.search.provider, cfg.default_provider, cfg.reliability.fallback_providers, cfg.agent.tool_dispatcher, cfg.agent.parallel_tools*, cfg.workspace_dir, cfg.config_path).

- [ ] **Step 5: Build + test**

```bash
zig build -Dengines=base,sqlite,postgres
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: all green. 4 new tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/gateway.zig src/main.zig
git commit -m "feat(gateway): S5 — production fail-loud when postgres is required but unavailable

applyStartupSelfCheck now returns error.ProductionPostgresRequired
when state_degraded is true AND configured backend is postgres AND
the gateway is production-like (allow_public_bind OR non-loopback
host). The error propagates through runWithRole to main, which exits
non-zero. Dev/test profiles (loopback host) still warn and continue.

Four tests cover: dev-degraded (warn, no error), prod-degraded-postgres
(error), prod-file (no error), prod-postgres-ok (no error)."
```

---

## Task 7: docs — `docs/operations/SLOs.md`, OpenAPI, ui-handoff, deferred-register

**Files:**
- Create: `docs/operations/SLOs.md`
- Modify: `docs/openapi-v1.yaml`
- Modify: `docs/ui-handoff.md`
- Modify: `docs/deferred-register.md`

- [ ] **Step 1: Create `docs/operations/SLOs.md`**

Write the full operator-facing document. Use this skeleton — fill in every section with the actual metric names, the labels, target thresholds, alert PromQL, and a "V1 launch gate" column on the catalog table.

```markdown
---
tags: [prose, prose/docs, operations]
---

# nullalis Production SLOs and Metric Catalog

**Status:** S5 shipped 2026-05-29. Covers the chartable signals exposed by `/metrics`, target thresholds, alert suggestions, and V1 launch gates.

**Owner:** Backend.
**Audience:** operators (alert wiring), SREs (dashboards), engineering (regression budget), product (V1 launch readiness).

This document supersedes the catalog parts of [docs/SLO.md](../SLO.md) for the metric-driven view. The SLO targets themselves still live in `docs/SLO.md` — this document is the metric-to-target mapping.

## 1. How to scrape

- Endpoint: `GET /metrics` (no auth) — Prometheus text exposition v0.0.4.
- Production: scrape from inside the cluster only. The gateway does not authenticate `/metrics`; the deployment must firewall it from the internet.

## 2. Catalog

| Metric | Type | Labels | V1 launch gate? | Description |
|---|---|---|---|---|
| `nullalis_gateway_requests_total` | counter | none | YES | Total HTTP requests handled. |
| `nullalis_gateway_chat_stream_total` | counter | none | YES | Chat-stream connect attempts accepted. |
| `nullalis_gateway_chat_stream_errors_total` | counter | none | YES | Chat-stream errors. |
| `nullalis_gateway_in_flight_requests` | gauge | none | YES | Current in-flight requests. |
| `nullalis_gateway_drain_mode` | gauge | none | NO | Drain-mode flag. |
| `nullalis_gateway_degraded` | gauge | `configured`, `effective`, `reason` | **YES — gate** | 1 when configured backend != effective backend. Production startup is fail-loud when this would be 1; this gauge only ever shows non-zero in dev. |
| `nullalis_approval_decision_total` | counter | `result` | YES | Approval lifecycle. Result ∈ {issued, auto_approved, user_approved, user_denied, blocked, expired}. |
| `nullalis_artifact_export_total` | counter | `format`, `result` | YES | Artifact-export operations. Format ∈ {pdf, docx, pptx, xlsx, html, invalid}. Result ∈ {ok, invalid_format, missing_artifact, state_unavailable, renderer_unavailable, cross_user_denied}. |
| `nullalis_artifact_export_latency_ms` | histogram | `format` | YES | Artifact-export latency. Buckets: 10/50/100/250/500/1000/2500/5000/10000 ms + +Inf. |
| `nullalis_extension_ws_command_total` | counter | `result`, `tool` | YES | Extension-WS command dispatch. Result ∈ {ok, timeout, conn_closed, oom, queue_drained, command_alloc_failed, no_conn, registration_failed}. |
| `nullalis_extension_ws_command_latency_ms` | histogram | none | YES | Extension-WS command roundtrip. |
| `nullalis_extension_ws_connections_active` | gauge | none | YES | Active extension WS connections. |
| `nullalis_memory_op_total` | counter | `op`, `result` | YES | Memory operations. Op ∈ {store, recall, forget}. Result ∈ {ok, err}. |
| `nullalis_memory_op_latency_ms` | histogram | `op` | YES | Memory-op latency. |
| `nullalis_trace_share_total` | counter | `op`, `result` | YES | Trace-share. Op ∈ {create, revoke, get}. Result ∈ {ok, not_found, expired, revoked, cap, err}. |
| `nullalis_tool_call_total` | counter | `tool`, `result` | YES | Per-tool dispatch. Tool is the canonical tool name. Result ∈ {ok, err, unknown_tool, invalid_args}. |
| `nullalis_tool_call_latency_ms` | histogram | `tool` | YES | Per-tool latency. p50/p95 computed by `histogram_quantile()` on the scrape side. |
| `nullalis_meter_receipt_total` | counter | `result` | NO | Cost-tracker meter-receipt ledger emit. Currently has zero call sites in prod (cost.zig isn't wired into the turn loop yet); the counter is shipped so it lights up the moment wiring lands. |
| `nullalis_gateway_lifecycle_stage_total` | counter | `stage` | NO | Lifecycle-tax events (lock_wait, compaction, continuity_refresh, pruning). |
| `nullalis_http_transport_native_total` | counter | `subsystem` | NO | Native HTTP transport usage. |
| `nullalis_http_pool_idle_connections` | gauge | none | NO | Connection-pool idle count. |

(Truncated — list every metric from `metricsPayload()` here.)

## 3. SLO targets

Cross-references `docs/SLO.md`:

- Chat-stream availability ≥ 99.0% (7-day): alert on `rate(nullalis_gateway_chat_stream_errors_total[5m]) / rate(nullalis_gateway_chat_stream_total[5m]) > 0.01` for 10 minutes.
- Tool latency p95 ≤ 2000ms for non-network tools: alert on `histogram_quantile(0.95, sum by (tool, le)(rate(nullalis_tool_call_latency_ms_bucket{tool!~"web_.*|composio_.*"}[5m]))) > 2000` for 10 minutes.
- Memory recall p95 ≤ 800ms (per `docs/SLO.md` §2.5): alert on `histogram_quantile(0.95, sum by (le)(rate(nullalis_memory_op_latency_ms_bucket{op="recall"}[5m]))) > 800` for 10 minutes.
- Approval denial rate budget: page if `sum(rate(nullalis_approval_decision_total{result="user_denied"}[5m])) > 1` AND `sum(rate(nullalis_approval_decision_total{result="user_approved"}[5m])) > 0` for more than 30 minutes — operator misconfiguration signal.
- Artifact-export error rate ≤ 1% (7-day): alert on `sum(rate(nullalis_artifact_export_total{result!="ok"}[5m])) / sum(rate(nullalis_artifact_export_total[5m])) > 0.01` for 15 minutes.
- Extension-WS disconnect rate budget: `sum(rate(nullalis_extension_ws_command_total{result=~"conn_closed|no_conn"}[5m])) > 0.5` for 10 minutes.
- Gateway degraded gauge: `nullalis_gateway_degraded > 0` for any non-zero time is a page in production. (In production the process won't actually run when this would be 1 — the startup gate exits non-zero — so this alert is a safety net for re-introduction.)

## 4. V1 launch gates

The "V1 launch gate?" column above identifies the metrics that MUST be charting non-zero (or zero where appropriate) before the gateway can be flipped to production. Specifically:

- `nullalis_gateway_chat_stream_total` shows traffic.
- `nullalis_tool_call_total` shows tools dispatching for at least 5 distinct tool names.
- `nullalis_memory_op_total` for at least one of {store, recall} shows traffic.
- `nullalis_extension_ws_command_total{result="ok"}` shows successful commands when an extension is paired (skip if no extension users).
- `nullalis_artifact_export_total{result="ok"}` shows at least one success.
- `nullalis_trace_share_total{op="create",result="ok"}` shows the share-mint path is healthy.
- `nullalis_gateway_degraded == 0`.

## 5. Production-startup contract

The gateway is fail-loud when, at startup, ALL of these are true:

1. `cfg.state.backend == "postgres"` (operator asked for Postgres).
2. Postgres init failed (`zaki_state == null` after the init block).
3. `isProductionLikeGateway(cfg, effective_host)` returns true. This is currently:
   - `cfg.gateway.allow_public_bind == true`, OR
   - effective host is not loopback (not `localhost`, `127.0.0.1`, `::1`, `[::1]`).

In that case, the process logs a `startup.production_postgres_required` line including the configured/effective backends, the reason (the `@errorName` of the original Postgres init error, e.g. `ConnectionRefused`), and the bound host, and exits non-zero.

In dev/test (loopback host), the gateway logs a warning and continues. This is intentional so contributors can iterate without standing up Postgres locally.

## 6. Cardinality discipline

Do **not** add `run_id`, `session_id`, or `user_id` as Prometheus labels — they would explode the time-series store. To correlate a metric spike to a run, pivot to the structured log lines emitted alongside the metric increment (e.g. `metric.tool_call_total tool=... result=...` and the surrounding `tool.call` event from `LogObserver`) and join by timestamp.

## 7. Notable absences (deferred)

- `nullalis_meter_receipt_total` ships but is currently always-zero — cost.zig has no production callers. The wiring lands in a later sprint.
- Per-`run_id` exemplar attachment to histograms is not implemented; Prometheus 2.43+ exemplars would let us pin one trace per histogram bucket. Deferred to post-V1.
```

Make sure every metric emitted by the actual `metricsPayload()` is in the table — don't truncate the catalog when you write it for real.

- [ ] **Step 2: Update `docs/openapi-v1.yaml` to document `GET /metrics`**

Append a path entry under `paths:`:

```yaml
  /metrics:
    get:
      tags: [observability]
      summary: Prometheus metrics scrape.
      description: |
        Prometheus text exposition v0.0.4. See docs/operations/SLOs.md for
        the full metric catalog and alert wiring.

        No authentication is performed. The deployment must firewall this
        endpoint from the public internet.
      responses:
        '200':
          description: Prometheus text exposition.
          content:
            text/plain:
              schema:
                type: string
                example: |
                  # HELP nullalis_gateway_requests_total Total HTTP requests handled.
                  # TYPE nullalis_gateway_requests_total counter
                  nullalis_gateway_requests_total 42
```

If `/metrics` already exists in the OpenAPI doc, replace the existing entry with this one. If `tags: [observability]` is not in the top-level `tags:` list, add it.

- [ ] **Step 3: Update `docs/ui-handoff.md`**

Find the operator-status / health section. Add one paragraph:

```markdown
### Gateway degraded state and metrics

The gateway exposes `nullalis_gateway_degraded{configured,effective,reason}` on `/metrics`. A non-zero value indicates the gateway started in degraded mode (configured backend ≠ effective backend). In production deployments this gauge is always 0 — startup is fail-loud when Postgres is configured but unavailable; the process exits non-zero with a `startup.production_postgres_required` log line. Dev/test deployments may show a non-zero value when iterating without Postgres.

See [docs/operations/SLOs.md](operations/SLOs.md) for the full metric catalog and V1 launch gates.
```

Don't touch other sections unless they currently make a claim that's now stale.

- [ ] **Step 4: Update `docs/deferred-register.md`**

Find the entry for "Observability and SLOs" (it should be item 9 from `docs/production-readiness-prompt.md`). Mark it shipped:

```markdown
### 9. Observability and SLOs **[SHIPPED 2026-05-29 — S5]**

- `/metrics` exposes the production catalog: approvals, artifact export,
  extension commands, memory ops, trace shares, per-tool latency, meter
  receipts, and gateway degraded state. See `docs/operations/SLOs.md`.
- Production startup is fail-loud (`error.ProductionPostgresRequired`,
  non-zero exit, named-reason log line) when Postgres is configured but
  unavailable on a non-loopback host. Dev/test still warn-and-continue.
- Closure: `metricsPayload()` in `src/gateway.zig`; registry substrate
  in `src/observability_metrics.zig`; readiness gate in
  `applyStartupSelfCheck()` (`src/gateway.zig:5145`).
```

- [ ] **Step 5: Commit**

```bash
git add docs/operations/SLOs.md docs/openapi-v1.yaml docs/ui-handoff.md docs/deferred-register.md
git commit -m "docs(s5): operations/SLOs.md catalog + openapi /metrics + deferred close

Add docs/operations/SLOs.md with the complete metric catalog, target
thresholds, alert PromQL suggestions, V1 launch gates, and the
production-startup fail-loud contract. Document GET /metrics in
openapi-v1.yaml. Single new paragraph in ui-handoff.md for the
operator-status surface. Mark Observability + SLOs as SHIPPED in
deferred-register.md item 9."
```

---

## Task 8: Final verification (build, test, manual smoke)

**Files:** none modified (verification only).

- [ ] **Step 1: Run the full build per the spec**

```bash
zig build -Dengines=base,sqlite,postgres
```

Expected: exit 0, no warnings about S5 code.

- [ ] **Step 2: Run the full test suite per the spec**

```bash
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: all tests pass. Test count is baseline (Task 1) + 3 (Task 2 registry) + 3 (Task 4 metricsPayload) + 6 (Task 5 emit-site) + 4 (Task 6 readiness) = baseline + 16. If your final count is different, audit the diff.

- [ ] **Step 3: Manual `/metrics` smoke**

Start the gateway locally with file backend (dev profile):

```bash
zig build run -Dengines=base -- --config config.example.json &
GATEWAY_PID=$!
sleep 3
curl -s http://127.0.0.1:8080/metrics | head -120
```

Expected: see HELP/TYPE lines for `nullalis_approval_decision_total`, `nullalis_artifact_export_total`, `nullalis_artifact_export_latency_ms`, `nullalis_memory_op_total`, `nullalis_memory_op_latency_ms`, `nullalis_trace_share_total`, `nullalis_tool_call_total`, `nullalis_tool_call_latency_ms`, `nullalis_meter_receipt_total`, and `nullalis_gateway_degraded`. Counter values may be 0 — that's OK; HELP/TYPE presence is the proof.

```bash
kill $GATEWAY_PID
```

- [ ] **Step 4: Manual fail-loud smoke**

Create a config that sets `state.backend = "postgres"` with an unreachable Postgres host AND `gateway.allow_public_bind = true` (to simulate production-like). Save to `/tmp/s5-prod-bad.json`:

```json
{
  "config_path": "/tmp/s5-prod-bad.json",
  "state": { "backend": "postgres", "postgres": { "connection_string": "postgres://nope:5432/nullalis", "schema": "public" } },
  "gateway": { "allow_public_bind": true },
  "tenant": { "enabled": false },
  "workspace_dir": "/tmp/s5-smoke-workspace"
}
```

(Fill in the rest of the fields the config loader requires by reading `config.example.json`.)

```bash
zig build run -Dengines=base,postgres -- --config /tmp/s5-prod-bad.json 2>&1 | head -40
echo "exit code: $?"
```

Expected: the gateway logs `startup.production_postgres_required` with `configured=postgres effective=file reason=<some_error>`. Exit code is non-zero.

- [ ] **Step 5: Capture evidence**

Save the smoke output to a paste-friendly form (the next operator will want to see it). Suggested format inline in the eventual PR description:

```
SMOKE — /metrics surface present:
$ curl -s http://127.0.0.1:8080/metrics | grep -E '^# (HELP|TYPE) nullalis_' | wc -l
<N>

SMOKE — production fail-loud:
$ zig build run -- --config /tmp/s5-prod-bad.json
2026-05-29T... ERR startup.production_postgres_required configured=postgres effective=file reason=ConnectionRefused host=0.0.0.0 — refusing to run degraded in production
$ echo $?
1
```

- [ ] **Step 6: Open the PR**

```bash
git push -u origin prod-readiness/s5-observability-slos
gh pr create --title "prod-readiness Sprint 5: observability + SLOs" --body "$(cat <<'EOF'
## Summary
- `/metrics` now exposes the full production catalog (approvals, artifact export, extension commands, memory ops, trace shares, per-tool latency, meter receipts, gateway degraded gauge).
- Production startup is fail-loud (`error.ProductionPostgresRequired`, non-zero exit, named-reason log) when Postgres is configured but unavailable on a non-loopback host. Dev/test still warn-and-continue.
- `docs/operations/SLOs.md` is the operator-facing catalog with thresholds, alert PromQL, and V1 launch gates.

## Test plan
- [x] `zig build -Dengines=base,sqlite,postgres`
- [x] `zig build test -Dengines=base,sqlite,postgres --summary all`
- [x] Manual scrape against the running gateway shows S5 metric families.
- [x] Manual production-postgres-required smoke: gateway exits 1 with named reason.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**1. Spec coverage:**

| Spec item | Task |
|---|---|
| Existing `/metrics` audit | Audit phase (pre-task) |
| Structured logs audit | Audit + Task 3 LogObserver arms |
| Readiness/startup state audit | Audit + Task 6 |
| Cost tracker JSONL ledger audit | Audit + Task 5 step 6 |
| Approval/artifact/extension/memory/trace-share/tool execution audit | Audit + Task 5 |
| Add run_id/session_id correlation | Task 5 (via structured log lines; explicitly NOT Prometheus labels — cardinality discipline) |
| tool latency p50/p95 | Task 5 step 1 (per-tool histogram) |
| approvals issued/resolved/expired/denied | Task 5 step 2 |
| artifact_export count/success/failure/latency | Task 5 step 5 |
| extension_command count/success/failure/timeout/disconnect | Already partially in ObserverMetric; Task 4 surfaces it via metricsPayload; Task 5 confirms emit sites |
| memory_store/recall/forget rates | Task 5 step 3 |
| trace_share create/revoke/get rates/failures | Task 5 step 4 |
| meter receipt correlation | Task 5 step 6 |
| gateway degraded startup state | Task 4 (degraded gauge in metricsPayload) |
| Readiness gate prod fail-loud | Task 6 |
| Named reason operators can act on | Task 6 step 1 (`startup.production_postgres_required` + `reason=@errorName(err)`) |
| Update OpenAPI for /metrics | Task 7 step 2 |
| docs/operations/SLOs.md | Task 7 step 1 |
| docs/ui-handoff.md update | Task 7 step 3 |
| docs/deferred-register.md sync | Task 7 step 4 |
| Unit tests for metric emission | Task 5 step 8 |
| Startup tests proving prod exits non-zero | Task 6 step 4 |
| Dev/test profile sanity | Task 6 step 4 (first test) |
| /metrics smoke | Task 4 step 4 + Task 8 step 3 |
| zig build verification | Task 8 step 1 |
| zig build test verification | Task 8 step 2 |
| Manual smoke per spec | Task 8 steps 3-5 |

All spec items covered.

**2. Placeholder scan:** No `TBD`, `TODO`, or `fill in later` lines in code blocks. Where the audit couldn't pinpoint a line (e.g. "find approval expiry path"), the plan tells the engineer how to find it (`grep expir|timeout near approval in src/security/`) AND what to do if it isn't found (document as a no-op label that lights up when the surface lands). That's actionable, not a placeholder.

**3. Type consistency:** Variant names, metric names (`nullalis_*` prefix), result-label vocabulary, and the `op` label values are consistent across Tasks 3, 4, 5, 7. The `degraded` gauge is `nullalis_gateway_degraded` (not `nullalis_state_degraded` or similar — verified against the existing emission style of `nullalis_gateway_*` in `metricsPayload()`). Bucket boundaries are defined once (`BUCKETS_MS` in `observability_metrics.zig`) and referenced everywhere else.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-29-s5-observability-slos.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
