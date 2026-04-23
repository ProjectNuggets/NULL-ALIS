//! Entitlement — per-session billing + capability state.
//!
//! Source of truth is the zaki-prod BFF: Stripe/Creem webhooks update
//! `zaki_users.plan_tier` / `status` / `period_end`, and the
//! `/api/v1/users/provision` response (S2.1) carries those fields across
//! to nullalis. Nullalis stores the resolved `Entitlement` per-session
//! on `RuntimeTurnContext` so tool preflight, chat-stream entry,
//! scheduler dispatch, and integration calls (S2.3-S2.6) can check it
//! without re-resolving.
//!
//! Design constraint: the default `Entitlement{}` value must be safe for
//! deployments that haven't finished the BFF plumbing yet — that means
//! "pro active, no hard caps." This keeps tests green and existing
//! production paths working until the revocation webhook (S2.7) + the
//! 4 enforcement sites (S2.3-S2.6) all land. When the Entitlement is
//! pushed from the BFF for a real user session, the actual tier +
//! status replaces the default.
//!
//! Budgets are expressed in CostClass weight units (A=1, B=5, C=25 per
//! `tools/metadata.zig`). That keeps a single cheap memory_list call
//! meaningfully distinct from one image_generate call. Concrete $
//! translation lives on the BFF / billing side — nullalis only decides
//! "over weight cap or not."

const std = @import("std");

pub const Tier = enum {
    free,
    pro,
    team,
    enterprise,

    pub fn toSlice(self: Tier) []const u8 {
        return switch (self) {
            .free => "free",
            .pro => "pro",
            .team => "team",
            .enterprise => "enterprise",
        };
    }

    pub fn fromSlice(s: []const u8) ?Tier {
        const trimmed = std.mem.trim(u8, s, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "free")) return .free;
        if (std.ascii.eqlIgnoreCase(trimmed, "pro")) return .pro;
        if (std.ascii.eqlIgnoreCase(trimmed, "team")) return .team;
        if (std.ascii.eqlIgnoreCase(trimmed, "enterprise")) return .enterprise;
        return null;
    }
};

pub const Status = enum {
    /// Subscription current; full entitlement applies.
    active,
    /// Payment failed but grace window still open; treat as active for
    /// a short period while the BFF retries the charge.
    past_due,
    /// User cancelled; period_end still in the future means active until
    /// that timestamp, then drops to free.
    canceled,
    /// Period expired without renewal; treat as free tier regardless of
    /// stored plan_tier.
    expired,

    pub fn toSlice(self: Status) []const u8 {
        return switch (self) {
            .active => "active",
            .past_due => "past_due",
            .canceled => "canceled",
            .expired => "expired",
        };
    }

    pub fn fromSlice(s: []const u8) ?Status {
        const trimmed = std.mem.trim(u8, s, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "active")) return .active;
        if (std.ascii.eqlIgnoreCase(trimmed, "past_due")) return .past_due;
        if (std.ascii.eqlIgnoreCase(trimmed, "canceled")) return .canceled;
        if (std.ascii.eqlIgnoreCase(trimmed, "cancelled")) return .canceled; // UK spelling from some providers
        if (std.ascii.eqlIgnoreCase(trimmed, "expired")) return .expired;
        return null;
    }

    /// Does this billing status permit paid-tier capabilities?
    /// `.active` and `.past_due` (in the grace window) do; others don't.
    /// The caller still has to check `period_end` against now for the
    /// `.canceled` edge case where the user's paid period hasn't elapsed.
    pub fn paidEffective(self: Status) bool {
        return switch (self) {
            .active, .past_due => true,
            .canceled, .expired => false,
        };
    }
};

/// Hard caps and feature gates per tier. Values are nominal; operator
/// can re-tune via config in a future iteration without ABI break since
/// Limits is resolved per-tier at the nullalis boundary.
pub const Limits = struct {
    /// Monthly cost-weight budget. Defaults to unbounded so an
    /// un-initialized Entitlement never accidentally blocks real users.
    monthly_weight_budget: u64 = std.math.maxInt(u64),
    /// Daily budget for autonomous (scheduler / heartbeat / proactive)
    /// turns. Prevents runaway cost from misconfigured cron jobs.
    daily_autonomous_weight_budget: u64 = std.math.maxInt(u64),
    /// Can this tier register proactive automation (cron jobs, heartbeat
    /// responses)?
    proactive_enabled: bool = true,
    /// Can this tier call Composio / MCP / third-party integrations?
    integrations_enabled: bool = true,
    /// Cap on concurrent active scheduled jobs (the aspirational "64 per
    /// user" from the reliability runbook — S2.11 enforces via this).
    active_jobs_cap: u32 = 64,
};

/// Per-session billing + capability state. Default construction yields
/// an "unlimited pro active" shape so tests + pre-wired code paths
/// continue to behave as before S2.1-S2.7 plumbing lands.
pub const Entitlement = struct {
    tier: Tier = .pro,
    status: Status = .active,
    /// Unix seconds; null = no known end (unlimited / provision failed
    /// to populate).
    period_end_unix: ?i64 = null,
    limits: Limits = .{},

    /// Does this entitlement allow any paid-tier action right now?
    /// Returns false only for `.canceled` past `period_end_unix` and
    /// `.expired`. Keeps `.past_due` users functional in the grace window.
    pub fn canAct(self: Entitlement, now_unix: i64) bool {
        return switch (self.status) {
            .active, .past_due => true,
            .canceled => if (self.period_end_unix) |end| now_unix < end else false,
            .expired => false,
        };
    }

    /// The tier's effective entitlement when you include billing-status
    /// collapse: a canceled user past period_end effectively reverts to
    /// the free tier regardless of stored `tier`.
    pub fn effectiveTier(self: Entitlement, now_unix: i64) Tier {
        if (self.canAct(now_unix)) return self.tier;
        return .free;
    }

    /// Resolve the canonical Limits for a tier. S2.3-S2.6 enforcement
    /// sites call `defaultsFor(ent.effectiveTier(now))` rather than
    /// reading `ent.limits` directly so a canceled-pro user sees free
    /// limits automatically, no re-plumbing required.
    pub fn defaultsFor(tier: Tier) Entitlement {
        return .{
            .tier = tier,
            .status = .active,
            .period_end_unix = null,
            .limits = limitsFor(tier),
        };
    }

    pub fn limitsFor(tier: Tier) Limits {
        return switch (tier) {
            .free => .{
                // ~100 cheap ops OR ~20 medium OR ~4 expensive per month.
                // Tuned to feel restrictive but not insulting; real product
                // balance lives in the BFF plan definition + marketing page.
                .monthly_weight_budget = 500,
                .daily_autonomous_weight_budget = 10,
                .proactive_enabled = false,
                .integrations_enabled = false,
                .active_jobs_cap = 4,
            },
            .pro => .{
                .monthly_weight_budget = 50_000,
                .daily_autonomous_weight_budget = 500,
                .proactive_enabled = true,
                .integrations_enabled = true,
                .active_jobs_cap = 64,
            },
            .team => .{
                .monthly_weight_budget = 250_000,
                .daily_autonomous_weight_budget = 2_500,
                .proactive_enabled = true,
                .integrations_enabled = true,
                .active_jobs_cap = 256,
            },
            .enterprise => .{
                // Unlimited by default; contract overrides per customer.
                .monthly_weight_budget = std.math.maxInt(u64),
                .daily_autonomous_weight_budget = std.math.maxInt(u64),
                .proactive_enabled = true,
                .integrations_enabled = true,
                .active_jobs_cap = std.math.maxInt(u32),
            },
        };
    }

    /// Called by the BFF-facing provision handler (future S2.1 landing
    /// point) to install the real user's entitlement for a session. The
    /// BFF sends strings; this function validates + collapses to the
    /// typed form. Invalid or missing fields fall back to free/expired
    /// so we fail-closed rather than accidentally upgrading a user.
    pub fn fromProvision(tier_str: ?[]const u8, status_str: ?[]const u8, period_end_unix: ?i64) Entitlement {
        const tier = if (tier_str) |t| Tier.fromSlice(t) orelse .free else .free;
        const status = if (status_str) |s| Status.fromSlice(s) orelse .expired else .expired;
        return .{
            .tier = tier,
            .status = status,
            .period_end_unix = period_end_unix,
            .limits = limitsFor(tier),
        };
    }
};

// ── Per-user resolver ───────────────────────────────────────────────
//
// Pluggable lookup from a user_id string to the canonical Entitlement.
// S2.1 (BFF provision push) will populate the backing store; the daemon
// and gateway chat-stream call this at enforcement time.
//
// Until S2.1 lands, the resolver returns null so callers fall back to
// the default Entitlement{} (pro/active/unlimited). That preserves
// pre-enforcement behavior and gives S2.1 a concrete wire-up target
// without further refactoring.

/// Signature for the pluggable resolver. Implementations must be
/// allocator-free and thread-safe — called from both the gateway hot
/// path and the daemon scheduler tick.
pub const ResolveFn = *const fn (user_id: []const u8) ?Entitlement;

var resolver: ?ResolveFn = null;

pub fn setResolver(fn_ptr: ResolveFn) void {
    resolver = fn_ptr;
}

pub fn clearResolver() void {
    resolver = null;
}

/// Return the stored entitlement for a user, or null when no resolver
/// is registered / the user is unknown. Callers should fall back to
/// the `Entitlement{}` default (pro/active/unlimited) on null so
/// pre-S2.1 deployments keep working.
pub fn resolveUserEntitlement(user_id: []const u8) ?Entitlement {
    if (resolver) |f| return f(user_id);
    return null;
}

// ── Default in-memory store (S2.1 + S2.7 backing) ──────────────────
//
// Production path: zaki-prod BFF calls `/api/v1/users/provision` with
// the user's tier/status/period_end, which the gateway turns into an
// `installEntitlement(user_id, ent)` call. Stripe webhook revocation
// lands at `/internal/entitlements/revoke` and uses the same install
// call. The default resolver (`defaultResolver`) reads from this map.
//
// Threadsafety: a single mutex guards all map mutations + reads. The
// map stores OWNED user_id strings; installEntitlement duplicates the
// caller's slice so Entitlement survives request-lifetime input.

var store_mutex: std.Thread.Mutex = .{};
var store_map: std.StringHashMapUnmanaged(Entitlement) = .{};
var store_allocator: ?std.mem.Allocator = null;

/// Register the in-memory entitlement store as the active resolver.
/// Idempotent — safe to call multiple times during startup. Must be
/// paired with `resetDefaultStore` in tests to keep state isolated.
pub fn useDefaultResolver(allocator: std.mem.Allocator) void {
    store_mutex.lock();
    defer store_mutex.unlock();
    if (store_allocator == null) store_allocator = allocator;
    resolver = &defaultResolver;
}

fn defaultResolver(user_id: []const u8) ?Entitlement {
    store_mutex.lock();
    defer store_mutex.unlock();
    return store_map.get(user_id);
}

/// Persist (or replace) a user's entitlement in the in-memory store.
/// Called from gateway handlers that process provision + revocation
/// events. The `user_id` slice is duplicated; callers may free their
/// buffer after the call returns.
pub fn installEntitlement(user_id: []const u8, ent: Entitlement) !void {
    store_mutex.lock();
    defer store_mutex.unlock();
    const alloc = store_allocator orelse return error.DefaultStoreNotInitialized;
    const gop = try store_map.getOrPut(alloc, user_id);
    if (!gop.found_existing) {
        gop.key_ptr.* = try alloc.dupe(u8, user_id);
    }
    gop.value_ptr.* = ent;
}

/// Clear the in-memory store. Test-only; production callers should
/// never invoke this (revocation replaces entries via
/// `installEntitlement`).
pub fn resetDefaultStore() void {
    store_mutex.lock();
    defer store_mutex.unlock();
    if (store_allocator) |alloc| {
        var it = store_map.iterator();
        while (it.next()) |entry| alloc.free(@constCast(entry.key_ptr.*));
        store_map.deinit(alloc);
    }
    store_map = .{};
}

test "resolver defaults to null" {
    clearResolver();
    try std.testing.expect(resolveUserEntitlement("any") == null);
}

test "default resolver roundtrips installEntitlement (S2.1)" {
    resetDefaultStore();
    defer resetDefaultStore();
    clearResolver();
    defer clearResolver();

    useDefaultResolver(std.testing.allocator);
    try installEntitlement("99", Entitlement.defaultsFor(.free));
    const got = resolveUserEntitlement("99") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Tier.free, got.tier);
    try std.testing.expectEqual(Status.active, got.status);

    // Revocation via re-install.
    try installEntitlement("99", Entitlement.fromProvision("free", "canceled", 0));
    const after = resolveUserEntitlement("99") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Status.canceled, after.status);
    // canAct at t=1 should collapse to false (period_end=0 < 1).
    try std.testing.expect(!after.canAct(1));
}

test "default resolver returns null for unknown users" {
    resetDefaultStore();
    defer resetDefaultStore();
    clearResolver();
    defer clearResolver();

    useDefaultResolver(std.testing.allocator);
    try std.testing.expect(resolveUserEntitlement("nobody-home") == null);
}

test "resolver honors set fn" {
    const Impl = struct {
        fn resolve(user_id: []const u8) ?Entitlement {
            if (std.mem.eql(u8, user_id, "42")) {
                return Entitlement.defaultsFor(.free);
            }
            return null;
        }
    };
    setResolver(&Impl.resolve);
    defer clearResolver();
    const found = resolveUserEntitlement("42") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Tier.free, found.tier);
    try std.testing.expect(resolveUserEntitlement("missing") == null);
}

// ── Tests ───────────────────────────────────────────────────────────

test "Tier roundtrip via slice" {
    try std.testing.expectEqual(Tier.free, Tier.fromSlice("free").?);
    try std.testing.expectEqual(Tier.pro, Tier.fromSlice("Pro").?);
    try std.testing.expectEqual(Tier.team, Tier.fromSlice("TEAM").?);
    try std.testing.expectEqual(Tier.enterprise, Tier.fromSlice(" enterprise ").?);
    try std.testing.expect(Tier.fromSlice("unknown") == null);
    try std.testing.expectEqualStrings("pro", Tier.pro.toSlice());
}

test "Status accepts US + UK cancelled spelling" {
    try std.testing.expectEqual(Status.canceled, Status.fromSlice("canceled").?);
    try std.testing.expectEqual(Status.canceled, Status.fromSlice("cancelled").?);
    try std.testing.expectEqual(Status.active, Status.fromSlice("Active").?);
    try std.testing.expect(Status.fromSlice("unknown") == null);
}

test "Status paidEffective" {
    try std.testing.expect(Status.active.paidEffective());
    try std.testing.expect(Status.past_due.paidEffective());
    try std.testing.expect(!Status.canceled.paidEffective());
    try std.testing.expect(!Status.expired.paidEffective());
}

test "Entitlement default is pro active unlimited" {
    const ent = Entitlement{};
    const limits = Entitlement.limitsFor(.pro);
    _ = limits; // ensure the type resolves
    try std.testing.expectEqual(Tier.pro, ent.tier);
    try std.testing.expectEqual(Status.active, ent.status);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), ent.limits.monthly_weight_budget);
    try std.testing.expect(ent.canAct(std.time.timestamp()));
}

test "canceled user past period_end cannot act" {
    const ent = Entitlement{
        .tier = .pro,
        .status = .canceled,
        .period_end_unix = 1000,
        .limits = Entitlement.limitsFor(.pro),
    };
    try std.testing.expect(!ent.canAct(2000));
    try std.testing.expect(ent.canAct(500));
}

test "expired user always blocked regardless of period_end" {
    const ent = Entitlement{
        .tier = .pro,
        .status = .expired,
        .period_end_unix = std.math.maxInt(i64),
        .limits = Entitlement.limitsFor(.pro),
    };
    try std.testing.expect(!ent.canAct(0));
}

test "effectiveTier collapses canceled-past-end to free" {
    const ent = Entitlement{
        .tier = .pro,
        .status = .canceled,
        .period_end_unix = 1000,
        .limits = Entitlement.limitsFor(.pro),
    };
    try std.testing.expectEqual(Tier.free, ent.effectiveTier(2000));
    try std.testing.expectEqual(Tier.pro, ent.effectiveTier(500));
}

test "limitsFor tiers scale as expected" {
    const free = Entitlement.limitsFor(.free);
    const pro = Entitlement.limitsFor(.pro);
    const team = Entitlement.limitsFor(.team);
    try std.testing.expect(free.monthly_weight_budget < pro.monthly_weight_budget);
    try std.testing.expect(pro.monthly_weight_budget < team.monthly_weight_budget);
    try std.testing.expect(!free.proactive_enabled);
    try std.testing.expect(pro.proactive_enabled);
    try std.testing.expect(!free.integrations_enabled);
    try std.testing.expect(pro.integrations_enabled);
    try std.testing.expectEqual(@as(u32, 4), free.active_jobs_cap);
    try std.testing.expectEqual(@as(u32, 64), pro.active_jobs_cap);
}

test "fromProvision fails closed on invalid tier/status" {
    const ent = Entitlement.fromProvision("gold-plated", "whatever", null);
    try std.testing.expectEqual(Tier.free, ent.tier);
    try std.testing.expectEqual(Status.expired, ent.status);
}

test "fromProvision happy path for Pro active" {
    const ent = Entitlement.fromProvision("pro", "active", 1_735_689_600);
    try std.testing.expectEqual(Tier.pro, ent.tier);
    try std.testing.expectEqual(Status.active, ent.status);
    try std.testing.expectEqual(@as(i64, 1_735_689_600), ent.period_end_unix.?);
    try std.testing.expectEqual(@as(u64, 50_000), ent.limits.monthly_weight_budget);
}
