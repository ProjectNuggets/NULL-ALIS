// WebSocket client with reconnect + exponential backoff + jitter, factored as a
// plain class so we can unit-test it with a mock WebSocket implementation.
//
// Lifecycle:
//   new WsClient({...})  →  .start()  →  open  →  send auth frame  →  ready
//                                         │
//                                         └─ on close: backoff → reconnect
//                                         └─ on error: log, let close handle reconnect
//
// The client is push-only from the gateway side: every inbound frame other
// than ping/pong/auth_ack is forwarded to onCommand().

import type { ClientMessage, ServerMessage } from "./types";

export interface WsClientOptions {
  url: string;
  token: string;
  extensionVersion: string;
  /** Called for every inbound non-control frame. */
  onMessage: (msg: ServerMessage) => void;
  /** Called whenever the connected state transitions. */
  onStateChange?: (connected: boolean, error?: string) => void;
  /** Injected for tests. Defaults to globalThis.WebSocket. */
  WebSocketImpl?: typeof WebSocket;
  /** Initial reconnect delay in ms. */
  initialBackoffMs?: number;
  /** Max reconnect delay cap. */
  maxBackoffMs?: number;
  /** Heartbeat interval. Set 0 to disable. */
  heartbeatMs?: number;
}

const DEFAULT_INITIAL_BACKOFF = 1_000;
const DEFAULT_MAX_BACKOFF = 30_000;
const DEFAULT_HEARTBEAT = 25_000;

// WebSocket readyState constants by literal value. We don't reference
// `WebSocket.OPEN` because in some test/runtime environments the WebSocket
// constructor's static fields aren't populated when an injected mock is used.
// The numeric values are stable per the HTML spec.
const WS_OPEN = 1;
const WS_CONNECTING = 0;

export class WsClient {
  private readonly opts: Required<Omit<WsClientOptions, "onStateChange">> & {
    onStateChange: ((connected: boolean, error?: string) => void) | undefined;
  };
  private ws: WebSocket | null = null;
  private backoffMs: number;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private stopped = false;

  constructor(opts: WsClientOptions) {
    this.opts = {
      url: opts.url,
      token: opts.token,
      extensionVersion: opts.extensionVersion,
      onMessage: opts.onMessage,
      onStateChange: opts.onStateChange,
      WebSocketImpl: opts.WebSocketImpl ?? (globalThis.WebSocket as typeof WebSocket),
      initialBackoffMs: opts.initialBackoffMs ?? DEFAULT_INITIAL_BACKOFF,
      maxBackoffMs: opts.maxBackoffMs ?? DEFAULT_MAX_BACKOFF,
      heartbeatMs: opts.heartbeatMs ?? DEFAULT_HEARTBEAT,
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

  /** True if the socket is OPEN. */
  isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WS_OPEN;
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

    ws.onopen = () => {
      // Reset backoff once we have a real connection.
      this.backoffMs = this.opts.initialBackoffMs;
      // Send the auth frame immediately so the gateway can reject early.
      this.send({
        type: "auth",
        token: this.opts.token,
        extension_version: this.opts.extensionVersion,
      });
      this.startHeartbeat();
      this.emitState(true);
    };

    ws.onmessage = (ev: MessageEvent) => {
      let parsed: ServerMessage;
      try {
        parsed = JSON.parse(typeof ev.data === "string" ? ev.data : "") as ServerMessage;
      } catch {
        // Malformed frame from server — drop silently. Could log.
        return;
      }
      // Inline ping handling: respond pong without bothering the consumer.
      if ((parsed as { type?: string }).type === "ping") {
        this.send({ type: "pong" });
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

  private emitState(connected: boolean, error?: string): void {
    if (this.opts.onStateChange) {
      this.opts.onStateChange(connected, error);
    }
  }

  /** Visible for tests — peek at the current backoff value. */
  getBackoffMs(): number {
    return this.backoffMs;
  }
}
