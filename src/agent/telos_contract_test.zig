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

// ── Invariants filled by later Slice-1 tasks. Kept as a visible checklist so a
// half-built slice still reads as "these are the guarantees, here is who owns
// each": ──
//   T1  [tasks 3,5] — single-source injection: `buildTelosBlock` renders telos
//                     rows; a filed telos referent is not also injected raw.
//   T2  [task 6]    — filing supersedes: `resolveContradiction` sets valid_to on
//                     the source row → excluded by `MEMORIES_VALIDITY_FILTER`.
//   T2b [task 4]    — the M3 archive/forget cascade must NOT close a telos row via
//                     a byte-identical raw duplicate; only explicit telos-key curation.
//   T3  [task 6]    — precedence telos > raw > WM, enforced at file-time by T2.
//   T4  [Slice 2]   — human authorship: rows enter via `wish/telos/*` proposals,
//                     approved through `execution_mode`; the loop never auto-files.
//   T6  [Slice 2]   — freshness: stale telos rows demote pinned → retrieval-gated.
