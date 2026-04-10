//! Tasks module — task ledger and lifecycle management.
//!
//! Provides the durable task ledger for tracking spawned/detached work
//! through its lifecycle (queued -> running -> succeeded/failed/timed_out/cancelled/lost).

pub const ledger = @import("ledger.zig");
pub const delivery = @import("delivery.zig");
pub const TaskStatus = ledger.TaskStatus;
pub const TaskEntry = ledger.TaskEntry;
pub const TaskLedger = ledger.TaskLedger;
pub const TaskDelivery = delivery.TaskDelivery;

test {
    _ = ledger;
    _ = delivery;
}

test "tasks root reexport" {
    _ = TaskStatus;
    _ = TaskEntry;
    _ = TaskLedger;
    _ = TaskDelivery;
}
