# Agent B: Phase 2 — Transport Native & Connection Pooling

## Preamble (Read Before Every Step)

**Project**: nullalis — Zig 0.15.2 vtable-driven autonomous agent runtime. 205 source files, ~146K LOC, 4,263+ tests.

**Branch**: Work on `transport-native-v1` (branch from `dogfood-stable`).

**Constraints**: Read `AGENTS.md`. All tests must pass. No breaking changes to `http_util.zig` public API — it remains the only transport facade. The `http_util.request_with_mode()` function is the sole entry point for all HTTP calls.

**What you're doing**: The native HTTP client (`src/http_native/`) exists but has no connection pooling — every request opens a fresh TCP+TLS connection with `Connection: close` hardcoded at `root.zig:308`. `PoolConfig` is defined in `types.zig` but completely unused. You are implementing connection pooling, then migrating remaining curl call sites to native where safe.

**Why**: curl subprocesses cost fork()+exec() per request. Connection pooling eliminates TLS handshake overhead for repeated calls to the same host (e.g., OpenAI API, Telegram API). Together these reduce latency by 50-200ms per request and eliminate process overhead.

## Key File References

| File | What | Key Lines |
|------|------|-----------|
| `src/http_native/root.zig` | Main `request()` function | Signature:148, internal:161-183 |
| `src/http_native/root.zig` | `Connection: close` hardcoded | Line 308 in `build_request()` |
| `src/http_native/root.zig` | `stream_body()` for streaming | Signature:152-159, internal:185-206 |
| `src/http_native/root.zig` | `shared_ca_bundle` singleton | Lines 69-91, mutex-guarded lazy init |
| `src/http_native/root.zig` | TCP connect | `tcpConnectToAddress`:168, 197 |
| `src/http_native/root.zig` | `TlsIoState` | Lines 18-67 |
| `src/http_native/types.zig` | `PoolConfig` (UNUSED) | Lines 16-20: max_connections:8, max_idle_time_ms:30000, max_requests_per_conn:100 |
| `src/http_native/types.zig` | `TransportConfig` | Lines 47-54: providers:24 conns, channels:16, tools:8, system:2 |
| `src/http_native/types.zig` | `RequestOptions` | Lines 27-39 |
| `src/http_native/types.zig` | `Response` | Lines 41-45, has `reused_connection: bool = false` |
| `src/http_util.zig` | `request_with_mode()` routing | Lines 491-556, three modes: curl_only/native_preferred/native_only |
| `src/http_util.zig` | Transport counters | Lines 38-51, 12 atomic counters |
| `src/http_util.zig` | `curlPost` | Line 205, delegates to `curlPostWithProxy` |
| `src/http_util.zig` | `curlPostWithProxy` | Lines 115-202, stdin pipe for body |
| `src/providers/helpers.zig` | `curlPostTimed` | Line 284, already calls `request_with_mode` with default (native_preferred) |
| `src/providers/sse.zig` | `curlStream` | Line 67, tries native_stream first, falls back to curl |
| `src/providers/sse.zig` | `curlStreamAnthropic` | Line 449, same native-first pattern |

### Files Using `curl_only` (Migration Candidates)

| File | Line | Context | Migrate? |
|------|------|---------|----------|
| `src/tools/web_search.zig` | 237 | Brave Search API | Yes — well-known HTTPS API |
| `src/tools/web_search.zig` | 302 | Exa Search API | Yes — well-known HTTPS API |
| `src/tools/web_fetch.zig` | 69 | Arbitrary URLs | No — user-supplied, curl is safer |
| `src/tools/http_request.zig` | 140 | Arbitrary URLs | No — user-supplied, curl is safer |
| `src/tools/message.zig` | 194 | Telegram send API | Yes — well-known HTTPS API |

## Steps

### Step B1: Implement Connection Pool

**Goal**: Add keep-alive connection reuse to the native HTTP client.

**Files to create**: `src/http_native/pool.zig`

**Design**:
```zig
pub const ConnectionPool = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    idle: StringHashMap(ArrayList(PooledConnection)),

    const PooledConnection = struct {
        stream: std.net.Stream,
        tls_state: ?*TlsIoState,
        created_at: i64,
        requests_served: u16,
    };

    pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16, is_tls: bool) ?PooledConnection {}
    pub fn release(self: *ConnectionPool, host: []const u8, port: u16, is_tls: bool, conn: PooledConnection) void {}
    pub fn evictExpired(self: *ConnectionPool) void {}
    pub fn deinit(self: *ConnectionPool) void {}
};
```

**Actions**:
1. Read `src/http_native/types.zig` lines 16-20 — `PoolConfig` defines `max_connections: 8`, `max_idle_time_ms: 30_000`, `max_requests_per_conn: 100`.
2. Read `src/http_native/root.zig` lines 161-183 — current `root_request` opens fresh connection every time.
3. Create `src/http_native/pool.zig`:
   - `acquire()`: Look up key `"{host}:{port}:{tls}"` in idle map. Return first non-expired connection. Remove from idle list.
   - `release()`: If connection healthy and under `max_requests_per_conn`, add to idle list. If idle list exceeds `max_connections`, close oldest. Otherwise close.
   - `evictExpired()`: Walk all idle connections, close those older than `max_idle_time_ms`.
   - Thread-safe via mutex.
4. Add the pool module to `src/http_native/root.zig` imports.
5. Create a process-wide pool singleton (similar to `shared_ca_bundle` pattern at root.zig:69):
   ```zig
   const shared_pool = struct {
       var mutex: std.Thread.Mutex = .{};
       var pool: ?ConnectionPool = null;
       fn get(allocator: Allocator) *ConnectionPool { ... }
   };
   ```
6. Tests:
   - Connection reuse (two requests to same host, second reuses)
   - Pool eviction (expired connections removed)
   - Max connections respected
   - Max requests per connection respected
   - Thread safety (concurrent acquire/release)
   - Different hosts get different pool entries
   - Stale connection handling (server closed, pool detects and opens new)

**Acceptance**: `ConnectionPool` implemented and tested. Not yet integrated into request path. `zig build test --summary all` passes.

---

### Step B2: Integrate Pool Into Request Path

**Goal**: Make `request()` and `stream_body()` use the connection pool.

**Files to modify**: `src/http_native/root.zig`

**Actions**:
1. In `root_request` (line 161), before `tcpConnectToAddress`:
   - Try `shared_pool.get(allocator).acquire(host, port, is_tls)`
   - If pool returns connection, skip `tcpConnectToAddress` and TLS init
   - If pool returns null, open fresh connection as before
2. After response parsed, if response headers indicate keep-alive:
   - Call `shared_pool.get(allocator).release(host, port, is_tls, conn)`
   - Do NOT close the stream (conditional `defer stream.close()`)
3. Change outgoing header from `Connection: close` (root.zig:308) to `Connection: keep-alive`.
4. Parse `Connection:` header from response to decide pool or close.
5. Same changes for `root_stream_body` (line 185).
6. Set `Response.reused_connection = true` on pool hits.
7. Periodic eviction: evict on every `acquire()` if enough time has passed since last eviction.

**Acceptance**: Consecutive requests to same host reuse connections. `Response.reused_connection` is `true` on hits. `zig build test --summary all` passes.

---

### Step B3: Migrate Tool HTTP Calls to Native

**Goal**: Switch tools from `curl_only` to `native_preferred` where safe.

**Files to modify**:
- `src/tools/web_search.zig` — lines 237, 302
- `src/tools/message.zig` — line 194

**Actions**:
1. `web_search.zig` (Brave, Exa): Well-known HTTPS APIs. Change `.mode = .curl_only` to `.mode = .native_preferred` (or remove mode override — default is `native_preferred`).
2. `message.zig` (Telegram send): Well-known API. Change to `native_preferred`.
3. **Keep `curl_only`** for `web_fetch.zig` and `http_request.zig` — arbitrary user-supplied URLs where curl's redirect/encoding handling is safer.
4. Verify fallback works: when native fails, curl takes over transparently.
5. Update tests.

**Acceptance**: web_search and message tools use native_preferred. web_fetch and http_request stay curl_only. `zig build test --summary all` passes.

---

### Step B4: Verify Provider Migration Status

**Goal**: Confirm provider HTTP calls are already on `native_preferred`.

**Files to read**:
- `src/providers/helpers.zig` line 284 — `curlPostTimed` already calls `http_util.request_with_mode` with default config (`native_preferred`)
- `src/providers/sse.zig` lines 67, 449 — `curlStream` and `curlStreamAnthropic` try native first

**Provider curl usage map**:

| Provider | Non-streaming | Streaming | Status |
|----------|---------------|-----------|--------|
| OpenAI | `request_with_mode` (default) | `sse.curlStream` (native-first) | OK |
| Anthropic | `request_with_mode` (default) | `sse.curlStreamAnthropic` (native-first) | OK |
| Gemini | `request_with_mode` (default) | `curlStreamGemini` (local) | Check |
| OpenRouter | `request_with_mode` (default) | `sse.curlStream` (native-first) | OK |
| Compatible | `request_with_mode` (default) | `sse.curlStream` (native-first) | OK |
| Ollama | `request_with_mode` (default) | N/A | OK |

**Actions**:
1. Read each provider and confirm they use `native_preferred` path.
2. Check Gemini's `curlStreamGemini` (gemini.zig:410) — verify it tries native first.
3. If any provider hardcodes `curl_only`, migrate it.
4. Document status.

**Acceptance**: All providers confirmed on `native_preferred`. No action needed if already correct.

---

### Step B5: Transport Observability

**Goal**: Clear metrics for native vs curl usage per subsystem.

**Files to modify**: `src/gateway.zig` — `/metrics` endpoint (around line 2570-2610)

**Actions**:
1. Read existing metrics. It already exports `nullalis_http_transport_curl_total` per subsystem.
2. Add native and fallback counters:
   - `nullalis_http_transport_native_total{subsystem="tools"}` etc.
   - `nullalis_http_transport_fallback_total{subsystem="tools"}` etc.
3. Add pool metrics:
   - `nullalis_http_pool_hits_total`
   - `nullalis_http_pool_misses_total`
   - `nullalis_http_pool_idle_connections`
4. Source from `http_util.transport_stats_snapshot()` (has native/curl/fallback) and pool stats.
5. Add to `/internal/diagnostics` JSON as well.

**Acceptance**: Prometheus-compatible metrics. Pool utilization visible. `zig build test --summary all` passes.

---

### Step B6: Connection Pool Stress Testing

**Goal**: Verify pool under concurrent load.

**Actions**:
1. Test: 100 concurrent requests to same host — pool reuses connections.
2. Test: Mixed hosts (50 to host A, 50 to host B) — separate pool entries.
3. Test: Pool eviction under memory pressure.
4. Test: Stale connection handling — pooled connection where server closed it. Pool detects and opens new.
5. Test: max_connections limit respected.
6. Test: max_requests_per_conn forces new connection after N requests.

**Acceptance**: All stress tests pass. No leaks. `zig build test --summary all` passes.
