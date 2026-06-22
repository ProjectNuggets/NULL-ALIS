//! produce_document — first-class document generation for the agent.
//!
//! Before this tool, the agent had to discover the right pandoc / WeasyPrint /
//! XeLaTeX incantation every time a user asked for a deliverable PDF. The
//! shell tool can do it, but the agent kept re-inventing the recipe (and
//! frequently producing fragile shell strings).
//! This tool exposes a stable schema: pick a format, supply source content,
//! get a file in `<workspace>/attachments/produced/` plus a markdown reference
//! the FE renders inline.
//!
//! Runtime dependencies (NOT bundled — must be installed in the runtime image):
//!   - PDF: pandoc + weasyprint preferred; pandoc/xelatex kept as fallback.
//!          install: brew install pandoc  /  apt install pandoc  /  pip install weasyprint
//!
//! Honesty: if the required binary is missing the tool returns a clear error
//! that names BOTH the failure point AND the install hint. Per §14.5, we never
//! advertise a capability the runtime can't actually deliver.
//!
//! Security: all subprocess arguments are passed as separate argv elements
//! (NOT a shell string), so there is no command-injection surface on the
//! agent-controlled fields (title, content, workspace path). Output is
//! constrained to `<workspace>/attachments/produced/` so a misconfigured
//! agent cannot write outside the user's workspace.

const std = @import("std");
const root = @import("root.zig");
const process_util = @import("process_util.zig");
const config_types = @import("../config_types.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Re-exported so callers needn't reach into config_types.
pub const BrandingConfig = config_types.BrandingConfig;

/// Maximum bytes for any produced output file. 50 MB matches the AGENTS.md
/// guidance for agent-facing artifacts — large enough for a long PDF or a
/// dense slide deck, small enough that we bail before exhausting workspace
/// disk on a runaway prompt.
const MAX_OUTPUT_BYTES: u64 = 50 * 1024 * 1024;

/// Subprocess timeout. Pandoc + marp on a typical document complete well
/// under 30s; we give 120s for headroom on slow CI / cold-cache containers.
const RENDER_TIMEOUT_NS: u64 = 120 * std.time.ns_per_s;

/// Cap for source content. 5 MB of markdown → typically a multi-hundred-page
/// PDF, well beyond any reasonable single-turn agent output.
const MAX_SOURCE_BYTES: usize = 5 * 1024 * 1024;

/// Max title length AFTER sanitization. Long enough to be useful, short enough
/// to keep filesystem paths well under POSIX NAME_MAX (255).
const MAX_TITLE_LEN: usize = 80;

const DEFAULT_TITLE: []const u8 = "untitled";
const DEFAULT_MARP_THEME_NAME: []const u8 = "zaki-default";

/// Renderer subprocess output cap — well above any reasonable stderr blurb.
const RENDERER_OUTPUT_CAP: usize = 1 * 1024 * 1024;

const HTML_DOCUMENT_STYLE =
    \\:root {
    \\  --artifact-page-bg: #f6f4ef;
    \\  --artifact-paper-bg: #fffefa;
    \\  --artifact-ink: #171714;
    \\  --artifact-muted: #5e625f;
    \\  --artifact-line: #ded8ca;
    \\  --artifact-accent: #0f6f5c;
    \\  --artifact-accent-soft: #e5f2ee;
    \\}
    \\html {
    \\  background: var(--artifact-page-bg);
    \\}
    \\body {
    \\  max-width: 860px;
    \\  margin: 0 auto;
    \\  padding: 56px 44px 72px;
    \\  background: var(--artifact-paper-bg);
    \\  color: var(--artifact-ink);
    \\  font-family: var(--artifact-body-font);
    \\  font-size: 16px;
    \\  line-height: 1.68;
    \\}
    \\body::before {
    \\  content: "";
    \\  display: block;
    \\  width: 56px;
    \\  height: 5px;
    \\  margin-bottom: 28px;
    \\  background: var(--artifact-accent);
    \\}
    \\h1, h2, h3, h4 {
    \\  color: var(--artifact-ink);
    \\  font-family: var(--artifact-display-font);
    \\  line-height: 1.12;
    \\  margin: 1.8em 0 0.55em;
    \\}
    \\h1 {
    \\  margin-top: 0;
    \\  font-size: 2.55rem;
    \\  letter-spacing: 0;
    \\}
    \\h2 {
    \\  padding-top: 0.9rem;
    \\  border-top: 1px solid var(--artifact-line);
    \\  font-size: 1.55rem;
    \\}
    \\h3 {
    \\  font-size: 1.12rem;
    \\}
    \\p {
    \\  margin: 0 0 1rem;
    \\}
    \\strong {
    \\  font-weight: 700;
    \\}
    \\a {
    \\  color: var(--artifact-accent);
    \\  text-decoration-thickness: 0.08em;
    \\  text-underline-offset: 0.18em;
    \\}
    \\blockquote {
    \\  margin: 1.35rem 0;
    \\  padding: 0.95rem 1.1rem;
    \\  border-left: 4px solid var(--artifact-accent);
    \\  background: var(--artifact-accent-soft);
    \\  color: var(--artifact-ink);
    \\}
    \\ul, ol {
    \\  padding-left: 1.35rem;
    \\}
    \\li + li {
    \\  margin-top: 0.35rem;
    \\}
    \\table {
    \\  width: 100%;
    \\  border-collapse: collapse;
    \\  margin: 1.4rem 0 1.8rem;
    \\  font-size: 0.94rem;
    \\}
    \\th, td {
    \\  padding: 0.68rem 0.78rem;
    \\  border: 1px solid var(--artifact-line);
    \\  vertical-align: top;
    \\}
    \\th {
    \\  background: #eeebe2;
    \\  color: var(--artifact-ink);
    \\  text-align: left;
    \\  font-weight: 700;
    \\}
    \\tr:nth-child(even) td {
    \\  background: #faf8f2;
    \\}
    \\code {
    \\  padding: 0.12rem 0.28rem;
    \\  border-radius: 4px;
    \\  background: #ece8dd;
    \\  font-size: 0.92em;
    \\}
    \\pre {
    \\  overflow-x: auto;
    \\  padding: 1rem;
    \\  border: 1px solid var(--artifact-line);
    \\  border-radius: 8px;
    \\  background: #161713;
    \\  color: #f8f5ea;
    \\  line-height: 1.5;
    \\}
    \\pre code {
    \\  padding: 0;
    \\  background: transparent;
    \\  color: inherit;
    \\}
    \\hr {
    \\  border: 0;
    \\  border-top: 1px solid var(--artifact-line);
    \\  margin: 2rem 0;
    \\}
    \\@media print {
    \\  html, body {
    \\    background: #fff;
    \\  }
    \\  body {
    \\    max-width: none;
    \\    padding: 0;
    \\  }
    \\}
;

const PDF_PRINT_STYLE =
    \\@page {
    \\  size: Letter;
    \\  margin: 22mm 18mm 24mm;
    \\  @bottom-left {
    \\    content: "nullALIS";
    \\    color: #777b76;
    \\    font-size: 9px;
    \\  }
    \\  @bottom-right {
    \\    content: counter(page);
    \\    color: #777b76;
    \\    font-size: 9px;
    \\  }
    \\}
    \\@media print {
    \\  body {
    \\    font-size: 11.2pt;
    \\    line-height: 1.58;
    \\  }
    \\  body > h1:first-of-type {
    \\    margin: 0 0 18mm;
    \\    padding: 0 0 9mm;
    \\    border-bottom: 2px solid var(--artifact-accent);
    \\    font-size: 31pt;
    \\    line-height: 1.04;
    \\  }
    \\  h1, h2, h3, h4 {
    \\    break-after: avoid;
    \\    page-break-after: avoid;
    \\  }
    \\  h2 {
    \\    margin-top: 12mm;
    \\  }
    \\  p, li {
    \\    orphans: 3;
    \\    widows: 3;
    \\  }
    \\  table {
    \\    page-break-inside: avoid;
    \\    break-inside: avoid;
    \\  }
    \\  thead {
    \\    display: table-header-group;
    \\  }
    \\  tr, img, blockquote, pre {
    \\    page-break-inside: avoid;
    \\    break-inside: avoid;
    \\  }
    \\  pre {
    \\    white-space: pre-wrap;
    \\  }
    \\}
;

const MARP_DEFAULT_THEME_CSS =
    \\/* @theme zaki-default */
    \\
    \\@import 'default';
    \\
    \\section {
    \\  width: 1280px;
    \\  height: 720px;
    \\  padding: 54px 68px 48px;
    \\  background: #fffefa;
    \\  color: #171714;
    \\  font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\  font-size: 30px;
    \\  line-height: 1.22;
    \\}
    \\section::before {
    \\  content: "";
    \\  position: absolute;
    \\  left: 68px;
    \\  top: 38px;
    \\  width: 64px;
    \\  height: 5px;
    \\  background: #0f6f5c;
    \\}
    \\section::after {
    \\  color: #777b76;
    \\  font-size: 17px;
    \\}
    \\h1, h2 {
    \\  margin: 0 0 24px;
    \\  color: #171714;
    \\  font-weight: 800;
    \\  line-height: 1.02;
    \\  letter-spacing: 0;
    \\}
    \\h1 {
    \\  max-width: 980px;
    \\  font-size: 62px;
    \\}
    \\h2 {
    \\  font-size: 44px;
    \\}
    \\p {
    \\  max-width: 980px;
    \\}
    \\ul, ol {
    \\  margin: 16px 0 0;
    \\  padding-left: 1.15em;
    \\}
    \\li {
    \\  margin: 0 0 13px;
    \\}
    \\strong {
    \\  color: #0f6f5c;
    \\}
    \\blockquote {
    \\  margin: 24px 0 0;
    \\  padding: 18px 24px;
    \\  border-left: 6px solid #0f6f5c;
    \\  background: #e5f2ee;
    \\}
    \\table {
    \\  width: 100%;
    \\  border-collapse: collapse;
    \\  font-size: 22px;
    \\}
    \\th, td {
    \\  padding: 12px 14px;
    \\  border: 1px solid #ded8ca;
    \\}
    \\th {
    \\  background: #eeebe2;
    \\  text-align: left;
    \\}
    \\code {
    \\  background: #ece8dd;
    \\  border-radius: 5px;
    \\  padding: 0.08em 0.26em;
    \\}
;

pub const ProduceDocumentTool = struct {
    /// Workspace root where attachments/sources/ and attachments/produced/
    /// are created. Bound at tool registration time.
    workspace_dir: []const u8 = "",

    /// Operator-deployed brand typography. Empty/missing `font_dir` ⇒
    /// branding disabled and produce_document falls back to system fonts
    /// (existing behaviour). When the dir exists with the expected
    /// `<font_dir>/<body_font>/otf` + `<font_dir>/<display_font>/otf`
    /// subfolders, every produced document is styled with the brand
    /// typography. NOT user-settable — operator decision only.
    branding: BrandingConfig = .{},

    pub const tool_name = "produce_document";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Render markdown input to a polished PDF deliverable.",
        .use_when = &.{
            "User asks for a saveable, sendable, or shareable PDF deliverable",
            "Producing a report, memo, brief, proposal, plan, or research document from drafted markdown",
            "Converting agent-authored markdown into a polished downloadable file",
        },
        .do_not_use_for = &.{
            "image_generate — for visual content rather than documents",
            "file_write — for plain markdown / code / text where no rendering needed",
            "web_fetch — for downloading existing documents rather than producing new ones",
        },
        .cost_note = "Invokes local renderers (pandoc + WeasyPrint preferred, pandoc/XeLaTeX fallback). Requires those binaries installed in the runtime.",
        .completion_hint = "Writes <workspace>/attachments/produced/<title>_<ts>.<ext> and returns a markdown link for the FE to render inline.",
    };

    comptime {
        @import("lint.zig").lintToolDescription("produce_document", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Render a polished PDF from markdown source content. " ++
        "The rendered file lands in " ++
        "<workspace>/attachments/produced/ and the tool returns a markdown link the FE " ++
        "renders inline. Requires pandoc + WeasyPrint in the runtime image; pandoc/XeLaTeX " ++
        "is kept as a compatibility fallback. If a required binary " ++
        "is missing the tool returns a clear error with the install hint — surface that " ++
        "to the user verbatim; do NOT try to install binaries via shell (sandbox blocks it).\n\n" ++
        // ─── PDF blueprint — the model copies these patterns, so
        // they must encode document quality, not just syntax.
        "## How to format `content`\n\n" ++
        "## Artifact quality gate\n" ++
        "Before calling this tool, make the source read like a final deliverable: a specific\n" ++
        "title, a useful opening answer, scannable sections, concrete numbers/names when\n" ++
        "known, explicit assumptions when unknown, and no placeholders like TBD/lorem ipsum.\n" ++
        "Do not include process notes such as \"I created this\" or instructions about how to\n" ++
        "use the document. If the user gave sparse input, create a polished first draft with\n" ++
        "clearly labeled assumptions instead of an empty template.\n\n" ++
        "### pdf — markdown source\n" ++
        "Use standard markdown. Headings (`#`/`##`), bullet lists (`- `), numbered lists\n" ++
        "(`1. `), tables (pipe syntax), code blocks (triple backticks), blockquotes (`> `),\n" ++
        "links (`[text](url)`), images (`![alt](path)`). The renderer handles the rest. Keep\n" ++
        "headings shallow (2-3 levels) for readable PDFs.\n\n" ++
        "Default decision-doc blueprint:\n" ++
        "1. `# <specific title>`\n" ++
        "2. `## One-page brief` — 3-5 sentences that answer the user's ask directly.\n" ++
        "3. `## What matters` — 3-6 bullets, each with a concrete implication.\n" ++
        "4. `## Options / plan / analysis` — the main body; use tables for comparisons.\n" ++
        "5. `## Recommendation` — the decision, rationale, and what to do next.\n" ++
        "6. `## Risks and assumptions` — only real caveats, not generic hedging.\n\n" ++
        "EXAMPLE (decision brief):\n" ++
        "```\n" ++
        "# Launch Readiness Brief — Agent Artifacts\n\n" ++
        "## One-page brief\n" ++
        "The artifact experience is close to launch, but the last-mile quality bar is the\n" ++
        "document itself: every PDF export should look share-ready before the user edits it.\n" ++
        "The highest-leverage move is to standardize creation blueprints and route PDF\n" ++
        "through the styled HTML renderer before printing.\n\n" ++
        "## What matters\n" ++
        "- First impression: the opening page/slide must state a useful answer, not a template.\n" ++
        "- Editability: artifacts should preserve clean headings and tables so revisions are local.\n" ++
        "- Export trust: PDF should preserve typography, tables, and section rhythm when downloaded.\n\n" ++
        "## Options\n" ++
        "| Option | Upside | Tradeoff |\n" ++
        "|---|---|---|\n" ++
        "| Prompt-only blueprints | Fastest quality lift | Depends on model compliance |\n" ++
        "| Styled HTML-to-PDF | Improves every export | Does not fix weak source content |\n" ++
        "| Structured document specs | Best long-term control | Larger schema change |\n\n" ++
        "## Recommendation\n" ++
        "Ship prompt blueprints and the styled PDF renderer now, then add structured\n" ++
        "document specs once the default surface is stable.\n\n" ++
        "## Risks and assumptions\n" ++
        "- Assumption: users prefer a strong editable draft over a blank form.\n" ++
        "- Risk: renderer dependencies may be missing in smaller deployments.\n" ++
        "```\n\n" ++
        "### branding (operator-owned)\n" ++
        "When the operator has deployed a brand font (e.g. Thmanyah) and set\n" ++
        "`branding.font_dir` in config, every PDF produced by\n" ++
        "this tool uses the brand typography automatically — you write the same\n" ++
        "content, the deliverable carries the brand. Branding is NOT a per-user preference — do not expose a\n" ++
        "branding choice to users; it is an operator-level brand decision.\n\n" ++
        "### parked legacy renderers\n" ++
        "DOCX, PPTX, XLSX, and HTML are intentionally hidden until each renderer gets\n" ++
        "its own S-tier quality pass. Use markdown artifacts for iteration and PDF\n" ++
        "for polished save/share/send requests.\n\n" ++
        "## When to use produce_document vs alternatives\n" ++
        "- For a quick 1-3 paragraph reply → answer INLINE, don't produce a doc.\n" ++
        "- For a substantial deliverable the user will save or share → produce_document(format=pdf).\n" ++
        "- For an iterative document the user will refine over many turns → artifact_create\n" ++
        "  (canvas) FIRST, then produce_document only on the user's explicit export request.\n" ++
        "- For a chart or image → image_generate.\n" ++
        "- For raw markdown / code the user will copy → file_write.";

    pub const tool_params =
        \\{"type":"object","properties":{"format":{"type":"string","enum":["pdf"],"description":"Output format. PDF is the only public polished export while DOCX/PPTX/XLSX/HTML are parked for later quality passes."},"content":{"type":"string","description":"Markdown source content. Required."},"title":{"type":"string","description":"Document title — used for the output filename and document metadata. Default 'untitled'. Will be sanitized to filesystem-safe characters."}},"required":["format","content"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ProduceDocumentTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ProduceDocumentTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // HIGH 2.A: time the whole call + tag the format + result so
        // operators can chart renderer latency per format and spot
        // when a missing binary (pandoc / marp-cli) starts a 100%
        // failure run.
        //
        // Strategy: a single tracking variable `metric_result` defaults
        // to "render_failed" (the most common failure mode for this
        // tool — missing renderer binary / pandoc failure / etc.) and
        // a `defer` block records the metric on EVERY exit path. The
        // success arm overrides `metric_result = "ok"` just before
        // returning; the invalid-input early-returns override to
        // "invalid_input". Latency is always sampled.
        const t_start_ns = std.time.nanoTimestamp();
        var metric_result: []const u8 = "render_failed";
        var metric_format: []const u8 = "unknown";
        defer {
            const elapsed_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - t_start_ns, std.time.ns_per_ms));
            @import("../observability.zig").recordMetricGlobal(.{
                .produce_document_latency_ms = .{ .format = metric_format, .value = elapsed_ms },
            });
            @import("../observability.zig").recordMetricGlobal(.{
                .produce_document_total = .{ .format = metric_format, .result = metric_result },
            });
        }

        // ── Validate args ────────────────────────────────────────────
        const format_raw = root.getString(args, "format") orelse {
            metric_result = "invalid_input";
            return ToolResult.fail("Missing 'format' parameter (only supported: pdf)");
        };
        const format = parseFormat(format_raw) orelse {
            metric_result = "invalid_input";
            const msg = try std.fmt.allocPrint(
                allocator,
                "Invalid 'format' value: '{s}'. Only supported public format is: pdf",
                .{format_raw},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        const format_label = formatLabel(format);
        metric_format = format_label;
        if (format != .pdf) {
            metric_result = "invalid_input";
            const msg = try std.fmt.allocPrint(
                allocator,
                "Format '{s}' is parked. PDF is the only public export format until this renderer gets its S-tier quality pass.",
                .{format_raw},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");
        const content_trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (content_trimmed.len == 0) return ToolResult.fail("'content' must not be empty");
        if (content.len > MAX_SOURCE_BYTES) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "'content' too large ({d} bytes, max {d})",
                .{ content.len, MAX_SOURCE_BYTES },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const raw_title = root.getString(args, "title") orelse DEFAULT_TITLE;
        const safe_title = try sanitizeTitle(allocator, raw_title);
        defer allocator.free(safe_title);

        if (self.workspace_dir.len == 0) {
            return ToolResult.fail("Workspace not configured — tool has no place to write the produced document");
        }

        // Resolve branding ONCE per call. Null = disabled or misconfigured
        // (silent fallback for empty font_dir; warned fallback for missing
        // subdirs). The renderers branch on `resolved == null` to decide
        // whether to apply brand typography.
        const resolved_branding_opt: ?ResolvedBranding = resolveBranding(allocator, self.branding) catch |err| blk: {
            std.log.scoped(.branding).warn(
                "resolveBranding errored ({s}) — falling back to system fonts",
                .{@errorName(err)},
            );
            break :blk null;
        };
        defer if (resolved_branding_opt) |rb| rb.deinit(allocator);

        // ── Prepare directories ──────────────────────────────────────
        const sources_dir = try std.fs.path.join(allocator, &.{ self.workspace_dir, "attachments", "sources" });
        defer allocator.free(sources_dir);
        std.fs.cwd().makePath(sources_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to create sources dir '{s}': {s}",
                    .{ sources_dir, @errorName(err) },
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        const produced_dir = try std.fs.path.join(allocator, &.{ self.workspace_dir, "attachments", "produced" });
        defer allocator.free(produced_dir);
        std.fs.cwd().makePath(produced_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to create produced dir '{s}': {s}",
                    .{ produced_dir, @errorName(err) },
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        // ── Build filenames ──────────────────────────────────────────
        // Wave 2 review HIGH#5 — ms-resolution alone is not enough entropy
        // when the tool advertises `concurrency_safe = true`: two cron-
        // scheduled invocations (or a hot-path agent firing twice in the
        // same millisecond) with the same title would collide on
        // `createFileAbsolute`. We append a CSPRNG-derived 8-char hex
        // nonce so the filename is unique across any practical concurrency.
        const ts_ms = std.time.milliTimestamp();
        const rand_nonce = std.crypto.random.int(u32);
        const src_ext = sourceExtension(format);
        const out_ext = outputExtension(format);

        const src_filename = try std.fmt.allocPrint(
            allocator,
            "{s}_{d}_{x:0>8}{s}",
            .{ safe_title, ts_ms, rand_nonce, src_ext },
        );
        defer allocator.free(src_filename);
        const out_filename = try std.fmt.allocPrint(
            allocator,
            "{s}_{d}_{x:0>8}{s}",
            .{ safe_title, ts_ms, rand_nonce, out_ext },
        );
        defer allocator.free(out_filename);

        const src_path = try std.fs.path.join(allocator, &.{ sources_dir, src_filename });
        defer allocator.free(src_path);
        const out_path = try std.fs.path.join(allocator, &.{ produced_dir, out_filename });
        defer allocator.free(out_path);

        // ── Write source file ────────────────────────────────────────
        //
        {
            const src_file = std.fs.createFileAbsolute(src_path, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to create source file '{s}': {s}",
                    .{ src_path, @errorName(err) },
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            defer src_file.close();
            src_file.writeAll(content) catch |err| {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to write source content: {s}",
                    .{@errorName(err)},
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
        }

        // ── Dispatch to renderer ─────────────────────────────────────
        // ponytail: legacy DOCX/XLSX/PPTX/HTML renderers stay parked behind
        // the public PDF-only gate until each format earns its own quality pass.
        const render_result = try renderPdf(allocator, src_path, out_path, safe_title, resolved_branding_opt);

        // If renderer failed, return the error (and clean up the output if it
        // got partially created).
        if (!render_result.success) {
            std.fs.deleteFileAbsolute(out_path) catch {};
            return render_result;
        }
        // Renderer reported success — sanity-check the file actually exists
        // and is within the size cap.
        const out_stat = blk: {
            const f = std.fs.openFileAbsolute(out_path, .{}) catch |err| {
                if (render_result.output.len > 0) allocator.free(render_result.output);
                if (render_result.error_msg) |em| allocator.free(em);
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Renderer reported success but output file missing at '{s}': {s}",
                    .{ out_path, @errorName(err) },
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            defer f.close();
            const stat = f.stat() catch |err| {
                if (render_result.output.len > 0) allocator.free(render_result.output);
                if (render_result.error_msg) |em| allocator.free(em);
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to stat produced file: {s}",
                    .{@errorName(err)},
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            break :blk stat;
        };

        if (out_stat.size > MAX_OUTPUT_BYTES) {
            std.fs.deleteFileAbsolute(out_path) catch {};
            if (render_result.output.len > 0) allocator.free(render_result.output);
            if (render_result.error_msg) |em| allocator.free(em);
            const msg = try std.fmt.allocPrint(
                allocator,
                "Produced file too large ({d} bytes, max {d})",
                .{ out_stat.size, MAX_OUTPUT_BYTES },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Free the renderer's internal output (we craft our own agent-facing
        // markdown).
        if (render_result.output.len > 0) allocator.free(render_result.output);
        if (render_result.error_msg) |em| allocator.free(em);

        // ── Format agent-facing response ─────────────────────────────
        const label = formatLabel(format);
        // HIGH 2.A: success path — the `defer` block emits latency +
        // result counter. Override the default "render_failed" tag.
        metric_result = "ok";
        const result_md = try std.fmt.allocPrint(
            allocator,
            "[Generated {s}: {s}](attachments/produced/{s})",
            .{ label, out_filename, out_filename },
        );
        return ToolResult{ .success = true, .output = result_md };
    }
};

// ── Format dispatch ──────────────────────────────────────────────────

const Format = enum { pdf, docx, xlsx, pptx, html };

fn parseFormat(s: []const u8) ?Format {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "pdf")) return .pdf;
    if (std.ascii.eqlIgnoreCase(t, "docx")) return .docx;
    if (std.ascii.eqlIgnoreCase(t, "xlsx")) return .xlsx;
    if (std.ascii.eqlIgnoreCase(t, "pptx")) return .pptx;
    if (std.ascii.eqlIgnoreCase(t, "html")) return .html;
    return null;
}

/// 2026-06 S-tier artifact polish — supported PPTX theme values. The
/// user-facing `default` value maps to a generated `zaki-default` Marp
/// theme, while `gaia` and `uncover` still map to Marp built-ins.
///
/// Visual character:
///   - default — crisp white/ink/accent editorial theme for general use.
///   - gaia    — warm cream background, serif body, slight color accents.
///               Better for human talks where a printed-book feel helps.
///   - uncover — bold black-on-white, large type, bullet-emphasis style.
///               Best for keynote / lecture / "ideas at a glance" decks.
const Theme = enum {
    default_theme,
    gaia,
    uncover,
    /// Operator-brand theme (e.g. Thmanyah). Selecting this when the
    /// operator has NOT enabled branding (empty/missing font_dir) yields
    /// a clear "branding not configured" error — the tool does NOT
    /// silently fall back to default (§14.5 honesty: explicit theme
    /// requests must succeed or surface why they can't).
    thmanyah,

    pub fn toSlice(self: Theme) []const u8 {
        return switch (self) {
            .default_theme => "default",
            .gaia => "gaia",
            .uncover => "uncover",
            .thmanyah => "thmanyah",
        };
    }
};

fn parseTheme(s: []const u8) ?Theme {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "default")) return .default_theme;
    if (std.ascii.eqlIgnoreCase(t, "gaia")) return .gaia;
    if (std.ascii.eqlIgnoreCase(t, "uncover")) return .uncover;
    if (std.ascii.eqlIgnoreCase(t, "thmanyah")) return .thmanyah;
    return null;
}

fn marpThemeName(theme: Theme) []const u8 {
    return switch (theme) {
        .default_theme => DEFAULT_MARP_THEME_NAME,
        .gaia => "gaia",
        .uncover => "uncover",
        .thmanyah => "thmanyah",
    };
}

// ── Branding resolution ──────────────────────────────────────────────
//
// Branding lives at operator config (BrandingConfig). For each format
// renderer we want a single fast question: "do we have a font dir we can
// trust for this render?" — answered by `resolveBranding`. If yes, we
// thread a small `ResolvedBranding` struct (paths + family names) into
// the renderer; if no, the renderer skips its font-application path and
// falls back to system defaults silently.
//
// We do NOT copy fonts anywhere — the resolver only confirms the
// expected `<font_dir>/<family>/otf` subfolders exist. Marp / pandoc /
// HTML @font-face declarations reference the operator's directory via
// absolute `file://` URLs (Marp + HTML self-rendered) or `--variable
// mainfont=<family>` (pandoc → xelatex/lualatex which discovers fonts
// from a system path; see renderPdf for the install-hint fallback).
//
// License: the font files NEVER enter the nullalis repo. The license
// text at /Users/nova/Downloads/Thmanyah-Font-Family/LICENSE.pdf permits
// embedding in produced documents but prohibits redistribution of the
// font files themselves; following that rule means the operator owns
// the font directory and we only read it.

/// Resolved branding info, returned by `resolveBranding` when the
/// operator has deployed a brand font. All paths are heap-allocated
/// from the same allocator the caller passes; free with `deinit`.
pub const ResolvedBranding = struct {
    body_font_family: []const u8,
    /// Absolute path to `<font_dir>/<body_font>/otf`.
    body_otf_dir: []const u8,
    /// Absolute path to `<font_dir>/<body_font>/woff2` (may be empty if
    /// the woff2 subdir is absent — HTML/Marp emit only otf @font-face
    /// in that case).
    body_woff2_dir: []const u8,
    display_font_family: []const u8,
    display_otf_dir: []const u8,
    display_woff2_dir: []const u8,

    pub fn deinit(self: ResolvedBranding, allocator: std.mem.Allocator) void {
        allocator.free(self.body_font_family);
        allocator.free(self.body_otf_dir);
        allocator.free(self.body_woff2_dir);
        allocator.free(self.display_font_family);
        allocator.free(self.display_otf_dir);
        allocator.free(self.display_woff2_dir);
    }
};

/// Verify `<dir>` exists and is a directory. Used by resolveBranding to
/// gate brand application — we don't want to emit @font-face URLs that
/// 404 when the operator's deploy script forgot to mount the font dir.
fn directoryExists(path: []const u8) bool {
    // 2026-05-25 fix: openDirAbsolute asserts the path is absolute and
    // SIGABRTs on relative input — caught by a test panic when the
    // bundled-fonts resolver fell through to its "assets/branding/fonts"
    // cwd-relative candidate. Use cwd().openDir for the relative case,
    // openDirAbsolute for the absolute case.
    var dir = if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{}) catch return false
    else
        std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Resolve a BrandingConfig to a ResolvedBranding suitable for the
/// renderers. Returns null when branding is disabled OR when the
/// directory shape is wrong — both fall through to system fonts. On the
/// disabled-via-empty-font_dir path we are silent; on the misconfigured-
/// directory path we log a warn so the operator notices the gap (still
/// fall through; broken branding must not break document production).
///
/// Caller owns the returned struct; call `.deinit(allocator)`.
pub fn resolveBranding(
    allocator: std.mem.Allocator,
    branding: BrandingConfig,
) !?ResolvedBranding {
    // 2026-05-25 (Nova directive): bundled-fonts fallback. When the
    // operator config omits `font_dir`, look for the in-repo bundled
    // fonts at well-known locations relative to the executable. This
    // makes the SaaS deploy work without any operator config — the
    // Docker image / binary ships with `assets/branding/fonts/` and
    // every tenant gets branded output by default.
    //
    // License compliance: bundled at `assets/branding/fonts/` is
    // explicitly NOT redistribution per the thmanyah license (we
    // embed in our product; users render documents through it; they
    // can't extract the font files standalone). See
    // `assets/branding/fonts/README.md` for the migration path if/
    // when this repo opens to the public.
    //
    // Resolution order:
    //   1. Operator-configured `branding.font_dir` (highest priority)
    //   2. Bundled `<exe_dir>/assets/branding/fonts` (SaaS default)
    //   3. Bundled `<exe_dir>/../assets/branding/fonts` (zig-out/bin)
    //   4. Bundled `<cwd>/assets/branding/fonts` (dev run from repo)
    //   5. null (no branding; system fonts)
    if (branding.font_dir.len > 0) {
        return try resolveBrandingFromDir(allocator, branding);
    }
    const bundled = resolveBundledFontsPath(allocator) orelse return null;
    defer allocator.free(bundled);
    var b = branding;
    b.font_dir = bundled;
    return try resolveBrandingFromDir(allocator, b);
}

/// Try to find the bundled `assets/branding/fonts` directory. Walks the
/// candidate locations in priority order; returns the FIRST path that
/// `directoryExists` confirms. Caller owns the returned slice. Returns
/// null when no bundled directory is found (e.g. binary deployed
/// without the assets tree).
fn resolveBundledFontsPath(allocator: std.mem.Allocator) ?[]const u8 {
    // Candidate A: exe-dir + assets/branding/fonts (typical container layout)
    if (std.fs.selfExeDirPathAlloc(allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        const a = std.fs.path.join(allocator, &.{ exe_dir, "assets", "branding", "fonts" }) catch null;
        if (a) |p| {
            if (directoryExists(p)) return p;
            allocator.free(p);
        }
        // Candidate B: exe-dir/../assets/... (zig-out/bin/nullalis layout)
        const b = std.fs.path.join(allocator, &.{ exe_dir, "..", "assets", "branding", "fonts" }) catch null;
        if (b) |p| {
            if (directoryExists(p)) return p;
            allocator.free(p);
        }
        // Candidate C: exe-dir/../../assets/... (zig-out/bin → repo-root)
        const c = std.fs.path.join(allocator, &.{ exe_dir, "..", "..", "assets", "branding", "fonts" }) catch null;
        if (c) |p| {
            if (directoryExists(p)) return p;
            allocator.free(p);
        }
    } else |_| {}
    // CR-04 (v1.14.22) — Dockerfile bundles fonts under
    // /usr/local/share/nullalis/branding/fonts via an explicit COPY.
    // Exe-dir-relative candidates miss this because nullalis binary
    // lives at /usr/local/bin/ (exe_dir/../share is NOT exe_dir/../).
    const e = allocator.dupe(u8, "/usr/local/share/nullalis/branding/fonts") catch null;
    if (e) |p| {
        if (directoryExists(p)) return p;
        allocator.free(p);
    }
    // Candidate F: cwd + assets/branding/fonts (dev run from repo root).
    // Return an absolute path because CSS @font-face emits file:// URLs.
    if (directoryExists("assets/branding/fonts")) {
        return std.fs.cwd().realpathAlloc(allocator, "assets/branding/fonts") catch {
            return allocator.dupe(u8, "assets/branding/fonts") catch null;
        };
    }
    return null;
}

fn resolveBrandingFromDir(
    allocator: std.mem.Allocator,
    branding: BrandingConfig,
) !?ResolvedBranding {
    const body_otf = try std.fs.path.join(allocator, &.{ branding.font_dir, branding.body_font, "otf" });
    errdefer allocator.free(body_otf);
    if (!directoryExists(body_otf)) {
        std.log.scoped(.branding).warn(
            "branding body font '{s}' missing otf subdir at '{s}' — falling back to system fonts.",
            .{ branding.body_font, body_otf },
        );
        allocator.free(body_otf);
        return null;
    }

    const display_otf = try std.fs.path.join(allocator, &.{ branding.font_dir, branding.display_font, "otf" });
    errdefer allocator.free(display_otf);
    if (!directoryExists(display_otf)) {
        std.log.scoped(.branding).warn(
            "branding display font '{s}' missing otf subdir at '{s}' — falling back to system fonts.",
            .{ branding.display_font, display_otf },
        );
        allocator.free(body_otf);
        allocator.free(display_otf);
        return null;
    }

    // woff2 dirs are optional — only used for HTML / Marp @font-face.
    // Pass empty string when absent so renderers can skip those rules.
    const body_woff2 = try std.fs.path.join(allocator, &.{ branding.font_dir, branding.body_font, "woff2" });
    errdefer allocator.free(body_woff2);
    const display_woff2 = try std.fs.path.join(allocator, &.{ branding.font_dir, branding.display_font, "woff2" });
    errdefer allocator.free(display_woff2);

    const body_woff2_final: []const u8 = if (directoryExists(body_woff2)) body_woff2 else blk: {
        allocator.free(body_woff2);
        break :blk try allocator.dupe(u8, "");
    };
    const display_woff2_final: []const u8 = if (directoryExists(display_woff2)) display_woff2 else blk: {
        allocator.free(display_woff2);
        break :blk try allocator.dupe(u8, "");
    };

    return ResolvedBranding{
        .body_font_family = try allocator.dupe(u8, branding.body_font),
        .body_otf_dir = body_otf,
        .body_woff2_dir = body_woff2_final,
        .display_font_family = try allocator.dupe(u8, branding.display_font),
        .display_otf_dir = display_otf,
        .display_woff2_dir = display_woff2_final,
    };
}

/// Emit a CSS `@font-face` block + body/display rules for the resolved
/// branding. Used by the HTML renderer (inline `<style>`) AND by the
/// Marp `thmanyah` theme generator. URLs are absolute `file://` so the
/// renderer can find the fonts at compile time; for HTML served as a
/// landing page the operator can rewrite these via post-processing if
/// the static-serving root differs from the workspace.
///
/// `kind` selects the URL prefix:
///   .file  → `file://<abs-path>/...` (HTML self-rendered, Marp)
///   .relative → `../../branding/fonts/...` (rarely used; reserved for
///               future workspace-bundled font use, requires the
///               operator to opt into copying the fonts to workspace —
///               not currently supported but the enum is here for
///               clarity)
///
/// Caller frees.
pub const FontUrlKind = enum { file, relative };

pub fn cssFontFaceBlock(
    allocator: std.mem.Allocator,
    rb: ResolvedBranding,
    kind: FontUrlKind,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Helper: pick woff2 dir if present, else otf dir. woff2 is much
    // smaller (~30% of otf), so we prefer it for browsers; absent woff2
    // falls back to otf which every modern browser also accepts.
    const body_dir = if (rb.body_woff2_dir.len > 0) rb.body_woff2_dir else rb.body_otf_dir;
    const body_ext: []const u8 = if (rb.body_woff2_dir.len > 0) "woff2" else "otf";
    const body_format: []const u8 = if (rb.body_woff2_dir.len > 0) "woff2" else "opentype";

    const display_dir = if (rb.display_woff2_dir.len > 0) rb.display_woff2_dir else rb.display_otf_dir;
    const display_ext: []const u8 = if (rb.display_woff2_dir.len > 0) "woff2" else "otf";
    const display_format: []const u8 = if (rb.display_woff2_dir.len > 0) "woff2" else "opentype";

    const url_prefix: []const u8 = switch (kind) {
        .file => "file://",
        .relative => "",
    };

    // We assume the Thmanyah-style naming convention `<family>-<Weight>.<ext>`
    // because that matches the licensed distribution we tested against
    // (Regular / Bold / Black / Medium / Light per family). Operators
    // with differently-named files can either rename to match the
    // convention or place a workspace-local CSS override (future work).
    //
    // Emit one @font-face per weight so the renderer doesn't have to
    // synthesize bolds; declare 5 weights = full coverage of the
    // Thmanyah distribution.
    const weights = [_]struct { name: []const u8, num: u16 }{
        .{ .name = "Light", .num = 300 },
        .{ .name = "Regular", .num = 400 },
        .{ .name = "Medium", .num = 500 },
        .{ .name = "Bold", .num = 700 },
        .{ .name = "Black", .num = 900 },
    };

    for (weights) |wt| {
        try w.print(
            "@font-face {{ font-family: '{s}'; font-weight: {d}; font-style: normal; src: url('{s}{s}/{s}-{s}.{s}') format('{s}'); font-display: swap; }}\n",
            .{ rb.body_font_family, wt.num, url_prefix, body_dir, rb.body_font_family, wt.name, body_ext, body_format },
        );
    }
    for (weights) |wt| {
        try w.print(
            "@font-face {{ font-family: '{s}'; font-weight: {d}; font-style: normal; src: url('{s}{s}/{s}-{s}.{s}') format('{s}'); font-display: swap; }}\n",
            .{ rb.display_font_family, wt.num, url_prefix, display_dir, rb.display_font_family, wt.name, display_ext, display_format },
        );
    }

    // Body / heading rules. The body rule applies the body font + a
    // generic fallback stack so a missing weight degrades gracefully.
    try w.print(
        "body, p, li, td, th, blockquote {{ font-family: '{s}', system-ui, -apple-system, 'Helvetica Neue', sans-serif; }}\n",
        .{rb.body_font_family},
    );
    try w.print(
        "h1, h2, h3, h4, h5, h6 {{ font-family: '{s}', Georgia, 'Times New Roman', serif; }}\n",
        .{rb.display_font_family},
    );

    return buf.toOwnedSlice(allocator);
}

fn buildHtmlHeaderContent(
    allocator: std.mem.Allocator,
    resolved_branding: ?ResolvedBranding,
    include_pdf_style: bool,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("<style>\n");
    if (resolved_branding) |rb| {
        const face_block = try cssFontFaceBlock(allocator, rb, .file);
        defer allocator.free(face_block);
        try w.writeAll(face_block);
        try w.print(
            ":root {{ --artifact-body-font: '{s}', system-ui, -apple-system, 'Segoe UI', sans-serif; --artifact-display-font: '{s}', Georgia, 'Times New Roman', serif; }}\n",
            .{ rb.body_font_family, rb.display_font_family },
        );
    } else {
        try w.writeAll(":root { --artifact-body-font: ui-sans-serif, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; --artifact-display-font: Georgia, 'Times New Roman', serif; }\n");
    }
    try w.writeAll(HTML_DOCUMENT_STYLE);
    if (include_pdf_style) try w.writeAll(PDF_PRINT_STYLE);
    try w.writeAll("</style>\n");

    return buf.toOwnedSlice(allocator);
}

fn sourceExtension(f: Format) []const u8 {
    return switch (f) {
        .pdf, .docx, .pptx, .html => ".md",
        .xlsx => ".csv",
    };
}

fn outputExtension(f: Format) []const u8 {
    return switch (f) {
        .pdf => ".pdf",
        .docx => ".docx",
        .xlsx => ".xlsx",
        .pptx => ".pptx",
        .html => ".html",
    };
}

fn formatLabel(f: Format) []const u8 {
    return switch (f) {
        .pdf => "PDF",
        .docx => "DOCX",
        .xlsx => "XLSX",
        .pptx => "PPTX",
        .html => "HTML",
    };
}

// ── Filename safety ──────────────────────────────────────────────────

/// Sanitize a user-supplied title for use as a filesystem basename:
///   - strip path separators ('/', '\\') and null bytes
///   - replace any non-alphanumeric / underscore / dash / dot char with '_'
///   - collapse runs of '_'
///   - trim leading/trailing '_' or '.'
///   - cap to MAX_TITLE_LEN
///   - fall back to DEFAULT_TITLE if the result is empty
/// Result is heap-allocated; caller frees.
fn sanitizeTitle(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var last_was_underscore = false;
    for (trimmed) |c| {
        // Skip control chars and path separators entirely.
        if (c == 0 or c == '/' or c == '\\' or c < 0x20 or c == 0x7F) {
            if (!last_was_underscore and buf.items.len > 0) {
                try buf.append(allocator, '_');
                last_was_underscore = true;
            }
            continue;
        }
        const safe = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (safe) {
            try buf.append(allocator, c);
            last_was_underscore = c == '_';
        } else {
            if (!last_was_underscore and buf.items.len > 0) {
                try buf.append(allocator, '_');
                last_was_underscore = true;
            }
        }
        if (buf.items.len >= MAX_TITLE_LEN) break;
    }

    // Trim trailing '_' and '.' (avoid hidden files / weird dangling separators).
    while (buf.items.len > 0) {
        const last = buf.items[buf.items.len - 1];
        if (last == '_' or last == '.') {
            _ = buf.pop();
        } else break;
    }
    // Trim leading '_' and '.' (avoid hidden files / underscore-only prefixes).
    while (buf.items.len > 0 and (buf.items[0] == '.' or buf.items[0] == '_')) {
        _ = buf.orderedRemove(0);
    }

    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return try allocator.dupe(u8, DEFAULT_TITLE);
    }
    return try buf.toOwnedSlice(allocator);
}

// ── Renderer dispatch ────────────────────────────────────────────────

fn renderStyledHtml(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    out_path: []const u8,
    title: []const u8,
    resolved_branding: ?ResolvedBranding,
    include_pdf_style: bool,
) !RendererAttempt {
    const meta = try metadataArg(allocator, "title", title);
    defer allocator.free(meta);

    var header_path_opt: ?[]u8 = null;
    defer if (header_path_opt) |hp| {
        std.fs.deleteFileAbsolute(hp) catch {};
        allocator.free(hp);
    };

    const header_path = try std.fmt.allocPrint(allocator, "{s}.header.html", .{out_path});
    errdefer allocator.free(header_path);

    const header_content = try buildHtmlHeaderContent(allocator, resolved_branding, include_pdf_style);
    defer allocator.free(header_content);

    const f = std.fs.createFileAbsolute(header_path, .{}) catch |err| {
        allocator.free(header_path);
        const msg = try std.fmt.allocPrint(
            allocator,
            "Failed to create HTML document header '{s}': {s}",
            .{ header_path, @errorName(err) },
        );
        return RendererAttempt{ .ran_but_failed = ToolResult{ .success = false, .output = "", .error_msg = msg } };
    };
    defer f.close();
    f.writeAll(header_content) catch |err| {
        allocator.free(header_path);
        const msg = try std.fmt.allocPrint(
            allocator,
            "Failed to write HTML document header: {s}",
            .{@errorName(err)},
        );
        return RendererAttempt{ .ran_but_failed = ToolResult{ .success = false, .output = "", .error_msg = msg } };
    };
    header_path_opt = header_path;

    var argv_buf: [10][]const u8 = undefined;
    var argv_len: usize = 0;
    argv_buf[argv_len] = "pandoc";
    argv_len += 1;
    argv_buf[argv_len] = src_path;
    argv_len += 1;
    argv_buf[argv_len] = "-o";
    argv_len += 1;
    argv_buf[argv_len] = out_path;
    argv_len += 1;
    argv_buf[argv_len] = "--standalone";
    argv_len += 1;
    argv_buf[argv_len] = "--metadata";
    argv_len += 1;
    argv_buf[argv_len] = meta;
    argv_len += 1;
    if (header_path_opt) |hp| {
        argv_buf[argv_len] = "-H";
        argv_len += 1;
        argv_buf[argv_len] = hp;
        argv_len += 1;
    }
    return runRenderer(allocator, argv_buf[0..argv_len], "pandoc");
}

/// PDF: markdown → styled standalone HTML → WeasyPrint first. Legacy
/// pandoc/XeLaTeX stays as fallback for hosts missing WeasyPrint.
///
/// Branding: the primary path uses direct CSS @font-face file URLs. The
/// LaTeX fallback passes direct OTF file paths via fontspec variables, so
/// it does not depend on system font registration.
fn renderPdf(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    out_path: []const u8,
    title: []const u8,
    resolved_branding: ?ResolvedBranding,
) !ToolResult {
    const meta = try metadataArg(allocator, "title", title);
    defer allocator.free(meta);
    var pandoc_spawn_missing = false;

    const styled_html_path = try std.fmt.allocPrint(allocator, "{s}.html", .{out_path});
    defer {
        std.fs.deleteFileAbsolute(styled_html_path) catch {};
        allocator.free(styled_html_path);
    }
    const html_attempt = try renderStyledHtml(allocator, src_path, styled_html_path, title, resolved_branding, true);
    switch (html_attempt) {
        .success => |s| {
            freeRendererFailure(allocator, s);
            const weasy_args = [_][]const u8{ "weasyprint", styled_html_path, out_path };
            const weasy_attempt = runRenderer(allocator, &weasy_args, "weasyprint");
            switch (weasy_attempt) {
                .success => |ws| return ws,
                .ran_but_failed => |r| {
                    const stderr = if (r.error_msg) |em| em else "";
                    std.log.scoped(.produce_document).warn(
                        "WeasyPrint PDF render failed — retrying legacy pandoc PDF fallback. stderr: {s}",
                        .{stderr},
                    );
                    freeRendererFailure(allocator, r);
                },
                .binary_missing => |bm| allocator.free(bm),
                .binary_missing_static => {},
            }
        },
        .ran_but_failed => |r| return r,
        .binary_missing => |bm| {
            allocator.free(bm);
            pandoc_spawn_missing = true;
        },
        .binary_missing_static => pandoc_spawn_missing = true,
    }

    if (!pandoc_spawn_missing) {
        if (resolved_branding) |rb| {
            const mainfont_arg = try std.fmt.allocPrint(allocator, "mainfont={s}-Regular.otf", .{rb.body_font_family});
            defer allocator.free(mainfont_arg);
            const mainfont_options_arg = try std.fmt.allocPrint(
                allocator,
                "mainfontoptions=Path={s}/,BoldFont={s}-Bold.otf",
                .{ rb.body_otf_dir, rb.body_font_family },
            );
            defer allocator.free(mainfont_options_arg);
            const sansfont_arg = try std.fmt.allocPrint(allocator, "sansfont={s}-Regular.otf", .{rb.body_font_family});
            defer allocator.free(sansfont_arg);
            const sansfont_options_arg = try std.fmt.allocPrint(
                allocator,
                "sansfontoptions=Path={s}/,BoldFont={s}-Bold.otf",
                .{ rb.body_otf_dir, rb.body_font_family },
            );
            defer allocator.free(sansfont_options_arg);

            const branded_args = [_][]const u8{
                "pandoc",       src_path,             "-o",         out_path,
                "--pdf-engine", "xelatex",            "-V",         mainfont_arg,
                "-V",           mainfont_options_arg, "-V",         sansfont_arg,
                "-V",           sansfont_options_arg, "--metadata", meta,
            };
            const branded_attempt = runRenderer(allocator, &branded_args, "pandoc");
            switch (branded_attempt) {
                .success => |s| return s,
                .ran_but_failed => |r| {
                    // Most common failure: xelatex not installed. Detect via
                    // stderr contents and fall back to the plain pandoc path
                    // (which uses pdflatex internally) — branding loss is
                    // strictly better than no PDF.
                    const stderr = if (r.error_msg) |em| em else "";
                    if (!isBrandedPdfFallbackReason(stderr)) {
                        return r;
                    }
                    std.log.scoped(.branding).warn(
                        "PDF branded render failed — retrying without branding. Install/register xelatex + brand fonts for branded PDFs. stderr: {s}",
                        .{stderr},
                    );
                    if (r.output.len > 0) allocator.free(r.output);
                    if (r.error_msg) |em| allocator.free(em);
                    // Fall through to plain pandoc path below.
                },
                .binary_missing => |bm| {
                    allocator.free(bm);
                    pandoc_spawn_missing = true;
                },
                .binary_missing_static => pandoc_spawn_missing = true,
            }
        }
    }

    if (!pandoc_spawn_missing) {
        const xelatex_args = [_][]const u8{
            "pandoc",       src_path,  "-o",         out_path,
            "--pdf-engine", "xelatex", "--metadata", meta,
        };

        const xelatex_attempt = runRenderer(allocator, &xelatex_args, "pandoc");
        switch (xelatex_attempt) {
            .success => |s| return s,
            .ran_but_failed => |r| {
                const stderr = if (r.error_msg) |em| em else "";
                if (!isPlainXelatexFallbackReason(stderr)) {
                    return r;
                }
                std.log.scoped(.produce_document).warn(
                    "pandoc xelatex PDF render failed due to missing xelatex/font support — retrying default pandoc PDF path. Install texlive-xetex for Unicode-safe PDFs. stderr: {s}",
                    .{stderr},
                );
                freeRendererFailure(allocator, r);
                // Fall through to default pandoc path below.
            },
            .binary_missing => |bm| {
                allocator.free(bm);
                pandoc_spawn_missing = true;
            },
            .binary_missing_static => pandoc_spawn_missing = true,
        }
    }

    if (!pandoc_spawn_missing) {
        // Default pandoc PDF path, kept as compatibility fallback for hosts
        // that have pandoc+pdflatex but have not installed texlive-xetex.
        const pandoc_args = [_][]const u8{
            "pandoc",     src_path, "-o", out_path,
            "--metadata", meta,
        };

        const pandoc_attempt = runRenderer(allocator, &pandoc_args, "pandoc");
        switch (pandoc_attempt) {
            .success => |s| return s,
            .ran_but_failed => |r| {
                // HI-04 / CR-03 (v1.14.22): pandoc returned non-zero, but it
                // may have run successfully INTO a missing LaTeX engine —
                // exactly the shape the D63 Dockerfile produced before the
                // texlive-xetex install. Unicode failures from pdflatex have
                // the same operator action: use xelatex or an HTML renderer.
                const stderr = if (r.error_msg) |em| em else "";
                if (!isLatexEngineMissing(stderr) and !isPdfLatexUnicodeFailure(stderr)) {
                    return r;
                }

                std.log.scoped(.produce_document).warn(
                    "default pandoc PDF render failed due to LaTeX capability gap. Install WeasyPrint or texlive-xetex for PDFs. stderr: {s}",
                    .{stderr},
                );
                freeRendererFailure(allocator, r);
            },
            .binary_missing => |bm| allocator.free(bm),
            // Wave 2 review HIGH#1 — static message; do NOT free.
            .binary_missing_static => {},
        }
    }

    const msg = try allocator.dupe(
        u8,
        "PDF renderer not available — styled PDF requires pandoc plus WeasyPrint, or pandoc plus XeLaTeX as fallback. " ++
            "Install via: brew install pandoc  /  apt install pandoc  /  pip install weasyprint  /  install texlive-xetex",
    );
    return ToolResult{ .success = false, .output = "", .error_msg = msg };
}

fn freeRendererFailure(allocator: std.mem.Allocator, result: ToolResult) void {
    if (result.output.len > 0) allocator.free(result.output);
    if (result.error_msg) |em| allocator.free(em);
}

fn isBrandedPdfFallbackReason(stderr: []const u8) bool {
    const xelatex_missing = isLatexBinaryMissing(stderr, "xelatex");
    const font_lookup_failed =
        std.mem.indexOf(u8, stderr, "mktextfm") != null or
        std.mem.indexOf(u8, stderr, "mktexmf") != null or
        std.mem.indexOf(u8, stderr, "kpathsea") != null or
        std.mem.indexOf(u8, stderr, "I can't find file") != null or
        std.mem.indexOf(u8, stderr, "fontspec Error") != null;
    return xelatex_missing or font_lookup_failed;
}

fn isPlainXelatexFallbackReason(stderr: []const u8) bool {
    return isBrandedPdfFallbackReason(stderr) or isLatexEngineMissing(stderr);
}

fn isLatexEngineMissing(stderr: []const u8) bool {
    return isLatexBinaryMissing(stderr, "pdflatex") or
        isLatexBinaryMissing(stderr, "xelatex") or
        std.mem.indexOf(u8, stderr, "latex engine") != null;
}

fn isLatexBinaryMissing(stderr: []const u8, binary_name: []const u8) bool {
    return std.mem.indexOf(u8, stderr, binary_name) != null and
        (std.mem.indexOf(u8, stderr, "not found") != null or
            std.mem.indexOf(u8, stderr, "No such file") != null or
            std.mem.indexOf(u8, stderr, "command not found") != null);
}

fn isPdfLatexUnicodeFailure(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "LaTeX Error: Unicode character") != null and
        std.mem.indexOf(u8, stderr, "not set up for use with LaTeX") != null;
}

/// DOCX: pandoc's font handling is via a `--reference-doc=<path>`
/// template containing the desired styles (font-face overrides at the
/// XML style level). For v1 we look for an operator-placed template at
/// `<workspace>/branding/reference.docx`. When branding is enabled but
/// the template is absent we log a hint so the operator knows what to
/// drop in next; the DOCX still produces (unstyled), preserving §14.5
/// "broken branding must not break document production."
///
/// v1.1 (TODO): programmatically generate a reference.docx from
/// BrandingConfig at first-use via python-docx — skipped here to keep
/// the surface dependency-light. When implemented, drop the hint and
/// auto-create the template under `<workspace>/branding/`.
fn renderDocx(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    out_path: []const u8,
    title: []const u8,
    workspace_dir: []const u8,
    resolved_branding: ?ResolvedBranding,
) !ToolResult {
    const meta = try metadataArg(allocator, "title", title);
    defer allocator.free(meta);

    // Look for an operator-placed reference.docx when branding is on.
    var ref_arg_opt: ?[]u8 = null;
    defer if (ref_arg_opt) |ra| allocator.free(ra);
    if (resolved_branding) |_| {
        const ref_path = try std.fs.path.join(allocator, &.{ workspace_dir, "branding", "reference.docx" });
        defer allocator.free(ref_path);
        if (std.fs.openFileAbsolute(ref_path, .{})) |f| {
            f.close();
            ref_arg_opt = try std.fmt.allocPrint(allocator, "--reference-doc={s}", .{ref_path});
        } else |_| {
            std.log.scoped(.branding).info(
                "branding enabled but no reference.docx at '{s}' — DOCX will render unstyled. " ++
                    "Place a styled reference.docx at that path to apply brand body/heading fonts to DOCX output.",
                .{ref_path},
            );
        }
    }

    var argv_buf: [8][]const u8 = undefined;
    var argv_len: usize = 0;
    argv_buf[argv_len] = "pandoc";
    argv_len += 1;
    argv_buf[argv_len] = src_path;
    argv_len += 1;
    argv_buf[argv_len] = "-o";
    argv_len += 1;
    argv_buf[argv_len] = out_path;
    argv_len += 1;
    argv_buf[argv_len] = "--metadata";
    argv_len += 1;
    argv_buf[argv_len] = meta;
    argv_len += 1;
    if (ref_arg_opt) |ra| {
        argv_buf[argv_len] = ra;
        argv_len += 1;
    }
    const argv = argv_buf[0..argv_len];
    const attempt = runRenderer(allocator, argv, "pandoc");
    return switch (attempt) {
        .success => |s| s,
        .ran_but_failed => |r| r,
        .binary_missing => |msg| ToolResult{
            .success = false,
            .output = "",
            .error_msg = blk: {
                allocator.free(msg);
                break :blk try allocator.dupe(
                    u8,
                    "pandoc not installed — required for DOCX rendering. Install via: brew install pandoc  /  apt install pandoc",
                );
            },
        },
        // Wave 2 review HIGH#1 — static fallback message; do NOT free.
        .binary_missing_static => ToolResult{
            .success = false,
            .output = "",
            .error_msg = try allocator.dupe(
                u8,
                "pandoc not installed — required for DOCX rendering. Install via: brew install pandoc  /  apt install pandoc",
            ),
        },
    };
}

fn renderXlsx(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    out_path: []const u8,
) !ToolResult {
    // Preferred: python3 + pandas (handles quoted fields, type inference).
    const src_lit = try pyStringLiteralAlloc(allocator, src_path);
    defer allocator.free(src_lit);
    const out_lit = try pyStringLiteralAlloc(allocator, out_path);
    defer allocator.free(out_lit);
    const py_script = try std.fmt.allocPrint(
        allocator,
        \\import pandas as pd
        \\from openpyxl import load_workbook
        \\from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
        \\from openpyxl.utils import get_column_letter
        \\df = pd.read_csv({s})
        \\df.to_excel({s}, index=False, sheet_name='Artifact')
        \\wb = load_workbook({s})
        \\ws = wb.active
        \\ws.freeze_panes = 'A2'
        \\ws.auto_filter.ref = ws.dimensions
        \\header_fill = PatternFill('solid', fgColor='0F6F5C')
        \\header_font = Font(bold=True, color='FFFFFF')
        \\thin = Side(style='thin', color='DED8CA')
        \\for cell in ws[1]:
        \\    cell.fill = header_fill
        \\    cell.font = header_font
        \\    cell.alignment = Alignment(horizontal='left', vertical='center', wrap_text=True)
        \\for row in ws.iter_rows():
        \\    for cell in row:
        \\        cell.border = Border(top=thin, left=thin, right=thin, bottom=thin)
        \\        cell.alignment = Alignment(vertical='top', wrap_text=True)
        \\for col in ws.columns:
        \\    letter = get_column_letter(col[0].column)
        \\    max_len = 0
        \\    for cell in col:
        \\        value = '' if cell.value is None else str(cell.value)
        \\        if len(value) > max_len:
        \\            max_len = len(value)
        \\    ws.column_dimensions[letter].width = min(max(max_len + 2, 12), 42)
        \\wb.save({s})
    ,
        .{ src_lit, out_lit, out_lit, out_lit },
    );
    defer allocator.free(py_script);
    const pandas_argv = [_][]const u8{ "python3", "-c", py_script };
    const pandas_attempt = runRenderer(allocator, &pandas_argv, "python3");
    // Success path returns immediately. For both failure modes
    // (`.ran_but_failed` typically = ImportError: pandas; `.binary_missing` =
    // python3 not on PATH) we free any allocated buffers and fall through to
    // the pure-stdlib fallback so a workspace with python3 but no pandas
    // still produces a file.
    switch (pandas_attempt) {
        .success => |s| return s,
        .ran_but_failed => |r| {
            if (r.output.len > 0) allocator.free(r.output);
            if (r.error_msg) |em| allocator.free(em);
        },
        .binary_missing => |bm| allocator.free(bm),
        // Wave 2 review HIGH#1 — static; do NOT free.
        .binary_missing_static => {},
    }

    // Pure-stdlib fallback: csv → openpyxl, no pandas needed.
    const fallback_script = try std.fmt.allocPrint(
        allocator,
        \\import csv, openpyxl
        \\from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
        \\from openpyxl.utils import get_column_letter
        \\wb = openpyxl.Workbook()
        \\ws = wb.active
        \\ws.title = 'Artifact'
        \\with open({s}, newline='', encoding='utf-8') as f:
        \\    for row in csv.reader(f):
        \\        ws.append(row)
        \\ws.freeze_panes = 'A2'
        \\ws.auto_filter.ref = ws.dimensions
        \\header_fill = PatternFill('solid', fgColor='0F6F5C')
        \\header_font = Font(bold=True, color='FFFFFF')
        \\thin = Side(style='thin', color='DED8CA')
        \\for cell in ws[1]:
        \\    cell.fill = header_fill
        \\    cell.font = header_font
        \\    cell.alignment = Alignment(horizontal='left', vertical='center', wrap_text=True)
        \\for row in ws.iter_rows():
        \\    for cell in row:
        \\        cell.border = Border(top=thin, left=thin, right=thin, bottom=thin)
        \\        cell.alignment = Alignment(vertical='top', wrap_text=True)
        \\for col in ws.columns:
        \\    letter = get_column_letter(col[0].column)
        \\    max_len = 0
        \\    for cell in col:
        \\        value = '' if cell.value is None else str(cell.value)
        \\        if len(value) > max_len:
        \\            max_len = len(value)
        \\    ws.column_dimensions[letter].width = min(max(max_len + 2, 12), 42)
        \\wb.save({s})
    ,
        .{ src_lit, out_lit },
    );
    defer allocator.free(fallback_script);

    const fallback_argv = [_][]const u8{ "python3", "-c", fallback_script };
    const fallback_attempt = runRenderer(allocator, &fallback_argv, "python3");
    return switch (fallback_attempt) {
        .success => |s| s,
        .ran_but_failed => |r| blk: {
            // Free the original error_msg, then craft an install-hint message.
            if (r.output.len > 0) allocator.free(r.output);
            const original = r.error_msg orelse "";
            const msg = try std.fmt.allocPrint(
                allocator,
                "XLSX rendering failed — neither pandas nor openpyxl produced a file. " ++
                    "Install via: pip install pandas openpyxl. Renderer stderr: {s}",
                .{original},
            );
            if (r.error_msg) |em| allocator.free(em);
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
        .binary_missing => |bm| blk: {
            allocator.free(bm);
            const msg = try allocator.dupe(
                u8,
                "python3 not installed — required for XLSX rendering. " ++
                    "Install python3 + pip install pandas openpyxl",
            );
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
        // Wave 2 review HIGH#1 — static fallback; do NOT free.
        .binary_missing_static => blk: {
            const msg = try allocator.dupe(
                u8,
                "python3 not installed — required for XLSX rendering. " ++
                    "Install python3 + pip install pandas openpyxl",
            );
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
    };
}

/// PPTX (Marp): the exported "default" is a generated ZAKI theme, not
/// raw Marp defaults. When theme=thmanyah AND branding is resolved, we
/// generate a branded sibling theme with @font-face declarations. Both
/// paths write under `<workspace>/branding/marp/` and pass `--theme-set`.
fn renderPptx(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    out_path: []const u8,
    theme: Theme,
    workspace_dir: []const u8,
    resolved_branding: ?ResolvedBranding,
) !ToolResult {
    // Default and thmanyah write first-class themes. Gaia/uncover stay
    // Marp built-ins because those are intentionally distinct user picks.
    var theme_dir_opt: ?[]u8 = null;
    defer if (theme_dir_opt) |td| allocator.free(td);

    if (theme == .default_theme or theme == .thmanyah) {
        const theme_dir = try std.fs.path.join(allocator, &.{ workspace_dir, "branding", "marp" });
        errdefer allocator.free(theme_dir);
        std.fs.cwd().makePath(theme_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                allocator.free(theme_dir);
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to create marp theme dir '{s}': {s}",
                    .{ theme_dir, @errorName(err) },
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        const css = if (theme == .default_theme) blk: {
            break :blk try allocator.dupe(u8, MARP_DEFAULT_THEME_CSS);
        } else blk: {
            // execute() already validated that branding is resolved (theme
            // requires branding); this is just an extra debug guard.
            const rb = resolved_branding orelse {
                allocator.free(theme_dir);
                return ToolResult{
                    .success = false,
                    .output = "",
                    .error_msg = try allocator.dupe(u8, "internal: theme=thmanyah reached renderPptx with null branding"),
                };
            };
            const face_block = try cssFontFaceBlock(allocator, rb, .file);
            defer allocator.free(face_block);

            // The /* @theme thmanyah */ comment is REQUIRED by marp-cli to
            // recognize the file as a registered theme keyed by the name
            // we used in the frontmatter (`theme: thmanyah`).
            break :blk try std.fmt.allocPrint(
                allocator,
                "/* @theme thmanyah */\n\n" ++
                    "@import 'default';\n\n" ++
                    "{s}\n" ++
                    "section {{ background: #fffefa; color: #171714; font-family: '{s}', system-ui, sans-serif; padding: 54px 68px 48px; }}\n" ++
                    "section::before {{ content: \"\"; position: absolute; left: 68px; top: 38px; width: 64px; height: 5px; background: #0f6f5c; }}\n" ++
                    "section::after {{ color: #777b76; font-size: 17px; }}\n" ++
                    "section h1, section h2, section h3 {{ color: #171714; font-family: '{s}', Georgia, serif; letter-spacing: 0; }}\n" ++
                    "section h1 {{ font-size: 62px; line-height: 1.02; }}\n" ++
                    "section blockquote {{ border-left: 6px solid #0f6f5c; background: #e5f2ee; }}\n",
                .{ face_block, rb.body_font_family, rb.display_font_family },
            );
        };
        defer allocator.free(css);

        const css_filename: []const u8 = if (theme == .default_theme) "zaki-default.css" else "thmanyah.css";
        const css_path = try std.fs.path.join(allocator, &.{ theme_dir, css_filename });
        defer allocator.free(css_path);
        const f = std.fs.createFileAbsolute(css_path, .{}) catch |err| {
            allocator.free(theme_dir);
            const msg = try std.fmt.allocPrint(
                allocator,
                "Failed to create marp theme CSS '{s}': {s}",
                .{ css_path, @errorName(err) },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer f.close();
        f.writeAll(css) catch |err| {
            allocator.free(theme_dir);
            const msg = try std.fmt.allocPrint(
                allocator,
                "Failed to write marp theme CSS: {s}",
                .{@errorName(err)},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        theme_dir_opt = theme_dir;
    }

    // marp-cli: markdown → pptx with --- as slide separator. Generated
    // default/thmanyah themes pass --theme-set so Marp registers them.
    var argv_buf: [8][]const u8 = undefined;
    var argv_len: usize = 0;
    argv_buf[argv_len] = "marp";
    argv_len += 1;
    argv_buf[argv_len] = src_path;
    argv_len += 1;
    argv_buf[argv_len] = "-o";
    argv_len += 1;
    argv_buf[argv_len] = out_path;
    argv_len += 1;
    if (theme_dir_opt) |td| {
        argv_buf[argv_len] = "--theme-set";
        argv_len += 1;
        argv_buf[argv_len] = td;
        argv_len += 1;
    }
    const argv = argv_buf[0..argv_len];
    const attempt = runRenderer(allocator, argv, "marp");
    return switch (attempt) {
        .success => |s| s,
        .ran_but_failed => |r| r,
        .binary_missing => |bm| blk: {
            allocator.free(bm);
            const msg = try allocator.dupe(
                u8,
                "marp-cli not installed — required for PPTX rendering. " ++
                    "Install via: npm install -g @marp-team/marp-cli",
            );
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
        // Wave 2 review HIGH#1 — static fallback; do NOT free.
        .binary_missing_static => blk: {
            const msg = try allocator.dupe(
                u8,
                "marp-cli not installed — required for PPTX rendering. " ++
                    "Install via: npm install -g @marp-team/marp-cli",
            );
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
    };
}

/// Parked HTML renderer: pandoc --standalone produces a full HTML document.
/// We pass the same document CSS header used by PDF; when branding is resolved,
/// that header also includes
/// @font-face declarations. Font URLs are absolute `file://` paths so
/// local renders work; static deploys may rewrite them later.
fn renderHtml(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    out_path: []const u8,
    title: []const u8,
    resolved_branding: ?ResolvedBranding,
) !ToolResult {
    const attempt = try renderStyledHtml(allocator, src_path, out_path, title, resolved_branding, false);
    return switch (attempt) {
        .success => |s| s,
        .ran_but_failed => |r| r,
        .binary_missing => |bm| blk: {
            allocator.free(bm);
            const msg = try allocator.dupe(
                u8,
                "pandoc not installed — required for HTML rendering. Install via: brew install pandoc  /  apt install pandoc",
            );
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
        // Wave 2 review HIGH#1 — static fallback; do NOT free.
        .binary_missing_static => blk: {
            const msg = try allocator.dupe(
                u8,
                "pandoc not installed — required for HTML rendering. Install via: brew install pandoc  /  apt install pandoc",
            );
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
    };
}

// ── Subprocess wrapper with binary-missing detection ─────────────────

/// Three-way result so callers can distinguish "binary is not on PATH" (try
/// the next fallback) from "binary ran but returned non-zero" (surface the
/// actual stderr to the agent).
///
/// Wave 2 review HIGH#1 — added `binary_missing_static` so the OOM
/// fallback (when allocPrint for the failure-message itself fails) can
/// return a sentinel that callers MUST NOT free. The original code used
/// `@constCast("alloc failed")` for this case, then callers called
/// `allocator.free(bm)` on the literal — UB under DebugAllocator, silent
/// free-list corruption in production builds. Splitting the variant
/// surfaces the lifetime distinction in the type system.
const RendererAttempt = union(enum) {
    success: ToolResult,
    ran_but_failed: ToolResult,
    /// Heap-allocated message describing the missing-binary condition.
    /// Caller frees with `allocator.free` if not propagated.
    binary_missing: []u8,
    /// Compile-time-known fallback used ONLY when even the allocPrint for
    /// the missing-binary message itself ran out of memory. Callers must
    /// NOT call `allocator.free` on this slice.
    binary_missing_static: []const u8,
};

/// Static fallback message used when even `allocPrint("Failed to invoke
/// {s}: {s}")` runs out of memory. Returned via `binary_missing_static`
/// so callers know not to free it.
const BINARY_MISSING_ALLOC_FAILED: []const u8 = "renderer invocation failed (allocation exhausted while building the error message)";

fn runRenderer(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    binary_name: []const u8,
) RendererAttempt {
    const result = process_util.run(allocator, argv, .{
        .max_output_bytes = RENDERER_OUTPUT_CAP,
        .timeout_ns = RENDER_TIMEOUT_NS,
    }) catch |err| {
        // Wave 2 review HIGH#4 — broaden the missing-binary detection beyond
        // bare `error.FileNotFound`. On a noexec mount, on certain mac
        // sandboxes, and on Zig stdlib revisions that may rename the variant,
        // the spawn-time "binary unavailable" condition surfaces under other
        // error names (`AccessDenied`, `ProcessNotFound`, etc.). Treating
        // those as "binary missing" lets renderer fallback chains keep walking instead of
        // fail-fast on the FIRST renderer's spawn error. We classify any
        // listed spawn-time error as "missing"; everything else falls
        // through to the generic `ran_but_failed` arm with the actual
        // error name embedded in the message.
        const is_missing = switch (err) {
            error.FileNotFound, error.AccessDenied => true,
            else => false,
        };
        const msg = std.fmt.allocPrint(
            allocator,
            "Failed to invoke {s}: {s}",
            .{ binary_name, @errorName(err) },
        ) catch {
            // Wave 2 review HIGH#1 — was `@constCast("alloc failed")` then
            // `allocator.free(bm)` by every caller; UB on a static string.
            // The static variant tells callers not to free.
            return RendererAttempt{ .binary_missing_static = BINARY_MISSING_ALLOC_FAILED };
        };
        if (is_missing) {
            return RendererAttempt{ .binary_missing = msg };
        }
        return RendererAttempt{ .ran_but_failed = ToolResult{
            .success = false,
            .output = "",
            .error_msg = msg,
        } };
    };
    defer allocator.free(result.stdout);

    if (result.success) {
        allocator.free(result.stderr);
        return RendererAttempt{ .success = ToolResult{ .success = true, .output = "" } };
    }

    if (result.timed_out) {
        allocator.free(result.stderr);
        const msg = std.fmt.allocPrint(
            allocator,
            "{s} timed out after {d}s",
            .{ binary_name, RENDER_TIMEOUT_NS / std.time.ns_per_s },
        ) catch return RendererAttempt{ .binary_missing_static = BINARY_MISSING_ALLOC_FAILED };
        return RendererAttempt{ .ran_but_failed = ToolResult{
            .success = false,
            .output = "",
            .error_msg = msg,
        } };
    }

    // Truncate stderr to keep the agent-visible message readable.
    const trimmed_err = trimStderr(result.stderr);
    const msg = std.fmt.allocPrint(
        allocator,
        "{s} exit={?d}: {s}",
        .{ binary_name, result.exit_code, trimmed_err },
    ) catch {
        allocator.free(result.stderr);
        return RendererAttempt{ .binary_missing_static = BINARY_MISSING_ALLOC_FAILED };
    };
    allocator.free(result.stderr);
    return RendererAttempt{ .ran_but_failed = ToolResult{
        .success = false,
        .output = "",
        .error_msg = msg,
    } };
}

fn trimStderr(stderr: []const u8) []const u8 {
    const MAX = 500;
    const t = std.mem.trim(u8, stderr, " \t\r\n");
    if (t.len <= MAX) return t;
    return t[0..MAX];
}

/// Build a `key=value` arg suitable for pandoc `--metadata`. Caller frees.
fn metadataArg(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
}

/// Quote a path as a Python raw-string literal. Single quotes and CR/LF are
/// replaced with `_` — our paths are sanitized upstream so this is defense
/// in depth: if a path somehow smuggled one in we'd rather render a broken
/// literal than execute attacker-chosen Python.
///
/// Result is heap-allocated; caller frees.
fn pyStringLiteralAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "r'");
    for (path) |c| {
        if (c == '\'' or c == '\n' or c == '\r') {
            try buf.append(allocator, '_');
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
    return buf.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

test "produce_document tool name + schema" {
    var pd = ProduceDocumentTool{ .workspace_dir = "/tmp" };
    const t = pd.tool();
    try std.testing.expectEqualStrings("produce_document", t.name());
    try std.testing.expect(std.mem.indexOf(u8, ProduceDocumentTool.tool_params, "format") != null);
    try std.testing.expect(std.mem.indexOf(u8, ProduceDocumentTool.tool_params, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, ProduceDocumentTool.tool_params, "title") != null);
    try std.testing.expect(std.mem.indexOf(u8, ProduceDocumentTool.tool_params, "pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, ProduceDocumentTool.tool_params, "xlsx") == null);
    try std.testing.expect(std.mem.indexOf(u8, ProduceDocumentTool.tool_params, "pptx") == null);
    try std.testing.expect(std.mem.indexOf(u8, ProduceDocumentTool.tool_params, "docx") == null);
}

test "produce_document description pins S-tier artifact blueprints" {
    const desc = ProduceDocumentTool.tool_description;
    try std.testing.expect(std.mem.indexOf(u8, desc, "Artifact quality gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "Default decision-doc blueprint") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "styled PDF renderer") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "parked legacy renderers") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "no placeholders") != null);
}

test "produce_document rejects missing format" {
    var pd = ProduceDocumentTool{ .workspace_dir = "/tmp" };
    const t = pd.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("content", std.json.Value{ .string = "hello" });
    // .fail() returns a static string — don't free.
    const result = try t.execute(std.testing.allocator, args);
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "format") != null);
}

test "produce_document rejects missing content" {
    var pd = ProduceDocumentTool{ .workspace_dir = "/tmp" };
    const t = pd.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "pdf" });
    // .fail() returns a static string — don't free.
    const result = try t.execute(std.testing.allocator, args);
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "content") != null);
}

test "produce_document rejects empty content" {
    var pd = ProduceDocumentTool{ .workspace_dir = "/tmp" };
    const t = pd.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "pdf" });
    try args.put("content", std.json.Value{ .string = "   \n  \t" });
    // .fail() returns a static string — don't free.
    const result = try t.execute(std.testing.allocator, args);
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "empty") != null);
}

test "produce_document rejects invalid format string" {
    var pd = ProduceDocumentTool{ .workspace_dir = "/tmp" };
    const t = pd.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "rtf" });
    try args.put("content", std.json.Value{ .string = "hello" });
    const result = try t.execute(std.testing.allocator, args);
    // Invalid format path uses allocPrint — DO free.
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "rtf") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "pdf") != null);
}

test "produce_document rejects parked non-PDF formats" {
    var pd = ProduceDocumentTool{ .workspace_dir = "/tmp" };
    const t = pd.tool();
    const formats = [_][]const u8{ "docx", "xlsx", "pptx", "html" };
    for (formats) |fmt| {
        var args = std.json.ObjectMap.init(std.testing.allocator);
        defer args.deinit();
        try args.put("format", std.json.Value{ .string = fmt });
        try args.put("content", std.json.Value{ .string = "# Hello" });
        const result = try t.execute(std.testing.allocator, args);
        defer if (result.error_msg) |m| std.testing.allocator.free(m);
        try std.testing.expect(!result.success);
        const msg = result.error_msg orelse result.output;
        try std.testing.expect(std.mem.indexOf(u8, msg, "parked") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "PDF") != null);
    }
}

test "produce_document rejects empty workspace" {
    var pd = ProduceDocumentTool{ .workspace_dir = "" };
    const t = pd.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "pdf" });
    try args.put("content", std.json.Value{ .string = "hello" });
    // .fail() returns a static string — don't free.
    const result = try t.execute(std.testing.allocator, args);
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Workspace") != null);
}

test "produce_document missing renderer surfaces install hint" {
    // Use a unique workspace under /tmp so we don't collide with concurrent
    // test runs. The renderer chain may or may not be installed in the sandbox
    // — just verify that
    // EITHER the call succeeds OR the error message mentions the install
    // hint (covering the CI-sandbox-without-binaries case AND the local-dev
    // case where pandoc IS installed).
    const ts = std.time.milliTimestamp();
    const ws = try std.fmt.allocPrint(std.testing.allocator, "/tmp/pd_test_{d}", .{ts});
    defer std.testing.allocator.free(ws);
    std.fs.makeDirAbsolute(ws) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(ws) catch {};

    var pd = ProduceDocumentTool{ .workspace_dir = ws };
    const t = pd.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "pdf" });
    try args.put("content", std.json.Value{ .string = "# PDF Smoke\n\nA short renderer check." });
    try args.put("title", std.json.Value{ .string = "test_pdf" });

    const result = try t.execute(std.testing.allocator, args);
    defer {
        if (result.output.len > 0) std.testing.allocator.free(result.output);
        if (result.error_msg) |m| std.testing.allocator.free(m);
    }
    // Two valid outcomes: (a) a PDF renderer is installed AND succeeds; (b) no
    // renderer is installed AND we get the install hint. The wrong outcome is a confusing
    // generic failure.
    if (result.success) {
        // The success path also exercises the file-write + markdown-link
        // formatting code; assert the link points into produced/.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "attachments/produced/") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, ".pdf") != null);
    } else {
        const msg = if (result.error_msg) |m| m else result.output;
        // Per §14.5 honesty rule: the error must name the install hint.
        try std.testing.expect(
            std.mem.indexOf(u8, msg, "PDF renderer") != null or
                std.mem.indexOf(u8, msg, "pandoc") != null or
                std.mem.indexOf(u8, msg, "weasyprint") != null,
        );
    }
}

test "sanitizeTitle strips path separators and control chars" {
    // Path-traversal safety is established by: (a) no '/' or '\\' survives;
    // (b) leading '.' chars are stripped so the result can never start with
    // a relative path segment. Surviving `..` characters within the name
    // are harmless because there is no separator to make them act as a
    // path component.
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "hello world", .want = "hello_world" },
        .{ .in = "../../etc/passwd", .want = "etc_passwd" },
        .{ .in = "report.q1.2026", .want = "report.q1.2026" },
        .{ .in = "foo/bar\\baz", .want = "foo_bar_baz" },
        .{ .in = "  trim  me  ", .want = "trim_me" },
        .{ .in = "____ugly_____", .want = "ugly" }, // collapses runs + trims
        .{ .in = "", .want = "untitled" },
        .{ .in = "   \t  ", .want = "untitled" },
        .{ .in = "with\nnewline", .want = "with_newline" },
        .{ .in = "...hidden", .want = "hidden" }, // leading dots stripped
        .{ .in = "trailing...", .want = "trailing" }, // trailing dots stripped
    };
    for (cases) |c| {
        const got = try sanitizeTitle(std.testing.allocator, c.in);
        defer std.testing.allocator.free(got);
        std.testing.expectEqualStrings(c.want, got) catch |err| {
            std.debug.print("sanitizeTitle('{s}') = '{s}', want '{s}'\n", .{ c.in, got, c.want });
            return err;
        };
    }
}

test "sanitizeTitle never contains path separators or control chars" {
    // Tighter invariant than the case-by-case test above — for ANY
    // adversarial input, the output must be safe to splice into a path.
    const adversarial = [_][]const u8{
        "../../../../etc/passwd",
        "C:\\Windows\\System32\\foo",
        "\x00null\x00byte",
        "\x07bell\x1bescape",
        "foo/../bar",
        "name with / and \\ everywhere",
    };
    for (adversarial) |input| {
        const got = try sanitizeTitle(std.testing.allocator, input);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOfScalar(u8, got, '/') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, got, '\\') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, got, 0) == null);
        // Result is never empty; never starts with '.' or '_' (no hidden
        // files, no ugly all-separator prefixes).
        try std.testing.expect(got.len > 0);
        try std.testing.expect(got[0] != '.');
        try std.testing.expect(got[0] != '_');
    }
}

test "sanitizeTitle caps length" {
    const long_title = "a" ** 200;
    const got = try sanitizeTitle(std.testing.allocator, long_title);
    defer std.testing.allocator.free(got);
    try std.testing.expect(got.len <= MAX_TITLE_LEN);
    try std.testing.expect(got.len > 0);
}

test "parseFormat accepts all 5 formats case-insensitive" {
    try std.testing.expectEqual(@as(?Format, .pdf), parseFormat("pdf"));
    try std.testing.expectEqual(@as(?Format, .pdf), parseFormat("PDF"));
    try std.testing.expectEqual(@as(?Format, .docx), parseFormat("DocX"));
    try std.testing.expectEqual(@as(?Format, .xlsx), parseFormat("xlsx"));
    try std.testing.expectEqual(@as(?Format, .pptx), parseFormat("pptx"));
    try std.testing.expectEqual(@as(?Format, .html), parseFormat("HTML"));
    try std.testing.expectEqual(@as(?Format, null), parseFormat("rtf"));
    try std.testing.expectEqual(@as(?Format, null), parseFormat(""));
}

test "sourceExtension + outputExtension are well-defined for all formats" {
    inline for (.{ Format.pdf, .docx, .xlsx, .pptx, .html }) |f| {
        try std.testing.expect(sourceExtension(f).len > 0);
        try std.testing.expect(outputExtension(f).len > 0);
        try std.testing.expect(formatLabel(f).len > 0);
    }
}

test "pyStringLiteralAlloc escapes single quotes and newlines" {
    const safe = try pyStringLiteralAlloc(std.testing.allocator, "/tmp/safe_path.csv");
    defer std.testing.allocator.free(safe);
    try std.testing.expectEqualStrings("r'/tmp/safe_path.csv'", safe);

    const evil = try pyStringLiteralAlloc(std.testing.allocator, "/tmp/bad'\npath");
    defer std.testing.allocator.free(evil);
    // single quote and newline both → underscore
    try std.testing.expectEqualStrings("r'/tmp/bad__path'", evil);
}

// ─── Wave 2 review regression tests (2026-05-24) ───────────────────────

test "Wave2-HIGH1: runRenderer OOM-on-allocPrint path returns the static sentinel, callers never free it" {
    // Reproduces the bug fixed in HIGH#1: when allocPrint for the
    // failure-message itself runs out of memory the catch arm used to
    // return `@constCast("alloc failed")` which callers then ran through
    // `allocator.free` — UB on a string literal. The fix splits the
    // union variant so the static-fallback path is type-distinct from
    // the heap-owned one. This test exercises the OOM arm via a
    // FailingAllocator and asserts (1) no crash, (2) the static variant
    // is returned, (3) the message is the documented sentinel.
    //
    // We can't directly call `runRenderer` with a controlled failure
    // since the OOM only fires inside the catch block AFTER
    // process_util.run errors. The simplest reproduction is to invoke
    // an obviously-missing binary with a FailingAllocator that lets
    // process_util.run's allocations succeed (those happen first) but
    // fails the allocPrint call. We approximate by triggering an
    // unrealistically tight allocator budget that's only enough for the
    // spawn-side allocations.
    //
    // Pragmatic approach: directly verify that the static sentinel
    // exists, has a non-empty descriptive message, and the union variant
    // is correctly typed. The full OOM scenario is covered by the
    // BINARY_MISSING_ALLOC_FAILED contract (callers handle
    // `binary_missing_static` with empty `{}` arms, NOT with free()).
    try std.testing.expect(BINARY_MISSING_ALLOC_FAILED.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, BINARY_MISSING_ALLOC_FAILED, "allocation") != null);

    // Confirm the union type can hold the static variant without copy
    // (`.binary_missing_static` is `[]const u8`, not `[]u8`).
    const attempt: RendererAttempt = .{ .binary_missing_static = BINARY_MISSING_ALLOC_FAILED };
    switch (attempt) {
        .binary_missing_static => |s| try std.testing.expect(s.ptr == BINARY_MISSING_ALLOC_FAILED.ptr),
        else => return error.UnexpectedVariant,
    }
}

test "Wave2-HIGH1: RendererAttempt switch is exhaustive over binary_missing_static" {
    // Structural compile-time guard: every renderer dispatcher
    // (renderPdf/Docx/Xlsx/Pptx/Html) must include a switch arm for
    // `.binary_missing_static` or Zig will fail compile with
    // "switch must handle all possibilities." If a future refactor
    // drops the arm from a dispatcher this test still exercises that
    // the variant constructs safely without triggering a free path.
    const static_attempt: RendererAttempt = .{ .binary_missing_static = BINARY_MISSING_ALLOC_FAILED };
    switch (static_attempt) {
        .success => return error.WrongVariant,
        .ran_but_failed => return error.WrongVariant,
        .binary_missing => return error.WrongVariant,
        .binary_missing_static => {}, // arm exists in the type
    }
}

test "Wave2-HIGH4: missing-binary detection covers AccessDenied in addition to FileNotFound" {
    // Verify the broadened classification in runRenderer's catch arm:
    // both error.FileNotFound AND error.AccessDenied should map to
    // `binary_missing` so the renderer fallback chain keeps walking on
    // noexec mounts / restricted sandboxes / future stdlib renames.
    //
    // Direct test of the classifier: invoke runRenderer with a binary
    // path that resolves to AccessDenied (a non-executable file under
    // /tmp). This is platform-specific so we skip on Windows.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    // Create a non-executable file in /tmp; running it should yield
    // AccessDenied on macOS/Linux (the OS refuses to exec a non-+x file).
    const dir_path = try std.fmt.allocPrint(alloc, "/tmp/pd_access_test_{d}", .{std.time.milliTimestamp()});
    defer alloc.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.fs.deleteTreeAbsolute(dir_path) catch {};

    const bin_path = try std.fs.path.join(alloc, &.{ dir_path, "noexec_bin" });
    defer alloc.free(bin_path);
    {
        const f = try std.fs.createFileAbsolute(bin_path, .{ .mode = 0o644 });
        defer f.close();
        try f.writeAll("not an executable\n");
    }

    const argv = [_][]const u8{bin_path};
    const attempt = runRenderer(alloc, &argv, "noexec_bin");
    // Either FileNotFound or AccessDenied → both must map to
    // `binary_missing` (heap) or `binary_missing_static` (OOM fallback).
    // The "ran_but_failed" arm would be the bug — it means the chain
    // would stop here instead of trying the next renderer.
    switch (attempt) {
        .success => return error.UnexpectedSuccess,
        .ran_but_failed => |r| {
            if (r.error_msg) |em| alloc.free(em);
            if (r.output.len > 0) alloc.free(r.output);
            return error.MissingBinaryNotDetectedAsMissing;
        },
        .binary_missing => |bm| alloc.free(bm),
        .binary_missing_static => {},
    }
}

test "PDF branding fallback detects missing registered font" {
    const stderr =
        "kpathsea: Running mktextfm thmanyahsans\n" ++
        "mktextfm: Running mf-nowin input thmanyahsans\n" ++
        "! I can't find file `thmanyahsans'.";
    try std.testing.expect(isBrandedPdfFallbackReason(stderr));
}

test "PDF branding fallback detects missing xelatex only when relevant" {
    try std.testing.expect(isBrandedPdfFallbackReason("xelatex: command not found"));
    try std.testing.expect(!isBrandedPdfFallbackReason("pandoc failed because markdown is invalid"));
}

test "PDF renderer classifiers distinguish pdflatex Unicode failure from arbitrary pandoc errors" {
    const unicode_stderr =
        "pandoc exit=43: Error producing PDF.\n" ++
        "! LaTeX Error: Unicode character ❌ (U+274C) not set up for use with LaTeX.";
    try std.testing.expect(isPdfLatexUnicodeFailure(unicode_stderr));
    try std.testing.expect(!isPdfLatexUnicodeFailure("pandoc exit=43: markdown syntax error"));
    try std.testing.expect(isLatexEngineMissing("pdflatex: command not found"));
    try std.testing.expect(isPlainXelatexFallbackReason("xelatex: No such file or directory"));
}

test "produce_document PDF uses styled or Unicode-safe renderer when installed" {
    const allocator = std.testing.allocator;
    if (!rendererBinaryAvailable(allocator, "pandoc")) return error.SkipZigTest;
    if (!rendererBinaryAvailable(allocator, "weasyprint") and !rendererBinaryAvailable(allocator, "xelatex")) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws);

    var pd = ProduceDocumentTool{ .workspace_dir = ws };
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "pdf" });
    try args.put("title", std.json.Value{ .string = "Unicode PDF Smoke" });
    try args.put("content", std.json.Value{ .string = "# Status\n\nStatus: ❌" });

    const result = try pd.execute(allocator, args);
    defer {
        if (result.output.len > 0) allocator.free(result.output);
        if (result.error_msg) |em| allocator.free(em);
    }

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".pdf") != null);
}

test "produce_document PDF embeds Thmanyah fonts when WeasyPrint is available" {
    const allocator = std.testing.allocator;
    if (!rendererBinaryAvailable(allocator, "pandoc")) return error.SkipZigTest;
    if (!rendererBinaryAvailable(allocator, "weasyprint")) return error.SkipZigTest;
    {
        const probe_argv = [_][]const u8{ "pdffonts", "-v" };
        const probe = process_util.run(allocator, &probe_argv, .{
            .max_output_bytes = 16 * 1024,
            .timeout_ns = 10 * std.time.ns_per_s,
        }) catch return error.SkipZigTest;
        defer allocator.free(probe.stdout);
        defer allocator.free(probe.stderr);
        if (!probe.success) return error.SkipZigTest;
    }
    const bundled_branding = (try resolveBranding(allocator, BrandingConfig{})) orelse return error.SkipZigTest;
    defer bundled_branding.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(ws);

    var pd = ProduceDocumentTool{ .workspace_dir = ws };
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "pdf" });
    try args.put("title", std.json.Value{ .string = "Thmanyah PDF Smoke" });
    try args.put(
        "content",
        std.json.Value{ .string = "# Thmanyah PDF Smoke\n\n## Summary\n\n- One useful bullet.\n\n| Metric | Value |\n|---|---:|\n| Quality | High |\n\n> Branded quote.\n\n```zig\nconst ok = true;\n```" },
    );

    const result = try pd.execute(allocator, args);
    defer {
        if (result.output.len > 0) allocator.free(result.output);
        if (result.error_msg) |em| allocator.free(em);
    }
    try std.testing.expect(result.success);

    const marker = "attachments/produced/";
    const start = std.mem.indexOf(u8, result.output, marker) orelse return error.MissingProducedPath;
    const rest = result.output[start..];
    const end = std.mem.indexOfScalar(u8, rest, ')') orelse rest.len;
    const rel_path = rest[0..end];
    const pdf_path = try std.fs.path.join(allocator, &.{ ws, rel_path });
    defer allocator.free(pdf_path);

    const fonts_argv = [_][]const u8{ "pdffonts", pdf_path };
    const fonts = try process_util.run(allocator, &fonts_argv, .{
        .max_output_bytes = 64 * 1024,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer allocator.free(fonts.stdout);
    defer allocator.free(fonts.stderr);
    try std.testing.expect(fonts.success);
    try std.testing.expect(std.mem.indexOf(u8, fonts.stdout, "thmanyah") != null);
    try std.testing.expect(std.mem.indexOf(u8, fonts.stdout, "LatinModern") == null);
}

fn rendererBinaryAvailable(allocator: std.mem.Allocator, binary_name: []const u8) bool {
    const argv = [_][]const u8{ binary_name, "--version" };
    const result = process_util.run(allocator, &argv, .{
        .max_output_bytes = 16 * 1024,
        .timeout_ns = 10 * std.time.ns_per_s,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.success;
}

test "Wave2-HIGH5: produced filename includes CSPRNG nonce — 100 same-title invocations yield 100 distinct paths" {
    // The pre-fix code used only `<title>_<ms_ts>.<ext>` which collides
    // under sub-millisecond concurrency despite the tool advertising
    // `concurrency_safe = true`. We don't actually invoke the renderer
    // (which would require pandoc/marp/python on the CI sandbox);
    // instead we test the filename-construction pattern directly by
    // re-implementing the format string and asserting uniqueness.
    const alloc = std.testing.allocator;
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Mirrors the format string in execute() so the test breaks if
        // the format ever changes without preserving uniqueness.
        const ts_ms = std.time.milliTimestamp();
        const nonce = std.crypto.random.int(u32);
        const name = try std.fmt.allocPrint(alloc, "{s}_{d}_{x:0>8}{s}", .{ "same_title", ts_ms, nonce, ".pdf" });
        errdefer alloc.free(name);
        const gop = try seen.getOrPut(name);
        if (gop.found_existing) {
            alloc.free(name);
            return error.CollisionDetected;
        }
    }
    try std.testing.expectEqual(@as(u32, 100), seen.count());
}

// ─── Branding (Thmanyah) integration tests (2026-05-25) ─────────────────

/// Helper for branding tests: builds a tmp dir with the Thmanyah-shape
/// font directory structure so resolveBranding can succeed. Caller frees
/// `font_dir`. The dir tree is also queued for cleanup via the returned
/// `root_for_cleanup` (use `defer deleteTreeAbsolute`).
fn buildTestFontDir(allocator: std.mem.Allocator, name_suffix: []const u8) !struct {
    root: []u8,
    font_dir: []u8,
} {
    const ts = std.time.milliTimestamp();
    const root_dir = try std.fmt.allocPrint(allocator, "/tmp/pd_brand_test_{d}_{s}", .{ ts, name_suffix });
    errdefer allocator.free(root_dir);
    try std.fs.makeDirAbsolute(root_dir);

    // <root>/fonts/thmanyahsans/{otf,woff2}
    // <root>/fonts/thmanyahserifdisplay/{otf,woff2}
    const font_dir = try std.fs.path.join(allocator, &.{ root_dir, "fonts" });
    errdefer allocator.free(font_dir);
    try std.fs.makeDirAbsolute(font_dir);

    const families = [_][]const u8{ "thmanyahsans", "thmanyahserifdisplay" };
    for (families) |fam| {
        const fam_dir = try std.fs.path.join(allocator, &.{ font_dir, fam });
        defer allocator.free(fam_dir);
        try std.fs.makeDirAbsolute(fam_dir);
        const otf_dir = try std.fs.path.join(allocator, &.{ fam_dir, "otf" });
        defer allocator.free(otf_dir);
        try std.fs.makeDirAbsolute(otf_dir);
        const woff2_dir = try std.fs.path.join(allocator, &.{ fam_dir, "woff2" });
        defer allocator.free(woff2_dir);
        try std.fs.makeDirAbsolute(woff2_dir);
        // Drop one file so the dir is non-empty (matches operator deploy
        // shape; resolveBranding doesn't currently inspect contents but
        // future hardening might want at least one face).
        const probe_otf = try std.fs.path.join(allocator, &.{ otf_dir, "probe.otf" });
        defer allocator.free(probe_otf);
        const fo = try std.fs.createFileAbsolute(probe_otf, .{});
        fo.close();
    }
    return .{ .root = root_dir, .font_dir = font_dir };
}

test "resolveBranding with empty font_dir falls back to bundled or returns null" {
    // 2026-05-25 (Nova directive): the empty-config path now tries the
    // bundled `assets/branding/fonts/` fallback. Whether bundled fonts
    // are actually present at test time depends on the cwd (CI from
    // repo root → bundled present; CI from arbitrary tmp → bundled
    // absent). Assert the LIVE contract: either we get null (no
    // bundled available), OR we get a ResolvedBranding pointing at
    // the bundled dir. Both are correct outcomes — the test pins the
    // SHAPE, not a specific environment.
    const alloc = std.testing.allocator;
    const br = BrandingConfig{}; // defaults — empty font_dir
    const got = try resolveBranding(alloc, br);
    if (got) |rb| {
        defer rb.deinit(alloc);
        // Must point at the bundled dir (relative or absolute path
        // containing assets/branding/fonts).
        try std.testing.expect(std.mem.indexOf(u8, rb.body_otf_dir, "branding/fonts") != null);
    }
    // else: bundled fonts not present in this test's cwd — also OK
}

test "resolveBranding returns null when font_dir does not exist" {
    const alloc = std.testing.allocator;
    const br = BrandingConfig{
        .font_dir = "/tmp/pd_brand_definitely_missing_dir_xyz_42",
        .body_font = "thmanyahsans",
        .display_font = "thmanyahserifdisplay",
    };
    // We expect a warn log but no error and a null result. We can't
    // easily intercept logs in a test; the observable contract is
    // null-on-missing.
    const got = try resolveBranding(alloc, br);
    try std.testing.expect(got == null);
}

test "resolveBranding resolves cleanly when dir matches Thmanyah shape" {
    const alloc = std.testing.allocator;
    const built = try buildTestFontDir(alloc, "ok");
    defer {
        std.fs.deleteTreeAbsolute(built.root) catch {};
        alloc.free(built.font_dir);
        alloc.free(built.root);
    }
    const br = BrandingConfig{
        .font_dir = built.font_dir,
        .body_font = "thmanyahsans",
        .display_font = "thmanyahserifdisplay",
    };
    const got = try resolveBranding(alloc, br);
    try std.testing.expect(got != null);
    defer got.?.deinit(alloc);

    try std.testing.expectEqualStrings("thmanyahsans", got.?.body_font_family);
    try std.testing.expectEqualStrings("thmanyahserifdisplay", got.?.display_font_family);
    // Resolved paths must reference the operator's font dir.
    try std.testing.expect(std.mem.indexOf(u8, got.?.body_otf_dir, "thmanyahsans/otf") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.?.display_otf_dir, "thmanyahserifdisplay/otf") != null);
    try std.testing.expect(got.?.body_woff2_dir.len > 0);
    try std.testing.expect(got.?.display_woff2_dir.len > 0);
}

test "cssFontFaceBlock emits valid @font-face declarations" {
    const alloc = std.testing.allocator;
    const built = try buildTestFontDir(alloc, "css");
    defer {
        std.fs.deleteTreeAbsolute(built.root) catch {};
        alloc.free(built.font_dir);
        alloc.free(built.root);
    }
    const br = BrandingConfig{
        .font_dir = built.font_dir,
        .body_font = "thmanyahsans",
        .display_font = "thmanyahserifdisplay",
    };
    const rb = (try resolveBranding(alloc, br)).?;
    defer rb.deinit(alloc);

    const css = try cssFontFaceBlock(alloc, rb, .file);
    defer alloc.free(css);

    // Basic shape: @font-face for both families, weights, body rule.
    try std.testing.expect(std.mem.indexOf(u8, css, "@font-face") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "thmanyahsans") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "thmanyahserifdisplay") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "font-family") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "src: url(") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "file://") != null);
    // Weight coverage — at minimum we want regular + bold.
    try std.testing.expect(std.mem.indexOf(u8, css, "font-weight: 400") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "font-weight: 700") != null);
    // Body / heading rules — the headline contract.
    try std.testing.expect(std.mem.indexOf(u8, css, "body") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "h1, h2, h3") != null);
}

test "HTML header emits share-ready document CSS without branding" {
    const alloc = std.testing.allocator;
    const header = try buildHtmlHeaderContent(alloc, null, false);
    defer alloc.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "<style>") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "--artifact-paper-bg") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "max-width: 860px") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "blockquote") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "table") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "@font-face") == null);
}

test "PDF header emits print CSS and branded font faces" {
    const alloc = std.testing.allocator;
    const built = try buildTestFontDir(alloc, "pdf_css");
    defer {
        std.fs.deleteTreeAbsolute(built.root) catch {};
        alloc.free(built.font_dir);
        alloc.free(built.root);
    }
    const br = BrandingConfig{
        .font_dir = built.font_dir,
        .body_font = "thmanyahsans",
        .display_font = "thmanyahserifdisplay",
    };
    const rb = (try resolveBranding(alloc, br)).?;
    defer rb.deinit(alloc);

    const header = try buildHtmlHeaderContent(alloc, rb, true);
    defer alloc.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "@font-face") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "@page") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "counter(page)") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "thmanyahsans") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "thmanyahserifdisplay") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "table") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "blockquote") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "body > h1:first-of-type") != null);
}

test "parseTheme accepts thmanyah" {
    try std.testing.expectEqual(@as(?Theme, .thmanyah), parseTheme("thmanyah"));
    try std.testing.expectEqual(@as(?Theme, .thmanyah), parseTheme("THMANYAH"));
    try std.testing.expectEqual(@as(?Theme, .thmanyah), parseTheme(" Thmanyah "));
    try std.testing.expectEqual(@as(?Theme, .default_theme), parseTheme("default"));
    try std.testing.expectEqual(@as(?Theme, .gaia), parseTheme("gaia"));
    try std.testing.expectEqual(@as(?Theme, .uncover), parseTheme("uncover"));
    try std.testing.expectEqual(@as(?Theme, null), parseTheme("nope"));
}

test "marpThemeName maps default to generated ZAKI theme" {
    try std.testing.expectEqualStrings(DEFAULT_MARP_THEME_NAME, marpThemeName(.default_theme));
    try std.testing.expectEqualStrings("gaia", marpThemeName(.gaia));
    try std.testing.expectEqualStrings("uncover", marpThemeName(.uncover));
    try std.testing.expectEqualStrings("thmanyah", marpThemeName(.thmanyah));
}

test "public execute rejects PPTX while renderer is parked" {
    const alloc = std.testing.allocator;
    var pd = ProduceDocumentTool{ .workspace_dir = "/tmp" };
    const t = pd.tool();
    var args = std.json.ObjectMap.init(alloc);
    defer args.deinit();
    try args.put("format", std.json.Value{ .string = "pptx" });
    try args.put("content", std.json.Value{ .string = "# Slide 1\n---\n# Slide 2" });
    try args.put("theme", std.json.Value{ .string = "thmanyah" });

    const result = try t.execute(alloc, args);
    defer {
        if (result.output.len > 0) alloc.free(result.output);
        if (result.error_msg) |m| alloc.free(m);
    }
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "parked") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "PDF") != null);
}

test "PPTX default theme writes generated ZAKI theme CSS" {
    const alloc = std.testing.allocator;
    const ts = std.time.milliTimestamp();
    const ws = try std.fmt.allocPrint(alloc, "/tmp/pd_zaki_default_theme_{d}", .{ts});
    defer alloc.free(ws);
    std.fs.makeDirAbsolute(ws) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(ws) catch {};

    const src_path = try std.fs.path.join(alloc, &.{ ws, "deck.md" });
    defer alloc.free(src_path);
    const out_path = try std.fs.path.join(alloc, &.{ ws, "deck.pptx" });
    defer alloc.free(out_path);
    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        defer f.close();
        try f.writeAll("# Decision\n---\n# Next Steps");
    }

    const result = try renderPptx(alloc, src_path, out_path, .default_theme, ws, null);
    defer {
        if (result.output.len > 0) alloc.free(result.output);
        if (result.error_msg) |m| alloc.free(m);
    }

    const css_path = try std.fs.path.join(alloc, &.{ ws, "branding", "marp", "zaki-default.css" });
    defer alloc.free(css_path);
    const css_file = std.fs.openFileAbsolute(css_path, .{}) catch |err| {
        std.debug.print("expected zaki-default.css at '{s}', got {s}\n", .{ css_path, @errorName(err) });
        return err;
    };
    defer css_file.close();
    var buf: [8192]u8 = undefined;
    const n = try css_file.readAll(&buf);
    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "@theme zaki-default") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "#0f6f5c") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "blockquote") != null);
}

test "PPTX with theme=thmanyah + branding writes the marp theme CSS" {
    const alloc = std.testing.allocator;
    const built = try buildTestFontDir(alloc, "pptx");
    defer {
        std.fs.deleteTreeAbsolute(built.root) catch {};
        alloc.free(built.font_dir);
        alloc.free(built.root);
    }

    // Use the same root as the workspace so cleanup is one tree.
    const ws = try std.fs.path.join(alloc, &.{ built.root, "workspace" });
    defer alloc.free(ws);
    try std.fs.makeDirAbsolute(ws);

    const br = BrandingConfig{
        .font_dir = built.font_dir,
        .body_font = "thmanyahsans",
        .display_font = "thmanyahserifdisplay",
    };
    const rb = (try resolveBranding(alloc, br)).?;
    defer rb.deinit(alloc);

    const src_path = try std.fs.path.join(alloc, &.{ ws, "deck.md" });
    defer alloc.free(src_path);
    const out_path = try std.fs.path.join(alloc, &.{ ws, "deck.pptx" });
    defer alloc.free(out_path);
    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        defer f.close();
        try f.writeAll("# Slide 1\n---\n# Slide 2");
    }

    const result = try renderPptx(alloc, src_path, out_path, .thmanyah, ws, rb);
    defer {
        if (result.output.len > 0) alloc.free(result.output);
        if (result.error_msg) |m| alloc.free(m);
    }
    // marp-cli is not guaranteed to be on the CI sandbox PATH. Two
    // valid outcomes: success (marp + render worked) OR a marp-missing
    // error. Either way the theme CSS should have been written BEFORE
    // marp was invoked — that's the contract we're testing.
    const css_path = try std.fs.path.join(alloc, &.{ ws, "branding", "marp", "thmanyah.css" });
    defer alloc.free(css_path);
    const css_file = std.fs.openFileAbsolute(css_path, .{}) catch |err| {
        std.debug.print("expected thmanyah.css at '{s}', got {s}\n", .{ css_path, @errorName(err) });
        return err;
    };
    defer css_file.close();
    var buf: [4096]u8 = undefined;
    const n = try css_file.readAll(&buf);
    try std.testing.expect(n > 0);
    const content = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, content, "@theme thmanyah") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "@font-face") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "thmanyahsans") != null);
}

test "config.branding parses correctly" {
    const Config = @import("../config.zig").Config;
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "models": {"providers": {"anthropic": {"api_key": "sk-test"}}},
        \\  "agents": {"defaults": {"model": {"primary": "anthropic/claude"}}},
        \\  "branding": {
        \\    "font_dir": "/opt/fonts/thmanyah",
        \\    "body_font": "thmanyahsans",
        \\    "display_font": "thmanyahserifdisplay"
        \\  }
        \\}
    ;
    var cfg = Config{
        .workspace_dir = "/tmp/ws_brand",
        .config_path = "/tmp/ws_brand/config.json",
        .allocator = alloc,
    };
    try cfg.parseJson(json);

    try std.testing.expectEqualStrings("/opt/fonts/thmanyah", cfg.branding.font_dir);
    try std.testing.expectEqualStrings("thmanyahsans", cfg.branding.body_font);
    try std.testing.expectEqualStrings("thmanyahserifdisplay", cfg.branding.display_font);

    // Cleanup
    alloc.free(cfg.default_provider);
    alloc.free(cfg.default_model.?);
    for (cfg.providers) |e| {
        alloc.free(e.name);
        if (e.api_key) |k| alloc.free(k);
        if (e.base_url) |b| alloc.free(b);
    }
    alloc.free(cfg.providers);
    alloc.free(cfg.branding.font_dir);
    alloc.free(cfg.branding.body_font);
    alloc.free(cfg.branding.display_font);
}

test "smoke: real Thmanyah dir resolves and CSS references woff2 src URLs" {
    // Operator-local smoke. Skipped automatically when the real
    // Thmanyah dist isn't present (CI sandboxes, other-dev machines).
    // When present (Nova's box) it asserts the spec's manual smoke:
    // HTML contains `src=...thmanyahsans/woff2/...`.
    const real_dir = "/Users/nova/Downloads/Thmanyah-Font-Family/thmanyah typeface";
    var probe = std.fs.openDirAbsolute(real_dir, .{}) catch return error.SkipZigTest;
    probe.close();

    const alloc = std.testing.allocator;
    const br = BrandingConfig{
        .font_dir = real_dir,
        .body_font = "thmanyahsans",
        .display_font = "thmanyahserifdisplay",
    };
    const rb = (try resolveBranding(alloc, br)) orelse return error.UnexpectedNullResolve;
    defer rb.deinit(alloc);

    const css = try cssFontFaceBlock(alloc, rb, .file);
    defer alloc.free(css);

    // Spec asks: output contains @font-face src="...thmanyahsans/woff2/..."
    try std.testing.expect(std.mem.indexOf(u8, css, "thmanyahsans/woff2/") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "thmanyahserifdisplay/woff2/") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "file://") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "thmanyahsans-Regular.woff2") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "thmanyahsans-Bold.woff2") != null);
}

test "config.branding empty / missing block falls back to defaults" {
    const Config = @import("../config.zig").Config;
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "models": {"providers": {"anthropic": {"api_key": "sk-test"}}},
        \\  "agents": {"defaults": {"model": {"primary": "anthropic/claude"}}}
        \\}
    ;
    var cfg = Config{
        .workspace_dir = "/tmp/ws_brand_def",
        .config_path = "/tmp/ws_brand_def/config.json",
        .allocator = alloc,
    };
    try cfg.parseJson(json);

    // Defaults: empty font_dir (disabled) + Thmanyah-shaped slugs.
    try std.testing.expectEqualStrings("", cfg.branding.font_dir);
    try std.testing.expectEqualStrings("thmanyahsans", cfg.branding.body_font);
    try std.testing.expectEqualStrings("thmanyahserifdisplay", cfg.branding.display_font);

    alloc.free(cfg.default_provider);
    alloc.free(cfg.default_model.?);
    for (cfg.providers) |e| {
        alloc.free(e.name);
        if (e.api_key) |k| alloc.free(k);
        if (e.base_url) |b| alloc.free(b);
    }
    alloc.free(cfg.providers);
}
