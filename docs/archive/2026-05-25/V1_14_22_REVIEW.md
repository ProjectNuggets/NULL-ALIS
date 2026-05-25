---
phase: v1.14.22 hotfix second-pass review
reviewed: 2026-05-25T00:00:00Z
depth: deep
commit_range: v1.14.21..HEAD (7 in-scope commits)
prior_review: /tmp/V1_14_21_REVIEW.md (4 CRIT + 8 HIGH + 7 MED + 5 LOW)
findings:
  critical: 0
  high: 0
  warning: 3
  info: 2
  total: 5
status: ship_with_notes
---

# v1.14.22 Hotfix Second-Pass Review

Commit range: `v1.14.21..HEAD`, 7 in-scope code commits
(see prompt for commit list).

## Summary

All 4 CRIT and all 8 HIGH from /tmp/V1_14_21_REVIEW.md were touched
by this hotfix series. Verification:

| Prior | Fix commit | Verdict |
|-------|-----------|---------|
| CR-01 (1M routing half-wired) | `227e07b1` | **Closed correctly.** Synthetic `-1m` suffix entries deleted; Claude Opus 4.7 + Sonnet 4.6 + Gemini 2.5 Pro promoted to 1M on base id. Comptime audit pins no `-1m` entries can leak back. max_output stays at 8_192 (Anthropic's published per-request cap — no inflation). |
| CR-02 (sendCommand UAF) | `4637cd63` | **Closed correctly** except for one OOM-path ref leak (WR-01 below). PendingCommand refcount semantics traced end-to-end on all 4 race interleavings: A-wins, B-wins, OOM-during-dup, hub-deinit-drain. |
| CR-03 (Dockerfile renderer broken) | `b7f1da9f` | **Closed correctly.** `texlive-xetex` added; verification step now runs an actual `pandoc → /tmp/probe.pdf` render. |
| CR-04 (Thmanyah fonts not bundled) | `b7f1da9f` | **Closed correctly.** `COPY assets/branding /usr/local/share/nullalis/branding` lands at the path resolveBundledFontsPath candidate E expects; build-time `ls` verification pins the canonical file. |
| HI-01 (9 tools missing ResultDeliveryOom arm) | `6fe78b61` | **Closed correctly.** `grep -L ResultDeliveryOom src/tools/extension_*.zig` returns empty. |
| HI-02 (output vs error_msg) | `8d9f59dd` | **Closed correctly.** All 6 tools use the canonical `error_msg` field; failure tests sweep to `result.error_msg.?`; defer-free added on heap-allocated msgs. |
| HI-03 (256-token cap) | `8d9f59dd` | **Closed correctly** with one minor UX gap (IN-01). Heap-allocated, scope is synchronous (handleUpgrade is fully blocking through the pump). |
| HI-04 (PDF fallback returns on `ran_but_failed`) | `b7f1da9f` | **Closed correctly.** New `latex_engine_missing` arm matches the sibling `xelatex_missing` pattern; wkhtmltopdf also falls through. |
| HI-05 (writeJsonString control-char bug) | `6fe78b61` | **Closed correctly.** New `src/tools/json_escape.zig` is RFC 8259 §7-compliant. All 8 string-arg-bearing extension tools import the shared escaper; the 2 that don't (`list_tabs`, `screenshot`) take no user-controlled strings. |
| HI-06 (hub.deinit OOM drain swallow) | `4637cd63` | **Closed correctly.** Pre-allocate via ensureTotalCapacity; if THAT fails, log + bail (process is exiting). |
| HI-07 (screenshot FrameTooLarge unsurfaced) | `6fe78b61` | **PARTIALLY closed — see WR-02 below.** Description string corrected to "~3 MB" (good). But the explicit `error.FrameTooLarge` switch arm in extension_screenshot.zig is **dead code** — FrameTooLarge originates in `extension_ws/server.zig:155` inside the pump's `readFrame`, kills the entire pump via `try`, and the sender sees `error.ConnectionClosed` instead. The user-visible failure mode is unchanged. |
| HI-08 (allowlist bracket strip) | `6fe78b61` | **Closed correctly.** `stripIPv6Brackets` mirrors `trimTrailingDot`; regression test pins both `[::1]` and `::1` allowlist forms work via `https://` (not `wss://` — test originally tripped the scheme allowlist first). |

The new per-user-model-selection feature (`6e3b48b0`) is **honestly
end-to-end wired**: parse → patch → render → merge → normalize →
apply all carry `selected_model`; validation rejects whitespace,
provider prefixes, length overflows, and non-string shapes;
applySettingsToConfig correctly frees the previous
`cfg.default_model` before duping the new one; inline 64-byte buffer
isolates the field from JSON arena lifetime.

Remaining findings are 3 WARNING + 2 INFO, all narrow:

## Critical Issues

None.

## High Issues

None.

## Warnings

### WR-01: sendCommand success path leaks PendingCommand on OOM during final result_allocator.dupe

**File:** `src/extension_ws/hub.zig:329-330` (commit `4637cd63`)
**Severity:** WARNING (memory leak on OOM — does not corrupt data)

After `pending.ready.timedWait` succeeds with `result_slice` populated, the success path runs:

```zig
const caller_owned: ?[]u8 = if (result_slice) |r|
    try result_allocator.dupe(u8, r)  // ← throws on OOM
else
    null;

pending.release(self.allocator); // sender ref — NEVER REACHED on OOM
```

If `result_allocator.dupe` returns `error.OutOfMemory`, the `try`
propagates the error out of `sendCommand` WITHOUT releasing the
sender's reference. The map ref was already released by
`deliverResult`. With sender's ref orphaned at 1 and map ref at 0,
`pending` is permanently leaked along with `pending.result`.

This is the inverse of the explicit "Re-dup BEFORE releasing"
comment at line 327 — the comment correctly flags the timing
constraint for `pending.result` freshness but didn't account for the
dup itself being a fault point.

**Fix:**
```zig
const caller_owned: ?[]u8 = if (result_slice) |r| blk: {
    const owned = result_allocator.dupe(u8, r) catch |err| {
        pending.release(self.allocator); // sender ref
        return err;
    };
    break :blk owned;
} else null;

pending.release(self.allocator); // sender ref
```

Or refactor with a `defer pending.release(self.allocator)` at the
top of the success block (after `was_oom`/`result_slice` are
read off pending).

### WR-02: HI-07 FrameTooLarge arm in extension_screenshot is unreachable

**File:** `src/tools/extension_screenshot.zig:94`
**Severity:** WARNING (dead code — the user-visible failure-mode
fix the commit claims is not actually wired)

The fix commit `6fe78b61` claims:

> Explicit error.FrameTooLarge arm added to the dispatch switch with
> operator-friendly remediation ("pass full_page:false, crop the
> viewport, or split the capture into multiple regions") — was
> falling into the generic `else => |e|` arm and surfacing the bare
> "FrameTooLarge" error.

In reality:

1. `error.FrameTooLarge` is only raised in `extension_ws/server.zig:155`
   inside `readFrame`, which runs INSIDE the per-connection
   `pumpFrames` loop on the gateway thread that owns the socket.
2. `pumpFrames` calls `readFrame` with `try` (line 590) — on
   FrameTooLarge the error propagates out of `pumpFrames`.
3. `handleUpgrade` catches it at line 530-536 → `else => return .io_error`
   → connection closes → pending sender gets `error.ConnectionClosed`
   from the hub drain.
4. The screenshot tool sees `error.ConnectionClosed`, not
   `error.FrameTooLarge`. The new arm at extension_screenshot.zig:94
   is unreachable in production.

The user-visible message remains the unhelpful
"extension connection closed before screenshot completed."

The description-honesty piece (cap reduced from "~5 MB" → "~3 MB",
lines 35 + 49) IS correctly fixed. Only the dispatch-time error
mapping is vacuous.

**Fix:** Either lift `MAX_FRAME_PAYLOAD` to ~5–6 MB so 3 MB
screenshots fit comfortably, OR propagate FrameTooLarge through the
hub (e.g. add a synthetic `FrameTooLarge`-flavored close: pump
catches FrameTooLarge, calls `conn.notifyTransportError(.frame_too_large)`
which sets a flag the sender's drain wake reads, sender returns
`error.FrameTooLarge` instead of `error.ConnectionClosed`). The
former is the cheaper closer; v2 could plumb the typed error.

### WR-03: gateway HI-03 OOM path leaves the peer hanging (no HTTP/WS response)

**File:** `src/gateway.zig:19681-19686` (commit `8d9f59dd`)
**Severity:** WARNING (operator/UX issue, not a correctness bug)

The new heap-allocation path for `entries_buf`:

```zig
const entries_buf = allocator.alloc(...) catch |alloc_err| {
    std.log.scoped(.extension_ws).err(
        "extension_ws: OOM allocating {d} auth entries: {s}",
        .{ state.extension_tokens.len, @errorName(alloc_err) },
    );
    return;  // ← peer sees a hung connection
};
```

On OOM, the function returns silently — no HTTP error response, no
WebSocket close. The peer (a connecting extension) waits until
TCP/HTTP timeout. This is a regression vs the prior fixed-256
buffer behavior, which would have at least attempted the auth
handshake.

**Fix:** Send a 503 before returning:

```zig
sendHttpResponse(
    conn.stream,
    "503 Service Unavailable",
    "application/json",
    "{\"error\":\"oom\",\"hint\":\"gateway temporarily out of memory; retry shortly\"}",
) catch {};
return;
```

## Info

### IN-01: CR-02 race regression test is probabilistic, not deterministic

**File:** `src/extension_ws/hub.zig:1001-1091` (test "CR-02: timeout firing while deliverResult is mid-write does not UAF")
**Severity:** INFO (test design — does not affect ship decision)

The test is documented as probabilistic ("half-likely to fire before
deliver, half after... we're not asserting WHICH wins") and runs 20
iterations to maximize race-window hits. Under Zig's testing
allocator (which detects double-free / UAF), a regression to the
pre-fix code would surface on at least one iteration. But the test
can pass on a buggy build if the race never fires within 20 trials,
which is possible on a heavily loaded CI host where the 5 ms timeout
and 5 ms helper sleep diverge enough to never coincide.

For v2: drive the race deterministically by injecting a
`std.Thread.ResetEvent` between deliverResult's `fetchRemove` (line
360) and its `pending.result = dup` (line 391), letting the test
release the gate right after the sender's `timedWait` fires. That
guarantees the race window is hit every iteration.

### IN-02: model_capabilities CR-01 fix raises provider-level fallbacks to 1M — affects unknown Anthropic models

**File:** `src/agent/model_capabilities.zig:131, 133-134` (commit `227e07b1`)
**Severity:** INFO (intentional per commit message, but worth flagging)

The PROVIDER_TABLE fallbacks for `anthropic`, `google`, and `gemini`
were bumped from 200K → 1M as part of the CR-01 fix. This means
an unknown model id like `anthropic/claude-opus-5-preview` now
reports 1M context window via the provider-fallback path, even though
the new model may ship with a smaller window. The previous 200K
default was the safer pessimistic floor.

The MODEL_TABLE specific entries still win first, so this only
affects truly-unknown models. inferFromPattern at lines 223-227 also
hardcodes 1M for any `claude-` / `gemini-` prefix — same exposure.

If Anthropic ships (e.g.) a `claude-haiku-4-6` with 200K context,
operators routing through this id without an explicit MODEL_TABLE
entry will get a 1M context-window assumption → compaction
thresholds will be wrong, agent may try to fit > 200K context and
get rejected by the provider.

**Fix (defensive):** Either keep the provider-fallback at 200K (only
the explicit MODEL_TABLE wins 1M), or add a note that whenever a
new Anthropic SKU is announced its MODEL_TABLE entry must land
BEFORE the SKU is configured anywhere downstream.

---

## Verdict

**SHIP WITH NOTES.**

All 4 CRIT + all 8 HIGH from /tmp/V1_14_21_REVIEW.md are closed;
the new per-user model-selection feature is honestly wired end-to-end;
no security regression introduced. The 3 WARNING-class findings are
narrow:

- WR-01 is an OOM-path memory leak; production exposure is low but
  not zero (memory pressure during deliverResult success path).
- WR-02 is "fix claims user gets a helpful error; in reality user
  gets the same unhelpful one as before" — the cosmetic
  half (description string) is correct.
- WR-03 is "OOM → silent hang" instead of "OOM → 503 close" — bad
  operator UX, not a security or correctness bug.

None of these block shipping the hotfix. Recommend opening tracking
items for all three and addressing WR-02 in the next sprint (it's
the only one that contradicts a commit-message claim about
user-visible behavior).

### Top 3 things to fix next

1. **WR-02 (HI-07 dead arm).** Either lift MAX_FRAME_PAYLOAD to
   5–6 MB or plumb FrameTooLarge through the hub. The commit
   message claim is currently §14.5-borderline ("operator-friendly
   remediation" message is unreachable).
2. **WR-01 (sendCommand OOM ref leak).** One-line fix wrapping the
   dup in a catch.
3. **WR-03 (OOM 503 response).** One-line `sendHttpResponse(503)`
   before the return.

---

_Reviewed: 2026-05-25_
_Reviewer: Claude (gsd-code-reviewer, deep mode, second pass)_
_Commit range: v1.14.21..HEAD (7 commits)_
