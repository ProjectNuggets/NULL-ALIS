//! Session module — canonical session identity and lane routing.
//!
//! Provides first-class session identity types, bidirectional key parsing and
//! formatting, and ownership validation for the session subsystem.

pub const identity = @import("identity.zig");
pub const SessionIdentity = identity.SessionIdentity;
pub const SessionLane = identity.SessionLane;
pub const parseSessionKey = identity.parseSessionKey;
pub const formatSessionKey = identity.formatSessionKey;
pub const isOwnedBy = identity.isOwnedBy;

test {
    _ = identity;
}
