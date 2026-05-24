// Tests for WsClient reconnect-with-backoff + auth-frame-on-open behavior.
// Uses a tiny in-memory MockWebSocket so we can drive events deterministically.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WsClient } from "../src/ws_client";
import type { ClientMessage } from "../src/types";

// ---- MockWebSocket implementation ----

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
  }

  // Test driver helpers
  simulateOpen(): void {
    this.readyState = MockWebSocket.OPEN;
    if (this.onopen) this.onopen();
  }
  simulateMessage(payload: unknown): void {
    if (this.onmessage) {
      this.onmessage(new MessageEvent("message", { data: JSON.stringify(payload) }));
    }
  }
  simulateClose(code = 1006, reason = "abnormal"): void {
    this.readyState = MockWebSocket.CLOSED;
    if (this.onclose) {
      this.onclose(new CloseEvent("close", { code, reason }));
    }
  }
}

// vi.useFakeTimers controls setTimeout/setInterval so backoff is deterministic.

describe("WsClient", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    MockWebSocket.instances = [];
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("sends auth frame on open and reports connected", () => {
    const messages: unknown[] = [];
    const states: Array<{ connected: boolean; error?: string }> = [];
    const client = new WsClient({
      url: "wss://example/ws",
      token: "tok-abc",
      extensionVersion: "0.1.0",
      onMessage: (m) => messages.push(m),
      onStateChange: (connected, error) => states.push({ connected, error }),
      WebSocketImpl: MockWebSocket as unknown as typeof WebSocket,
    });

    client.start();
    expect(MockWebSocket.instances.length).toBe(1);
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();

    // Auth frame went out
    expect(ws.sent.length).toBe(1);
    const sent: ClientMessage = JSON.parse(ws.sent[0]!);
    expect(sent).toEqual({
      type: "auth",
      token: "tok-abc",
      extension_version: "0.1.0",
    });

    expect(client.isConnected()).toBe(true);
    expect(states.some((s) => s.connected)).toBe(true);
  });

  it("auto-responds to ping with pong without surfacing it to onMessage", () => {
    const messages: unknown[] = [];
    const client = new WsClient({
      url: "wss://example/ws",
      token: "tok",
      extensionVersion: "0.1.0",
      onMessage: (m) => messages.push(m),
      WebSocketImpl: MockWebSocket as unknown as typeof WebSocket,
      heartbeatMs: 0,
    });
    client.start();
    const ws = MockWebSocket.instances[0]!;
    ws.simulateOpen();
    ws.sent = []; // drop auth frame from the assertion below

    ws.simulateMessage({ type: "ping" });

    expect(messages).toEqual([]); // ping not surfaced
    expect(ws.sent.length).toBe(1);
    expect(JSON.parse(ws.sent[0]!)).toEqual({ type: "pong" });
  });

  it("reconnects with exponentially growing backoff after consecutive failures", () => {
    const client = new WsClient({
      url: "wss://example/ws",
      token: "tok",
      extensionVersion: "0.1.0",
      onMessage: () => {},
      WebSocketImpl: MockWebSocket as unknown as typeof WebSocket,
      initialBackoffMs: 100,
      maxBackoffMs: 10_000,
      heartbeatMs: 0,
    });

    // Force jitter delay to be deterministic (return max of range).
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0.999);

    client.start();
    expect(MockWebSocket.instances.length).toBe(1);
    // Simulate connection failure WITHOUT reaching open — onopen never fires,
    // so backoff is not reset on this attempt.
    MockWebSocket.instances[0]!.simulateClose();
    expect(client.getBackoffMs()).toBe(200);

    // Advance through the scheduled reconnect.
    vi.advanceTimersByTime(150);
    expect(MockWebSocket.instances.length).toBe(2);

    // Second consecutive failure (still no open).
    MockWebSocket.instances[1]!.simulateClose();
    expect(client.getBackoffMs()).toBe(400);

    vi.advanceTimersByTime(500);
    expect(MockWebSocket.instances.length).toBe(3);

    // Third consecutive failure.
    MockWebSocket.instances[2]!.simulateClose();
    expect(client.getBackoffMs()).toBe(800);

    randomSpy.mockRestore();
  });

  it("stop() cancels reconnect and reports disconnected", () => {
    const states: Array<{ connected: boolean }> = [];
    const client = new WsClient({
      url: "wss://example/ws",
      token: "tok",
      extensionVersion: "0.1.0",
      onMessage: () => {},
      onStateChange: (connected) => states.push({ connected }),
      WebSocketImpl: MockWebSocket as unknown as typeof WebSocket,
      initialBackoffMs: 100,
      heartbeatMs: 0,
    });
    client.start();
    MockWebSocket.instances[0]!.simulateOpen();
    MockWebSocket.instances[0]!.simulateClose();

    client.stop();

    // Even after a long wait, no new socket is created.
    vi.advanceTimersByTime(60_000);
    expect(MockWebSocket.instances.length).toBe(1);
    expect(states[states.length - 1]!.connected).toBe(false);
  });

  it("backoff resets to initial on successful open", () => {
    const client = new WsClient({
      url: "wss://example/ws",
      token: "tok",
      extensionVersion: "0.1.0",
      onMessage: () => {},
      WebSocketImpl: MockWebSocket as unknown as typeof WebSocket,
      initialBackoffMs: 100,
      heartbeatMs: 0,
    });
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0.5);

    client.start();
    MockWebSocket.instances[0]!.simulateOpen();
    MockWebSocket.instances[0]!.simulateClose();
    expect(client.getBackoffMs()).toBe(200);

    vi.advanceTimersByTime(500);
    MockWebSocket.instances[1]!.simulateOpen();

    expect(client.getBackoffMs()).toBe(100);
    randomSpy.mockRestore();
  });
});
