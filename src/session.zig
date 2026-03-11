//! Session Manager — persistent in-process Agent sessions.
//!
//! Replaces subprocess spawning with reusable Agent instances keyed by
//! session_key (e.g. "telegram:chat123"). Each session maintains its own
//! conversation history across turns.
//!
//! Thread safety: SessionManager.mutex guards the sessions map (short hold),
//! Session.mutex serializes turn() per session (may be long). Different
//! sessions are processed in parallel.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const Agent = @import("agent/root.zig").Agent;
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const memory_mod = @import("memory/root.zig");
const Memory = memory_mod.Memory;
const observability = @import("observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const MultiObserver = observability.MultiObserver;
const tools_mod = @import("tools/root.zig");
const Tool = tools_mod.Tool;
const SecurityPolicy = @import("security/policy.zig").SecurityPolicy;
const log = std.log.scoped(.session);
const SESSION_LOCK_WAIT_STAGE = "session_lock_wait";
const SESSION_LOCK_WAIT_WARN_MS: u64 = 50;

// ═══════════════════════════════════════════════════════════════════════════
// Session
// ═══════════════════════════════════════════════════════════════════════════

pub const Session = struct {
    agent: Agent,
    created_at: i64,
    last_active: i64,
    last_consolidated: u64 = 0,
    session_key: []const u8, // owned copy
    turn_count: u64,
    turn_observers: [2]Observer,
    turn_observer_multi: MultiObserver,
    mutex: std.Thread.Mutex,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        self.agent.deinit();
        allocator.free(self.session_key);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SessionManager
// ═══════════════════════════════════════════════════════════════════════════

pub const SessionManager = struct {
    allocator: Allocator,
    config: *const Config,
    provider: Provider,
    tools: []const Tool,
    mem: ?Memory,
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*memory_mod.cache.ResponseCache = null,
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    observer: Observer,
    policy: ?*const SecurityPolicy = null,

    mutex: std.Thread.Mutex,
    sessions: std.StringHashMapUnmanaged(*Session),

    pub const ProcessMessageOptions = struct {
        message_turn_context: ?tools_mod.MessageTurnContext = null,
        turn_origin: tools_mod.TurnOrigin = .user,
        progress_observer: ?Observer = null,
    };

    pub fn init(
        allocator: Allocator,
        config: *const Config,
        provider: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
        session_store: ?memory_mod.SessionStore,
        response_cache: ?*memory_mod.cache.ResponseCache,
    ) SessionManager {
        tools_mod.bindMemoryTools(tools, mem);

        return .{
            .allocator = allocator,
            .config = config,
            .provider = provider,
            .tools = tools,
            .mem = mem,
            .session_store = session_store,
            .response_cache = response_cache,
            .observer = observer_i,
            .mutex = .{},
            .sessions = .{},
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
    }

    /// Find or create a session for the given key. Thread-safe.
    pub fn getOrCreate(self: *SessionManager, session_key: []const u8) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_key)) |session| {
            session.last_active = std.time.timestamp();
            return session;
        }

        // Create new session
        const owned_key = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(owned_key);

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);

        var agent = try Agent.fromConfig(
            self.allocator,
            self.config,
            self.provider,
            self.tools,
            self.mem,
            self.observer,
        );
        agent.policy = self.policy;
        agent.session_store = self.session_store;
        agent.response_cache = self.response_cache;
        agent.mem_rt = self.mem_rt;
        agent.memory_session_id = owned_key;

        session.* = .{
            .agent = agent,
            .created_at = std.time.timestamp(),
            .last_active = std.time.timestamp(),
            .last_consolidated = 0,
            .session_key = owned_key,
            .turn_count = 0,
            .turn_observers = .{ self.observer, self.observer },
            .turn_observer_multi = .{ .observers = &.{} },
            .mutex = .{},
        };
        // From here, session owns agent — must deinit on error.
        errdefer session.agent.deinit();

        // Restore persisted conversation history from session store
        if (self.session_store) |store| {
            const entries = store.loadMessages(self.allocator, session_key) catch &.{};
            if (entries.len > 0) {
                session.agent.loadHistory(entries) catch {};
                session.agent.enforceHistoryBounds();
                for (entries) |entry| {
                    self.allocator.free(entry.role);
                    self.allocator.free(entry.content);
                }
                self.allocator.free(entries);
            }
        }

        try self.sessions.put(self.allocator, owned_key, session);
        return session;
    }

    fn slashCommandName(message: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (trimmed.len <= 1 or trimmed[0] != '/') return null;

        const body = trimmed[1..];
        var split_idx: usize = 0;
        while (split_idx < body.len) : (split_idx += 1) {
            const ch = body[split_idx];
            if (ch == ':' or ch == ' ' or ch == '\t') break;
        }
        if (split_idx == 0) return null;
        return body[0..split_idx];
    }

    fn slashClearsSession(message: []const u8) bool {
        const cmd = slashCommandName(message) orelse return false;
        return std.ascii.eqlIgnoreCase(cmd, "new") or
            std.ascii.eqlIgnoreCase(cmd, "reset") or
            std.ascii.eqlIgnoreCase(cmd, "restart");
    }

    /// Process a message within a session context.
    /// Finds or creates the session, locks it, runs agent.turn(), returns owned response.
    pub fn processMessage(self: *SessionManager, session_key: []const u8, content: []const u8, conversation_context: ?ConversationContext) ![]const u8 {
        return self.processMessageWithContext(session_key, content, conversation_context, .{});
    }

    pub fn processMessageWithToolContext(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        message_turn_context: ?tools_mod.MessageTurnContext,
    ) ![]const u8 {
        return self.processMessageWithContext(session_key, content, conversation_context, .{
            .message_turn_context = message_turn_context,
        });
    }

    pub fn processMessageWithContext(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        options: ProcessMessageOptions,
    ) ![]const u8 {
        const total_start_ms = std.time.milliTimestamp();
        const session = try self.getOrCreate(session_key);

        const lock_wait_start_ms = std.time.milliTimestamp();
        session.mutex.lock();
        const lock_wait_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - lock_wait_start_ms));
        defer session.mutex.unlock();

        tools_mod.setMessageTurnContext(options.message_turn_context);
        defer tools_mod.clearMessageTurnContext();
        tools_mod.setTurnContext(.{
            .origin = options.turn_origin,
            .session_key = session_key,
            .provider = session.agent.default_provider,
            .model = session.agent.model_name,
        });
        defer tools_mod.clearTurnContext();

        // Set conversation context for this turn (Signal-specific for now)
        session.agent.conversation_context = conversation_context;
        defer session.agent.conversation_context = null;

        const base_observer = session.agent.observer;
        var progress_attached = false;
        if (options.progress_observer) |progress_observer| {
            session.turn_observers = .{ base_observer, progress_observer };
            session.turn_observer_multi.observers = session.turn_observers[0..];
            session.agent.observer = session.turn_observer_multi.observer();
            progress_attached = true;
        }
        defer if (progress_attached) {
            session.agent.observer = base_observer;
            session.turn_observer_multi.observers = &.{};
        };

        if (lock_wait_ms > 0) {
            const lock_wait_event = ObserverEvent{ .turn_stage = .{
                .stage = SESSION_LOCK_WAIT_STAGE,
                .duration_ms = lock_wait_ms,
            } };
            session.agent.observer.recordEvent(&lock_wait_event);
            if (lock_wait_ms >= SESSION_LOCK_WAIT_WARN_MS) {
                log.warn("session.lock_wait session={s} wait_ms={d}", .{ session_key, lock_wait_ms });
            }
        }

        const agent_start_ms = std.time.milliTimestamp();
        const response = try (&session.agent).turn(content);
        const agent_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - agent_start_ms));
        session.turn_count += 1;
        session.last_active = std.time.timestamp();

        // Track consolidation timestamp
        if (session.agent.last_turn_compacted) {
            session.last_consolidated = @intCast(@max(0, std.time.timestamp()));
        }

        // Persist messages via session store
        const persist_start_ms = std.time.milliTimestamp();
        if (self.session_store) |store| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (slashClearsSession(trimmed)) {
                // Clear persisted messages on session reset
                store.clearMessages(session_key) catch {};
                // Clear stale auto-saved memories
                store.clearAutoSaved(session_key) catch {};
            } else if (!std.mem.startsWith(u8, trimmed, "/")) {
                // Persist user + assistant messages (skip slash commands)
                store.saveMessage(session_key, "user", content) catch {};
                store.saveMessage(session_key, "assistant", response) catch {};
            }
        }
        const persist_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - persist_start_ms));
        const total_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - total_start_ms));
        log.info("message.process session={s} agent_ms={d} persist_ms={d} total_ms={d}", .{
            session_key,
            agent_duration_ms,
            persist_duration_ms,
            total_duration_ms,
        });

        return response;
    }

    /// Number of active sessions.
    pub fn sessionCount(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }

    /// Evict sessions idle longer than max_idle_secs. Returns number evicted.
    pub fn evictIdle(self: *SessionManager, max_idle_secs: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var evicted: usize = 0;

        // Collect keys to remove (can't modify map while iterating)
        var to_remove: std.ArrayListUnmanaged([]const u8) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            const idle_secs: u64 = @intCast(@max(0, now - session.last_active));
            if (idle_secs > max_idle_secs) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                const session = kv.value;
                session.deinit(self.allocator);
                self.allocator.destroy(session);
                evicted += 1;
            }
        }

        return evicted;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;
var test_noop_observer_impl = observability.NoopObserver{};

// ---------------------------------------------------------------------------
// MockProvider — returns a fixed response, no network calls
// ---------------------------------------------------------------------------

const MockProvider = struct {
    response: []const u8,

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
    };

    fn provider(self: *MockProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return self.response;
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn mockDeinit(_: *anyopaque) void {}
};

const CountingObserver = struct {
    event_count: u32 = 0,
    saw_turn_stage: bool = false,

    const vtable = Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
    };

    fn observer(self: *CountingObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *CountingObserver {
        return @ptrCast(@alignCast(ptr));
    }

    fn recordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self = resolve(ptr);
        self.event_count += 1;
        switch (event.*) {
            .turn_stage => self.saw_turn_stage = true,
            else => {},
        }
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "counting";
    }
};

/// Create a test SessionManager with mock provider.
fn testSessionManager(allocator: Allocator, mock: *MockProvider, cfg: *const Config) SessionManager {
    return testSessionManagerWithMemory(allocator, mock, cfg, null, null);
}

fn testSessionManagerWithMemory(allocator: Allocator, mock: *MockProvider, cfg: *const Config, mem: ?Memory, session_store: ?memory_mod.SessionStore) SessionManager {
    return SessionManager.init(
        allocator,
        cfg,
        mock.provider(),
        &.{},
        mem,
        test_noop_observer_impl.observer(),
        session_store,
        null,
    );
}

fn testConfig() Config {
    return .{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .allocator = testing.allocator,
    };
}

// ---------------------------------------------------------------------------
// 1. Struct tests
// ---------------------------------------------------------------------------

test "SessionManager init/deinit — no leaks" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    sm.deinit();
}

test "getOrCreate creates new session for unknown key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("telegram:chat1");
    try testing.expect(session.turn_count == 0);
    try testing.expectEqualStrings("telegram:chat1", session.session_key);
}

test "getOrCreate returns same session for same key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("key1");
    const s2 = try sm.getOrCreate("key1");
    try testing.expect(s1 == s2); // pointer equality
}

test "getOrCreate creates separate sessions for different keys" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("telegram:a");
    const s2 = try sm.getOrCreate("discord:b");
    try testing.expect(s1 != s2);
}

test "sessionCount reflects active sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
    _ = try sm.getOrCreate("a");
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
    _ = try sm.getOrCreate("b");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
    _ = try sm.getOrCreate("a"); // existing
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

test "session has correct initial state" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:init");
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(!s.agent.has_system_prompt);
    try testing.expectEqual(@as(usize, 0), s.agent.historyLen());
}

// ---------------------------------------------------------------------------
// 2. processMessage tests
// ---------------------------------------------------------------------------

test "processMessage returns mock response" {
    var mock = MockProvider{ .response = "Hello from mock" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp = try sm.processMessage("user:1", "hi", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("Hello from mock", resp);
}

test "processMessage refreshes system prompt when conversation context is cleared" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const sender_uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    const with_context: ?ConversationContext = .{
        .channel = "signal",
        .sender_number = "+15551234567",
        .sender_uuid = sender_uuid,
        .group_id = null,
        .is_group = false,
    };

    const resp1 = try sm.processMessage("ctx:user", "first", with_context);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("ctx:user");
    try testing.expect(session.agent.history.items.len > 0);
    const sys1 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys1, "## Conversation Context") != null);
    try testing.expect(std.mem.indexOf(u8, sys1, sender_uuid) != null);

    const resp2 = try sm.processMessage("ctx:user", "second", null);
    defer testing.allocator.free(resp2);

    try testing.expect(session.agent.history.items.len > 0);
    const sys2 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys2, "## Conversation Context") == null);
    try testing.expect(std.mem.indexOf(u8, sys2, sender_uuid) == null);
}

test "processMessage updates last_active" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("user:2");
    const before = session.last_active;

    // Small sleep so timestamp changes
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const resp = try sm.processMessage("user:2", "hello", null);
    defer testing.allocator.free(resp);

    try testing.expect(session.last_active >= before);
}

test "processMessage increments turn_count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("user:3", "msg1", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("user:3");
    try testing.expectEqual(@as(u64, 1), session.turn_count);

    const resp2 = try sm.processMessage("user:3", "msg2", null);
    defer testing.allocator.free(resp2);
    try testing.expectEqual(@as(u64, 2), session.turn_count);
}

test "processMessage preserves session across calls" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("persist:1", "first", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("persist:1");
    // After first processMessage: system prompt + user msg + assistant response
    try testing.expect(session.agent.historyLen() > 0);

    const history_before = session.agent.historyLen();

    const resp2 = try sm.processMessage("persist:1", "second", null);
    defer testing.allocator.free(resp2);

    // History should have grown (user msg + assistant response added)
    try testing.expect(session.agent.historyLen() > history_before);
}

test "processMessage different keys — independent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp_a = try sm.processMessage("user:a", "hello a", null);
    defer testing.allocator.free(resp_a);

    const resp_b = try sm.processMessage("user:b", "hello b", null);
    defer testing.allocator.free(resp_b);

    const sa = try sm.getOrCreate("user:a");
    const sb = try sm.getOrCreate("user:b");
    try testing.expect(sa != sb);
    try testing.expectEqual(@as(u64, 1), sa.turn_count);
    try testing.expectEqual(@as(u64, 1), sb.turn_count);
}

test "processMessageWithContext forwards progress observer and restores base observer" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    var progress = CountingObserver{};
    const response = try sm.processMessageWithContext("progress:1", "hello", null, .{
        .progress_observer = progress.observer(),
    });
    defer testing.allocator.free(response);

    try testing.expect(progress.event_count > 0);
    try testing.expect(progress.saw_turn_stage);

    const session = try sm.getOrCreate("progress:1");
    try testing.expectEqualStrings("noop", session.agent.observer.getName());
}

test "agent turn emits observer events with counting observer" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("progress:direct");
    var progress = CountingObserver{};
    session.agent.observer = progress.observer();

    const response = try session.agent.turn("hello");
    defer testing.allocator.free(response);

    try testing.expect(progress.event_count > 0);
    try testing.expect(progress.saw_turn_stage);
}

test "processMessage /new clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    // Seed autosave entries for two different sessions.
    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /new with model clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new gpt-4o-mini", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /reset clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/reset", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /restart clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/restart", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage with sqlite memory first turn does not panic" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const resp = try sm.processMessage("signal:session:1", "hello", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("ok", resp);

    const entries = try sqlite_mem.loadMessages(testing.allocator, "signal:session:1");
    defer {
        for (entries) |entry| {
            testing.allocator.free(entry.role);
            testing.allocator.free(entry.content);
        }
        testing.allocator.free(entries);
    }
    // One user + one assistant message should be persisted.
    try testing.expect(entries.len >= 2);
}

test "session restore enforces max history bound before first turn" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.agent.max_history_messages = 5;

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var idx: usize = 0;
    while (idx < 12) : (idx += 1) {
        const role = if ((idx % 2) == 0) "user" else "assistant";
        const msg = try std.fmt.allocPrint(testing.allocator, "message-{d}", .{idx});
        defer testing.allocator.free(msg);
        try store.saveMessage("restore:trim", role, msg);
    }

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, sqlite_mem.memory(), store);
    defer sm.deinit();

    const session = try sm.getOrCreate("restore:trim");
    try testing.expectEqual(@as(usize, 5), session.agent.historyLen());
    const last = session.agent.history.items[session.agent.history.items.len - 1].content;
    try testing.expectEqualStrings("message-11", last);
}

// ---------------------------------------------------------------------------
// 3. evictIdle tests
// ---------------------------------------------------------------------------

test "evictIdle removes old sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("old:1");
    // Force last_active to the past
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(500);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "evictIdle preserves recent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("recent:1");
    // This session was just created, last_active is now

    const evicted = sm.evictIdle(3600); // 1 hour threshold
    try testing.expectEqual(@as(usize, 0), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle returns correct count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create 3 sessions, make 2 old
    const s1 = try sm.getOrCreate("s1");
    const s2 = try sm.getOrCreate("s2");
    _ = try sm.getOrCreate("s3");

    s1.last_active = std.time.timestamp() - 2000;
    s2.last_active = std.time.timestamp() - 2000;
    // s3 stays recent

    const evicted = sm.evictIdle(1000);
    try testing.expectEqual(@as(usize, 2), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle with no sessions returns 0" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.evictIdle(60));
}

// ---------------------------------------------------------------------------
// 4. Thread safety tests
// ---------------------------------------------------------------------------

test "concurrent getOrCreate same key — single Session created" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;

    for (0..num_threads) |t| {
        handles[t] = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
            fn run(mgr: *SessionManager, out: **Session) void {
                out.* = mgr.getOrCreate("shared:key") catch unreachable;
            }
        }.run, .{ &sm, &sessions[t] });
    }

    for (handles) |h| h.join();

    // All threads should have gotten the same session pointer
    for (1..num_threads) |i| {
        try testing.expect(sessions[0] == sessions[i]);
    }
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "concurrent getOrCreate different keys — separate Sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "key:{d}", .{t}) catch "?";
        handles[t] = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, out: **Session) void {
                out.* = mgr.getOrCreate(key) catch unreachable;
            }
        }.run, .{ &sm, keys[t], &sessions[t] });
    }

    for (handles) |h| h.join();

    // All sessions should be distinct
    for (0..num_threads) |i| {
        for (i + 1..num_threads) |j| {
            try testing.expect(sessions[i] != sessions[j]);
        }
    }
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage different keys — no crash" {
    var mock = MockProvider{ .response = "concurrent ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "conc:{d}", .{t}) catch "?";
        handles[t] = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator) void {
                for (0..3) |_| {
                    const resp = mgr.processMessage(key, "hello", null) catch return;
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator });
    }

    for (handles) |h| h.join();
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage with sqlite memory does not panic" {
    var mock = MockProvider{ .response = "concurrent sqlite ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][24]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;
    var failed = std.atomic.Value(bool).init(false);

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "sqlite-conc:{d}", .{t}) catch "?";
        // SQLite+FTS parsing can exceed 256 KiB stack on some macOS test runs.
        // Use a larger stack here to keep this concurrency regression deterministic.
        handles[t] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator, failed_flag: *std.atomic.Value(bool)) void {
                for (0..5) |_| {
                    const resp = mgr.processMessage(key, "hello sqlite", null) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator, &failed });
    }

    for (handles) |h| h.join();
    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());

    const count = try mem.count();
    try testing.expect(count > 0);
}

// ---------------------------------------------------------------------------
// 5. Session consolidation tests
// ---------------------------------------------------------------------------

test "session last_consolidated defaults to zero" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:consolidation");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
}

test "session initial state includes last_consolidated" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:fields");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(s.created_at > 0);
    try testing.expect(s.last_active > 0);
}
