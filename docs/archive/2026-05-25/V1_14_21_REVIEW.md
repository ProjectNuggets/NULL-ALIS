---
phase: v1.14.21 commercial-v1 sprint
reviewed: 2026-05-25T00:00:00Z
depth: deep
commit_range: v1.14.20..v1.14.21 (16 in-scope code commits)
findings:
  critical: 4
  high: 8
  medium: 7
  low: 5
  total: 24
status: issues_found
---

# v1.14.21 Code Review

Commit range reviewed: `v1.14.20..v1.14.21`, 16 in-scope code commits
(documentation-only commits like `351a74eb`, `8fdf5673` were skipped).

Scope of deep review:
- `src/extension_ws/{url_sanitize,auth,hub,server}.zig`
- `src/tools/extension_*.zig` (all 10 tools)
- `src/tools/{artifact_share,artifact_revoke_share,artifact_diff,artifact_history,memory_doctor,trace_query}.zig`
- `src/tools/produce_document.zig` (resolveBranding + cssFontFaceBlock path)
- `src/agent/model_capabilities.zig`
- `src/gateway.zig` (TraceShareStore + extension wiring)
- `Dockerfile`
- `src/tools/{root,lint}.zig` (cherry-pick coherence)
- `.spike/nullalis-extension/src/session_state.ts`

## Summary

Sixteen commits shipped a substantial new attack surface (10-tool
extension WS family + 4 artifact share/history/diff/revoke tools +
2 doctor/trace tools) plus a Dockerfile renderer chain, branding
bundling, and a 1M-context routing entry. The CRITICAL #1 §14.5
honesty finding the maintainer pre-flagged is confirmed exactly.

Beyond it I am surfacing **3 additional CRITICAL findings**:
a definitive use-after-free in `hub.sendCommand` timeout-vs-deliver
race, a non-existent renderer toolchain in the Dockerfile (the D63
"close" leaves PDF rendering broken in production), and the bundled
Thmanyah font directory is not COPYied into the runtime image so
the "SaaS deploy ships with branding ENABLED out of the box" claim
in commit 49ad4618 is false.

I am also surfacing **8 HIGH** issues, of which the most material
are: META HIGH #3's `ResultDeliveryOom` is wired in only 1 of 10
extension tools (the cherry-pick from the 9-tools worktree never
re-derived the META HIGH fix); a JSON escape bug shared across all
extension tools that produces invalid JSON for any control char
outside `\n \r \t`; the extension `entries_buf` silently truncates
operators with > 256 tokens; and produce_document's PDF fallback
chain never reaches weasyprint when pandoc-with-no-LaTeX runs (the
exact configuration the Dockerfile installs).

The artifact-tools and extension-tools cherry-picks each landed a
**systematic error-surface inconsistency** (HIGH-severity quality
regression): the success-path uses `output:` but the failure-path
puts the error message into `output:` instead of `error_msg:`. This
will silently confuse every downstream consumer that reads
`error_msg` (the FE error-banner, the trace event sanitizer, the
metrics tagger). Half the same files' own tests read `output` for
errors — the inconsistency is enshrined.

## Critical Issues

### CR-01 (confirmed): 1M-context routing is half-wired

**File:** `src/agent/model_capabilities.zig:58-61, 82` (commit `db5dad47`)
**Issue (confirmed verbatim from maintainer pre-flag):**
The capability table claims `context_window = 1_000_000` for
`claude-{opus,sonnet}-4.6-1m` and `gemini-2.5-pro-1m`, but
`src/providers/anthropic.zig` only emits `anthropic-beta:
oauth-2025-04-20` (lines 408, 679) — never the `context-1m-*` beta
header that Anthropic actually requires to opt into the 1M tier on
their API. The model id is sent through unchanged (line 545, 546,
619, 620), so a request with `model=claude-opus-4-6-1m` is sent to
Anthropic as a model id they don't publish (their 1M path uses the
base `claude-opus-4-...` id + the beta header). Expected outcome:
either a silent 200K response, a 404 on unknown model, or both
depending on Anthropic's release window.

There is no user-FE toggle (`default_model` is operator-owned per
the existing `operator_owned_top_level_config_keys` policy) and no
automatic context-aware routing.

Verification:
```
$ grep -n "anthropic-beta\|context-1m" src/providers/anthropic.zig
408:            headers_buf[hdr_count] = "anthropic-beta: oauth-2025-04-20";
679:            "anthropic-beta: oauth-2025-04-20",
# (no context-1m hit)
```

**Fix:** Either complete the wiring (in `anthropic.zig`, emit the
`anthropic-beta: context-1m-2026-04-15` header whenever
`lookupCapabilities(model_ref).?.context_window >= 1_000_000` AND
the provider is Anthropic; also strip the `-1m` suffix from the
outbound model_id since that suffix is a nullalis-internal routing
key, not an Anthropic SKU; add a user toggle so operators can flip
back to 200K) — OR revert the four `-1m` model_capabilities entries
plus the inferFromPattern `-1m` branch (lines 218-225) until the
provider layer is wired.

### CR-02: hub.sendCommand has a definitive UAF in the timeout-vs-deliver race

**File:** `src/extension_ws/hub.zig:236-260` + `:274-329` (commit `cac40f28`)
**Issue:** When `sendCommand` times out at the same instant
`deliverResult` is mid-flight, both call `self.pending.fetchRemove`
under `pending_mu`. Exactly one wins. If `deliverResult` wins:

```
Thread A (sendCommand):                       Thread B (deliverResult):
ready.timedWait → error.Timeout
                                              acquire pending_mu
                                              fetchRemove(id) → entry
                                              release pending_mu
                                              (NOT yet writing to pending)
acquire pending_mu
fetchRemove(id) → null (B removed it)
release pending_mu
result_allocator.destroy(pending)             pending.result = dup;  ← UAF
                                              pending.ready.set();   ← UAF
```

The window is small (microseconds between line 286's `pending_mu.unlock`
and line 327's `pending.result = dup`) but reachable under load. ASan
or a GPA double-free detector would surface this. The OOM error path
(lines 322-324) has the same shape — sets fields on a pending the
timeout-path may have just freed.

**Fix:** Reference-count `PendingCommand` (same pattern as the
META CRIT #3 conn refcount in the same file). `sendCommand` retains
+ releases; `deliverResult` retains for the duration of its
dupe/write/ready.set sequence. The last release runs `destroy`.
Alternative: in `deliverResult`, hold `pending_mu` across the
`set/.ready.set()` block instead of releasing right after
`fetchRemove`; then `sendCommand`'s timeout path always sees either
"still in map" (no race) or "removed AND complete" (also safe).

### CR-03: Dockerfile renderer chain advertised by D63 is incomplete / broken in practice

**File:** `Dockerfile` (commit `9eaf0d40`)
**Issue:** Three concrete problems make the "produce_document
works for every format" claim false in the shipped image:

1. **No LaTeX engine installed.** Comment on lines 89-90 explicitly
   says "and texlive for pandoc's LaTeX engine" but `texlive` is
   NOT in the `apk add` list (lines 80-113). Pandoc without a LaTeX
   engine cannot render markdown → PDF (it returns "pdflatex: not
   found").
2. **PDF fallback chain bug compounds it.** In `produce_document.zig:947-952`
   the `renderPdf` function returns immediately on
   `ran_but_failed` instead of falling back to weasyprint. The
   docstring at lines 877-879 says "Each fallback is attempted
   only if the binary genuinely could not be invoked (FileNotFound)"
   — but in the Docker image, pandoc IS invocable and IS the first
   tried renderer, so it always reaches `.ran_but_failed` with a
   pdflatex-missing error and the fallback to weasyprint (which
   IS in the image, lines 123-126) is never tried. Net: every
   markdown → PDF call from a Docker tenant fails with a confusing
   "pdflatex not found" stderr, even though weasyprint would
   succeed.
3. **Verification step doesn't actually test the binaries work.**
   Line 131-133 runs `pandoc --version > /dev/null` etc., which
   only checks the binary exists, not that it can produce output.
   The marp dependency on Chromium would also benefit from a
   `chromium-browser --version` probe.

**Fix:** Either add `texlive` (heavy) or `texlive-xetex` (lighter,
needed for branded PDFs anyway per `renderPdf` line 906-908) to the
apk list AND/OR fix `produce_document.zig:947-952` to fall back to
weasyprint on pdflatex-missing stderr. The latter is the smaller
change and aligns with the existing `xelatex-missing → strip branding
+ retry` pattern in the branded path (lines 916-923, 927-932).

### CR-04: Thmanyah fonts are NOT shipped in the runtime image

**File:** `Dockerfile` (49ad4618 / 9a85c60a)
**Issue:** Commit `49ad4618` claims:
> Net behavior: SaaS deploy ships with branding ENABLED out of the
> box — every tenant gets Thmanyah-styled PDFs / DOCX / PPTX /
> HTML / landing pages without any operator config.

This requires `assets/branding/fonts/` to be present in the runtime
image at a location `resolveBundledFontsPath` (produce_document.zig:621-648)
can find. The candidate paths are
`<exe_dir>/assets/branding/fonts`,
`<exe_dir>/../assets/branding/fonts`, etc. The runtime image
COPYs only `/app/zig-out/bin/nullalis → /usr/local/bin/nullalis`
(Dockerfile:115). There is **no `COPY assets/ → /usr/local/bin/assets/`
or any other variant** in the Dockerfile. The fonts ship in the
repo but are never bundled into the runtime image.

Result: in production, `resolveBundledFontsPath` walks all 4
candidates, none exist, returns null, and `resolveBranding` returns
null. Every tenant renders with system fonts (ttf-dejavu is the
only TTF in the image; it'll fall back to that). The "branding
ENABLED out of the box" promise is false.

**Fix:** Add `COPY --from=builder /app/assets /usr/local/bin/assets`
(or COPY directly from the build context: `COPY assets
/usr/local/bin/assets`) to Dockerfile's release-base stage,
positioned alongside the binary copy at line 115. Verify
post-build:
`docker run --rm <image> ls /usr/local/bin/assets/branding/fonts`.

## High Issues

### HI-01: 9 of 10 extension_* tools missing ResultDeliveryOom error mapping

**Files:** `src/tools/extension_{click,type,fill_form,screenshot,get_text,get_dom,wait_for,scroll,list_tabs}.zig` (commit `9307f60e`)
**Issue:** Commit `cac40f28` (META HIGH #3) introduced the
distinct `error.ResultDeliveryOom` so operators see "gateway OOM"
instead of "extension died." It was added to `extension_navigate.zig`
(line 142-144). The 9-tools follow-up cherry-pick in `9307f60e`
copy-pasted the `error.Timeout` / `error.ConnectionClosed` /
`error.NoExtensionConnected` switch arms but **NOT the
`error.ResultDeliveryOom` arm**. Confirmed:

```
$ grep -L "ResultDeliveryOom" src/tools/extension_*.zig
src/tools/extension_get_text.zig
src/tools/extension_click.zig
src/tools/extension_fill_form.zig
src/tools/extension_get_dom.zig
src/tools/extension_scroll.zig
src/tools/extension_list_tabs.zig
src/tools/extension_screenshot.zig
src/tools/extension_wait_for.zig
src/tools/extension_type.zig
```

On any of these 9 tools, an OOM in `deliverResult` falls into the
generic `else => |e|` arm and prints "extension_click dispatch
failed: ResultDeliveryOom" — non-actionable garbage instead of the
operator-friendly "gateway ran out of memory delivering the
extension result..." that `extension_navigate` produces.

**Fix:** Add the same `error.ResultDeliveryOom` arm to every
extension_*.zig file. This is a 9-line patch (one switch arm per
file).

### HI-02: Systematic error-surface inconsistency in 6 new follow-up tools

**Files:** `src/tools/{artifact_share,artifact_revoke_share,artifact_diff,artifact_history,memory_doctor,trace_query}.zig` (commit `bf45a471`)
**Issue:** All 6 new tools mix two conventions for surfacing error
messages on `success=false`:

- `ToolResult.fail("...")` (sets `error_msg`, leaves `output` empty)
  — used for arg-validation paths (line 82, 83, 84 etc.)
- Manually-constructed `ToolResult{ .success = false, .output = msg }`
  — used for state/runtime/persistence failure paths (e.g.
  `artifact_share.zig:104-107, 110-113, 120, 124-126, 137, 143`).

The tests reflect the inconsistency: e.g. `artifact_share.zig:176`
reads `result.error_msg.?` for one error, line 198 reads
`result.output` for another. Half the tool's own tests are wrong
about which field the failure path uses.

This will confuse every downstream consumer:
- FE error-banner renderer reads `error_msg` (per the existing
  ToolResult convention) → sees nothing → renders an empty banner.
- Trace-event sanitizer reads `error_msg` for redaction → sees
  nothing → the failure context leaks unsanitized into
  `output`.
- Metrics tagger reads `error_msg` for the error-code dimension →
  every failure gets tagged as "unknown" instead of the specific
  reason.

**Fix:** Use `ToolResult.fail(...)` OR
`ToolResult{ .success = false, .error_msg = msg, .output = "" }`
throughout. Pick one convention and apply across all 6 files
consistently. The same fix should sweep tests so they all read
`error_msg.?`.

### HI-03: Extension entries_buf silently truncates operators with > 256 tokens

**File:** `src/gateway.zig:19671-19680` (commit `cac40f28`)
**Issue:** The auth-validator entries are copied into a 256-entry
stack array:
```zig
var entries_buf: [256]extension_ws_auth.TokenEntry = undefined;
const ent_count = @min(state.extension_tokens.len, entries_buf.len);
for (state.extension_tokens[0..ent_count], 0..) |e, i| {
    entries_buf[i] = .{ .token = e.token, .user_id = e.user_id };
}
```
If the operator configures > 256 (token, user_id) entries, the
excess is silently dropped. The 257th-and-onward users find their
tokens don't authenticate, and there's nothing in the log to
indicate why. SaaS deploys with > 256 active users will hit this.

**Fix:** Either heap-allocate the buffer to fit
`state.extension_tokens.len`, or log a warn at the truncation site
(and at boot if `cfg.gateway.extension_tokens.len > 256`).

### HI-04: PDF fallback chain returns on first ran_but_failed instead of trying weasyprint

**File:** `src/tools/produce_document.zig:946-981`
**Issue:** Already detailed in CR-03 but logging separately because
this is the code-level bug independent of the Dockerfile. The chain
`pandoc → wkhtmltopdf → weasyprint` only falls through on
`.binary_missing`, never on `.ran_but_failed`. In any environment
where pandoc is installed but its underlying engine (pdflatex /
xelatex) isn't, the chain stops at the pandoc-ran-and-errored
step and never reaches weasyprint.

The docstring at lines 877-879 acknowledges this as the design
intent — but the design is wrong for the deployment shape D63
created (pandoc present, no LaTeX, weasyprint present). The
documented design loses the documented v1 promise.

**Fix:** When `pandoc` returns `.ran_but_failed` AND its stderr
indicates a missing latex engine (similar string-match logic to
the existing `xelatex_missing` detection at lines 920-923), fall
through to weasyprint instead of returning the pandoc error.

### HI-05: Extension tools' writeJsonString does NOT escape control chars below 0x20

**Files:** `src/tools/extension_{click,type,fill_form,navigate,screenshot,get_text,get_dom,wait_for,scroll,list_tabs}.zig`
**Issue:** Every extension tool ships a private
`writeJsonString` that escapes only `"`, `\`, `\n`, `\r`, `\t`:
```zig
fn writeJsonString(allocator, buf, s) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"'  => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        else => try buf.append(allocator, c),  ← UNSAFE
    };
    try buf.append(allocator, '"');
}
```
JSON RFC 8259 §7 mandates every U+0000–U+001F be escaped. A
user-controlled `selector` or `text` containing `\b` (0x08),
`\f` (0x0C), `\x01`-`\x07`, `\x0B`, `\x0E`-`\x1F`, or NUL produces
invalid JSON. The extension's `JSON.parse` rejects it → the agent
sees "extension returned malformed CommandResult JSON" → wasted
turn budget on a self-inflicted parse failure.

The OTHER 6 tools (`artifact_share` etc.) ship a `jsonEscapeInto`
that DOES escape `c < 0x20` via `\\u{x:0>4}`. The extension tools'
escaper was copy-pasted from `extension_navigate.zig` (line 211-224)
and that one is similarly broken. The maintainer's "minimal JSON
escaper" comment at line 207-210 explicitly defers control-char
escaping with "the URL has already been validated to start with
http:// or https://, which rules out the control chars JSON cares
about" — true for `extension_navigate` (the URL was sanitized) but
WRONG for `extension_click.selector`, `extension_type.text`,
`extension_fill_form.fields[].text`, etc. None of these are
control-char-validated.

**Fix:** Replace each tool's private `writeJsonString` with a
shared escaper that handles `c < 0x20` via `\u{x:0>4}` like
`artifact_diff.zig:142-159`. Or — better — extract that into a
helper module both call paths share.

### HI-06: Hub deinit leaks pending command keys via `keys.append catch {}`

**File:** `src/extension_ws/hub.zig:120-141`
**Issue:** In `ExtensionWsConn.deinit`, the pending-map drain
enumerates keys into an arraylist with `keys.append(self.allocator, k.*) catch {};`.
On OOM during enumeration, the catch swallows the error. The
comment claims "by-design: shutdown path; failing to enumerate a
key just leaks the entry." But if any one `append` fails, the
loop continues and may succeed on subsequent iterations — leading
to a partial drain. Any keys that WERE collected are then removed
from the map and freed (line 137-138); but the keys that AREN'T
in `keys.items` remain in the map AND are leaked AND their
PendingCommand structs are orphaned (because their `ready.set`
fired but no one will free them — `sendCommand` waiters are gone
since the hub is shutting down). This is fine for process exit but
unsafe if the hub is reinitialized in-process.

**Fix:** Either propagate the OOM out of `deinit` (signature
change but cleanest), or pre-allocate `keys` to the known map size
(`keys.ensureTotalCapacity(self.allocator, self.pending.count())`)
before the loop so subsequent appends can't OOM.

### HI-07: extension_screenshot description claims 5 MB cap, frame parser rejects > 4 MB

**File:** `src/tools/extension_screenshot.zig:35, 47-50`
**Issue:** Description string and `tool_description` both say
"Returns up to ~5 MB base64-encoded PNG" and "cap ~5 MB". The hub
imposes `MAX_FRAME_PAYLOAD: u64 = 4 * 1024 * 1024` (`extension_ws/server.zig:241`).
A screenshot whose CommandResult JSON exceeds 4 MB returns
`error.FrameTooLarge` — and that error is not in the explicit
`switch (err)` arms at line 82-89, so it falls into the generic
`else => |e|` and the user sees a confusing "extension_screenshot
dispatch failed: FrameTooLarge".

§14.5 honesty: the tool description LIES about its cap. A
full-page 4K screenshot will trip this.

**Fix:** Either lift `MAX_FRAME_PAYLOAD` to match the documented
5 MB (and audit DoS risk), or correct the description string to
"up to ~3 MB base64-encoded PNG" (giving JSON overhead headroom
under the 4 MB frame cap). Add an explicit `error.FrameTooLarge`
arm with a clear "tab screenshot exceeded 4 MB transport cap;
crop or split the request" message.

### HI-08: SSRF defense bypasses don't cover IPv4 in IPv6 scope-id or zone-id forms

**File:** `src/extension_ws/url_sanitize.zig:430-436` (commit `cac40f28`)
**Issue:** `parseIPv6` defers to `std.net.Ip6Address.parse` which
accepts the canonical forms. But it does NOT canonicalize forms
with scope-id (e.g. `fe80::1%eth0`) — Zig's parser returns an
error on `%`, so `parseIPv6` returns the malformed-literal
rejection at line 209. Good. But forms with `0x` prefix per-group
(e.g. `[0x100::]` is invalid IPv6) — also rejected. So this is
mostly fine.

What's NOT covered: **operator allowlist entries with IPv6
brackets**. The allowlist comparison at line 172-178 strips a
trailing dot but does NOT strip brackets. An operator who writes
`extension_browser_allowlist: ["[::1]"]` won't allowlist `[::1]`
because the bracketed form is normalized away (`bare_host = "::1"`).
The comparison compares `"::1"` against `"[::1]"` → no match. This
breaks an obvious operator-write pattern. There's no test for
"allowlist permits IPv6 literal" so this didn't surface.

**Fix:** Pre-trim operator allowlist entries of brackets in the
comparison loop (mirror the `trimTrailingDot` pattern). Add a
test "allowlist: operator-bracketed IPv6 literal works."

## Medium Issues

### ME-01: trace_query docstring claims "runs are global" — misleading

**File:** `src/tools/trace_query.zig:10-13` (commit `bf45a471`)
**Issue:** Docstring says "runs are global; user scoping happens
at the HTTP layer via auth — at the tool layer the agent is
already running as the user, so the in-process store IS the
agent's view." This is false: the trace store IS per-tenant
(`runtime.trace_store`, gateway.zig:1579). The docstring suggests
multi-tenant cross-pollution which would be a security finding;
the code actually scopes correctly. Just bad documentation.

**Fix:** Rewrite the docstring to say "the trace store is bound
per-tenant via `runtime.trace_store`; calls only see the current
agent's runs."

### ME-02: Auth validator's constant-time loop still has a length-based timing leak

**File:** `src/extension_ws/auth.zig:121-145`
**Issue:** The comment claims "Don't break — keep iterating so an
attacker can't time-attack which slot did I hit." But
`constantTimeEql` early-exits on length mismatch (line 158). So
the per-entry compare time IS proportional to `min(token_len,
inbound_len)` for length-match entries and ~O(1) for
length-mismatch entries. An attacker can guess the operator-chosen
token length by measuring total validate time. The doc-comment
acknowledges this as v1-accepted (MEDIUM #6) — accepted, but the
"defeats time attack" claim in the loop comment is overstated.

**Fix:** Either soften the comment ("provides constant-time within
each length class") or implement true constant-time by padding all
compares to MAX_TOKEN_LEN. Lower priority — the v2 JWT path is
where this matters.

### ME-03: image_info / image_generate alphabetical ordering broken in lint registry

**File:** `src/tools/lint.zig:59-60`
**Issue:** Entries:
```
"image_info",
"image_generate",
```
`image_generate` is lexicographically before `image_info`, so the
list is out-of-order. Confirmed with `sort | diff`:
```
$ diff <raw> <sorted>
41d40
< image_info
42a42
> image_info
```
The lint module documents itself as alphabetical at line 18-19.

**Fix:** Swap the two entries.

### ME-04: lint.zig "Registry of 63 production tools" comment is stale

**File:** `src/tools/lint.zig:16`
**Issue:** Comment says "Registry of 63 production tools" but the
list has 74 entries. Each cherry-pick (artifact_*, extension_*,
trace_query, memory_doctor, etc.) bumped the count but the comment
was never updated. §14.5-borderline (low-impact) but it's a
documentation lie in a file specifically about lint correctness.

**Fix:** Update to "Registry of 74 production tools" or make it
derive at comptime: `// Registry of {N} production tools (count at end of file)`.

### ME-05: Hub success-path may double-account when extension delivers AFTER timeout in race window

**File:** `src/extension_ws/hub.zig:236-260`
**Issue:** Distinct from the UAF in CR-02, there's also a
correctness issue. If sendCommand times out and frees `pending`,
and deliverResult later successfully removes a different entry
(no-op — the entry was gone), the agent sees `error.Timeout` AND
the operator may see "dropping result for unknown command_id" in
the log. Coupled with CR-02 the audit log misrepresents what
actually happened.

**Fix:** Solved by CR-02's refcount fix.

### ME-06: cssFontFaceBlock emits `file://<relative-path>` when bundled fonts resolve via cwd

**File:** `src/tools/produce_document.zig:742-744, 766, 772`
**Issue:** When the bundled fonts resolve via the cwd-relative
candidate D (`"assets/branding/fonts"`, line 644), the path stays
relative. Then `cssFontFaceBlock` emits
`url('file://assets/branding/fonts/...-Regular.woff2')` which is
not a valid file:// URL (those require absolute paths). HTML
renderers will silently 404 the fonts and fall back to system
sans/serif.

This only triggers in dev-from-repo runs (candidates A, B, C
return absolute paths from `selfExeDirPathAlloc`). But once the
Dockerfile is fixed per CR-04, this could resurface depending on
the exact COPY location.

**Fix:** In `resolveBundledFontsPath`, canonicalize candidate D
via `std.fs.realpathAlloc` (which returns absolute) before
returning. Or reject candidate D and require an absolute exe-dir.

### ME-07: Auth boot warning text refers to nonexistent "extension never connects" path

**File:** `src/gateway.zig:20427-20431`
**Issue:** Warning message says "Configure at least one (token,
user_id) entry to admit users." Fine. But there's no symmetric
warn when `extension_browser_allowlist` is empty AND
`extension_ws_enabled=true` — this is the secure default but it
means operators of LAN-only kiosks who forgot the allowlist will
get every navigation rejected with `private_ip_blocked` and have
no breadcrumb at boot.

**Fix:** Add a single-line `info` (not warn) at boot:
`"extension_ws: extension_browser_allowlist is empty — SSRF defense will block all RFC1918/loopback navigation targets. Add entries here for trusted LAN/internal hosts."`

## Low Issues

### LO-01: Dead `_ = &existing_opt` in artifact tools

**Files:** `src/tools/artifact_share.zig:130`, `artifact_history.zig:116`, `artifact_diff.zig:108, 122`
**Issue:** After `var existing = existing_opt.?; existing.deinit(allocator);`
the line `_ = &existing_opt;` does nothing. Looks like a leftover
from an earlier draft that captured the value with a reference.

**Fix:** Remove the dead lines.

### LO-02: artifact_share share_url is a relative path, not a public URL

**File:** `src/tools/artifact_share.zig:146-150`
**Issue:** The tool returns `"share_url":"/api/v1/share/artifact/{share_code}"`
— a relative path. The `tool_description` at line 60 promises "a
URL the user can send to anyone." A user copying the relative path
into Slack will not get a clickable link. The HTTP handler does
the same — but the HTTP handler also lives behind a base URL the
client already knows. The agent has no such context.

**Fix:** Either resolve to an absolute URL using the gateway's
configured public base URL (would need wiring), or document that
the share_url is path-only and the agent must prepend the gateway
base.

### LO-03: trace_query test reads `result.output` for error path despite ToolResult convention

**File:** `src/tools/trace_query.zig:290`
**Issue:** `try std.testing.expect(std.mem.indexOf(u8, result.output, "trace store not configured") != null);`
But the canonical ToolResult convention puts error text in
`error_msg`. This is the same HI-02 issue but reflected in
test asserts — meaning the test will start failing the day someone
correctly fixes the production code. Tests should drive the
correct contract.

**Fix:** Sweep tests in all 6 follow-up tools to read `error_msg`
once HI-02 is applied.

### LO-04: extension_navigate.execute treats non-string `new_tab` silently

**File:** `src/tools/extension_navigate.zig:125-127`
**Issue:** `root.getBool(args, "new_tab")` returns null when the
arg is present but not a boolean (e.g. agent passes `"true"` as a
string). Silently fallthrough to no-`new_tab`. Not a security
issue but a §14.5 quietness — the agent thinks it asked for a new
tab and the user sees the navigation replace the current one.

**Fix:** When `args.get("new_tab")` exists but is not a bool,
return a clean error rather than silently treating as default.

### LO-05: Many extension tools omit `screenshot` from `do_not_use_for` cross-refs

**Files:** `src/tools/extension_screenshot.zig:33`, etc.
**Issue:** The `screenshot` tool (terminal capture, line 78 of lint.zig)
is correctly cross-ref'd from `extension_screenshot.do_not_use_for`
("for capturing the operator's local terminal"). But the reverse
isn't enforced — terminal `screenshot.zig` (if it has a
`do_not_use_for`) likely doesn't mention extension_screenshot. Low
impact; consistency-only.

**Fix:** A linter sweep when ALL_TOOLS is fixed (ME-03).

---

## Cherry-pick artifact summary

The META subagent, 9-tools subagent, and 6-tools subagent each
worked in isolation per AGENTS.md §14.12 (worktree isolation).
Cherry-picking onto main surfaced these consistency gaps:

1. **HI-01** — META HIGH #3 was applied to `extension_navigate.zig`
   in the META worktree, but the 9-tools subagent forked off a
   pre-META baseline and copy-pasted the older 3-arm switch into
   all 9 new tools.
2. **ME-03** — `image_info` ordering precedes the alphabetical
   sweep that should have placed `image_generate` first; suggests
   the ALL_TOOLS edit was done by-hand rather than via a sort.
3. **ME-04** — "63 production tools" comment was the 6-tools
   subagent's intent. The 9-tools commit landed after and didn't
   re-do the comment.
4. **HI-02** — `output` vs `error_msg` divergence is identical
   across all 6 new follow-up tools, suggesting the 6-tools
   subagent's first file set the wrong pattern and the others
   copy-pasted from it. Same shape repeated 6 times = workshop
   error not project drift.

---

_Reviewed: 2026-05-25_
_Reviewer: Claude (gsd-code-reviewer, deep mode)_
_Commit range: v1.14.20..v1.14.21 (16 in-scope commits)_
