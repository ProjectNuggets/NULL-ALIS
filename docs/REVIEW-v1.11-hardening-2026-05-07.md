---
review: V1.11 hardening session (8 commits)
date: 2026-05-07
reviewer: gsd-code-reviewer (Claude Opus 4.7, 1M context)
scope_commits:
  - 5947d11 feat(modes): K2.6 full switch
  - a7cc866 feat(audio): audio_reply SSE event
  - 5df1840 feat(audio): native STT in /chat/stream
  - 8e442f0 feat(providers): streaming usage + overload classify
  - 3725a88 feat(pricing): Together-hosted prices
  - 223dfc1 fix(gateway): jsonSafeFloat importance/score
  - b42f4c3 fix(high+med): HI-01..04 + ME-01/02/05
  - c44dfd4 fix(critical): CR-01..03
files_reviewed:
  - src/agent/commands.zig
  - src/agent/root.zig
  - src/agent/model_capabilities.zig
  - src/config_types.zig
  - src/gateway.zig
  - src/providers/compatible.zig
  - src/providers/error_classify.zig
  - src/providers/helpers.zig
  - src/providers/pricing.zig
  - src/providers/reliable.zig
  - src/providers/sse.zig
  - src/subagent.zig
  - src/user_settings.zig
  - src/voice.zig
  - src/voice_mode.zig
  - src/zaki_state.zig
findings:
  critical: 0
  high: 4
  medium: 7
  low: 8
  nit: 4
  total: 23
verdict: conditional_ship
---

# V1.11 Hardening Code Review — 2026-05-07

## Executive Summary

The V1.11 hardening session lands eight commits covering three categories: (a) **bug fixes** (CR-01/02/03, HI/ME-batch) for demo-blocking UAFs and JSON-corruption paths — these are tight, correct, and well-commented; (b) **provider hardening** (streaming usage, overload classify, pricing table) — mostly correct with one substring-collision class-bug and one false-positive risk in the overload pattern matcher; (c) **multimodal audio** (STT input + audio_reply SSE event + K2.6 full switch) — the wiring is honest and graceful-degradation-shaped, but four issues need attention before booth: a residual pending-state leak path in CR-01, a pricing-table substring collision (`glm-5.1` shadows `glm-5.1-air`; `deepseek-v3` shadows `deepseek-v3.2`), an overload classifier that false-positives on `"model unavailable"` (entitlement errors retried as if transient), and a possibly-incorrect "balanced↔deep cache stays warm" claim for the K2.6 mode swap (reasoning_effort + temperature both differ across modes, so the request body bytes differ — Together's prefix cache will not hit unless it's content-key scoped to messages-only).

**Top 3 risks for booth:**

1. **HI-01 — pricing collision** (`glm-5.1` shadows `glm-5.1-air`, `deepseek-v3` shadows `deepseek-v3.2`). Booth doesn't run on these models, but cost-attribution and the entitlement quota system will silently mis-bill any tenant who switches.
2. **HI-02 — overload classifier false-positive** on `"model unavailable"`. An Anthropic 403 for "model unavailable in your tier" gets retried with backoff as if transient. Worst case: latency spike + eventual `error.ProviderOverloaded` instead of clear `error.PermissionDenied`.
3. **HI-03 — CR-01 residual leak.** If `std.fmt.allocPrint` for the synthetic continuation message OOMs (low probability), `pending_tool_approval` is never cleared. Next /approve call would re-execute the stale tool. The committed fix moved the clear AFTER allocPrint specifically to avoid the original UAF; the cleaner pattern is `clone tool_name → clearPendingToolApproval → allocPrint`.

Subject to these three being addressed (or accepted as known-risk), V1.11 hardening is **green to ship for booth**. The audio path is solid, the SSE usage parser is correct, the CR-02/CR-03 fixes are textbook, and the K2.6 switch is mechanically clean (model_capabilities.zig + pricing.zig + helpers.zig all aligned).

---

## HIGH

### HI-01 — Pricing-table substring collision shadows specific model rows

**File:** `src/providers/pricing.zig:99-100, 73, 105`
**Severity:** HIGH (cost-attribution + quota enforcement)

The matcher in `lookup()` walks `TABLE` top-to-bottom and returns the FIRST row whose `match` is a case-insensitive substring of the model id. The header comment on line 31-34 explicitly says "more specific names must come before more generic ones" — that contract is now violated:

- `glm-5.1` (row 99) is a substring of `glm-5.1-air`. Looking up the model `"glm-5.1-air"` returns the `glm-5.1` price ($0.60/$2.20) — three to four times the real `air` price ($0.20/$1.10).
- `deepseek-v3` (row 73) is a substring of `deepseek-v3.2`. Real model id `deepseek-v3.2` exists at `src/providers/compatible.zig:135` and `src/onboard.zig:255`. (Mitigated for the chat path because `compatible.zig:970` normalizes `deepseek-v3.2` → `deepseek-chat` before lookup; but any caller that passes the raw name lands on the wrong row.)
- `kimi-k2.5` (row 82) would shadow any future `kimi-k2.5-mini`, `kimi-k2.5-thinking` etc. Pre-emptive risk.

**What to do:** swap the `glm-5.1`/`glm-5.1-air` rows so `air` (more specific) is matched first. Same for any v3.2 / k2.5-variant additions. Better long-term: add a regression test that asserts each declared model id resolves to its *intended* row (an explicit fixture mapping `model_id → expected.price`).

**How to verify:** `zig test src/providers/pricing.zig` after adding:
```zig
test "glm-5.1-air does not shadow to glm-5.1 base price" {
    const air = lookup("together", "glm-5.1-air").?;
    try std.testing.expectEqual(@as(f64, 0.20), air.input_per_million);
}
```

---

### HI-02 — Overload classifier false-positive on `"model unavailable"`

**File:** `src/providers/error_classify.zig:39, src/providers/reliable.zig:88-127`
**Severity:** HIGH (correctness — wrong retry behavior on permission errors)

`isOverloadedText` matches `"model unavailable"` and `"model is loading"` as transient overload. Anthropic and OpenAI both return error messages of the shape `"The model claude-opus-4 is unavailable for your account tier"` for entitlement / permission denials — those should NOT be retried as transient. They will now classify as `.transient_overload`, get retried with backoff, and ultimately surface as `error.ProviderOverloaded` instead of the more-actionable `error.PermissionDenied`.

The `reliable.zig` mirror also has the looser `503` + `"service"` heuristic — a generic 503 that mentions the word "service" anywhere (`"X-Service-Mesh: …"`) would trip overload. Lower probability.

**What to do:** tighten the patterns:
- Drop `"model unavailable"` (too broad). Keep `"upstream model unavailable"` (more specific) and `"model is currently loading"` (Together-specific).
- Anchor the 503-pair check to actual response shapes (HTTP status line vs. random body content).
- Add a non-false-positive test: `try std.testing.expect(!isOverloadedText("model unavailable in your tier"));`

**How to verify:** the existing 11-case test in `reliable.zig:768-787` passes; add 3-5 entitlement / permission-error fixtures that should NOT classify as overload.

---

### HI-03 — CR-01 residual: pending_tool_approval leaks if synthetic-message allocPrint fails

**File:** `src/agent/commands.zig:2608-2620`
**Severity:** HIGH (leftover stale state, demo-relevant)

CR-01 moved the `clearPendingToolApproval` call from `executeApprovedPendingTool` (the freer) to `handleGenericToolApprove` (the slice-reader). The fix is correct for the original UAF, but it left one window open:

```zig
const synthetic = try std.fmt.allocPrint(...);  // ← reads pending.tool_name
defer self.allocator.free(synthetic);
self.clearPendingToolApproval();                 // ← only fires on success
```

If `allocPrint` returns `error.OutOfMemory`, the `try` propagates and `clearPendingToolApproval` is never called. The next `/approve` will see `pending` still set and re-execute the prior pending tool — defeating the very re-entrancy guard the commit message promised.

The error-branch at line 2548-2555 and the `!continues_turn` branch at line 2585-2594 both clear pending correctly. The default-path is the one that misses.

**What to do:** clone the slices first, then clear, then format:
```zig
const tool_name_owned = try self.allocator.dupe(u8, pending.tool_name);
defer self.allocator.free(tool_name_owned);
self.clearPendingToolApproval();           // safe: pending no longer needed
const synthetic = try std.fmt.allocPrint(  // uses owned copy
    self.allocator,
    "...{s}...",
    .{ id_snapshot, tool_name_owned, success_word, ... },
);
```
Alternative: wrap the `allocPrint` in `errdefer self.clearPendingToolApproval();` before the call.

**How to verify:** unit-test that simulates `allocPrint` OOM (FailingAllocator at the right call count) and asserts `agent.pending_tool_approval == null` after the call returns the error.

---

### HI-04 — K2.6 "cache stays warm across modes" claim is likely false

**File:** `src/config_types.zig:230-247, 275-286, 313-322`
**Severity:** HIGH (cost / latency claim — verify before booth talking-points)

The K2.6 commit (5947d11) repeatedly claims that because all three modes use `Kimi-K2.6`, the prompt cache shares freely (`balanced↔deep cache stays warm`). That assertion only holds if Together's prefix cache keys on the messages content, NOT on the full request body bytes. But:

- `default_temperature` differs per mode: 0.5 / 0.7 / 0.8 (`config_types.zig:213,271,306`).
- `reasoning_effort` differs per mode: `"low"` / `"medium"` / `"high"` — emitted into the JSON body via `helpers.zig:237-239`.

If Together's prefix cache hashes the full body (or hashes the body *up to and including* `reasoning_effort`), every mode switch invalidates. The byte-stable-prefix invariant tracked elsewhere in the codebase (memory `[[project_byte_stability_confirmed_2026_04_20]]`) was confirmed for *the same mode across turns*, not for *cross-mode hops*.

**What to do:** before booth, run the same byte-stability harness from 04-20 with a balanced→deep flip mid-session. If the prefix hash changes (it will, since temperature alone changes), update the commit comment to: *"K2.6 across modes preserves model identity (no warm-load between providers); prefix cache shares only when the user stays in one mode."* That is still a real win over the V4-Pro+K2.5 split, but a smaller one than the comment claims.

**How to verify:** capture the streaming request body at the wire for one balanced and one deep request with identical messages; diff. Bytes will differ. Then confirm with Together support docs whether their cache is content-keyed or body-hashed.

---

## MEDIUM

### ME-01 — Audio temp file leaks if `toSentinelPath` fails on agent-emitted path

**File:** `src/gateway.zig:9733-9755`
**Severity:** MEDIUM (defense-in-depth; low probability)

In the audio_reply extraction:
```zig
var path_z_buf: [512]u8 = undefined;
const path_z = toSentinelPath(&path_z_buf, marker.audio_path);
if (path_z) |p| {
    if (std.fs.openFileAbsolute(p, .{})) |file| { ... }
    std.fs.deleteFileAbsolute(p) catch {};
}
```

The `deleteFileAbsolute` only fires when `toSentinelPath` succeeds (path ≤ 511 chars). If the agent ever emitted a longer path (defensive: it doesn't today; tts_synthesize_fn writes to `/tmp/nullalis_tts_<n>.<ext>` which is ~30 chars), the temp file would be orphaned. Same applies if `openFileAbsolute` fails — the file isn't deleted. Wait, actually it IS deleted because the delete is outside the `openFileAbsolute` block. ✓ Re-verifying: only the `toSentinelPath = null` branch leaks.

**What to do:** lift the `deleteFileAbsolute` to fire even on `path_z == null` by doing `defer std.fs.deleteFileAbsolute(marker.audio_path) catch {};` at the top of the extraction block. (Note: `deleteFileAbsolute` accepts `[]const u8` not sentinel — verify in the local Zig version.)

**How to verify:** test with a contrived 600-char path emitted by a stub agent.

---

### ME-02 — STT path: silent ignore if both `audio` and `message` are present

**File:** `src/gateway.zig:9404-9498`
**Severity:** MEDIUM (API contract clarity)

The blk: walks fields in order `message → text → audio`. If a client sends both `{message: "...", audio: "..."}`, the audio is silently ignored — there's no warning and the FE has no signal that its audio was discarded. Forward-compat: if the FE later starts sending both as a "voice + text annotation" feature, the audio will silently disappear.

**What to do:** either (a) reject with 400 `mutually_exclusive_inputs` when both are non-empty, or (b) document that `message` wins and add a structured log when audio is present alongside message.

**How to verify:** smoke test `curl -d '{"message":"hi","audio":"YQ=="}'` — confirm the chosen behavior.

---

### ME-03 — Audio format string lifted from path extension is unsanitized

**File:** `src/gateway.zig:9728-9732`
**Severity:** MEDIUM (low-impact JSON noise; not a security issue)

```zig
if (std.mem.lastIndexOfScalar(u8, marker.audio_path, '.')) |dot_idx| {
    const ext = marker.audio_path[dot_idx + 1 ..];
    if (ext.len > 0 and ext.len <= 8) audio_emit.format = ext;
}
```

`ext` is sliced from the agent-emitted path with no character-class check. `extractAudioReplyMarker` already rejects `\n`/`\r`/`\0`, so the worst-case content of `ext` is something like `"hack` (with quotes) or `m p3` (with space). The downstream `jsonEscapeInto` in `sseAudioReplyFrame` does properly escape these, so JSON validity is preserved — but the FE's `format` field would be junk, and a future code path might trust it without escaping (mp3-vs-webm dispatch).

**What to do:** restrict ext to `[A-Za-z0-9]` (3-8 chars) before accepting it.

**How to verify:** add a unit test feeding `extractAudioReplyMarker("[AUDIO:/tmp/x.\"hack]\nbody")` — currently it's rejected by the bracket-close check (the `]` is inside the quote). Test more: `[AUDIO:/tmp/x.m p3]\nbody` — passes the marker check but ext = `"m p3"`.

---

### ME-04 — Holding registry mutex across enqueue serializes all SSE publishes

**File:** `src/gateway.zig:750-767`
**Severity:** MEDIUM (perf, not correctness — accepted trade for booth)

CR-02's fix holds `AppEventSubscriberRegistry.mutex` across the call to `subscriber.enqueue(...)` — which itself acquires `subscriber.mutex` and does an allocator append + cond signal. Concurrent publishes to *different* subscribers now serialize on the registry mutex. At booth scale (single user, small fanout) this is fine. Under fanout (10+ concurrent SSE streams), the serialization is observable.

**What to do:** post-booth, refactor to take a `subscriber.refcount.acquire()` while still under registry.mutex (atomic increment), then release registry.mutex, then enqueue, then `subscriber.refcount.release()`. Keeps the UAF guarantee without serializing across subscribers. Out of scope for V1.11.

**How to verify:** N/A for booth. Post-booth: load test with 20 concurrent /chat/events streams + bursts of publishes; measure p99 publish latency.

---

### ME-05 — `transcribed_message` defer-free fires even on early-return paths *before* `wrapped` is assigned

**File:** `src/gateway.zig:9402-9498`
**Severity:** MEDIUM (correctness; reads a null pointer is fine, but the lifecycle is confusing)

The structure:
```zig
var transcribed_message: ?[]u8 = null;
defer if (transcribed_message) |t| req_allocator.free(t);
const message: []const u8 = blk: {
    ...
    transcribed_message = wrapped;
    break :blk wrapped;
};
```

Functionally correct — `transcribed_message` stays null until `wrapped` is allocated, so the defer no-ops on every early-return path. But the pattern is brittle: any future refactor that moves the `transcribed_message = wrapped` assignment *after* a fallible call would risk a double-free. The reviewer (me) had to trace every error path to convince myself.

**What to do:** either (a) document the contract in a comment ("transcribed_message is the single owned escape hatch out of the blk:"), or (b) restructure as `defer if (...) ...` placed immediately after assignment, in a do-block.

**How to verify:** N/A — code is correct as-is. This is maintainability.

---

### ME-06 — `audio_format` from request body fed directly into temp filename

**File:** `src/gateway.zig:9431, 9450`
**Severity:** MEDIUM (path-component injection; low risk because `/tmp` only)

```zig
const audio_format = jsonStringField(body, "format") orelse "webm";
...
const tmp_path = std.fmt.bufPrint(&path_buf, "/tmp/nullalis_chat_stt_{d}_{x}.{s}", .{ ts, rand_suffix, audio_format }) catch { ... };
```

If a malicious client sends `{"format": "webm/../etc/passwd"}`, the resulting path would be `/tmp/nullalis_chat_stt_<ts>_<rand>.webm/../etc/passwd`. `createFileAbsolute` would attempt to create that path; if `/tmp/nullalis_chat_stt_..._<rand>.webm` doesn't exist as a directory, the call fails (404). Effective harm: limited to a denial-of-service (request returns 500 tempfile_failed). Not file-write outside /tmp because the prefix is fixed and the path can't escape upward.

**What to do:** validate `audio_format ∈ {webm, mp3, ogg, wav, m4a, flac}` before use.

**How to verify:** smoke test `curl -d '{"audio":"...","format":"../../etc/passwd"}'` — should return 400 invalid_format.

---

### ME-07 — Audio_reply emits even when `live_streamed=false` AND `is_tool_only=true`

**File:** `src/gateway.zig:9761-9809`
**Severity:** MEDIUM (low-priority behavior bug)

If `is_tool_only` is true (reply is empty), the marker extraction still runs. But an empty reply has no `[AUDIO:` prefix, so `extractAudioReplyMarker` returns null and `audio_emit.b64` stays null. ✓ Skip.

But: if reply is exactly `"[AUDIO:/x.mp3]\n"` (marker only, no visible body), `reply.len > 0` so `is_tool_only=false`, `payload_text=""`, the buffered branch sends zero token frames, then `audio_reply` emits, then `done`. Functionally OK — FE plays the audio without any text. But the code path wasn't designed for this; tools-only-with-audio is an emergent behavior that should be either tested or explicitly forbidden.

**What to do:** add a test for `reply == "[AUDIO:/x.mp3]\n"` (empty visible body) → asserts audio_reply frame emitted, no token frames.

**How to verify:** new gateway integration test with a mock agent that returns marker-only.

---

## LOW

### LO-01 — `extractAudioReplyMarker` accepts `]` in path via early-close but later code reads up to first `]` only

**File:** `src/gateway.zig:8483-8501`
**Severity:** LOW (defense in depth; agent doesn't emit such paths)

`indexOfScalar(u8, after_prefix, ']')` finds the FIRST close-bracket. If the agent ever emitted `[AUDIO:/tmp/some]weird]path.mp3]\nbody`, the path would resolve to `/tmp/some` and the body to `weird]path.mp3]\nbody`. The agent doesn't do this today, but if a future channel adapter (e.g., a custom voice provider) writes paths with brackets, they'd silently truncate.

**What to do:** explicit comment ("paths must not contain `]`; this is enforced at write time by tts_synthesize_fn"). Or use `std.mem.lastIndexOfScalar` as defense — though that lets a body `]` pull the path long. No clean answer; document the assumption.

---

### LO-02 — `extractAudioReplyMarker` test #4 ("missing newline") accepts ANY suffix as body

**File:** `src/gateway.zig:24299-24304`
**Severity:** LOW (test correctness, not behavior)

The test asserts:
```zig
const marker = extractAudioReplyMarker("[AUDIO:/tmp/x.mp3]body").?;
try std.testing.expectEqualStrings("body", marker.visible_text);
```

This codifies that an agent emitting `[AUDIO:/p]body` (no newline separator) gets the body extracted. The agent's actual contract (`root.zig:1135`) is `"[AUDIO:{s}]\n{s}"` — the newline is mandatory. The "missing newline" test enshrines a behavior the agent will never actually emit. If the agent contract ever tightens to require the newline strictly, this test would be a misleading regression-target.

**What to do:** rename the test to `extractAudioReplyMarker is lenient about missing newline (defense-in-depth)` — make explicit it's defending against future channel adapters, not against the agent.

---

### LO-03 — Streaming usage parser: integer overflow on absurd token counts

**File:** `src/providers/sse.zig:243-285`
**Severity:** LOW (no real provider emits >4B tokens; defensive paranoia)

Each `@intCast(v.integer)` from i64 to u32 silently wraps. If a buggy provider emits `prompt_tokens: 8589934592` (2³²+2³¹), the cast wraps to 2³¹ and pricing reports a believable but wrong number. The `>= 0` check guards against negatives but not against exceeding u32::MAX.

**What to do:** clamp via `if (v.integer > std.math.maxInt(u32)) ... else @intCast(...)` or use u64 fields. Latter is cleaner.

---

### LO-04 — `isOverloaded` 503 + "service" pattern is too loose

**File:** `src/providers/reliable.zig:114-122`
**Severity:** LOW (low probability)

```zig
if (std.mem.indexOf(u8, lower, "503") != null and
    (std.mem.indexOf(u8, lower, "service") != null or
        std.mem.indexOf(u8, lower, "unavailable") != null or
        std.mem.indexOf(u8, lower, "overload") != null))
```

A response like `"failed to connect to model service at 503ms timeout"` would trip overload because of the literal substring `"503"` plus `"service"`. False-positive risk is low because the fixture is contrived, but the check is too permissive.

**What to do:** match `503` only at message start or after an HTTP status colon: `"HTTP 503"`, `"status: 503"`, etc.

---

### LO-05 — `audio_emit.format` could be `"mp3"` when path has no extension

**File:** `src/gateway.zig:9728-9732`
**Severity:** LOW (mostly correct)

If `lastIndexOfScalar` returns null (no dot), format defaults to "mp3". If the path is `/tmp/notes` with no extension, format stays mp3 — but the actual file might be webm/ogg. Browsers usually figure it out from data anyway, but the format hint to the FE would be wrong.

**What to do:** accept the default, document it, or read-magic-bytes for first-12-bytes detection. Probably skip — the agent's tts_synthesize_fn always emits an extension.

---

### LO-06 — Pricing comment for K2.6 stale across two commits

**File:** `src/providers/pricing.zig:78-91`
**Severity:** LOW (documentation rot)

Commit 3725a88 added K2.6 at $0.55/$2.20 with comment "Conservative estimate uses K2.5's current Together rate". Commit 5947d11 (4 commits later) updated K2.6 to $1.20/$4.50 with new MoonViT vision rationale. The K2.5 block above (lines 77-84) still has the OLD comment `"K2.6 (April 2026 release) adds vision + reasoning toggle; pricing on Together is similar to K2.5"`. Out of date.

**What to do:** rewrite the K2.5 comment block to: `"K2.5 is Fast/Balanced/Deep's predecessor (was Fast in V1.10). K2.6 superseded all three modes in V1.11 hardening."`

---

### LO-07 — `transcribed_message` allocator is `req_allocator` but transcript freed before wrap

**File:** `src/gateway.zig:9472-9495`
**Severity:** LOW (already correct, but order is fragile)

```zig
const transcript = voice.transcribeFile(req_allocator, ...) catch { ... };
if (transcript.len == 0) {
    req_allocator.free(transcript);  // ← OK
    sendSseErrorResponse(...);
    return true;
}
const wrapped = std.fmt.allocPrint(req_allocator, "[voice] {s}", .{transcript}) catch {
    req_allocator.free(transcript);  // ← also OK
    ...
};
req_allocator.free(transcript);  // ← OK after wrapped is built
transcribed_message = wrapped;
```

Three free-sites for transcript. Currently correct. If any path is added between wrapped-build and the third free, double-free or leak risk. Minor.

**What to do:** `defer req_allocator.free(transcript);` immediately after assignment, then drop the manual frees.

---

### LO-08 — Choices loop indentation is 8-space inside a 12-space scope

**File:** `src/providers/sse.zig:121-208`
**Severity:** LOW (style; compiler doesn't care)

The diff retained the old indentation under a new wrapper block, leaving the loop body at the outer level visually:
```zig
        if (choices_v == .array) {
            const choices_array = choices_v.array;
            for (choices_array.items) |choice| {
        const choice_obj = switch (choice) {  // ← 8-space, parent is 16
            ...
```

Future edits in this file will be confusing.

**What to do:** reflow indentation. Trivial.

---

## NIT

### NI-01 — Comment in CR-03 mentions "4 sites" but jsonSafeFloat usage is at more sites after 223dfc1

**File:** `src/gateway.zig:130-138` (the jsonSafeFloat doc comment)
**Severity:** NIT

The doc comment near the helper says `"every formatter-driven JSON emission of a float"` but the commit message of c44dfd4 said "4 sites in gateway.zig"; commit 223dfc1 added 3 more (importance/score). The helper's docstring is correct in spirit; the commit-message reference is now an undercount. Documentation drift only.

---

### NI-02 — `K2.6` byte-stable test missing

**File:** `src/agent/model_capabilities.zig:55-62, src/providers/helpers.zig:411-435`
**Severity:** NIT (recommend new test)

`isReasoningCapableModel("kimi-k2.6")` is tested. `lookupModelTable("kimi-k2.6")` is implicitly tested via the table. But there's no end-to-end byte-shape test asserting that a request body for K2.6 with reasoning_effort=low matches a known fixture.

**What to do:** add a fixture-based test in `helpers.zig` that pins the K2.6 request body shape for low/medium/high.

---

### NI-03 — Audio metrics absent

**File:** `src/gateway.zig` (no metrics emitted)
**Severity:** NIT (Tier 3 ask)

The Telegram STT path increments structured counters (`telegramSttMetricsSnapshot` at 7822-7843). The new app /chat/stream STT path emits no metrics. Likewise audio_reply emit success/fail and Together overload retry counts have no metrics. `error.ProviderOverloaded` is now distinct from `error.AllProvidersFailed` but no dashboard surface increments on it.

**What to do:** add three counters: `app_stt_attempted`, `app_stt_failed`, `app_audio_reply_emitted`. Add `provider_transient_overload_total` mirror of the existing rate_limited counter. Out of scope for booth; track for V1.12.

---

### NI-04 — `extractAudioReplyMarker` 4 tests are good but not enough

**File:** `src/gateway.zig:24268-24304`
**Severity:** NIT

The four tests cover happy path, no marker, malformed, no-newline. Adversarial inputs from the spec (very long path, unicode, embedded `[AUDIO:` mid-text) are partially covered (the third test catches one: "marker substring inside text but not at start"). Missing:

- Path of length 600+ chars (defense — would the buffer overflow?). Currently `path_z_buf: [512]u8` — if path > 511 chars, `toSentinelPath` returns null and we silently skip without freeing the temp file (see ME-01).
- Unicode in path: `[AUDIO:/tmp/zähler.mp3]\nbody` — should pass since UTF-8 bytes are non-NUL non-newline.
- A bracket-only marker: `[AUDIO:]\nbody` — already tested.

**What to do:** add tests for long-path-rejection and unicode-path-acceptance.

---

## Verification of CR/HI/ME claims (Tier 2)

### CR-01 (re-verify pending ownership)

**Status:** ⚠️ HI-03 above. Three out of four error paths clear pending correctly; the synthetic-allocPrint OOM path leaks.

### CR-02 (mutex held across enqueue)

**Status:** ✓ Correct. Enqueue (line 639-650) acquires only its own mutex, no callbacks into registry. Lock order registry→subscriber preserved. closeAll (line 769) follows same order.

### CR-03 (jsonSafeFloat coverage)

**Status:** ✓ All emit sites identified in the verification trace are wrapped: handleBrainGraph similarity (12161), handleBrainGraph confidence/weight (12188), handleBrainMemoryDetail weight/confidence (12608), handleBrainLocalGraph weight (13353). 223dfc1 added importance + score (12085, 12323, 13302). Spot-checked grep for unwrapped `{d:.3}` / `{d:.4}` against f64 — clean.

### HI-01 (subagent.zig completeTask leak)

**Status:** Not re-verified in detail — outside core booth path. Commit comment + diff structure are consistent with the bug description.

### HI-03 (root.zig comment on compaction)

**Status:** ✓ Comment correctly references 70/90 thresholds and the Pass-A/C structure (Pass B deleted).

### ME-01 (getJobsJson NULL handling)

**Status:** ✓ COALESCE wrapping at line 6584+ matches the diff.

### ME-02 (getJobsJson LIMIT 500)

**Status:** ✓.

### ME-05 (composeFinalReply whitespace-only reasoning_content)

**Status:** ✓ Trim-once-at-source pattern is correct.

---

## Ship verdict

**Conditional ship for booth** with three pre-flight items:

1. **HI-03 fix recommended before booth.** The pending-leak path is low-probability but easy to hit with synthetic chaos testing. 5-line fix (clone tool_name, then clear, then format).
2. **HI-01 fix recommended before booth.** If a tenant ever switches to glm-5.1-air or deepseek-v3.2, the entitlement quota will mis-bill. Two-line swap of table rows.
3. **HI-02 + HI-04 acceptable as known-risk for booth, must address in V1.12.** Tighten overload patterns and verify Together's prefix-cache scope.

The audio path (STT in + audio_reply out + voice_mode capability) is honest, well-tested, and demo-ready. The K2.6 swap mechanically integrates everywhere it should. The streaming usage parser correctly handles the empty-choices regression vector. The CR-02/CR-03 fixes are textbook.

V1.11 hardening is **fundamentally green**, blocked only by the surfaceable HI-01/HI-03 quick fixes (~10 lines total) and HI-02/HI-04 awareness for the V1.12 backlog.

---

_Reviewed: 2026-05-07_
_Reviewer: Claude Opus 4.7 (1M context)_
_Depth: deep (cross-file analysis on call chains for CR fixes + audio path + provider hardening)_
