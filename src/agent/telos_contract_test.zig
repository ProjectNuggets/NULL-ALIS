//! TELOS Contract — executable form of `docs/telos-contract.md`.
//!
//! Normative: code and the contract doc must agree (change one, change both).
//! This file is the contract-first anchor of the TELOS Slice 1 build — it lands
//! BEFORE the feature code it guards. Each invariant is filled in by the task
//! that implements it (task id in brackets); until then it is a visible
//! checklist so the contract is executable end-to-end and cannot silently drift.
//!
//! Hosted into the build via `_ = @import("telos_contract_test.zig")` in a test
//! block of `memory_loader.zig`, so it compiles+runs under BOTH the default
//! `zig build` and the all-engine `zig build test` — the stub-parity gate.

const std = @import("std");
const memory_loader = @import("memory_loader.zig");
const memory_root = @import("../memory/root.zig");

// ── T5 — axis honesty. Telos rows are `memory_type = core`, a DURABLE type;
// durability is a property of memory_type only (memory-contract Invariant 5). ──
test "T5: telos rows use a durable memory_type (core)" {
    try std.testing.expect(memory_root.isDurableMemoryType("core"));
}

// ── Namespace. `durable_fact/telos/<type>/<id>` is recognized as a durable
// fact for free because `isDurableFactKey` is prefix-only. The enforcement map
// and the T1/T2 substrate all assume this holds. ──
test "namespace: durable_fact/telos/* is a durable-fact key" {
    try std.testing.expect(memory_loader.isDurableFactKey("durable_fact/telos/goal/42"));
    try std.testing.expect(memory_loader.isDurableFactKey("durable_fact/telos/mission/0"));
    // A non-telos durable fact still qualifies; a bare (non-durable_fact) key does not.
    try std.testing.expect(memory_loader.isDurableFactKey("durable_fact/hrs_contact"));
    try std.testing.expect(!memory_loader.isDurableFactKey("telos/goal/42"));
}

// ── T2b — telos rows are protected from the content_hash dedup cascade.
// `isTelosKey` is the protected-key hook; `phase05BackfillExactDedup` skips telos
// losers so a byte-identical raw duplicate cannot supersede a curated telos row
// (docs/telos-contract.md). Behavioral proof (dedup + real DB) lives in
// zaki_state.zig; here we pin the predicate the cascade consults. ──
test "T2b: isTelosKey recognizes the telos namespace, rejects others" {
    try std.testing.expect(memory_root.isTelosKey("durable_fact/telos/goal/0"));
    try std.testing.expect(memory_root.isTelosKey("durable_fact/telos/mission/0"));
    try std.testing.expect(!memory_root.isTelosKey("durable_fact/other_fact"));
    try std.testing.expect(!memory_root.isTelosKey("durable_fact/telosX/0"));
    try std.testing.expect(!memory_root.isTelosKey("telos/goal/0"));
}

// ── T1 — single-source injection (pure discriminators). A telos referent rides
// the durable substrate (isDurableFactKey true) AND is routed to the curated
// <telos> block rather than the generic durable-fact injection path (isTelosKey
// true). These two predicates together are what make injection single-source:
// buildTelosBlock consumes exactly the isTelosKey rows, and the filing path
// supersedes their raw source. The behavioral proof that the raw source is NOT
// also injected lives in the PG tests (zaki_state.zig `fileTelosFact`/supersede
// + the extended live drive B1/B3); here we pin the discriminators. ──
test "T1: telos keys ride the durable substrate AND route to the telos block" {
    // durable substrate (so aliveness/decay/GDPR all apply for free):
    try std.testing.expect(memory_loader.isDurableFactKey("durable_fact/telos/mission/0"));
    // routed to the curated block, distinct from a generic durable fact:
    try std.testing.expect(memory_root.isTelosKey("durable_fact/telos/mission/0"));
    try std.testing.expect(!memory_root.isTelosKey("durable_fact/generic_pref"));
}

// ── T3 — precedence telos > raw durable_fact > WM is enforced at FILE-TIME by T2
// (the source raw row is superseded, so at query time only the telos copy is
// live). That is a PG/txn property; the behavioral proof is the PG supersede test
// in zaki_state.zig (`fileTelosFact` sets valid_to on the raw source). The pure
// invariant we can pin here: the classifier that underpins the ordering treats a
// telos key as strictly more specific than a bare durable_fact key. ──
test "T3: telos key is strictly more specific than a bare durable_fact key" {
    // both are durable facts...
    try std.testing.expect(memory_loader.isDurableFactKey("durable_fact/telos/goal/0"));
    try std.testing.expect(memory_loader.isDurableFactKey("durable_fact/goal_note"));
    // ...but only the telos one is telos (the discriminator that wins precedence):
    try std.testing.expect(memory_root.isTelosKey("durable_fact/telos/goal/0"));
    try std.testing.expect(!memory_root.isTelosKey("durable_fact/goal_note"));
}

// ── T6 — freshness (Slice 1.1). A curated telos row past the reconfirmation
// horizon is rendered with an age annotation so the model discounts stale intent.
// `telosStaleDays` is the pure decision fn; the renderer behavior (fresh clean,
// stale annotated) is pinned in memory_loader.zig's renderTelosBlock tests. The
// pinned→retrieval-gated DEMOTION remains Slice 2. ──
test "T6: telosStaleDays annotates only rows past the horizon; fail-soft otherwise" {
    const base: i64 = 1_000_000_000;
    try std.testing.expectEqual(@as(?u64, null), memory_loader.telosStaleDays("1000000000", base + 10 * 86_400)); // fresh
    try std.testing.expectEqual(@as(?u64, 200), memory_loader.telosStaleDays("1000000000", base + 200 * 86_400)); // stale
    try std.testing.expectEqual(@as(?u64, null), memory_loader.telosStaleDays("0", base + 9_999 * 86_400)); // sentinel
    try std.testing.expectEqual(@as(?u64, null), memory_loader.telosStaleDays("garbage", base)); // fail-soft
}

// ── Invariants covered by PG behavioral tests (named here so the "executable
// form" claim is honest — pure predicates asserted above, DB behavior below): ──
//   T2  [PG] — filing supersedes: `fileTelosFact`→`setMemoryInvalidation` sets
//              valid_to on the source row → excluded by `MEMORIES_VALIDITY_FILTER`
//              (zaki_state.zig telos supersede test + live-drive B3).
//   T2b [✓]  — telos rows shielded from the content_hash dedup AND the M3
//              information-scoped archive/forget cascade (isTelosKey +
//              phase05BackfillExactDedup + informationScopedSweep guards;
//              zaki_state.zig telos-twin-shield tests + live-drive B3).
//   T4  [Slice 2] — human authorship: rows enter via `wish/telos/*` proposals,
//                   approved through `execution_mode`; the loop never auto-files.
