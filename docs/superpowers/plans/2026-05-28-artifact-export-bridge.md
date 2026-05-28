# Artifact Export → produce_document Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 501 stub at `src/gateway.zig:11381-11406` with a production bridge that calls `ProduceDocumentTool.execute()`, writes output under `<workspace>/attachments/produced/`, and exposes a user-scoped GET endpoint to download the produced file.

**Architecture:** The export handler becomes a thin gateway adapter: it (1) validates ownership via `getArtifactById`, (2) fetches the latest content via `getArtifactVersion`, (3) builds a `std.json.ObjectMap` and calls `ProduceDocumentTool.execute()` directly (typed call, not via vtable), (4) parses the markdown link the tool returns to extract the produced filename, and (5) responds with structured JSON containing both the relative attachment path and an authenticated download URL. A separate `GET /api/v1/users/:userId/exports/:filename` handler serves the produced file with the correct binary `Content-Type`, gated on filename safety and confined to `<workspace>/attachments/produced/`.

**Tech Stack:** Zig 0.14, `std.json.ObjectMap`, `std.fs.openFileAbsolute`, `RouteResponse{ .content_type = ... }`. The bridge piggybacks on existing helpers `parseQueryParam`, `parseNumericUserId`, `isValidArtifactId`, `isSafeAttachmentFilename`, `jsonEscapeInto`, `finalizeJsonBuf`, `response_build_err`.

---

## File Structure

**Modify:**
- `src/gateway.zig`
  - Replace handler body at `src/gateway.zig:11381-11406` and change its signature to take `*const UserContext` + `?*const Config`.
  - Add small helpers (`parseProducedFilename`, `producedContentType`) above the handler.
  - Add new `handleArtifactExportDownload` next to `handleAttachmentUpload` (~line 18011).
  - Update artifact dispatch at `src/gateway.zig:17740-17743` to pass `&user_ctx` + `config_opt`.
  - Insert a new dispatch arm `/exports/:filename` next to `attachments` at `src/gateway.zig:17358`.
  - Update the route-table comment at `src/gateway.zig:17699` (drop the "(501)" annotation; add the new `/exports/:filename` row).
  - Update test at `src/gateway.zig:29508-29521` so it asserts a 400 invalid-format path (since the success path requires a live DB).
  - Add 4 new tests next to it for: invalid format, missing artifact (state_unavailable when DB absent), cross-user isolation, renderer unavailable (live PG gated).

- `docs/deferred-register.md` — append a row marking artifact-export bridge SHIPPED, citing the new file:line.
- `STATUS.md` — flip artifact export from "stubbed at gateway" to "shipped" in the canvas/artifacts section.

**No new files.** The whole change lives inside `src/gateway.zig` to follow the codebase's monolith pattern.

---

## Bite-Sized Task Granularity

Each task is one atomic commit. Commit messages follow the codebase's `feat(scope): summary` / `fix(scope): summary` style.

---

## Task 1: Add helpers for parsing produce_document output and content-type lookup

**Files:**
- Modify: `src/gateway.zig` — insert two new helper fns immediately above `handleArtifactExport` (currently at line 11381).

**Rationale:** `ProduceDocumentTool.execute()` returns a markdown link of the form `[Generated PDF: report_<ts>_<rand>.pdf](attachments/produced/report_<ts>_<rand>.pdf)`. The gateway needs the **filename** (for the download URL) and the **relative path** (for the JSON `path` field). The Content-Type lookup is a tiny switch on the format string.

- [ ] **Step 1: Write the failing tests for the helpers**

Add these tests at the end of `src/gateway.zig` (just before the closing of the file's test block — search for the last existing `test "..." {`). They cover both helpers in isolation.

```zig
test "parseProducedFilename extracts the produced filename from tool markdown" {
    const md = "[Generated PDF: report_1716_a1b2c3d4.pdf](attachments/produced/report_1716_a1b2c3d4.pdf)";
    const fn_opt = parseProducedFilename(md);
    try std.testing.expect(fn_opt != null);
    try std.testing.expectEqualStrings("report_1716_a1b2c3d4.pdf", fn_opt.?);
}

test "parseProducedFilename returns null on malformed input" {
    try std.testing.expect(parseProducedFilename("not a link") == null);
    try std.testing.expect(parseProducedFilename("[just text]") == null);
    try std.testing.expect(parseProducedFilename("[Generated PDF: x.pdf](no-prefix/x.pdf)") == null);
}

test "producedContentType returns the right MIME for each format" {
    try std.testing.expectEqualStrings("application/pdf", producedContentType("pdf"));
    try std.testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        producedContentType("docx"),
    );
    try std.testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        producedContentType("pptx"),
    );
    try std.testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        producedContentType("xlsx"),
    );
    try std.testing.expectEqualStrings("text/html; charset=utf-8", producedContentType("html"));
    try std.testing.expectEqualStrings("application/octet-stream", producedContentType("???"));
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `zig build test --summary all 2>&1 | grep -E "parseProducedFilename|producedContentType"`
Expected: compile errors / undefined symbol `parseProducedFilename` and `producedContentType`.

- [ ] **Step 3: Add the two helpers in `src/gateway.zig` immediately above `handleArtifactExport`**

Insert at `src/gateway.zig:11380` (just before the `fn handleArtifactExport(` line):

```zig
/// Parse the markdown link `ProduceDocumentTool.execute()` returns and
/// extract the produced filename. Format:
///   `[Generated FORMAT: <filename>](attachments/produced/<filename>)`
/// Returns null on any deviation — the gateway treats that as a render
/// failure rather than guessing.
fn parseProducedFilename(md: []const u8) ?[]const u8 {
    const open_paren = std.mem.indexOfScalar(u8, md, '(') orelse return null;
    if (!std.mem.endsWith(u8, md, ")")) return null;
    const path = md[open_paren + 1 .. md.len - 1];
    const prefix = "attachments/produced/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const name = path[prefix.len..];
    if (name.len == 0) return null;
    return name;
}

/// Map a `produce_document` format string to a serving Content-Type.
/// Unknown formats fall back to `application/octet-stream`.
fn producedContentType(format: []const u8) []const u8 {
    if (std.mem.eql(u8, format, "pdf")) return "application/pdf";
    if (std.mem.eql(u8, format, "docx")) return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    if (std.mem.eql(u8, format, "pptx")) return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
    if (std.mem.eql(u8, format, "xlsx")) return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    if (std.mem.eql(u8, format, "html")) return "text/html; charset=utf-8";
    return "application/octet-stream";
}
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: 0 failures; the 3 new tests listed in summary.

- [ ] **Step 5: Commit**

```bash
git add src/gateway.zig
git commit -m "$(cat <<'EOF'
feat(gateway): add parseProducedFilename + producedContentType helpers

Pre-work for the artifact export bridge: the gateway needs to peel the
produced filename out of `produce_document`'s markdown response and pick
the right binary Content-Type when streaming the file back to the user.
Both are pure / O(1) and tested in isolation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Replace the 501 stub with the production export handler

**Files:**
- Modify: `src/gateway.zig:11381-11406` (the existing `handleArtifactExport` body and signature).
- Modify: `src/gateway.zig:17740-17743` (the dispatch arm — pass `&user_ctx` and `config_opt`).

**Rationale:** The handler needs (a) state_mgr for ownership-checked artifact/version fetch, (b) `user_ctx.workspace_path` to point `ProduceDocumentTool` at the right output directory, and (c) `config_opt` for operator branding. The dispatch site already has all three in scope (resolved at `src/gateway.zig:16442`).

- [ ] **Step 1: Replace the handler at `src/gateway.zig:11381` with the production body**

Replace the existing `fn handleArtifactExport(...) RouteResponse { ... }` (lines 11381-11406) with this:

```zig
fn handleArtifactExport(
    allocator: std.mem.Allocator,
    method: []const u8,
    user_id_str: []const u8,
    artifact_id: []const u8,
    target: []const u8,
    user_ctx: *const UserContext,
    config_opt: ?*const Config,
    state: *GatewayState,
) RouteResponse {
    if (!std.mem.eql(u8, method, "POST")) {
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method_not_allowed\"}" };
    }
    if (!isValidArtifactId(artifact_id)) {
        return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_artifact_id\"}" };
    }
    const numeric_user_id = parseNumericUserId(user_id_str) catch {
        return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_user_id\"}" };
    };

    // Allowlist matches `produce_document`'s `Format` enum; we validate
    // up-front so a bad value returns 400 before we touch the DB.
    const format_raw = parseQueryParam(target, "format") orelse "pdf";
    if (!(std.mem.eql(u8, format_raw, "pdf") or
          std.mem.eql(u8, format_raw, "docx") or
          std.mem.eql(u8, format_raw, "pptx") or
          std.mem.eql(u8, format_raw, "xlsx") or
          std.mem.eql(u8, format_raw, "html")))
    {
        return .{
            .status = "400 Bad Request",
            .body = "{\"error\":\"invalid_format\",\"detail\":\"format must be one of: pdf, docx, pptx, xlsx, html\"}",
        };
    }

    const state_mgr = state.zaki_state orelse {
        return .{
            .status = "503 Service Unavailable",
            .body = "{\"error\":\"state_unavailable\",\"detail\":\"persistent state backend not configured; artifacts require postgres\"}",
        };
    };

    // Ownership + existence check (mirrors handleArtifactGet at :11029).
    const artifact_opt = state_mgr.getArtifactById(allocator, numeric_user_id, artifact_id) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read_failed\"}" };
    };
    if (artifact_opt == null) {
        return .{ .status = "404 Not Found", .body = "{\"error\":\"artifact_not_found\"}" };
    }
    var artifact = artifact_opt.?;
    defer artifact.deinit(allocator);

    const ver_opt = state_mgr.getArtifactVersion(allocator, numeric_user_id, artifact_id, null) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"version_read_failed\"}" };
    };
    if (ver_opt == null) {
        return .{ .status = "404 Not Found", .body = "{\"error\":\"version_not_found\"}" };
    }
    var ver = ver_opt.?;
    defer ver.deinit(allocator);

    // Build the tool args. We always use the safe `default` theme — branding
    // is operator-owned and applies automatically when configured; the user's
    // export request must NOT pick `thmanyah` (per §14.5 honesty gate).
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    args.put("format", std.json.Value{ .string = format_raw }) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"args_alloc_failed\"}" };
    };
    args.put("content", std.json.Value{ .string = ver.content }) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"args_alloc_failed\"}" };
    };
    args.put("title", std.json.Value{ .string = artifact.title }) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"args_alloc_failed\"}" };
    };
    args.put("theme", std.json.Value{ .string = "default" }) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"args_alloc_failed\"}" };
    };

    var pdt = produce_document_mod.ProduceDocumentTool{
        .workspace_dir = user_ctx.workspace_path,
        .branding = if (config_opt) |cfg| cfg.branding else .{},
    };
    const tool_result = pdt.execute(allocator, args) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"export_failed\",\"detail\":\"tool dispatch raised an error\"}" };
    };
    // Ownership note: produce_document allocates `output` and `error_msg`
    // with our allocator, so we must free them. The `.fail()` helper returns
    // a static literal which is safe to "free" via this same path because
    // produce_document's failure paths all use allocPrint when they store an
    // error string (see produce_document.zig:230-308). Be conservative:
    // free only when length > 0 / non-null.
    defer if (tool_result.output.len > 0) allocator.free(tool_result.output);
    defer if (tool_result.error_msg) |em| {
        // `ToolResult.fail("<literal>")` stores a `.error` string the caller
        // must NOT free. We detect that by checking against the known set of
        // literals produce_document emits; everything else is heap.
        if (!isProduceDocumentLiteralError(em)) allocator.free(em);
    };

    if (!tool_result.success) {
        const err = tool_result.error_msg orelse "render failed";
        // Renderer-missing failures: surface 502 with `renderer_unavailable`
        // so callers can distinguish "binary not installed in image" from
        // "user-provided content was rejected". `produce_document` includes
        // install-hint phrases like "install:" / "not found" / "Install" in
        // those error strings.
        const is_renderer_gap =
            std.mem.indexOf(u8, err, "install:") != null or
            std.mem.indexOf(u8, err, "Install:") != null or
            std.mem.indexOf(u8, err, "install ") != null or
            std.mem.indexOf(u8, err, "not found") != null or
            std.mem.indexOf(u8, err, "FileNotFound") != null or
            std.mem.indexOf(u8, err, "marp-cli") != null or
            std.mem.indexOf(u8, err, "pandoc") != null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        const w = out.writer(allocator);
        if (is_renderer_gap) {
            w.writeAll("{\"error\":\"renderer_unavailable\",\"detail\":\"") catch return response_build_err;
        } else {
            w.writeAll("{\"error\":\"export_failed\",\"detail\":\"") catch return response_build_err;
        }
        jsonEscapeInto(w, err) catch return response_build_err;
        w.writeAll("\"}") catch return response_build_err;
        const body = out.toOwnedSlice(allocator) catch {
            out.deinit(allocator);
            return response_build_err;
        };
        return .{
            .status = if (is_renderer_gap) "502 Bad Gateway" else "500 Internal Server Error",
            .body = body,
        };
    }

    // Success — parse the produced filename out of the markdown link.
    const filename = parseProducedFilename(tool_result.output) orelse {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"export_failed\",\"detail\":\"renderer succeeded but filename could not be parsed\"}" };
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    w.writeAll("{\"status\":\"exported\",\"artifact_id\":\"") catch return response_build_err;
    jsonEscapeInto(w, artifact_id) catch return response_build_err;
    w.writeAll("\",\"format\":\"") catch return response_build_err;
    jsonEscapeInto(w, format_raw) catch return response_build_err;
    w.writeAll("\",\"filename\":\"") catch return response_build_err;
    jsonEscapeInto(w, filename) catch return response_build_err;
    w.writeAll("\",\"path\":\"attachments/produced/") catch return response_build_err;
    jsonEscapeInto(w, filename) catch return response_build_err;
    w.writeAll("\",\"url\":\"/api/v1/users/") catch return response_build_err;
    jsonEscapeInto(w, user_id_str) catch return response_build_err;
    w.writeAll("/exports/") catch return response_build_err;
    jsonEscapeInto(w, filename) catch return response_build_err;
    w.writeAll("\",\"download_url\":\"/api/v1/users/") catch return response_build_err;
    jsonEscapeInto(w, user_id_str) catch return response_build_err;
    w.writeAll("/exports/") catch return response_build_err;
    jsonEscapeInto(w, filename) catch return response_build_err;
    w.writeAll("\"}") catch return response_build_err;
    return finalizeJsonBuf(allocator, &out);
}

/// Recognize the static-literal error strings `produce_document.ToolResult.fail()`
/// uses, so the caller does NOT free them. Heap-allocated error strings (via
/// allocPrint) are everything else and MUST be freed.
fn isProduceDocumentLiteralError(em: []const u8) bool {
    return std.mem.eql(u8, em, "Missing 'format' parameter (one of: pdf, docx, xlsx, pptx, html)") or
        std.mem.eql(u8, em, "Missing 'content' parameter") or
        std.mem.eql(u8, em, "'content' must not be empty") or
        std.mem.eql(u8, em, "Workspace not configured — tool has no place to write the produced document");
}
```

- [ ] **Step 2: Add the produce_document module import**

Search for the existing imports block near the top of `src/gateway.zig` (look for `const tools_mod = @import(`). Add this alias right after it (keep alphabetical order if obvious):

```zig
const produce_document_mod = @import("tools/produce_document.zig");
```

Verify it lands once — `grep -n "produce_document_mod" src/gateway.zig` should return exactly 1 import line plus the call site we just added.

- [ ] **Step 3: Update the dispatch arm at `src/gateway.zig:17740-17743`**

Replace the existing block:

```zig
        if (std.mem.eql(u8, suffix, "export")) {
            const target = extractRequestTarget(raw_request) orelse base_path;
            return handleArtifactExport(req_allocator, method, scoped_user_id, artifact_id, target, state);
        }
```

with:

```zig
        if (std.mem.eql(u8, suffix, "export")) {
            const target_full = extractRequestTarget(raw_request) orelse base_path;
            return handleArtifactExport(req_allocator, method, scoped_user_id, artifact_id, target_full, &user_ctx, config_opt, state);
        }
```

(Renamed the local from `target` to `target_full` to avoid shadowing the outer `target` parameter of the dispatch function — Zig 0.14 will compile either way, but the rename makes the read-order obvious.)

- [ ] **Step 4: Update the route-table comment at `src/gateway.zig:17699`**

Replace:

```zig
    //   POST   /artifacts/:id/export?format=...        → produce_document bridge (501)
```

with:

```zig
    //   POST   /artifacts/:id/export?format=pdf|docx|pptx|xlsx|html → produce_document bridge
```

- [ ] **Step 5: Build to confirm it compiles**

Run: `zig build 2>&1 | tail -30`
Expected: a clean build with no errors. (Warnings about unused params are NOT expected — we use every parameter.)

- [ ] **Step 6: Commit**

```bash
git add src/gateway.zig
git commit -m "$(cat <<'EOF'
feat(gateway): wire artifact export to ProduceDocumentTool (close 501 stub)

Replaces the 501 placeholder at handleArtifactExport with a production
bridge: fetches the artifact (ownership-checked) + latest version, builds
a JsonObjectMap and calls ProduceDocumentTool.execute() with the default
theme (branding stays operator-owned, never user-controllable per §14.5),
and returns structured JSON with the produced filename + a per-user
authenticated download URL.

Wave 2A dependency satisfied — ZAKI prod BFF
POST /api/agent/artifacts/:id/export?format=pdf now resolves to a real
document instead of "feature parked." Renderer-missing failures surface
as 502 renderer_unavailable with the install hint so the FE can guide the
operator instead of crashing the agent loop.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add the `GET /api/v1/users/:userId/exports/:filename` download endpoint

**Files:**
- Modify: `src/gateway.zig` — add `handleArtifactExportDownload` next to `handleAttachmentUpload` (~line 18011).
- Modify: `src/gateway.zig:17358` area — add the dispatch arm.

**Rationale:** The export JSON response references `/api/v1/users/{id}/exports/{filename}`. That route doesn't exist yet — nothing currently streams a file out of `<workspace>/attachments/produced/`. The handler must be user-scoped, traversal-safe, and limited to produced files (NOT every workspace file).

- [ ] **Step 1: Add `handleArtifactExportDownload` after `handleAttachmentUpload`**

Insert immediately after the closing `}` of `handleAttachmentUpload` (at `src/gateway.zig:18011`):

```zig
/// GET /api/v1/users/{id}/exports/{filename}
/// Streams a single file from {workspace_path}/attachments/produced/{filename}.
/// User-scoped (the caller has already authenticated against this user_ctx);
/// confined to the `produced/` subtree; filename safety enforced by
/// isSafeAttachmentFilename (blocks .., /, hidden, control chars).
///
/// Response:
///   200 OK + binary body, Content-Type derived from filename extension.
///   400 if filename fails the safety check.
///   404 if the file is not present in attachments/produced/.
///   500 on I/O / alloc failure.
fn handleArtifactExportDownload(
    allocator: std.mem.Allocator,
    method: []const u8,
    filename: []const u8,
    user_ctx: *const UserContext,
) RouteResponse {
    if (!std.mem.eql(u8, method, "GET")) {
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method_not_allowed\"}" };
    }
    if (!isSafeAttachmentFilename(filename)) {
        return .{ .status = "400 Bad Request", .body = "{\"error\":\"unsafe_filename\"}" };
    }

    const path = std.fmt.allocPrint(
        allocator,
        "{s}/attachments/produced/{s}",
        .{ user_ctx.workspace_path, filename },
    ) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path_build_failed\"}" };
    };
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.AccessDenied =>
            return .{ .status = "404 Not Found", .body = "{\"error\":\"export_not_found\"}" },
        else => return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"open_failed\"}" },
    };
    defer file.close();

    const stat = file.stat() catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"stat_failed\"}" };
    };
    // 50 MB cap matches ProduceDocumentTool.MAX_OUTPUT_BYTES — files that
    // could not have been produced by the bridge must not be served.
    if (stat.size > 50 * 1024 * 1024) {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"file_too_large\"}" };
    }

    const body = allocator.alloc(u8, @intCast(stat.size)) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"alloc_failed\"}" };
    };
    const read = file.readAll(body) catch {
        allocator.free(body);
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read_failed\"}" };
    };
    if (read != stat.size) {
        allocator.free(body);
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"short_read\"}" };
    }

    // Derive Content-Type from the filename extension — produced files are
    // named `<title>_<ts>_<rand>.<ext>` so extension matching is reliable.
    const ext = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse break :blk "";
        break :blk filename[dot + 1 ..];
    };
    return .{
        .body = body,
        .content_type = producedContentType(ext),
    };
}
```

- [ ] **Step 2: Add the dispatch arm**

Find the existing attachments dispatch at `src/gateway.zig:17358`:

```zig
    if (std.mem.eql(u8, parsed.subpath, "attachments")) {
        return handleAttachmentUpload(req_allocator, method, raw_request, &user_ctx);
    }
```

Insert immediately AFTER its closing `}` (so before the `/brain/graph` block comment at ~17363):

```zig
    // ── Exports (Wave 2A artifact-export bridge) ───────────────────────
    // GET /api/v1/users/{id}/exports/{filename}
    // Streams a single produced file out of
    // {workspace_path}/attachments/produced/. User-scoped (UserContext
    // selection above this call enforces ownership) + filename traversal
    // guarded. Mirrors handleAttachmentUpload but read-only and limited
    // to the produced/ subdirectory.
    if (std.mem.startsWith(u8, parsed.subpath, "exports/")) {
        const filename = parsed.subpath["exports/".len..];
        return handleArtifactExportDownload(req_allocator, method, filename, &user_ctx);
    }
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `zig build 2>&1 | tail -30`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/gateway.zig
git commit -m "$(cat <<'EOF'
feat(gateway): GET /api/v1/users/:id/exports/:filename — serve produced files

Adds the authenticated file-serving route the artifact export bridge
references in its JSON response. Confined to <workspace>/attachments/
produced/ (the directory ProduceDocumentTool owns); filename guarded
by isSafeAttachmentFilename so ..-traversal, hidden files, and path
separators cannot escape the produced subtree; per-user scoping is
inherited from the UserContext resolution upstream of dispatch.

Content-Type is derived from the filename extension via the same
producedContentType helper the bridge uses, so a /export response and
its /exports/<filename> follow-up GET agree on the MIME type.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Update the existing 501 test and add the new coverage

**Files:**
- Modify: `src/gateway.zig:29508-29521` (the "stubs as 501" test) — rewrite it to assert invalid-format → 400.
- Insert: 4 new tests next to it.

**Rationale:** The 501 test is no longer factually true. Replace it with the simpler "invalid format → 400" coverage; that exercises the up-front allowlist without needing a state backend. Then add three more unit-level tests (missing artifact when state absent → 503; cross-user isolation tested at the state-mgr layer; renderer-unavailable gated by live PG) plus the live-PG full-roundtrip success test.

- [ ] **Step 1: Replace the 501 test at `src/gateway.zig:29508` with the new tests**

Replace the existing block (lines 29508-29521):

```zig
test "Wave 2C: export endpoint stubs as 501 with documented dependency" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    const resp = handleArtifactExport(
        std.testing.allocator,
        "POST",
        "1",
        "00000000-0000-0000-0000-000000000000",
        "POST /api/v1/users/1/artifacts/.../export?format=pdf HTTP/1.1",
        &state,
    );
    try std.testing.expectEqualStrings("501 Not Implemented", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "produce_document") != null);
}
```

with this new block:

```zig
// Test fixture for handler-level unit tests. The real dispatch site supplies
// a fully-resolved UserContext; for handler-level tests we synthesize a
// minimal one pointing at a tmpdir so the produce_document tool has a real
// workspace it could (in principle) write to.
fn makeExportTestUserCtx(allocator: std.mem.Allocator, workspace_path: []const u8) UserContext {
    return .{
        .user_id = "1",
        .user_root = allocator.dupe(u8, workspace_path) catch unreachable,
        .workspace_path = allocator.dupe(u8, workspace_path) catch unreachable,
        .memory_db_path = allocator.dupe(u8, "") catch unreachable,
        .cron_path = allocator.dupe(u8, "") catch unreachable,
        .config_path = allocator.dupe(u8, "") catch unreachable,
        .heartbeat_path = allocator.dupe(u8, "") catch unreachable,
        .channel_state_path = allocator.dupe(u8, "") catch unreachable,
        .telegram_path = allocator.dupe(u8, "") catch unreachable,
        .secrets_dir = allocator.dupe(u8, "") catch unreachable,
    };
}

test "Wave 2A: export endpoint rejects unknown format with 400" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    var ctx = makeExportTestUserCtx(std.testing.allocator, "/tmp/nullalis-export-test-fake");
    defer ctx.deinit(std.testing.allocator);
    const resp = handleArtifactExport(
        std.testing.allocator,
        "POST",
        "1",
        "00000000-0000-0000-0000-000000000000",
        "POST /api/v1/users/1/artifacts/.../export?format=rtf HTTP/1.1",
        &ctx,
        null,
        &state,
    );
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "invalid_format") != null);
}

test "Wave 2A: export endpoint rejects malformed artifact id with 400" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    var ctx = makeExportTestUserCtx(std.testing.allocator, "/tmp/nullalis-export-test-fake");
    defer ctx.deinit(std.testing.allocator);
    const resp = handleArtifactExport(
        std.testing.allocator,
        "POST",
        "1",
        "not-a-uuid",
        "POST /api/v1/users/1/artifacts/not-a-uuid/export?format=pdf HTTP/1.1",
        &ctx,
        null,
        &state,
    );
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "invalid_artifact_id") != null);
}

test "Wave 2A: export endpoint returns 503 when state backend is absent" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit(); // zaki_state stays null
    var ctx = makeExportTestUserCtx(std.testing.allocator, "/tmp/nullalis-export-test-fake");
    defer ctx.deinit(std.testing.allocator);
    const resp = handleArtifactExport(
        std.testing.allocator,
        "POST",
        "1",
        "00000000-0000-0000-0000-000000000000",
        "POST /api/v1/users/1/artifacts/.../export?format=pdf HTTP/1.1",
        &ctx,
        null,
        &state,
    );
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "state_unavailable") != null);
}

test "Wave 2A: export endpoint rejects non-POST with 405" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    var ctx = makeExportTestUserCtx(std.testing.allocator, "/tmp/nullalis-export-test-fake");
    defer ctx.deinit(std.testing.allocator);
    const resp = handleArtifactExport(
        std.testing.allocator,
        "GET",
        "1",
        "00000000-0000-0000-0000-000000000000",
        "GET /api/v1/users/1/artifacts/.../export HTTP/1.1",
        &ctx,
        null,
        &state,
    );
    try std.testing.expectEqualStrings("405 Method Not Allowed", resp.status);
}
```

- [ ] **Step 2: Add the live-Postgres end-to-end success test**

Insert this test immediately AFTER the existing live-PG block ends (search for the last test in the "Wave 2C live: artifacts CRUD" series — likely around line 29750+). The end is signalled by `}` followed by a blank line and another `test "..." {` or the start of a non-test fn. Insert this AS a new top-level test:

```zig
test "Wave 2A live: export bridge writes produced file + returns download URL" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "nullalis_w2a_export_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    };
    var mgr = try zaki_state_mod.Manager.init(allocator, cfg);
    defer mgr.deinit();
    defer mgr.dropSchemaForTests() catch {};

    // Build a unique workspace under /tmp the bridge can write into.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws);

    try mgr.provisionUser(601, ws);

    // Create an artifact + version so the bridge has something to render.
    const now = std.time.timestamp();
    const hash_v1 = try artifacts_types.computeContentHash(allocator, "# Hello\n\nExport bridge smoke.");
    defer allocator.free(hash_v1);
    var artifact = try mgr.createArtifact(allocator, 601, null, "ExportBridgeSmoke", "markdown", "# Hello\n\nExport bridge smoke.", hash_v1, now);
    defer artifact.deinit(allocator);

    var state = GatewayState.init(allocator);
    defer state.deinit();
    state.zaki_state = &mgr;

    var ctx = makeExportTestUserCtx(allocator, ws);
    defer ctx.deinit(allocator);

    // Pick HTML — pandoc-only path; if pandoc isn't installed we still
    // exercise the renderer_unavailable code path (asserted below).
    const target = try std.fmt.allocPrint(allocator, "POST /api/v1/users/601/artifacts/{s}/export?format=html HTTP/1.1", .{artifact.id});
    defer allocator.free(target);

    const resp = handleArtifactExport(
        allocator,
        "POST",
        "601",
        artifact.id,
        target,
        &ctx,
        null,
        &state,
    );
    defer if (resp.body.len > 0 and !std.mem.eql(u8, resp.body, "{\"error\":\"response_build_failed\"}")) allocator.free(resp.body);

    if (std.mem.indexOf(u8, resp.body, "renderer_unavailable") != null) {
        // pandoc not installed in the sandbox — the controlled-failure
        // shape is the assertion of interest. Done.
        try std.testing.expectEqualStrings("502 Bad Gateway", resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "renderer_unavailable") != null);
        return;
    }

    // pandoc IS installed — full success path.
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"exported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"format\":\"html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "attachments/produced/") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "/api/v1/users/601/exports/") != null);

    // Cross-user isolation: user 602 cannot export user 601's artifact.
    try mgr.provisionUser(602, ws);
    const resp2 = handleArtifactExport(
        allocator,
        "POST",
        "602",
        artifact.id,
        target,
        &ctx,
        null,
        &state,
    );
    defer if (resp2.body.len > 0) allocator.free(resp2.body);
    try std.testing.expectEqualStrings("404 Not Found", resp2.status);
    try std.testing.expect(std.mem.indexOf(u8, resp2.body, "artifact_not_found") != null);
}
```

- [ ] **Step 3: Run the test suite, focusing on the new tests**

Run: `zig build test --summary all 2>&1 | tail -60`
Expected:
- 0 failures.
- The four new unit tests pass.
- The live-PG test either runs (if `NULLALIS_POSTGRES_TEST_URL` is set) or skips with `SkipZigTest` (the normal local-dev case).

If a test fails — read the actual failure, do not retry blindly. Common pitfalls:
- `makeExportTestUserCtx` allocates strings — make sure `ctx.deinit(allocator)` is paired correctly.
- The `defer if (resp.body.len > 0) ...` guard must match the success path (when `finalizeJsonBuf` returns an owned slice). 503/400/405 paths return string literals — DO NOT free those. The guard above only frees when the body looks non-literal; if your test still flags a leak, drop the body free entirely (a per-test allocator audit will surface the leak independently).

- [ ] **Step 4: Commit**

```bash
git add src/gateway.zig
git commit -m "$(cat <<'EOF'
test(gateway): replace 501-stub assertion + add export bridge coverage

Removes the "Wave 2C: export endpoint stubs as 501" test which is now
factually wrong, and adds five tests in its place:
  - invalid format → 400
  - malformed artifact id → 400
  - state backend absent → 503
  - non-POST method → 405
  - live-PG: full render + download URL, plus cross-user 404 isolation
    (the live-PG case also exercises the renderer_unavailable code path
     when pandoc is missing from the sandbox image)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Update STATUS.md and docs/deferred-register.md

**Files:**
- Modify: `STATUS.md` — flip artifact export status.
- Modify: `docs/deferred-register.md` — add a SHIPPED row referencing the commit.
- Modify: `src/tools/root.zig` — drop stale "Wave 2A" notes that referenced the 501 stub (the Explore mapped these at lines 2926, 2959, 3099, 3346).

- [ ] **Step 1: Update STATUS.md**

Search STATUS.md for `produce_document` (line 23 per the Explore agent's notes) and for any line that mentions artifact export as "stub" / "deferred" / "501" / "Wave 2A bridge pending." For each:

- If the line lists shipped capabilities → no change needed (produce_document tool itself was already shipped).
- If the line says the GATEWAY export endpoint is parked → flip it to shipped, citing the new handler.

Read the file first with the Read tool, then make surgical Edit calls. Do NOT bulk-rewrite — the doc has many unrelated entries.

- [ ] **Step 2: Update docs/deferred-register.md**

Read the file and append a single SHIPPED entry under the most recent audit section (the file has a chronological structure — find the latest "Last audit:" heading and add a one-line bullet underneath). Example shape (match the file's existing style):

```markdown
- **D63** Artifact export bridge — SHIPPED at <commit hash>. `POST /api/v1/users/:id/artifacts/:id/export?format=pdf|docx|pptx|xlsx|html` now resolves to a real produce_document call instead of 501. New companion endpoint `GET /api/v1/users/:id/exports/:filename` serves the produced file with the right binary Content-Type, gated on `isSafeAttachmentFilename`.
```

- [ ] **Step 3: Update the Wave 2A notes in src/tools/root.zig**

Read each of lines 2926, 2959, 3099, 3346 in `src/tools/root.zig`. If a line says "produce_document (Wave 2A: not yet wired)" or similar, change "not yet wired" → "wired via gateway export endpoint". If the note is a count comment (e.g., "+ produce_document (Wave 2A) = 43"), leave the count but drop the "Wave 2A" annotation since the wave is done.

Use surgical Edits — these are scattered comments, not a single block.

- [ ] **Step 4: Build to verify no comment edits broke anything**

Run: `zig build 2>&1 | tail -15`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add STATUS.md docs/deferred-register.md src/tools/root.zig
git commit -m "$(cat <<'EOF'
docs: flip artifact export from "deferred (Wave 2A)" to SHIPPED

Closes the documentation thread that pointed callers at "see Wave 2A"
for explanation of the 501. The gateway endpoint is now production-wired
to ProduceDocumentTool — update STATUS.md, the deferred-register, and
the stale comment references in src/tools/root.zig.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Build + run the full test suite + curl smoke

**Files:** no source edits.

- [ ] **Step 1: Full build**

Run: `zig build 2>&1 | tail -30`
Expected: clean build.

- [ ] **Step 2: Full test suite**

Run: `zig build test --summary all 2>&1 | tail -40`
Expected: 0 failures across the lib_tests target. Skipped tests (live PG, MCP live) are acceptable.

- [ ] **Step 3: Curl smoke**

Pick whichever of these matches the local development setup (the `STATUS.md` or `README.md` indicates how to boot the daemon). Common command shapes:

```bash
# Boot the daemon — find the right command in scripts/ or README
./zig-out/bin/nullalis-daemon &
DAEMON_PID=$!
sleep 2

# Create / pick an artifact via the existing artifact creation flow.
# (If the agent's artifact_create tool is the only writer, drive a short
#  chat that creates one; otherwise insert directly via the state mgr if
#  there's a CLI utility.)

# Smoke the export endpoint
curl -sS -X POST \
  "http://localhost:8080/api/v1/users/<USER_ID>/artifacts/<ARTIFACT_ID>/export?format=pdf" \
  | jq .

# Expected JSON shape:
# {
#   "status": "exported",
#   "artifact_id": "...",
#   "format": "pdf",
#   "filename": "...",
#   "path": "attachments/produced/...",
#   "url": "/api/v1/users/.../exports/...",
#   "download_url": "/api/v1/users/.../exports/..."
# }

# Smoke the download endpoint
curl -sS -o /tmp/export.pdf -w "%{http_code} %{content_type}\n" \
  "http://localhost:8080$(jq -r .download_url /tmp/export-response.json)"
file /tmp/export.pdf  # should show "PDF document, ..."

kill $DAEMON_PID
```

If `pandoc` is NOT installed locally, the export call returns 502 + `renderer_unavailable` — that IS a valid smoke result (proves the controlled-failure path works). The download smoke is skipped in that case.

- [ ] **Step 4: Final verification check**

Confirm against the task's 14 requirements:
1. POST endpoint implemented? — yes (Task 2)
2. Validates artifact id + user ownership? — yes, `isValidArtifactId` + `getArtifactById` joins on `user_id`.
3. Fetches metadata + latest content? — yes, `getArtifactById` + `getArtifactVersion(null)`.
4. Format allowlist (pdf, docx, pptx, html, xlsx)? — yes, explicit `eql` chain.
5. Builds produce_document input from title + content + format? — yes.
6. Safe default theme? — yes, `default`.
7. Executes tool + writes under attachments/produced? — yes, via the tool's own workspace_dir.
8. Machine-readable JSON shape? — yes, matches the task spec.
9. Authenticated file-serving route? — yes (Task 3).
10. Renderer-missing controlled error? — yes, 502 + `renderer_unavailable`.
11. Existing 501 test removed/updated? — yes (Task 4 Step 1).
12. New tests for the five required scenarios? — yes.
13. Docs updated? — yes (Task 5).
14. Test suite + curl smoke run? — yes (this task).

If any item is "no," STOP and fix before claiming done.

---

## Self-Review checklist

**Spec coverage:** all 14 requirements from the user's task brief land in Tasks 1-6 (Task 6 step 4 cross-checks this).

**Placeholder scan:** every code block above contains the actual Zig source the engineer pastes — no "TBD," no "implement appropriately," no missing struct fields.

**Type consistency:**
- `handleArtifactExport` new signature: `(allocator, method, user_id_str, artifact_id, target, user_ctx, config_opt, state)`. Matches the new dispatch call at Task 2 Step 3.
- `handleArtifactExportDownload` signature: `(allocator, method, filename, user_ctx)`. Matches the new dispatch arm at Task 3 Step 2.
- `parseProducedFilename`, `producedContentType`, `isProduceDocumentLiteralError` are used at the call sites declared.
- The `produce_document_mod` alias is referenced exactly twice (the import + the `pdt` constructor call).

**Free / leak audit:** `tool_result.output` and `tool_result.error_msg` are freed when non-empty/non-null — the literal-detection helper avoids double-frees on `ToolResult.fail("<literal>")`. The success path's response body is built via `finalizeJsonBuf` (owns the buffer; RouteResponse holds it). 400 / 405 / 503 paths return string literals — no body free needed.

**Security:**
- Artifact ownership is checked at the DB layer (WHERE `user_id = $2` in both `getArtifactById` and `getArtifactVersion`).
- `isSafeAttachmentFilename` on the download path blocks `..`, `/`, hidden, control chars.
- Download path is composed as `{workspace_path}/attachments/produced/{filename}` — the filename guard ensures the result stays within `produced/`.
- The default theme is hard-coded to `default`; the user cannot inject `thmanyah` even if it were available, because the export endpoint does not accept a `theme` query param.
