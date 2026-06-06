// WebSocket client with reconnect + exponential backoff + jitter, factored as a
// plain class so we can unit-test it with a mock WebSocket implementation.
//
// Lifecycle:
//   new WsClient({...})  →  .start()  →  open  →  send auth frame  →
//                                                  await auth_ack  →  ready
//                                         │
//                                         └─ on close: backoff → reconnect
//                                         └─ on error: log, let close handle reconnect
//
// AUTH GATE (Wave 3 review CRITICAL #5):
// The client buffers / drops every inbound non-control frame until the gateway
// has responded with `auth_ack` (ok: true). This prevents the
// "extension dispatches commands BEFORE the gateway has validated the token"
// trust-on-first-paste attack class:
//   1. User pastes attacker's wss://attacker/ws + fake token.
//   2. Extension opens socket, sends auth frame.
//   3. Pre-fix: attacker server immediately replied with a navigate Command
//      to a credential-harvest page; extension EXECUTED it.
//   4. Post-fix: any non-`auth_ack` / non-`ping` frame received before
//      auth_ack{ok:true} is dropped on the floor, the socket is closed after
//      `authTimeoutMs` with reason "auth_timeout", and on auth_ack{ok:false}
//      it closes with "auth_failed".
// Ping/pong is exempt — the proxy / gateway heartbeat must work pre-ack.

import type { ClientMessage, ServerMessage } from "./types";

export interface WsClientOptions {
  url: string;
  token: string;
  extensionVersion: string;
  /** Called for every inbound non-control frame, only after auth_ack{ok:true}. */
  onMessage: (msg: ServerMessage) => void;
  /** Called whenever the connected state transitions. */
  onStateChange?: (connected: boolean, error?: string) => void;
  /**
   * Called when the auth handshake transitions:
   *   - "authenticated":  auth_ack{ok:true} received; Commands now flow
   *   - "auth_failed":    auth_ack{ok:false} received; socket closing
   *   - "auth_timeout":   no auth_ack within authTimeoutMs; socket closing
   * Subscribed by background.ts to surface in the popup.
   */
  onAuthStateChange?: (
    state: "authenticated" | "auth_failed" | "auth_timeout",
    reason?: string,
  ) => void;
  /** Injected for tests. Defaults to globalThis.WebSocket. */
  WebSocketImpl?: typeof WebSocket;
  /** Initial reconnect delay in ms. */
  initialBackoffMs?: number;
  /** Max reconnect delay cap. */
  maxBackoffMs?: number;
  /** Heartbeat interval. Set 0 to disable. */
  heartbeatMs?: number;
  /**
   * How long to wait for `auth_ack` after the socket opens. Default 5s.
   * If the gateway doesn't respond within this window, the socket is closed
   * (the extension will then attempt to reconnect with normal backoff).
   */
  authTimeoutMs?: number;
}

const DEFAULT_INITIAL_BACKOFF = 1_000;
const DEFAULT_MAX_BACKOFF = 30_000;
const DEFAULT_HEARTBEAT = 25_000;
const DEFAULT_AUTH_TIMEOUT = 5_000;

// M4 — inbound frame size cap. A misbehaving / hostile gateway could stream a
// multi-hundred-MB frame to OOM the service worker or pin the main thread in
// JSON.parse. We drop any string frame larger than this BEFORE parsing.
// Legitimate command frames are tiny; get_dom/get_text results flow the OTHER
// direction (extension → gateway) and are capped in commands.ts.
const MAX_INBOUND_FRAME_BYTES = 8 * 1024 * 1024; // 8 MB

// WebSocket readyState constants by literal value. We don't reference
// `WebSocket.OPEN` because in some test/runtime environments the WebSocket
// constructor's static fields aren't populated when an injected mock is used.
// The numeric values are stable per the HTML spec.
const WS_OPEN = 1;
const WS_CONNECTING = 0;

export class WsClient {
  private readonly opts: Required<
    Omit<WsClientOptions, "onStateChange" | "onAuthStateChange">
  > & {
    onStateChange: ((connected: boolean, error?: string) => void) | undefined;
    onAuthStateChange:
      | ((
          state: "authenticated" | "auth_failed" | "auth_timeout",
          reason?: string,
        ) => void)
      | undefined;
  };
  private ws: WebSocket | null = null;
  private backoffMs: number;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private authTimer: ReturnType<typeof setTimeout> | null = null;
  private stopped = false;
  /**
   * True only after the gateway acknowledged auth (auth_ack{ok:true}).
   * Reset to false on every socket open. Public via `isAuthenticated()` so
   * background.ts can double-defend command dispatch.
   */
  private authAcked = false;

  constructor(opts: WsClientOptions) {
    this.opts = {
      url: opts.url,
      token: opts.token,
      extensionVersion: opts.extensionVersion,
      onMessage: opts.onMessage,
      onStateChange: opts.onStateChange,
      onAuthStateChange: opts.onAuthStateChange,
      WebSocketImpl: opts.WebSocketImpl ?? (globalThis.WebSocket as typeof WebSocket),
      initialBackoffMs: opts.initialBackoffMs ?? DEFAULT_INITIAL_BACKOFF,
      maxBackoffMs: opts.maxBackoffMs ?? DEFAULT_MAX_BACKOFF,
      heartbeatMs: opts.heartbeatMs ?? DEFAULT_HEARTBEAT,
      authTimeoutMs: opts.authTimeoutMs ?? DEFAULT_AUTH_TIMEOUT,
    };
    this.backoffMs = this.opts.initialBackoffMs;
  }

  /** Open the socket. Idempotent — calling twice is a no-op while connecting. */
  start(): void {
    this.stopped = false;
    if (this.ws && (this.ws.readyState === WS_OPEN || this.ws.readyState === WS_CONNECTING)) {
      return;
    }
    this.openSocket();
  }

  /** Tear down the socket and cancel any pending reconnect. */
  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.clearHeartbeat();
    this.clearAuthTimer();
    this.authAcked = false;
    if (this.ws) {
      try {
        this.ws.close(1000, "client_stop");
      } catch {
        // closing an already-closed socket throws; we don't care
      }
      this.ws = null;
    }
    this.emitState(false);
  }

  /** True if the socket is OPEN. Does NOT imply auth_ack — see isAuthenticated(). */
  isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WS_OPEN;
  }

  /**
   * True only after the gateway sent `auth_ack{ok:true}`. Background dispatch
   * should always gate on this in addition to whatever WsClient does internally.
   */
  isAuthenticated(): boolean {
    return this.authAcked && this.isConnected();
  }

  /** Send a frame to the gateway. Returns false if the socket isn't open. */
  send(msg: ClientMessage): boolean {
    if (!this.ws || this.ws.readyState !== WS_OPEN) return false;
    try {
      this.ws.send(JSON.stringify(msg));
      return true;
    } catch {
      return false;
    }
  }

  private openSocket(): void {
    const WsCtor = this.opts.WebSocketImpl;
    let ws: WebSocket;
    try {
      ws = new WsCtor(this.opts.url);
    } catch (err) {
      this.emitState(false, err instanceof Error ? err.message : String(err));
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;
    // Reset auth state for the new socket. Critical for reconnect: a
    // previously-authenticated session does not carry over its auth_ack to
    // the next socket — the gateway must ack the new socket too.
    this.authAcked = false;

    ws.onopen = () => {
      // Reset backoff once we have a real connection.
      this.backoffMs = this.opts.initialBackoffMs;
      // Plan-8 — the auth frame is NO LONGER sent here. The gateway
      // issues a per-connection `challenge` nonce first; we send `auth`
      // (echoing that nonce) only once the challenge arrives (see
      // onmessage). The auth timer still starts now so a gateway that
      // never sends a challenge (or never acks) still trips the
      // auth_timeout close.
      this.startHeartbeat();
      this.startAuthTimer();
      this.emitState(true);
    };

    ws.onmessage = (ev: MessageEvent) => {
      // M4 — drop oversized frames before we ever touch JSON.parse. We only
      // ever expect string frames; a non-string frame (Blob/ArrayBuffer) is
      // outside the protocol and parses to "" → dropped below.
      const data = typeof ev.data === "string" ? ev.data : "";
      if (data.length > MAX_INBOUND_FRAME_BYTES) {
        // Silently drop — same policy as malformed frames: a misbehaving
        // gateway must not be able to crash the extension.
        return;
      }
      let parsed: ServerMessage;
      try {
        parsed = JSON.parse(data) as ServerMessage;
      } catch {
        // Malformed frame from server — drop silently. By design: a misbehaving
        // gateway shouldn't crash the extension. See docs/silent-catches-policy.md.
        return;
      }
      const type = (parsed as { type?: string }).type;

      // Heartbeat is always allowed, before AND after auth_ack — the proxy /
      // load balancer needs the keepalive regardless of app-layer auth state.
      if (type === "ping") {
        this.send({ type: "pong" });
        return;
      }
      if (type === "pong") {
        // No-op; we sent a ping and got the expected reply.
        return;
      }

      // Plan-8 — per-connection anti-replay challenge. The gateway
      // issues a fresh nonce before it waits for auth; we echo it back
      // in the `auth` frame. Sent pre-ack, so it's handled BEFORE the
      // authAcked gate below (like ping/pong/auth_ack).
      if (type === "challenge") {
        const chal = parsed as { type: "challenge"; nonce?: unknown };
        if (typeof chal.nonce === "string" && chal.nonce.length > 0) {
          this.send({
            type: "auth",
            token: this.opts.token,
            extension_version: this.opts.extensionVersion,
            nonce: chal.nonce,
          });
        }
        // A malformed challenge (missing/empty nonce) is dropped; the
        // auth timer will close the socket since no valid auth is sent.
        return;
      }

      // Auth handshake.
      if (type === "auth_ack") {
        const ack = parsed as { type: "auth_ack"; ok: boolean; error?: string };
        this.clearAuthTimer();
        if (ack.ok) {
          this.authAcked = true;
          this.emitAuthState("authenticated");
        } else {
          // Server rejected the token. Close the socket; popup will surface.
          this.authAcked = false;
          this.emitAuthState("auth_failed", ack.error);
          this.closeSocket(1008, ack.error ?? "auth_failed");
        }
        return;
      }

      // Anything else (Command frames, unknown control frames) is GATED on
      // auth_ack. Pre-fix this was the bypass: a malicious gateway could
      // send a Command before auth and the extension would execute it.
      if (!this.authAcked) {
        // Drop silently. Logging here would be noise on every reconnect race.
        return;
      }

      this.opts.onMessage(parsed);
    };

    ws.onerror = () => {
      // No-op; the close handler runs next and triggers reconnect.
      this.emitState(false, "websocket error");
    };

    ws.onclose = (ev: CloseEvent) => {
      this.clearHeartbeat();
      this.clearAuthTimer();
      this.authAcked = false;
      this.ws = null;
      this.emitState(false, ev.reason || `closed (code ${ev.code})`);
      if (!this.stopped) this.scheduleReconnect();
    };
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    // Full jitter: pick a random delay in [0, backoff). Caps storms.
    const jittered = Math.floor(Math.random() * this.backoffMs);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, jittered);
    // Double for next time, capped.
    this.backoffMs = Math.min(this.backoffMs * 2, this.opts.maxBackoffMs);
  }

  private startHeartbeat(): void {
    if (this.opts.heartbeatMs <= 0) return;
    this.clearHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      // We don't track pong replies aggressively — if the socket is dead, the
      // browser will surface it via close. Heartbeat keeps the proxy happy.
      this.send({ type: "ping" });
    }, this.opts.heartbeatMs);
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private startAuthTimer(): void {
    this.clearAuthTimer();
    this.authTimer = setTimeout(() => {
      this.authTimer = null;
      if (!this.authAcked) {
        this.emitAuthState("auth_timeout");
        this.closeSocket(1008, "auth_timeout");
      }
    }, this.opts.authTimeoutMs);
  }

  private clearAuthTimer(): void {
    if (this.authTimer) {
      clearTimeout(this.authTimer);
      this.authTimer = null;
    }
  }

  /** Close the socket with a code/reason. Silent on already-closed sockets. */
  private closeSocket(code: number, reason: string): void {
    if (!this.ws) return;
    try {
      this.ws.close(code, reason);
    } catch {
      // Already-closed socket; nothing to do.
    }
  }

  private emitState(connected: boolean, error?: string): void {
    if (this.opts.onStateChange) {
      this.opts.onStateChange(connected, error);
    }
  }

  private emitAuthState(
    state: "authenticated" | "auth_failed" | "auth_timeout",
    reason?: string,
  ): void {
    if (this.opts.onAuthStateChange) {
      this.opts.onAuthStateChange(state, reason);
    }
  }

  /** Visible for tests — peek at the current backoff value. */
  getBackoffMs(): number {
    return this.backoffMs;
  }
}
