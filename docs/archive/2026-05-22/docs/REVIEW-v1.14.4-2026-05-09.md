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

---

## F-A1 + F-A2 review (2026-05-09)

**Commit:** `fe0d094` — `feat(prompt): F-A1 + F-A2 — counterfactual reasoning + brain graph as default for entities`
**Scope:** Single file, +62 lines, `src/agent/prompt.zig` (response protocol section).
**Verdict:** **SHIP-WITH-FIXES.** Two CRITICAL issues that should land in the same wave or as a fast follow-up before the bench re-run is interpreted; one HIGH worth flagging publicly even if not patched today; the rest are MEDIUM/LOW. Detail below — and an explicit pushback on the framing in the closing section.

### Findings

#### CRITICAL CR-A1 — Direct contradiction with line 832 produces an ordering-bias coin-flip.

**File:** `src/agent/prompt.zig:832` vs. `src/agent/prompt.zig:932`.

The pre-existing rule at line 832 still reads:

> Skip the tool only when: (a) the answer is already in this turn's context, or (b) the question is purely about reasoning/preference that no tool could ground (\"what's 2+2\", \"tell me a joke\", **\"do you think X is a good idea\"**).

The new F-A1 paragraph at line 932 directly forbids the behavior the older rule licenses ("would Mia like the new restaurant" is structurally identical to "do you think X is a good idea"). The two rules now point in opposite directions for the exact class of question this commit is trying to fix. LLMs given conflicting instructions tend to favor the more recent / more strongly worded one, but that is a tendency, not a contract — Cat 3 will get a coin-flip's worth of regression on whichever turns the model latches onto the older rule.

The commit message even acknowledges this ("the earlier 'skip the tool' rule made this worse — it told the agent that inference questions were a licence to hedge") but did not edit line 832. The fix is a 1-line edit: drop the third "do you think X is a good idea" example from the line 832 exception list, or replace the parenthetical with `(\"what's 2+2\", \"tell me a joke\")` and add an explicit cross-reference: `Inference / counterfactual questions ("would X likely Y") are NOT in this exception — see the counterfactual discipline rule below.`

**Severity rationale:** this is the central conflict the new section was supposed to resolve. Leaving it unresolved means the prompt ships in a self-contradictory state on its primary use case.

**Fix:** Edit line 832, do not add another paragraph. Adding more text to win an ordering battle is the wrong lever; remove the source of the contradiction.

#### CRITICAL CR-A2 — F-A2 advertises a predicate that does not exist (`PARTICIPATES_IN`).

**File:** `src/agent/prompt.zig:975`.

The Nate worked example reads:

> ...`brain_graph local_graph(center_key=<nate_key>, depth=2)` to surface his typed-edge neighborhood (PARTICIPATES_IN, OWNS, LIKES, FRIENDS_WITH).

`OWNS`, `LIKES`, `FRIENDS_WITH` are real (verified in `src/memory/root.zig:290-301` and `src/agent/extraction_persist.zig:464-493`). **`PARTICIPATES_IN` is not in the codebase.** The closest existing predicates for the "Nate plays in tournaments / runs a vegan diet group" content the example walks through are `JOINED`, `ATTENDED`, `HAPPENED_ON` — all under the `episode` LinkType.

Why it matters: the example primes the agent to look for a predicate label it will never find in the subgraph, and to potentially reason about edges that aren't there. In the worst case, the agent reads the prompt as a contract about predicate names available in `local_graph` output, then fabricates `PARTICIPATES_IN`-shaped edges in its narration of the subgraph. That is exactly the "boundary erosion" risk flagged in the review brief — except it is now self-induced by the prompt rather than driven by the user.

**Fix:** Replace `PARTICIPATES_IN` with `JOINED` (or `ATTENDED`) in the Nate example. Two characters, one PR, removes the misleading advertisement.

#### HIGH HI-A1 — F-A1's "Caroline counseling" example mis-frames the bench behavior we're fixing.

**File:** `src/agent/prompt.zig:941-943` vs. `.spike/external/baselines/locomo_full_battery_2026-05-09.json`.

The example claims the agent's WRONG behavior on this question is:

> "The conversations don't explicitly address this counterfactual..." — refuses to reason.

The actual recall=0.0 reply we logged is:

> "The conversations don't explicitly address this counterfactual, but Caroline consistently describes her career choice as a direct result of the support she received... **the text strongly suggests she would not have pursued counseling specifically** without having experienced its impact firsthand."

The agent **did commit to a position** ("would not have pursued counseling specifically"). It scored 0.0 because the LoCoMo recall scorer is a bag-of-words substring match against the ground truth string `"Likely no"` — and the agent's commit was framed as `"would not have pursued"` instead of containing the literal token `"likely no"`. The bench failure is **not** a hedging failure; it is a scorer-string-match failure.

This matters for two reasons:

1. **The product diagnosis is wrong.** F-A1 is targeted at a hedging behavior that this specific Cat 3 example does not actually exhibit. The real failure mode, as captured in the trail, is a stylistic mismatch with the LoCoMo bag-of-words scorer. F-A1 will likely lift recall on this question because the prompt explicitly trains the agent to lead with a 2-word phrase ("Likely no.") that the substring scorer will match — but that lift is the scorer, not reasoning quality.

2. **The framing in the commit message ("ship product value first, let the benchmark show the real result") is at risk of being optimistic about its own causation.** If the next bench run shows Cat 3 jumping from 75.3% → ~85%+, the most parsimonious explanation is "we taught the agent to start replies with the literal tokens the scorer tokenizes against." That is closer to gaming the scorer (via prompt) than the framing admits. See the **Pushback** section below.

**Fix:** Replace the Caroline counseling WRONG example with one where the agent actually refused to reason (e.g., the "Mia restaurant" pattern — that one is a real production failure mode per the commit message). Keep Caroline as a RIGHT-only worked example to anchor the protocol, since the actual failure here was scorer-shape, not reasoning-shape.

#### HIGH HI-A2 — F-A2 has no cold-start handling; combined with F-A1 it primes hallucination.

**File:** `src/agent/prompt.zig:965-975` interacting with `src/tools/brain_graph.zig:117, 124, 133`.

`brain_graph local_graph` returns a hard tool error in three real conditions:
- `center_key` missing entirely → `"action=local_graph requires 'center_key'..."`
- `center_key` is a system bookkeeping key → `"center_key is hidden..."`
- `center_key` not found in the brain → `"center_key not found (or archived). Try memory_recall first to find a live key."`

For any entity the brain has never indexed (a person mentioned for the first time, a project name the agent has never persisted), the new F-A2 sequence is:
1. memory_recall — returns nothing useful
2. brain_graph local_graph — returns the third error above
3. ...silence in the prompt.

There is no "fall back to text recall," "say you don't know," or "report what failed" guidance after step 4 fails. The earlier R7-tool / R14 rules tell the agent to surface tool errors, which is good — but the new section's confidence-weighted "commit to a position" instruction (F-A1, three paragraphs above) is now the most recent specific guidance the model sees about how to answer entity questions. Under load, the most likely failure mode is: agent calls memory_recall, gets nothing, calls brain_graph, gets an error, then synthesizes an answer "from training" without admitting either tool failed — exactly the hallucination pattern the F-A1 exception clause was supposed to prevent.

**Fix:** Add one line at the end of F-A2: `If brain_graph local_graph returns an error or empty subgraph, fall back to memory_recall results alone — and if those are also empty, say "I have no signal on <entity>" (per the F-A1 zero-signal exception). Do not synthesize from training.`

#### MEDIUM MD-A1 — Cat 1 regression risk from F-A1's "commit to a position" rule.

**File:** `src/agent/prompt.zig:932-950`.

Cat 1 (single-hop factual) was the strongest category in the F-G4 baseline at 91.2%. Single-hop questions sometimes legitimately have no answer — when the truth is "the user never mentioned this," `memory_recall returns empty` is the right answer. F-A1's prose places strong gravity on "commit to a position" / "Don't hedge into 'I can't determine'" / "the hedge-trap is the failure" — *three* separate restatements of the commit-or-die directive — against *one* exception clause at the end (the ZERO-signal carve-out). Under recency-bias the carve-out is the most recent, which helps; but the cumulative weight of the page leans "commit." Expect Cat 1 to take a 1-3 point hit as the agent invents low-confidence guesses on questions where the right answer was "no mention."

**Fix:** Either (a) restate the zero-signal exception at the top of the section as well, not just at the end, so it has the same recency advantage as the commit rule; or (b) explicitly scope F-A1 to inference-shaped surface forms ("would X likely Y", etc.) and forbid it from firing on factual-shaped questions ("what is X's birthday"). Option (b) is the cleaner fix.

#### MEDIUM MD-A2 — `memory_recall` does not return a "canonical key" the way step 2 implies.

**File:** `src/agent/prompt.zig:968`.

> 2. Call `memory_recall` to find the canonical key for X (entity_<hash> or wiki:X).

`memory_recall` is text retrieval — it returns matched fact rows with their keys, but those keys are content keys (`durable_fact/<hash>`, etc.), not entity keys. The semantics implied by "find the canonical key" suggest there is a deterministic name-to-key resolver, which there isn't. In practice the agent will likely pass the key of whatever fact-row mentions Nate most prominently, then `local_graph` will expand from that fact-row, which gives a reasonable but less-than-ideal subgraph.

This is not a blocker — the path still produces useful output — but the prompt is more confident than the underlying tool semantics warrant. The agent reading "find the canonical key for X" may attempt key formats (`entity_<hash>`, `wiki:X`) that the `memory_recall` results don't include, then get confused about why none of the keys it tried fit.

**Fix:** Soften step 2 to reflect actual semantics: `Call memory_recall for "<entity name>" and pick the key of the most directly entity-naming fact row from the results. If memory_recall returns no rows, skip step 3 and report "no signal" per F-A1.`

#### LOW LO-A1 — Ordering-bias also affects the broadened brain_graph rule vs. line 821.

**File:** `src/agent/prompt.zig:821-824` vs. `src/agent/prompt.zig:965`.

The line 821 rule routes graph-shape questions ("what CONNECTS to X", "who works at Y") to brain_graph. The new rule at 965 broadens this to ANY entity-centric question. The two are not strictly contradictory (broad rule subsumes narrow), but the older rule's narrowness implicitly signals that other entity questions go to memory_recall alone — which the new rule overturns.

The agent will probably do the right thing because the new rule names the entity-centric pattern explicitly. But for hygiene: append `(see also "Brain graph as default for entity-centric questions" below — that rule generalizes this dispatch to all entity questions, not only explicit-connect language)` to line 821. One sentence; aligns the table-of-contents view of the protocol with the actual protocol.

#### LOW LO-A2 — Latency cost is real but acceptable for the entity-centric path.

The 3-call sequence (memory_recall → memory_recall again for canonical key → brain_graph local_graph) doubles tool round-trips on entity questions vs. the prior memory_recall-only path. For the LoCoMo bench (sequential, single user, single conv) this is fine. For production at the booth or post-booth, it adds ~600-1200ms per entity question depending on Together latency.

This is a UX trade-off, not a correctness issue, and the rule has a reasonable skip clause (questions about the agent itself, transient questions, no-entity questions). Flagging for awareness only — the trade is correct given the recall lift the structural neighborhood provides.

#### INFO IN-A1 — Comments are not emitted (verified).

The reviewer brief asks to confirm that `// V1.14.6 F-A1...` comments aren't accidentally written into the system prompt text. Verified: comments at lines 915-931, 952-964 are Zig source comments, separate from `try w.writeAll(...)` calls, and stay in the binary as compile-time-stripped. No prompt-text leak.

#### INFO IN-A2 — Token cost is ~1.0-1.2 KB, not 5 KB.

The brief estimated +5 KB (62 lines × 80 chars). Actual: the new section is ~5400 characters of prose embedded in `writeAll` calls — roughly 1.0-1.2 KB of system-prompt tokens after subtracting Zig-source overhead (string-literal escapes, indentation, comment lines). Marginal against the existing ~50 KB prompt. Not a concern.

### Pushback on the commit-message framing

The commit message reads:

> Both scaffolds are PURE PRODUCT IMPROVEMENTS — no scoring tweaks. They ship value to real users (counterfactual questions, "tell me about X" questions) regardless of bench impact. The benchmark is the honest test for whether they move the needle.

I want to push back on this honestly because the brief invited dissent.

**The framing is true for F-A2 and partially true for F-A1, but it understates what F-A1 is actually doing on the LoCoMo Cat 3 numbers.**

The Caroline counterfactual baseline reply (HI-A1 above) committed to a position, reasoned over the evidence, and scored 0.0 — because the recall scorer is a substring match against `"Likely no"` and the agent said `"would not have pursued"`. The product behavior on that question was already correct in the F-G4 baseline. The F-A1 prompt explicitly trains the agent to **lead with the 2-word phrase** ("Likely no.", "Liberal.", "Probably yes.") that the substring scorer rewards. If the bench re-run shows a meaningful Cat 3 lift, the dominant cause will be "answers now begin with scorer-friendly tokens," not "the agent reasons better."

That is not the same thing as scoring tweaks (which would edit the scorer or the answer extraction logic), but it sits closer to "shape the prompt to win the scorer" than the commit message admits. The product lift on UX-shaped questions ("would Mia like the restaurant?") is real and worth shipping; the bench lift will be partly real reasoning and partly scorer-targeting. Both should be acknowledged when the bench result lands.

Concretely: when reporting the post-commit Cat 3 number, also report **what fraction of the lift comes from questions where the F-G4 baseline already committed to the correct position but failed the substring match.** That number is the "scorer-targeting" portion of the gain. If it's >50%, the honest readout is "F-A1 lifted bench Cat 3 by N points, of which X points were prompt-shape alignment with the recall scorer and Y points were genuine reasoning improvements; production UX impact is captured separately by the qualitative pre/post on Mia-shaped questions."

This is the inverse of the test-fixing problem the brief asked me to look for: not "we changed the scorer to match the agent" but "we shaped the agent to match the scorer's tokenizer." The product justification covers it; the scorer-targeting portion should still be named.

### Verdict

**SHIP-WITH-FIXES.**

Recommended order:
1. **Land CR-A1 (line 832 edit) and CR-A2 (`PARTICIPATES_IN` → `JOINED`) before the bench re-run is interpreted** — both are 1-line edits. Without CR-A1 the agent gets contradictory guidance on the exact class of question this commit fixes; without CR-A2 the prompt asks the agent to reason over a predicate that doesn't exist.
2. **Add HI-A2 cold-start fallback in the same wave** — one sentence appended to F-A2.
3. **Address HI-A1 in the bench writeup** — even if the prompt example isn't edited, the bench post-mortem should report the scorer-shape vs. reasoning-shape decomposition described above.
4. MD-A1, MD-A2, LO-A1 are V1.14.7 hygiene; not blockers.

Without the CRs landed in the same wave, the bench re-run measures an internally-conflicted prompt and the result will be harder to interpret cleanly.

