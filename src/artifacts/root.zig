//! Wave 2C — canvas/artifacts backend: module root + test aggregation.
//!
//! Importing this module from `src/root.zig` (or wherever the test
//! gathering happens) pulls every artifacts test into the default
//! `zig build test` run.

pub const types = @import("types.zig");
pub const diff = @import("diff.zig");
pub const sanitizer = @import("sanitizer.zig");
pub const store = @import("store.zig");

test {
    _ = @import("types.zig");
    _ = @import("diff.zig");
    _ = @import("sanitizer.zig");
    _ = @import("store.zig");
}
