# Coverage audit — `.spike/coverage/<ts>/`

ROADMAP v1.14.18 Step 10 (B8). A **one-off** quarterly audit, not a CI
gate — the integration cost of source-instrumented coverage on Zig 0.15.2
under Darwin's LLVM toolchain is high, and the action-producing signal is
narrower than full line coverage: we want to surface **production
functions that have no test reference at all** (the `handleReady`-style
gap the ledger calls out).

## What this is

A static-analysis based **test-reference audit**:

- enumerate every `pub fn` in `src/`
- match each name against the test corpus (`grep -F` across all
  `test "…"` blocks + every satellite test under `tests/`)
- report functions with **zero test references** — i.e. production
  surfaces no test even names

This is NOT real line-coverage. A function appearing in a test name does
not prove every branch is exercised. But the converse is load-bearing: a
function with **zero** test references is provably untested. That set is
the actionable backlog for hardening; line-coverage would only refine
the inside of that set.

## What this is not

- A CI gate. Per ROADMAP "one-off; not a recurring gate (too slow)."
- A full coverage measurement. Real instrumented coverage on Zig
  0.15.2 under Darwin would need a custom `--test-cmd` wrapper around
  the runner emitting `.profraw` files + `llvm-profdata merge` +
  `llvm-cov export`. The wiring is sizable and out of scope for this
  sprint — registered as **D50** for the next test-infrastructure
  touch.

## Re-running

```sh
.spike/coverage/run.sh
```

Output goes to `.spike/coverage/<utc-timestamp>/`:

- `pub_fns.txt`            — every `pub fn` in `src/` (`file:line\tname`)
- `tested_pub_fns.txt`     — subset that appears in at least one
                             test name or test body
- `untested_pub_fns.txt`   — the actionable backlog: `pub fn`s with
                             zero test references in the corpus
- `summary.txt`            — counts + top-10 untested-per-file
                             concentration

## Cadence

Run once per quarter (every ~3 months). Add a row to the ledger if a
notable concentration of untested production surfaces appears.

## Limitations / honest disclaimers

- Test references are matched by **function name as a literal token**.
  Indirect calls via vtable / dynamic dispatch may register as
  "untested" even if exercised through an interface — that's a
  conservative miss, not a false alarm.
- `_test.zig` files and `test "..."` blocks inside source files are
  both scanned.
- Private (`fn …`, no `pub`) functions are deliberately excluded —
  the audit targets the public production surface.
