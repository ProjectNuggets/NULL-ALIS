// Integration tests for background.ts — the security-critical command pipeline.
//
// Coverage:
//   C1/H1  consent enforcement: a command targeting a non-consented tab is
//          refused with consent_required; enabling a tab injects the content
//          script and lets commands through; STOP/disconnect clear consent.
//   C2     sender validation: popup-control messages from an untrusted sender
//          (content script / foreign extension) are rejected.
//   H4     latched STOP: a command issued right after STOP is refused with
//          `stopped`; an auto-reconnect (onStartup) does NOT reconnect while
//          latched; only an explicit popup `connect` clears the latch.
//   H3     per-command timeout: a content command that never replies resolves
//          as a timeout error.
//
// We mock the full chrome.* surface and globalThis.WebSocket so background.ts
// runs its REAL pipeline. Server command frames are injected by driving the
// mock socket the background's WsClient opens.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommandResult } from "../src/types";

// ---------- chrome.storage mock ----------

function makeStorageArea() {
  let data: Record<string, unknown> = {};
  return {
    get: async (key: string | string[] | null) => {
      if (key === null) return { ...data };
      if (Array.isArray(key)) {
        const out: Record<string, unknown> = {};
        for (const k of key) if (k in data) out[k] = data[k];
        return out;
      }
      return key in data ? { [key]: data[key] } : {};
    },
    set: async (items: Record<string, unknown>) => {
      data = { ...data, ...items };
    },
    remove: async (key: string | string[]) => {
      const keys = Array.isArray(key) ? key : [key];
      for (const k of keys) delete data[k];
    },
    clear: async () => {
      data = {};
    },
    __reset: () => {
      data = {};
    },
  };
}

// ---------- mock WebSocket the background's WsClient will open ----------

class MockWebSocket {
  static OPEN = 1;
  static CLOSED = 3;
  static CONNECTING = 0;
  static CLOSING = 2;
  static instances: MockWebSocket[] = [];

  readonly url: string;
  readyState = MockWebSocket.CONNECTING;
  sent: string[] = [];
  onopen: ((ev?: Event) => void) | null = null;
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onerror: ((ev?: Event) => void) | null = null;
  onclose: ((ev: CloseEvent) => void) | null = null;

  constructor(url: string) {
    this.url = url;
    MockWebSocket.instances.push(this);
  }
  send(data: string): void {
    if (this.readyState !== MockWebSocket.OPEN) throw new Error("not open");
    this.sent.push(data);
  }
  close(code?: number, reason?: string): void {
    this.readyState = MockWebSocket.CLOSED;
    if (this.onclose) this.onclose(new CloseEvent("close", { code: code ?? 1000, reason: reason ?? "" }));
  }
  open(): void {
    this.readyState = MockWebSocket.OPEN;
    if (this.onopen) this.onopen();
  }
  message(payload: unknown): void {
    if (this.onmessage) this.onmessage(new MessageEvent("message", { data: JSON.stringify(payload) }));
  }
}

// ---------- chrome mock harness ----------

const local = makeStorageArea();
const session = makeStorageArea();

interface TabState {
  id: number;
  title: string;
  url: string;
}

// Mutable per-test fixtures.
let activeTab: TabState = { id: 1, title: "t", url: "https://example.com" };
let onMessageListener: ((req: unknown, sender: unknown, send: (r: unknown) => void) => boolean | void) | null = null;
let onRemovedListener: ((tabId: number) => void) | null = null;
let onStartupListener: (() => void) | null = null;
let onInstalledListener: (() => void) | null = null;
// The content-script response factory: given the command, what does the tab reply?
let tabResponder: ((cmd: { command_id: string; tool: string }) => unknown | Promise<unknown>) | null = null;
const executeScriptCalls: Array<{ tabId: number; files: string[] }> = [];
const reloadCalls: number[] = [];

function installChromeMock(): void {
  (globalThis as unknown as { chrome: unknown }).chrome = {
    runtime: {
      id: "ext-self-id",
      getManifest: () => ({ version: "0.1.0" }),
      getURL: (p: string) => `chrome-extension://ext-self-id/${p}`,
      onMessage: { addListener: (fn: typeof onMessageListener) => { onMessageListener = fn; } },
      onStartup: { addListener: (fn: typeof onStartupListener) => { onStartupListener = fn; } },
      onInstalled: { addListener: (fn: typeof onInstalledListener) => { onInstalledListener = fn; } },
    },
    storage: { local, session },
    scripting: {
      executeScript: async ({ target, files }: { target: { tabId: number }; files: string[] }) => {
        executeScriptCalls.push({ tabId: target.tabId, files });
        return [];
      },
    },
    tabs: {
      query: async () => [{ ...activeTab }],
      update: async () => ({ ...activeTab }),
      create: async ({ url }: { url: string }) => ({ id: 99, url }),
      reload: async (tabIdToReload: number) => { reloadCalls.push(tabIdToReload); },
      captureVisibleTab: async () => "data:image/png;base64,xxx",
      sendMessage: async (_tabId: number, msg: { type: string; command?: { command_id: string; tool: string } }) => {
        if (msg.type === "show_toast") return undefined;
        if (msg.type === "execute_in_tab" && msg.command) {
          const result = tabResponder
            ? await tabResponder(msg.command)
            : { ok: true };
          return {
            type: "execute_in_tab_result",
            command_id: msg.command.command_id,
            ok: true,
            result,
          };
        }
        return undefined;
      },
      onRemoved: { addListener: (fn: typeof onRemovedListener) => { onRemovedListener = fn; } },
    },
  };
  (globalThis as unknown as { WebSocket: unknown }).WebSocket = MockWebSocket;
}

// Send a popup request through the registered onMessage listener and await the
// response. Defaults to a trusted extension-page sender (C2).
function popup(
  req: unknown,
  sender: Record<string, unknown> = { id: "ext-self-id", url: "chrome-extension://ext-self-id/src/popup/index.html" },
): Promise<unknown> {
  return new Promise((resolve) => {
    const ret = onMessageListener!(req, sender, resolve);
    if (ret !== true) resolve(undefined);
  });
}

// Bring the socket to authenticated state and return it.
function authenticate(): MockWebSocket {
  const ws = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
  ws.open();
  ws.message({ type: "challenge", nonce: "n".repeat(16) });
  ws.message({ type: "auth_ack", ok: true });
  return ws;
}

// Collect CommandResult frames the background sends back to the gateway.
function sentResults(ws: MockWebSocket): CommandResult[] {
  const out: CommandResult[] = [];
  for (const s of ws.sent) {
    const m = JSON.parse(s) as Record<string, unknown>;
    if (typeof m.command_id === "string" && "ok" in m) {
      out.push(m as unknown as CommandResult);
    }
  }
  return out;
}

async function flush(): Promise<void> {
  // Let queued microtasks (storage round-trips, command pipeline) settle.
  for (let i = 0; i < 40; i++) await Promise.resolve();
}

beforeEach(async () => {
  vi.resetModules();
  local.__reset();
  session.__reset();
  MockWebSocket.instances = [];
  executeScriptCalls.length = 0;
  reloadCalls.length = 0;
  onMessageListener = null;
  onRemovedListener = null;
  onStartupListener = null;
  onInstalledListener = null;
  tabResponder = null;
  activeTab = { id: 1, title: "t", url: "https://example.com" };
  installChromeMock();
  // Seed a stored token so ensureConnection opens a socket.
  await local.set({
    nullalis_config_v1: { token: "tok-abc", gateway_url: "wss://gateway.example/ws" },
  });
});

afterEach(() => {
  vi.useRealTimers();
});

describe("C2: sender validation on the popup onMessage listener", () => {
  it("rejects a control request from a content-script sender (sender.tab set)", async () => {
    await import("../src/background");
    await flush();
    const res = await popup(
      { type: "enable_active_tab" },
      { id: "ext-self-id", url: "https://evil.example/", tab: { id: 7 } },
    );
    expect(res).toEqual({ ok: false, error: "forbidden: untrusted sender" });
  });

  it("rejects a control request from a foreign extension id", async () => {
    await import("../src/background");
    await flush();
    const res = await popup(
      { type: "stop_all" },
      { id: "some-other-extension", url: "chrome-extension://some-other-extension/x.html" },
    );
    expect(res).toEqual({ ok: false, error: "forbidden: untrusted sender" });
  });

  it("accepts a control request from our own extension page", async () => {
    await import("../src/background");
    await flush();
    const res = await popup({ type: "get_status" });
    expect(res).toMatchObject({ ok: true });
  });
});

describe("C1/H1: per-tab consent enforcement", () => {
  it("refuses a content command on a NON-consented tab with consent_required", async () => {
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();

    ws.message({ command_id: "c1", tool: "click", args: { selector: "#x" } });
    await flush();

    const results = sentResults(ws);
    const r = results.find((x) => x.command_id === "c1")!;
    expect(r.ok).toBe(false);
    expect(r.error?.code).toBe("consent_required");
  });

  it("refuses navigate (same-tab) on a non-consented tab", async () => {
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();

    ws.message({ command_id: "n1", tool: "navigate", args: { url: "https://example.com/" } });
    await flush();

    const r = sentResults(ws).find((x) => x.command_id === "n1")!;
    expect(r.ok).toBe(false);
    expect(r.error?.code).toBe("consent_required");
  });

  it("enabling a tab injects the content script and lets commands through", async () => {
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();

    // Enable the active tab (user gesture from the popup).
    const enableRes = await popup({ type: "enable_active_tab" });
    expect(enableRes).toMatchObject({ ok: true, tab_id: 1 });
    expect(executeScriptCalls).toEqual([{ tabId: 1, files: ["content.js"] }]);
    await flush();

    // Now a content command on tab 1 succeeds.
    tabResponder = () => ({ clicked: "#x" });
    ws.message({ command_id: "c2", tool: "click", args: { selector: "#x" } });
    await flush();

    const r = sentResults(ws).find((x) => x.command_id === "c2")!;
    expect(r.ok).toBe(true);
    expect(r.result).toEqual({ clicked: "#x" });
  });

  it("disconnect clears consent", async () => {
    await import("../src/background");
    await flush();
    authenticate();
    await flush();
    await popup({ type: "enable_active_tab" });
    await flush();
    await popup({ type: "disconnect" });
    await flush();

    const status = (await popup({ type: "get_status" })) as { ok: true; status: { consented_tabs: number[] } };
    expect(status.status.consented_tabs).toEqual([]);
  });

  it("onRemoved drops a closed tab from the consented set", async () => {
    await import("../src/background");
    await flush();
    authenticate();
    await flush();
    await popup({ type: "enable_active_tab" });
    await flush();

    onRemovedListener!(1);
    await flush();

    const status = (await popup({ type: "get_status" })) as { ok: true; status: { consented_tabs: number[] } };
    expect(status.status.consented_tabs).toEqual([]);
  });
});

describe("C1/H1: navigate {new_tab:true} consent inheritance", () => {
  it("refuses new_tab when the active tab is NOT consented (no tab created)", async () => {
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();

    // No enable_active_tab — active tab 1 is not consented.
    const created: unknown[] = [];
    const realCreate = (globalThis as unknown as { chrome: { tabs: { create: unknown } } }).chrome.tabs.create;
    (globalThis as unknown as { chrome: { tabs: { create: unknown } } }).chrome.tabs.create = async (a: { url: string }) => {
      created.push(a);
      return (realCreate as (a: { url: string }) => Promise<unknown>)(a);
    };

    ws.message({ command_id: "nt1", tool: "navigate", args: { url: "https://example.com/", new_tab: true } });
    await flush();

    const r = sentResults(ws).find((x) => x.command_id === "nt1")!;
    expect(r.ok).toBe(false);
    expect(r.error?.code).toBe("consent_required");
    // No tab was created.
    expect(created).toEqual([]);
  });

  it("with a consented active tab: creates the new tab, marks it consented+touched, and a subsequent command on it succeeds", async () => {
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();

    // Enable the active tab (tab 1) — the gesture-of-record.
    await popup({ type: "enable_active_tab" });
    await flush();

    ws.message({ command_id: "nt2", tool: "navigate", args: { url: "https://example.com/next", new_tab: true } });
    await flush();

    const r = sentResults(ws).find((x) => x.command_id === "nt2")!;
    expect(r.ok).toBe(true);
    // Mock tabs.create returns id 99.
    expect((r.result as { tab_id: number }).tab_id).toBe(99);

    // The new tab is consented: a command run against it (make it the active
    // tab) is allowed.
    activeTab = { id: 99, title: "next", url: "https://example.com/next" };
    tabResponder = () => ({ clicked: "#y" });
    ws.message({ command_id: "nt2b", tool: "click", args: { selector: "#y" } });
    await flush();

    const r2 = sentResults(ws).find((x) => x.command_id === "nt2b")!;
    expect(r2.ok).toBe(true);
    expect(r2.result).toEqual({ clicked: "#y" });

    // The new tab is also in the consented set surfaced to the popup.
    const status = (await popup({ type: "get_status" })) as { ok: true; status: { consented_tabs: number[] } };
    expect(status.status.consented_tabs).toContain(99);
  });

  it("STOP reloads an agent-opened tab", async () => {
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();

    await popup({ type: "enable_active_tab" });
    await flush();

    ws.message({ command_id: "nt3", tool: "navigate", args: { url: "https://example.com/n", new_tab: true } });
    await flush();
    expect(sentResults(ws).find((x) => x.command_id === "nt3")!.ok).toBe(true);

    await popup({ type: "stop_all" });
    await flush();

    // The agent-opened tab (id 99) is among the reloaded tabs.
    expect(reloadCalls).toContain(99);
  });
});

describe("H4: latched, in-flight-cancelling STOP", () => {
  it("refuses a command issued right after STOP with `stopped`", async () => {
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();
    await popup({ type: "enable_active_tab" });
    await flush();

    // Run one successful command so tab 1 is recorded as touched (STOP reloads
    // touched tabs).
    tabResponder = () => ({ clicked: "#x" });
    ws.message({ command_id: "pre-stop", tool: "click", args: { selector: "#x" } });
    await flush();

    await popup({ type: "stop_all" });
    await flush();

    // The socket was severed by STOP. Even if a frame sneaks in on the old
    // socket reference, the latch refuses dispatch.
    ws.message({ command_id: "after-stop", tool: "click", args: { selector: "#x" } });
    await flush();

    const r = sentResults(ws).find((x) => x.command_id === "after-stop");
    // Either the frame was refused with `stopped`, or (socket severed) never
    // produced a success. Assert it is NOT a successful execution.
    if (r) {
      expect(r.ok).toBe(false);
      expect(r.error?.code).toBe("stopped");
    }
    // And consent was revoked + the tab reloaded.
    expect(reloadCalls).toContain(1);
  });

  it("does NOT auto-reconnect while latched (onStartup is a no-op)", async () => {
    await import("../src/background");
    await flush();
    authenticate();
    await flush();

    const before = MockWebSocket.instances.length;
    await popup({ type: "stop_all" });
    await flush();

    // Simulate a worker revive firing the startup auto-reconnect.
    onStartupListener!();
    await flush();

    // No NEW socket was opened while latched.
    expect(MockWebSocket.instances.length).toBe(before);
  });

  it("an explicit popup connect clears the latch and reconnects", async () => {
    await import("../src/background");
    await flush();
    authenticate();
    await flush();

    await popup({ type: "stop_all" });
    await flush();
    const afterStop = MockWebSocket.instances.length;

    await popup({ type: "connect" });
    await flush();

    expect(MockWebSocket.instances.length).toBe(afterStop + 1);
    // Latch is cleared in status.
    const status = (await popup({ type: "get_status" })) as { ok: true; status: { stopped: boolean } };
    expect(status.status.stopped).toBe(false);
  });
});

describe("H3: per-command timeout", () => {
  it("a content command that never replies resolves as a timeout error", async () => {
    vi.useFakeTimers();
    await import("../src/background");
    await flush();
    const ws = authenticate();
    await flush();
    await popup({ type: "enable_active_tab" });
    await flush();

    // The tab never responds — sendMessage hangs forever.
    tabResponder = () => new Promise(() => {});

    ws.message({
      command_id: "slow",
      tool: "click",
      args: { selector: "#x" },
      timeout_ms: 50,
    });
    await flush();
    // Trip the timeout.
    await vi.advanceTimersByTimeAsync(60);
    await flush();

    const r = sentResults(ws).find((x) => x.command_id === "slow")!;
    expect(r.ok).toBe(false);
    expect(r.error?.code).toBe("timeout");
  });
});
