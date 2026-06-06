// Auth-gate tests — extension must NOT dispatch any Command until the
// gateway has responded with `auth_ack` (ok: true).
//
// Pre-Wave-3-fix: ws.onopen sent the auth frame, immediately emitted
// `connected: true`, and from that moment ANY inbound non-ping frame
// flowed to onMessage → executeCommand → real chrome.* calls. Combined
// with the trust-on-first-paste gateway URL (auth.ts:35), this turned a
// phishing-grade UX attack into full active-tab driving capability.
//
// Post-fix:
//   1. WsClient holds inbound frames until auth_ack{ok:true} is observed.
//   2. On auth_ack{ok:false}, the socket closes and emits "auth_failed".
//   3. If no auth_ack within authTimeoutMs (default 5s), socket closes
//      with "auth_timeout".
//   4. Ping/pong are always permitted (heartbeat must work pre-ack).

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WsClient } from "../src/ws_client";
import type { Command } from "../src/types";

class MockWebSocket {
  static OPEN = 1;
  static CLOSED = 3;
  static CONNECTING = 0;
  static CLOSING = 2;

  static instances: MockWebSocket[] = [];

  readonly url: string;
  readyState: number = MockWebSocket.CONNECTING;
  sent: string[] = [];
  closeCalls: Array<{ code?: number; reason?: string }> = [];

  onopen: ((ev?: Event) => void) | null = null;
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onerror: ((ev?: Event) => void) | null = null;
  onclose: ((ev: CloseEvent) => void) | null = null;

  constructor(url: string) {
    this.url = url;
    MockWebSocket.instances.push(this);
  }

  send(data: string): void {
    if (this.readyState !== MockWebSocket.OPEN) {
      throw new Error("not open");
    }
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.readyState = MockWebSocket.CLOSED;
    this.closeCalls.push({ code, reason });
    if (this.onclose) {
      this.onclose(new CloseEvent("close", { code: code ?? 1000, reason: reason ?? "" }));
    }
  }

  simulateOpen(): void {
    this.readyState = MockWebSocket.OPEN;
    if (this.onopen) this.onopen();
  }
  simulateMessage(payload: unknown): void {
    if (this.onmessage) {
      this.onmessage(new MessageEvent("message", { data: JSON.stringify(payload) }));
    }
  }
}

function makeClient(opts: {
  onMessage: (m: unknown) => void;
  onAuthState?: (state: "auth_failed" | "auth_timeout" | "authenticated", reason?: string) => void;
}): WsClient {
  return new WsClient({
    url: "wss://example/ws",
    token: "tok-abc",
    extensionVersion: "0.1.0",
    onMessage: opts.onMessage as (m: import("../src/types").ServerMessage) => void,
    onAuthStateChange: opts.onAuthState,
    WebSocketImpl: MockWebSocket as unknown as typeof WebSocket,
    heartbeatMs: 0,
    authTimeoutMs: 5_000,
  });
}

const SAMPLE_COMMAND: Command = {
  command_id: "cmd-1",
  tool: "navigate",
  args: { url: "https://example.com" },
};

describe("WsClient auth gate", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    MockWebSocket.instances = [];
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("DROPS Command frames received BEFORE auth_ack and does NOT call onMessage", () => {
    const messages: unknown[] = [];
    const client = makeClient({ onMessage: (m) => messages.push(m) });

    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();
    // Auth frame was sent, but no auth_ack yet.
    // Attacker / misbehaving gateway sends a Command anyway.
    ws.simulateMessage(SAMPLE_COMMAND);

    expect(messages).toEqual([]);
    expect(client.isAuthenticated()).toBe(false);
  });

  it("closes the socket with 'auth_timeout' if no auth_ack arrives within authTimeoutMs", () => {
    const messages: unknown[] = [];
    const authStates: Array<{ state: string; reason?: string }> = [];
    const client = makeClient({
      onMessage: (m) => messages.push(m),
      onAuthState: (state, reason) => authStates.push({ state, reason }),
    });

    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();

    // Advance past the auth timeout without sending auth_ack.
    vi.advanceTimersByTime(5_000);

    expect(ws.closeCalls.length).toBeGreaterThan(0);
    expect(authStates.some((s) => s.state === "auth_timeout")).toBe(true);
    expect(client.isAuthenticated()).toBe(false);
  });

  it("closes the socket with 'auth_failed' on auth_ack{ok:false}", () => {
    const messages: unknown[] = [];
    const authStates: Array<{ state: string; reason?: string }> = [];
    const client = makeClient({
      onMessage: (m) => messages.push(m),
      onAuthState: (state, reason) => authStates.push({ state, reason }),
    });

    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();
    ws.simulateMessage({ type: "auth_ack", ok: false, error: "invalid_token" });

    expect(ws.closeCalls.length).toBeGreaterThan(0);
    expect(authStates.some((s) => s.state === "auth_failed")).toBe(true);
    expect(client.isAuthenticated()).toBe(false);
  });

  it("auto-responds to ping with pong even BEFORE auth_ack (heartbeat must work pre-ack)", () => {
    const messages: unknown[] = [];
    const client = makeClient({ onMessage: (m) => messages.push(m) });

    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();
    ws.sent = []; // drop auth frame from comparison

    ws.simulateMessage({ type: "ping" });

    expect(messages).toEqual([]);
    expect(ws.sent.length).toBe(1);
    expect(JSON.parse(ws.sent[0]!)).toEqual({ type: "pong" });
  });

  it("echoes the server-issued nonce in the auth frame (Plan-8 anti-replay)", () => {
    const messages: unknown[] = [];
    const client = makeClient({ onMessage: (m) => messages.push(m) });

    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();
    // No auth frame sent until the challenge arrives.
    expect(ws.sent.length).toBe(0);

    const NONCE = "abcdef01".repeat(8); // 64-char hex
    ws.simulateMessage({ type: "challenge", nonce: NONCE });

    expect(ws.sent.length).toBe(1);
    expect(JSON.parse(ws.sent[0]!)).toEqual({
      type: "auth",
      token: "tok-abc",
      extension_version: "0.1.0",
      nonce: NONCE,
    });
  });

  it("does NOT send auth on a malformed challenge (missing/empty nonce)", () => {
    const client = makeClient({ onMessage: () => {} });
    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();

    ws.simulateMessage({ type: "challenge" }); // no nonce
    ws.simulateMessage({ type: "challenge", nonce: "" }); // empty nonce

    expect(ws.sent.length).toBe(0);
    expect(client.isAuthenticated()).toBe(false);
  });

  it("DISPATCHES subsequent Commands once auth_ack{ok:true} is received", () => {
    const messages: unknown[] = [];
    const authStates: Array<{ state: string; reason?: string }> = [];
    const client = makeClient({
      onMessage: (m) => messages.push(m),
      onAuthState: (state, reason) => authStates.push({ state, reason }),
    });

    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();
    ws.simulateMessage({ type: "auth_ack", ok: true });

    expect(client.isAuthenticated()).toBe(true);
    expect(authStates.some((s) => s.state === "authenticated")).toBe(true);

    // Now Commands flow through to onMessage.
    ws.simulateMessage(SAMPLE_COMMAND);
    expect(messages).toEqual([SAMPLE_COMMAND]);
  });

  it("RESETS auth state across reconnect — pre-ack frames on a new socket are dropped", () => {
    const messages: unknown[] = [];
    const client = makeClient({ onMessage: (m) => messages.push(m) });

    client.start();
    let ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();
    ws.simulateMessage({ type: "auth_ack", ok: true });
    ws.simulateMessage(SAMPLE_COMMAND);
    expect(messages.length).toBe(1);

    // Force-close so the client schedules a reconnect.
    ws.readyState = MockWebSocket.CLOSED;
    if (ws.onclose) ws.onclose(new CloseEvent("close", { code: 1006, reason: "abnormal" }));
    vi.advanceTimersByTime(60_000);

    // A new socket should have been created. Pre-ack frame on it must drop.
    expect(MockWebSocket.instances.length).toBeGreaterThanOrEqual(2);
    ws = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
    ws.simulateOpen();
    ws.simulateMessage({ ...SAMPLE_COMMAND, command_id: "cmd-2" });

    // Still only the one (pre-reconnect) command was dispatched.
    expect(messages.length).toBe(1);
  });
});
