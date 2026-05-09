# V1.14.4 — Booth-Readiness Sprint Code Review

**Date:** 2026-05-09
**Reviewer:** gsd-code-reviewer subagent + author response
**Branch:** `v1.14.4/booth-readiness`
**Closures:**
- Item 1 — Channel FE placeholders (Teams + Email added; WhatsApp removed)
- Item 2 — Approval drop bug (production wiring intact; regression-lock test added)
- Item 3 — Subagent "received" bug (gateway OOM fail-loud + stderr fallback)
- Item 4 — Autonomy toggle end-to-end wire-up (ProductSettings field + parse/merge/apply)

**Build status (post-fixes):** 5983/6043 tests pass (+8 from V1.14.3 baseline of 5975), 60 skipped. ReleaseFast binary 9.9 MB. Frontend typecheck clean for source files (pre-existing test-tooling errors in *.test.tsx are unrelated).

---

## Verdict: **SHIP** (after first-pass fixes landed)

First-pass verdict was **SHIP-WITH-FIXES**. The reviewer caught one Critical contract mismatch (CR-01) that would have made the autonomy toggle visibly broken at the booth, plus four Medium and one Low requiring follow-through. All landed in the same branch.

---

## Findings + responses

### CRITICAL CR-01 — Autonomy enum string contract mismatch. **FIXED.**

**Issue:** Backend `AutonomyLevel.toString()` emitted `"readonly"` (no underscore) while the FE TypeScript union at `ZakiSettingsSheet.tsx:80` was strictly `"read_only" | "supervised" | "full"`. Round-trip break:
- First-load with non-default autonomy: FE radio group has nothing selected (no value matches `"readonly"`)
- Summary label key `levels.readonly.label` doesn't exist → i18next renders raw key
- Save flow: user clicks `read_only`, backend stores it, echoes `"readonly"`, problem persists

**Fix:** One-line change in `src/security/policy.zig:21`:
```zig
.read_only => "read_only",  // was "readonly"
```
Plus updated tests in `policy.zig:967` and `user_settings.zig:867` that asserted the old literal. `fromString` remains permissive (accepts both `"readonly"` and `"read_only"`) for backward-compat with stored configs.

**Verification sweep:** `grep -rn '"readonly"' src/ --include="*.zig"` post-fix shows only doc comments + the `fromString` accept-both branch. No other call site relied on the underscoreless form.

### HIGH HI-01 — Subagent stderr fallback comment vs code mismatch. **FIXED.**

**Issue:** Comment claimed "Debug builds: panic. Release builds: dump to stderr." Code did neither — the stderr dump fired in `std.debug.runtime_safety` builds (Debug + ReleaseSafe) but NOT in ReleaseFast. Production lost the content while the comment claimed it didn't.

**Fix:** Rewrote the comment block at `subagent.zig:709` to honestly describe what the code does:
- Debug + ReleaseSafe (`runtime_safety = true`): stderr dump fires
- ReleaseFast (production): log.warn only, content lost — same as pre-V1.14.4 on this branch

This is honest disclosure: production users still don't see the result. Acceptable for booth because the path that actually ships (gateway tenant) is now closed by the OOM-propagation fix elsewhere.

### HIGH HI-02 — "Fix B above" reference + missed second OOM site. **FIXED.**

**Issue:** Subagent.zig diff comment claimed "Now mitigated at the dispatch site (Fix B above)" — but Fix B didn't exist. Worse: `gateway.zig:18485` had the same `allocator.create(SubagentCompletionRouter) catch null` pattern that was supposedly closed at line 1411, but only one of the two sites was actually fixed.

**Fix:**
1. Applied the same `catch null` → `try` change at `gateway.zig:18485` (standalone-mode router init).
2. Rewrote the subagent.zig:709 comment to honestly describe what V1.14.4 closes vs what's deferred:
   - Tenant init OOM: **closed** (both line 1425 + line 18491 now `try`).
   - main.zig:2760 / 3083 standalone CLI: **NOT FIXED** at the dispatch site; only mitigated by debug-build stderr fallback. Tracked as F-2 for V1.14.5.

### MEDIUM MD-01 — Backward-compat hole in `deriveNearestFromAgentObject`. **FIXED.**

**Issue:** When a tenant's stored config had `cfg.autonomy.level = "supervised"` (operator-set) but no `product_settings` block, the legacy fallback path returned `defaults()` ⇒ autonomy=.full. This silently elevated autonomy beyond what the operator configured the moment the user opened the FE settings sheet.

**Fix:** Modified `deriveNearestFromConfigJson` at `user_settings.zig:218` to extract top-level `autonomy.level` BEFORE delegating to the agent-shape snapper, then merge it into the result. Three cases handled:
1. Operator-set `autonomy.level` + agent block → snap from agent, override autonomy from operator
2. Operator-set `autonomy.level` + no agent block → defaults() with autonomy override
3. Operator-set `autonomy.level` accepted in both new (`"read_only"`) and legacy (`"readonly"`) forms

Added test "V1.14.4 review MD-01: operator-set cfg.autonomy.level honored when product_settings absent" with 4 sub-cases: supervised/read_only/legacy-readonly/no-agent-block.

### MEDIUM MD-02 — Test struct field-shape audit. **CONFIRMED CLEAN.**

Reviewer flagged: confirm `SecurityPolicy.autonomy` field shape after CR-01 fix. Verified at `policy.zig:96` — field is `autonomy: AutonomyLevel = .supervised`, the test's `.autonomy = .full` initializer compiles correctly. No bug.

### MEDIUM MD-03 — FE/backend default autonomy mismatch. **FIXED.**

**Issue:** Backend default `.full` (config_types.zig:67) vs FE default `"supervised"` (ZakiSettingsSheet.tsx:102). Fresh-install tenants would silently demote autonomy on first save (FE patch logic detected the inequality and sent the FE default).

**Fix:** Changed FE `DEFAULT_SETTINGS.autonomy` to `"full"` to match the backend. Comment block explains the rationale (config_types.zig:60-66 has the canonical "v1 single-pod ships .full" justification). The `(recommended)` label on the supervised radio remains as a SAFETY recommendation for future shared-pod scenarios; v1's actual default is full.

### MEDIUM MD-04 — Redundant import path. **FIXED.**

**Issue:** `user_settings.zig:4-5` imported `security/policy.zig` directly to get `AutonomyLevel`, but `config_types.zig:13` already re-exports it as `config_types.AutonomyLevel` with a documented "single source of truth" comment. The direct import bypassed the documented indirection.

**Fix:** Switched to `const AutonomyLevel = config_types.AutonomyLevel;` honoring the existing re-export.

### LOW LO-01 — Stale "WhatsApp" comment. **FIXED.**

Updated the comment block at `ZakiSettingsSheet.tsx:438` to reflect the V1.14.4 swap: "Telegram, Slack, Discord, Microsoft Teams, Email" with rationale for dropping WhatsApp (Meta Business API auth dance out of booth-week scope).

### LOW LO-02 — Built artifacts in working tree. **NOTED, NOT FIXED.**

`dist/index.html` + `dist/assets/index-*.{css,js}` deleted/added in working tree. Author flagged "ignore" but acknowledges this is sloppy. Not booth-blocking; clean up in next FE deploy commit.

### LOW LO-03 — Unnecessary `defaultValue` fallbacks. **NOTED, NOT FIXED.**

The `defaultValue` argument on `t()` calls for Teams + Email is dead code given both en.json and ar.json have the keys. Defensive style for the rare third-locale case; harmless. Leave.

### LOW LO-04 — `.empty` initializer in test agent. **NOTED, INFORMATIONAL.**

Reviewer flagged for `git blame` posterity: `defer agent.history.deinit(allocator)` on a never-grown empty list is a no-op. Kept for symmetry. No change.

---

## Tests added in V1.14.4 + post-review

| File | Test | Purpose |
|---|---|---|
| `user_settings.zig` | `V1.14.4: autonomy default is .full and survives patch round-trip` | Default + patch coverage |
| `user_settings.zig` | `V1.14.4: applyPatchToSettingsJson rejects invalid autonomy` | Bad-input rejection |
| `user_settings.zig` | `V1.14.4: applySettingsToConfig propagates autonomy into cfg.autonomy.level` | Config propagation across all 3 levels |
| `user_settings.zig` | `V1.14.4: pre-V1.14.4 stored configs without autonomy key default to .full` | Backward-compat with old configs |
| `user_settings.zig` | `V1.14.4: renderSettingsJson includes autonomy` | Wire-format render |
| `user_settings.zig` | `V1.14.4: mergeSettingsIntoConfigJson writes canonical autonomy` | Wire-format merge |
| `user_settings.zig` | `V1.14.4 review MD-01: operator-set cfg.autonomy.level honored when product_settings absent` | Backward-compat hole closed |
| `agent/root.zig` | `V1.14.4 booth-readiness: approval_continues_turn defaults to true (regression lock)` | Lock the production default |

Test count delta: **+8** from V1.14.3 baseline (5975 → 5983 passing; 6035 → 6043 total).

---

## Open follow-ups (V1.14.5+)

| ID | Item | Severity | Notes |
|---|---|---|---|
| F-1 | main.zig:2760 + 3083 standalone CLI subagent dispatch sites | Medium | No completion_delivery wired. Mitigated by debug-build stderr fallback only; ReleaseFast standalone CLI still loses subagent results. CLI is rare for booth (gateway tenant is the demo path). |
| F-2 | Built artifacts (`dist/`) tracked in zaki-prod | Low | Tracked deploy artifact policy needs review; clean up in next deploy. |
| F-3 | G-12 PII scrubbing admin CLI | Medium | Carry-over from V1.14 audit. Legal/GDPR for B2C launch. |

---

## Booth-week ship judgment

**SHIP.** The V1.14.4 sprint closes the four booth-blocking items the way it claimed to:
- Autonomy toggle works end-to-end (after CR-01 fix).
- Approval flow is production-wired and regression-locked.
- Subagent "received" bug closes the production tenant path; standalone CLI mitigated for debug, deferred for V1.14.5.
- Channel placeholders refreshed for booth's GCC/MENA + B2B audiences.

The reviewer's first-pass dissent was material — CR-01 alone would have made the headline feature visibly broken on stage. Author responded by landing every blocking + Medium fix in the same branch. No deferred booth-blockers remain.

---

## Files changed (final)

```
src/agent/root.zig         | 43 ++ — approval regression-lock test
src/gateway.zig            | 24 ++ — fail-loud OOM at TWO router init sites
src/security/policy.zig    | 14 ~~ — toString emits "read_only"; tests + comment
src/subagent.zig           | 41 ~~ — honest comment on stderr fallback scope
src/user_settings.zig      | 234 ++ — autonomy field + 7 tests + MD-01 fallback
docs/REVIEW-v1.14.4-...md  | NEW   — this doc

zaki-prod/.../ZakiSettingsSheet.tsx  | 38 ~~ — Teams+Email; FE default .full; comment
zaki-prod/.../i18n/locales/en.json   | 10 ~~ — teams + email keys
zaki-prod/.../i18n/locales/ar.json   | 10 ~~ — Arabic translations
```

Verdict: **SHIP.**

---

## F-1 closure review (2026-05-09)

Commit `beb87ad` — `fix(subagent): F-1 — close standalone CLI subagent "received" bug`. Single-file change: +45 lines in `src/main.zig`. Adds `cliSubagentCompletionDelivery` free function + two `attachCompletionDelivery` calls at the standalone-CLI dispatch sites.

### Checklist verification

| # | Claim | Result |
|---|---|---|
| 1 | Signature matches `CompletionDeliveryFn` | **OK.** `(_: ?*anyopaque, []const u8, []const u8) anyerror!void` matches `subagent.zig:88-92` exactly. `attachCompletionDelivery` accepts `?*anyopaque = null` (`subagent.zig:198-207`). |
| 2 | stderr is the right surface | **OK.** `std.debug.print` writes to stderr; CLI stdout is reserved for the agent's reply text. Mixing subagent fallbacks into stdout would corrupt user-visible reply. |
| 3 | Allocation / lifetime | **OK.** `subagent.zig:684-689` does `defer self.allocator.free(content)` and calls delivery synchronously inside that scope. The callback only reads + prints. No retention, no UAF risk. |
| 4 | Format-string safety | **OK.** Zig `std.fmt` is comptime/value-based, not C-style. Runtime content cannot inject format specifiers via `{s}`. |
| 5 | Concurrency | **OK.** `std.debug.print` (Zig 0.15.2 `lib/std/debug.zig:227`) wraps the format with `lockStderrWriter`/`unlockStderrWriter` — atomic per call. No other contended stderr writers in the CLI hot path that would interleave inside a single delivery call. |
| 6 | "Errors are non-fatal" | **OK.** Body has no `try`; `std.debug.print` swallows write errors (the inner `nosuspend bw.print(...) catch return;`). Returning `!void` is just contract conformance. |
| 7 | Both call sites attach properly | **OK.** `main.zig:2796/2802` (runSignalChannel) and `main.zig:3124/3129` (runTelegramChannel) both attach immediately after `defer subagent_manager.deinit()` and well before the agent loop starts. No subagent could have dispatched yet — race-free. |
| 8 | Gateway standalone path untouched | **OK.** `gateway.zig:18562` already wires `appendSubagentCompletionToGatewaySession` with router context. Independent shape; commit correctly does not touch it. |
| 9 | "No unit-test surface" | **PARTIALLY HONEST** — see HI-04 below. |

### New findings

#### HIGH HI-03 — Third standalone-CLI SubagentManager site missed (`agent/cli.zig:130`)

**Severity:** High. Same class of bug as F-1 was supposed to close.

`grep "SubagentManager.init" src/` reveals a third user-facing CLI dispatch site this commit did not address:

```
src/agent/cli.zig:130:    var subagent_manager = subagent_mod.SubagentManager.init(allocator, &cfg, null, .{});
```

This is the `nullalis agent` subcommand path (dispatched from `main.zig:422` → `yc.agent.run`). It:
1. Creates `SubagentManager` with `bus = null` — same shape as the two sites this commit fixes.
2. Passes `&subagent_manager` into the tool set at `agent/cli.zig:146`, so delegate/subagent tool calls *will* dispatch real async subagents.
3. Has **no** `attachCompletionDelivery` call.

When a subagent completes from this entry point, it lands in `subagent.zig:709` `path=none` and gets discarded — the exact bug F-1 claims to close for "CLI users." `nullalis agent` is part of the CLI surface; the closure is incomplete.

**Fix (trivial — same pattern):**

```zig
// src/agent/cli.zig, line 131:
var subagent_manager = subagent_mod.SubagentManager.init(allocator, &cfg, null, .{});
defer subagent_manager.deinit();
// V1.14.4 review F-1 — wire CLI completion delivery (same as main.zig
// runSignalChannel/runTelegramChannel sites). Otherwise async subagent
// results vanish into subagent.zig:709 path=none.
subagent_manager.attachCompletionDelivery(null, cliSubagentCompletionDelivery);
```

This requires either:
- Hoisting `cliSubagentCompletionDelivery` into a shared module (e.g., `src/subagent.zig` exports a `defaultStderrDelivery`, or a new `src/agent/cli_delivery.zig`), or
- Defining a local twin in `agent/cli.zig` (mild duplication, but cheap and self-contained).

The commit message phrase "Code review SHIP-with-fixes is now fully closed end-to-end" is overstated until this third site is wired.

#### MEDIUM MD-05 — F-1 follow-up entry not removed from "Open follow-ups" table

The "Open follow-ups" table at line 125 still lists F-1 as open (`Medium`, ReleaseFast standalone CLI loses results). With this commit, the table should be updated to mark F-1 as closed (or moved to a "Closed in V1.14.5" subsection) — and HI-03 above added if my finding holds.

#### LOW LO-05 — Format string spacing

The format string is `"\n[subagent → {s}]\n{s}\n\n"`. Two trailing newlines + leading newline = three blank-line separations bracketing the content. In a TTY this is fine; for piped/captured stderr (e.g., `nullalis run 2> log`) it produces extra whitespace in logs. Cosmetic; not blocking.

### Honest pushback on commit-message claims

1. **"Closes V1.14.4 review F-1 ... fully closed end-to-end."** — *Overstated.* HI-03 above shows the third CLI dispatch site (`agent/cli.zig:130`) is structurally identical and unwired. F-1's framing in the original review specifically said "main.zig:2760 + 3083 standalone CLI subagent dispatch sites" — narrowly read, those two are closed. But the *bug class* (CLI bus=null + no delivery → discard) still has one live site.

2. **"No unit-test surface."** — *Partially honest.* True that exercising the *production* CLI flow needs a live subagent run. But the existing test infrastructure (`subagent.zig:1320` `RecordingCompletionDelivery`) shows the delivery callback contract is unit-testable. A test that:
   - constructs a `SubagentManager` with `bus=null`
   - attaches `cliSubagentCompletionDelivery`
   - dispatches a synthetic completion
   - asserts no `path=none` log fires
   ...would lock the wiring contract. Not blocking, but the "no surface" claim sells the test surface short. Recommend adding a follow-up test alongside the HI-03 fix.

3. **stderr-only delivery is a real UX choice, not a workaround.** The doc-comment rationale (parent turn loop has typically returned; CLI lacks gateway session-pin) is correct. Accept the design.

### Verdict

**SHIP-WITH-FIXES.**

The two sites this commit targets are correctly wired and the callback is sound. But HI-03 means the bug class F-1 was meant to close still has a live third site (`nullalis agent` subcommand). One additional 3-line wire-up (with a shared or duplicated callback) closes the class properly. Until then, F-1 should remain on the V1.14.5 follow-up list with scope amended.

If this commit ships as-is for booth without the third site, that is acceptable *only* because:
- The `nullalis agent` path is rarely hit on the booth demo (gateway tenant is the demo surface, per the original review).
- The debug-build stderr fallback at `subagent.zig:748-753` still fires for `agent/cli.zig` users in dev/test builds.

But the commit message should not claim "fully closed end-to-end" while the third site is open.

**Recommended actions before next commit:**
1. Wire `agent/cli.zig:130` with the same callback (HI-03). Hoist `cliSubagentCompletionDelivery` to a shared location to avoid duplication.
2. Update this doc's "Open follow-ups" table: mark F-1 closed; add F-1b/HI-03 if the third site isn't wired in the same push.
3. (Optional, recommended) Add a `RecordingCompletionDelivery`-style test that exercises the attach + dispatch contract for `bus=null + delivery_attached` to lock the wiring against future regression.

Reviewed: 2026-05-08 (commit `beb87ad`, branch `main`).
