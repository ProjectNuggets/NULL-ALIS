# Native `browser_*` Tools + Gateway Gate — Implementation Plan (Plan 4 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Wire the Nullalis agent to the browser-orchestrator: native Zig `browser_*` tools that dispatch over HTTP to the orchestrator (cloning the proven `extension_*` shape), gated on `config.browser.backend == "agent_browser"`, per-user-bound (the gateway is the authz boundary — a Plan-3b carry-forward), advertised via `capabilities.zig`, with the legacy `browser`/`browser_open` tools **removed**.

**Architecture:** A mockable `OrchestratorClient` (curl transport by default, injectable stub for tests) exposes `newSession`/`exec`/`closeSession`. Five tools — `browser_new_session`, `browser_navigate`, `browser_snapshot`, `browser_exec`, `browser_close_session` — hold `*OrchestratorClient` + a per-request-bound `user_id`/`session_id` (mirroring how `extension_*` holds `*hub` + `user_id`). `browser_exec` is the full-verb passthrough (orchestrator enforces the §8.6 allowlist), so click/type/get_text/screenshot are reachable today; dedicated ergonomic wrappers are a follow-on (Plan 4b). Registration is gated on the agent_browser backend; the gateway passes the client + binds the user.

**Tech Stack:** Zig 0.15.2 (gateway compiles in ~25s in this worktree), `src/http_util.zig` (`curlRequest`), the orchestrator HTTP API from Plans 2–3b.

> **References:** spec §3/§4 (native tools, surface), §8.1 (approval metadata — these tools declare `mutating=high`); the exact code shapes are quoted inline below (verbatim from `src/tools/extension_navigate.zig`, `src/tools/root.zig`, `src/http_util.zig`, `src/config_types.zig`, `src/capabilities.zig`). The orchestrator runs at `config.browser.agent_browser.orchestrator_url`.

## Prerequisites
Build the gateway once to confirm the worktree is healthy: `cd /Users/nova/Desktop/nullalis-abk8s && zig build` (≈25s, must succeed). The orchestrator API contract: `POST /v1/sessions {user_id,auth_profile} → {session_id}`; `POST /v1/sessions/{id}/exec {args:[...]} → {stdout,stderr,exit_code}` (403 on disallowed verb); `DELETE /v1/sessions/{id} → {status}`.

## File Structure
- `src/browser_backend/client.zig` + tests — mockable `OrchestratorClient`.
- `src/tools/browser_new_session.zig`, `browser_navigate.zig`, `browser_snapshot.zig`, `browser_exec.zig`, `browser_close_session.zig` — the tools (clone `extension_navigate` shape).
- Modify `src/config_types.zig` — `BrowserConfig.agent_browser` sub-config.
- Modify `src/config_parse.zig` — parse it.
- Modify `src/tools/root.zig` — register `browser_*` when backend==agent_browser; **remove** `browser`/`browser_open` registration; add metadata; add `bindBrowserSessionTools`; add `agent_browser_client` to `allTools` opts.
- Modify `src/capabilities.zig` — advertise `browser_*` under the backend.
- Modify `src/gateway.zig` — construct the client when backend==agent_browser, pass to `allTools`, call `bindBrowserSessionTools` where `bindExtensionTools` would be.
- **Remove** `src/tools/browser.zig`, `src/tools/browser_open.zig`.

---

## Task 1: Mockable OrchestratorClient

**Files:** Create `src/browser_backend/client.zig`.

- [ ] **Step 1: Write the client + a mock-transport test**

`src/browser_backend/client.zig`:
```zig
const std = @import("std");
const http_util = @import("../http_util.zig");

pub const Response = struct { status_code: u16, body: []u8 };

/// Injectable transport so tools are unit-testable without a live orchestrator.
/// Default is `curl_transport`; tests supply a stub returning canned JSON.
pub const Transport = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, url: []const u8, body: ?[]const u8, timeout_secs: []const u8) anyerror!Response,
};

fn curlSend(_: *anyopaque, allocator: std.mem.Allocator, method: []const u8, url: []const u8, body: ?[]const u8, timeout_secs: []const u8) anyerror!Response {
    const r = try http_util.curlRequest(allocator, method, url, &.{}, body, null, timeout_secs);
    return .{ .status_code = r.status_code, .body = r.body };
}
var curl_ctx: u8 = 0;
pub const curl_transport = Transport{ .ctx = &curl_ctx, .sendFn = curlSend };

pub const OrchestratorClient = struct {
    base_url: []const u8,
    timeout_ms: u64 = 60_000,
    transport: Transport = curl_transport,

    fn timeoutSecs(self: OrchestratorClient, buf: []u8) []const u8 {
        const secs = (self.timeout_ms + 999) / 1000;
        return std.fmt.bufPrint(buf, "{d}", .{secs}) catch "60";
    }

    /// POST /v1/sessions {user_id, auth_profile} -> session_id (caller frees).
    pub fn newSession(self: OrchestratorClient, allocator: std.mem.Allocator, user_id: []const u8, auth_profile: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions", .{self.base_url});
        defer allocator.free(url);
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, "{\"user_id\":");
        try writeJsonString(allocator, &body, user_id);
        try body.appendSlice(allocator, ",\"auth_profile\":");
        try writeJsonString(allocator, &body, auth_profile);
        try body.append(allocator, '}');
        var tbuf: [16]u8 = undefined;
        const resp = try self.transport.sendFn(self.transport.ctx, allocator, "POST", url, body.items, self.timeoutSecs(&tbuf));
        defer allocator.free(resp.body);
        if (resp.status_code != 200) return error.OrchestratorError;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch return error.OrchestratorBadResponse;
        defer parsed.deinit();
        const obj = switch (parsed.value) { .object => |o| o, else => return error.OrchestratorBadResponse };
        const sid = switch (obj.get("session_id") orelse return error.OrchestratorBadResponse) { .string => |s| s, else => return error.OrchestratorBadResponse };
        return allocator.dupe(u8, sid);
    }

    /// POST /v1/sessions/{id}/exec {args} -> raw JSON body (caller frees) + status.
    pub fn exec(self: OrchestratorClient, allocator: std.mem.Allocator, session_id: []const u8, args_json: []const u8) !Response {
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions/{s}/exec", .{ self.base_url, session_id });
        defer allocator.free(url);
        const body = try std.fmt.allocPrint(allocator, "{{\"args\":{s}}}", .{args_json});
        defer allocator.free(body);
        var tbuf: [16]u8 = undefined;
        return self.transport.sendFn(self.transport.ctx, allocator, "POST", url, body, self.timeoutSecs(&tbuf));
    }

    /// DELETE /v1/sessions/{id}.
    pub fn closeSession(self: OrchestratorClient, allocator: std.mem.Allocator, session_id: []const u8) !void {
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions/{s}", .{ self.base_url, session_id });
        defer allocator.free(url);
        var tbuf: [16]u8 = undefined;
        const resp = try self.transport.sendFn(self.transport.ctx, allocator, "DELETE", url, null, self.timeoutSecs(&tbuf));
        allocator.free(resp.body);
        if (resp.status_code != 200) return error.OrchestratorError;
    }
};

const writeJsonString = @import("../tools/json_escape.zig").writeJsonString;

// ── tests ──
const TestTransport = struct {
    body: []const u8,
    status: u16 = 200,
    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: ?[]const u8, _: []const u8) anyerror!Response {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        return .{ .status_code = self.status, .body = try allocator.dupe(u8, self.body) };
    }
    fn transport(self: *TestTransport) Transport {
        return .{ .ctx = self, .sendFn = TestTransport.send };
    }
};

test "newSession parses session_id from a mock transport" {
    var tt = TestTransport{ .body = "{\"session_id\":\"abc123\"}" };
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    const sid = try c.newSession(std.testing.allocator, "alice", "");
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("abc123", sid);
}

test "newSession surfaces non-200 as error" {
    var tt = TestTransport{ .body = "{\"error\":\"cap\"}", .status = 429 };
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    try std.testing.expectError(error.OrchestratorError, c.newSession(std.testing.allocator, "alice", ""));
}
```

- [ ] **Step 2: Register the file in the build/test graph**

Confirm `src/browser_backend/client.zig` is reachable by the test runner. Run: `cd /Users/nova/Desktop/nullalis-abk8s && zig build test 2>&1 | tail -20`. If the test runner uses explicit test files / a `refAllDecls` root, add an `_ = @import("browser_backend/client.zig");` line wherever the root test aggregator lives (search: `grep -rn "refAllDecls\|test {" src/main.zig src/root.zig build.zig 2>/dev/null`). Expected: the two client tests run and PASS.

- [ ] **Step 3: Commit**

```bash
git add src/browser_backend/client.zig
git commit -m "feat(browser): mockable OrchestratorClient (newSession/exec/closeSession)"
```

---

## Task 2: `agent_browser` config sub-block

**Files:** Modify `src/config_types.zig`, `src/config_parse.zig`.

- [ ] **Step 1: Add the sub-config** — in `src/config_types.zig`, add above `BrowserConfig`:
```zig
pub const AgentBrowserConfig = struct {
    orchestrator_url: []const u8 = "http://browser-orchestrator.browser.svc.cluster.local:8080",
    timeout_ms: u64 = 60_000,
};
```
and add a field to `BrowserConfig`: `agent_browser: AgentBrowserConfig = .{},` (leave the existing fields, including `backend`, untouched).

- [ ] **Step 2: Parse it** — in `src/config_parse.zig`, inside the `if (root.get("browser")) |br|` block, after the `computer_use` parse, add:
```zig
            if (br.object.get("agent_browser")) |v| {
                if (v == .object) {
                    if (v.object.get("orchestrator_url")) |u| {
                        if (u == .string) self.browser.agent_browser.orchestrator_url = try self.allocator.dupe(u8, u.string);
                    }
                    if (v.object.get("timeout_ms")) |t| {
                        if (t == .integer) self.browser.agent_browser.timeout_ms = @intCast(t.integer);
                    }
                }
            }
```

- [ ] **Step 3:** `cd /Users/nova/Desktop/nullalis-abk8s && zig build` → compiles. Commit:
```bash
git add src/config_types.zig src/config_parse.zig
git commit -m "feat(browser): agent_browser config sub-block (orchestrator_url, timeout_ms)"
```

---

## Task 3: The five `browser_*` tools

**Files:** Create `src/tools/browser_new_session.zig`, `browser_navigate.zig`, `browser_snapshot.zig`, `browser_exec.zig`, `browser_close_session.zig`.

Each tool mirrors `extension_navigate`'s shape: fields `client: *OrchestratorClient`, `user_id: ?[]const u8 = null`, `session_id: ?[]const u8 = null` (where applicable); `tool_name`/`tool_description`/`tool_params`; `const vtable = root.ToolVTable(@This())`; `tool()`; `execute()`. Use the shared helper `interpretExecJson` (below) to turn an orchestrator exec `{stdout,stderr,exit_code}` (or `{error}`) response into a `ToolResult`.

- [ ] **Step 1: Shared exec-result interpreter** — put in `browser_exec.zig` and `pub`-export it (the other tools import it):
```zig
const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");
const writeJsonString = @import("json_escape.zig").writeJsonString;

/// Turn an orchestrator /exec Response into a ToolResult. On 200, returns the
/// stdout (the agent-browser output, e.g. an @eN snapshot or page title). On
/// non-200 (incl. 403 allowlist-deny, 5xx), returns a clear failure.
pub fn interpretExecResponse(allocator: std.mem.Allocator, resp: client_mod.Response) !ToolResult {
    defer allocator.free(resp.body);
    if (resp.status_code == 403) return ToolResult.fail("browser command not allowed by the orchestrator policy");
    if (resp.status_code != 200) {
        const msg = try std.fmt.allocPrint(allocator, "browser orchestrator error (status {d}): {s}", .{ resp.status_code, resp.body });
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch return ToolResult.fail("orchestrator returned malformed JSON");
    defer parsed.deinit();
    const obj = switch (parsed.value) { .object => |o| o, else => return ToolResult.fail("orchestrator returned non-object") };
    const stdout = if (obj.get("stdout")) |v| switch (v) { .string => |s| s, else => "" } else "";
    const out = try allocator.dupe(u8, stdout);
    return ToolResult{ .success = true, .output = out };
}
```

- [ ] **Step 2: `browser_exec` tool** (same file):
```zig
pub const BrowserExecTool = struct {
    client: *client_mod.OrchestratorClient,
    session_id: ?[]const u8 = null,

    pub const tool_name = "browser_exec";
    pub const tool_description = "Run a low-level agent-browser command in a browser session (passthrough). The orchestrator enforces an allowlist; eval/connect/raw-CDP are denied.";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Browser session id from browser_new_session."},"args":{"type":"array","items":{"type":"string"},"description":"agent-browser argv, e.g. [\"click\",\"@e1\"] or [\"get\",\"text\",\"body\"]."}},"required":["session_id","args"]}
    ;
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *BrowserExecTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }

    pub fn execute(self: *BrowserExecTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sid = root.getString(args, "session_id") orelse return ToolResult.fail("missing 'session_id'");
        const args_val = args.get("args") orelse return ToolResult.fail("missing 'args'");
        const args_json = try std.json.Stringify.valueAlloc(allocator, args_val, .{});
        defer allocator.free(args_json);
        const resp = self.client.exec(allocator, sid, args_json) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "browser orchestrator unreachable: {s}", .{@errorName(e)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        return interpretExecResponse(allocator, resp);
    }
};
```

- [ ] **Step 3: `browser_navigate`** — builds the open argv (the worker uses the `/usr/local/bin/chromium-ns` wrapper; the executable-path is a known worker-image constant):
```zig
// src/tools/browser_navigate.zig
const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");
const interpretExecResponse = @import("browser_exec.zig").interpretExecResponse;
const writeJsonString = @import("json_escape.zig").writeJsonString;

const EXEC_PATH = "/usr/local/bin/chromium-ns";

pub const BrowserNavigateTool = struct {
    client: *client_mod.OrchestratorClient,
    session_id: ?[]const u8 = null,
    pub const tool_name = "browser_navigate";
    pub const tool_description = "Navigate a browser session to a URL (headless, in-cluster). Use browser_snapshot afterward to get @eN refs for interaction.";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string"},"url":{"type":"string","description":"Absolute http/https URL."}},"required":["session_id","url"]}
    ;
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *BrowserNavigateTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn execute(self: *BrowserNavigateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sid = root.getString(args, "session_id") orelse return ToolResult.fail("missing 'session_id'");
        const url = root.getString(args, "url") orelse return ToolResult.fail("missing 'url'");
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return ToolResult.fail("url must be http(s)");
        // argv = ["--executable-path", EXEC_PATH, "open", <url>]
        var aj: std.ArrayListUnmanaged(u8) = .empty;
        defer aj.deinit(allocator);
        try aj.appendSlice(allocator, "[\"--executable-path\",\"" ++ EXEC_PATH ++ "\",\"open\",");
        try writeJsonString(allocator, &aj, url);
        try aj.append(allocator, ']');
        const resp = self.client.exec(allocator, sid, aj.items) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "browser orchestrator unreachable: {s}", .{@errorName(e)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        return interpretExecResponse(allocator, resp);
    }
};
```

- [ ] **Step 4: `browser_snapshot`** — identical shape; `tool_name="browser_snapshot"`; params `{"session_id"}` required; argv `["snapshot"]` (build `aj` = `"[\"snapshot\"]"`); same exec + interpret. Description: "Return the accessibility tree of the current page with @eN refs for the agent to act on."

- [ ] **Step 5: `browser_new_session`** — fields `client`, `user_id`; params `{"auth_profile":{optional}}`; execute: `const uid = self.user_id orelse return ToolResult.fail("browser_new_session not bound to a user (gateway-side wiring bug)");` then `const profile = root.getString(args,"auth_profile") orelse "";` then `const sid = self.client.newSession(allocator, uid, profile) catch |e| {...unreachable error...};` then return `{"session_id":"..."}` JSON: `const out = try std.fmt.allocPrint(allocator, "{{\"session_id\":{s}}}", .{quoted_sid})` — escape sid via writeJsonString into a buffer. Free `sid`. Description: "Open a new browser session; returns a session_id to pass to the other browser_* tools." `tool_params` = `{"type":"object","properties":{"auth_profile":{"type":"string","description":"Optional saved-login profile to inject."}}}`.

- [ ] **Step 6: `browser_close_session`** — fields `client`; params `{"session_id"}` required; execute: `self.client.closeSession(allocator, sid) catch ...`; return `ToolResult{ .success = true, .output = try allocator.dupe(u8, "{\"status\":\"closed\"}") }`.

- [ ] **Step 7: A unit test per tool using the mock transport** — add to `browser_exec.zig` (and one for navigate) a test like:
```zig
test "browser_exec returns stdout on 200" {
    var tt = client_mod.TestTransportPub{ .body = "{\"stdout\":\"- heading [ref=e1]\",\"exit_code\":0}" };
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    var et = BrowserExecTool{ .client = &cl };
    const parsed = try root.parseTestArgs("{\"session_id\":\"s1\",\"args\":[\"snapshot\"]}");
    defer parsed.deinit();
    const r = try et.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ref=e1") != null);
}
test "browser_exec maps 403 to a clear denial" {
    var tt = client_mod.TestTransportPub{ .body = "{}", .status = 403 };
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    var et = BrowserExecTool{ .client = &cl };
    const parsed = try root.parseTestArgs("{\"session_id\":\"s1\",\"args\":[\"eval\",\"x\"]}");
    defer parsed.deinit();
    const r = try et.execute(std.testing.allocator, parsed.value.object);
    defer if (r.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.error_msg.?, "not allowed") != null);
}
```
> To make `TestTransport` usable from tool tests, in `client.zig` rename the test helper to a `pub const TestTransportPub` (exported) so tool files can construct it. (Keep the two client-internal tests working.)

- [ ] **Step 8:** `zig build test 2>&1 | tail -20` → the new tool tests PASS. Commit:
```bash
git add src/tools/browser_new_session.zig src/tools/browser_navigate.zig src/tools/browser_snapshot.zig src/tools/browser_exec.zig src/tools/browser_close_session.zig src/browser_backend/client.zig
git commit -m "feat(browser): native browser_* tools (new_session/navigate/snapshot/exec/close)"
```

---

## Task 4: Gateway gate — register, bind, advertise; remove legacy

**Files:** Modify `src/tools/root.zig`, `src/capabilities.zig`, `src/gateway.zig`. Remove `src/tools/browser.zig`, `src/tools/browser_open.zig`.

- [ ] **Step 1: `allTools` opts + registration** (`src/tools/root.zig`):
  (a) Add to the `allTools` opts struct: `agent_browser_client: ?*@import("../browser_backend/client.zig").OrchestratorClient = null,`.
  (b) Add a registration block (near the extension_* block):
```zig
    if (opts.agent_browser_client) |bc| {
        const ns = try allocator.create(browser_new_session.BrowserNewSessionTool);
        ns.* = .{ .client = bc };
        try list.append(allocator, ns.tool());
        const nav = try allocator.create(browser_navigate.BrowserNavigateTool);
        nav.* = .{ .client = bc };
        try list.append(allocator, nav.tool());
        const snap = try allocator.create(browser_snapshot.BrowserSnapshotTool);
        snap.* = .{ .client = bc };
        try list.append(allocator, snap.tool());
        const ex = try allocator.create(browser_exec.BrowserExecTool);
        ex.* = .{ .client = bc };
        try list.append(allocator, ex.tool());
        const cl = try allocator.create(browser_close_session.BrowserCloseSessionTool);
        cl.* = .{ .client = bc };
        try list.append(allocator, cl.tool());
    }
```
  (c) Add the `@import` lines at the top for the five tool files.
  (d) **Remove** the legacy registration: delete the `if (opts.browser_enabled) { ... browser.BrowserTool ... }` block and the `if (opts.browser_open_domains) |...| { ... browser_open.BrowserOpenTool ... }` block, plus the `browser`/`browser_open` `@import`s and their `DEFAULT_TOOL_METADATA` entries.
  (e) Add `DEFAULT_TOOL_METADATA` entries for the five browser_* tools: `browser_new_session` (mutating, high, cost_class .b), `browser_navigate` (mutating, high, .b), `browser_snapshot` (read_only, medium, .a), `browser_exec` (mutating, high, .c), `browser_close_session` (mutating, low, .a).
  (f) Add `bindBrowserSessionTools(tools, user_id)` mirroring `bindExtensionTools`: for each of `browser_new_session` (the only one needing the user_id — set `.user_id`), set `ent.user_id = user_id`. (The other tools key off `session_id` args, not a bound user.)

- [ ] **Step 2: capabilities** (`src/capabilities.zig`): add `"browser_navigate"`, `"browser_snapshot"`, `"browser_exec"`, `"browser_new_session"`, `"browser_close_session"` to `optional_tool_names`; remove `"browser"` and `"browser_open"`. In `optionalToolEnabledByConfig`, replace the `browser`/`browser_open` lines with: for each `browser_*` name `return cfg.browser.enabled and std.mem.eql(u8, cfg.browser.backend, "agent_browser");`.

- [ ] **Step 3: gateway wiring** (`src/gateway.zig`, the `allTools` call ~line 1963): construct the client when the backend is active, and pass it:
```zig
        var agent_browser_client_storage: @import("browser_backend/client.zig").OrchestratorClient = undefined;
        const agent_browser_client: ?*@import("browser_backend/client.zig").OrchestratorClient =
            if (runtime.config.browser.enabled and std.mem.eql(u8, runtime.config.browser.backend, "agent_browser")) blk: {
                agent_browser_client_storage = .{ .base_url = runtime.config.browser.agent_browser.orchestrator_url, .timeout_ms = runtime.config.browser.agent_browser.timeout_ms };
                break :blk &agent_browser_client_storage;
            } else null;
```
(ensure `agent_browser_client_storage` outlives the tools — if `allTools`' result is used beyond this scope, hoist the storage to the same lifetime as the tools/runtime; match the surrounding lifetime pattern. If the tools are rebuilt per-turn, a per-turn stack var is fine as long as binding + use happen within the turn.) Then in the `allTools(.{...})` opts add `.agent_browser_client = agent_browser_client,` and **remove** `.browser_enabled` / `.browser_open_domains`. Where the code binds per-user tools (search for `bindExtensionTools` usage — if present in this path; if not, add the bind right after `allTools` returns), call `tools_mod.bindBrowserSessionTools(builtin_tools, user_ctx.user_id);`.
> Lifetime note: if `OrchestratorClient` must live as long as the tool slice, allocate it with the same allocator/lifetime as the tools (e.g. `allocator.create`) rather than a stack var; the implementer should match the existing tool-lifetime pattern and verify with a build + the existing gateway tests.

- [ ] **Step 4: Remove the legacy tool files**
```bash
git rm src/tools/browser.zig src/tools/browser_open.zig
```
Fix any remaining references (grep for `browser.BrowserTool`, `browser_open.BrowserOpenTool`, `BrowserTool`, `BrowserOpenTool` across `src/` and remove/replace). Update any test that referenced them.

- [ ] **Step 5: Build + full test**
```bash
cd /Users/nova/Desktop/nullalis-abk8s && zig build && zig build test 2>&1 | tail -30
```
Expected: compiles; all tests pass (the removed-tool tests are gone; the new browser_* tests pass). If a test or capability test asserts `browser`/`browser_open` exist, update it to assert the `browser_*` set under the agent_browser backend.

- [ ] **Step 6: Commit**
```bash
git add -A
git commit -m "feat(browser): gate browser_* on agent_browser backend, bind user, advertise; remove legacy browser/browser_open"
```

---

## Task 5: Live integration smoke (optional, gated)

**Files:** none (operational).

- [ ] **Step 1:** Run the orchestrator locally against k3d and drive a real session through the gateway client transport (not the agent loop). From `services/browser-orchestrator`: `AGENT_BROWSER_STATE_MASTER_KEY=$(openssl rand -hex 32) GOTOOLCHAIN=local go run . &` (listens :8080; talks to the k3d cluster via your kubeconfig). Then a tiny Zig or `curl` check that `POST localhost:8080/v1/sessions` → session_id, `.../exec {args:["--executable-path","/usr/local/bin/chromium-ns","open","https://example.com"]}` → 200, `.../exec {args:["snapshot"]}` → contains `ref=e`, `DELETE` → closed. (This is the same path the tools use.) Record the result; kill the orchestrator. This is a manual confidence check, not a committed test.

---

## Done criteria (Plan 4)
- `OrchestratorClient` unit-tested with a mock transport (newSession parse + non-200 error).
- Five `browser_*` tools exist, dispatch via the client, and have mock-transport unit tests (incl. 403→clear denial).
- Registration gated on `config.browser.backend == "agent_browser"`; `browser_new_session` is per-user-bound via `bindBrowserSessionTools`; capabilities advertise the set under that backend.
- Legacy `browser`/`browser_open` tools + their registration/metadata/capabilities entries are **removed**; `zig build && zig build test` are green.
- (Optional) live smoke: a real session create→navigate→snapshot(@eN)→close through the orchestrator+k3d.

**Carry-forward / next:** ergonomic wrappers (`browser_click`/`type`/`get_text`/`screenshot`/`wait_for`/`scroll`) as thin exec-wrappers (Plan 4b, optional — `browser_exec` already covers them); **Plan 5** = the in-app view-feed (`browser_frame` SSE + Zaki contract); **Plan 6** = decommission (.spike/playwright-mcp, dead config, doc reconciliation, single-source SSRF); **Plan 7** = extension productionization. Also fold in the Plan-3b carry-forwards that are gateway-side: the orchestrator must get HTTP read/write timeouts + graceful shutdown, and the gateway must keep `user_id` bound to the authenticated principal (done here via `bindBrowserSessionTools`).

**Plan-4 dedicated-code-review carry-forwards:**
- **(IMPORTANT, defense-in-depth) Orchestrator-side URL pre-check.** `browser_navigate` only checks the `http(s)://` prefix (no RFC1918/metadata/encoded-IP block like `extension_navigate`'s `url_sanitize`), and `browser_exec` can also `open` a URL — so a gateway-tool-only check would be incomplete. The correct fix is an **orchestrator** URL pre-check that fires on `open`/`goto`/`navigate` verbs for *all* exec calls, reusing the shared SSRF block-list (single-source with Plan 6). **Not exploitable today** — the Plan-1 NetworkPolicy drops egress to RFC1918/metadata (proven), which stays as the enforced backstop. Do this in the security/decommission pass.
- **(MINOR) `EXEC_PATH` hardcoded** in `browser_navigate` (`/usr/local/bin/chromium-ns`). Move `--executable-path` injection into the orchestrator (it owns the worker image) so the gateway sends just `["open", url]` and a worker-image path change can't silently break navigate. Alternatively config-drive it (`agent_browser.executable_path`).
