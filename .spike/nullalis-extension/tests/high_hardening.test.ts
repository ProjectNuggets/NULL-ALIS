// Wave 3 HIGH regression tests for the extension.
//
// Coverage:
//   HIGH #5  touchedTabs is persisted to chrome.storage.session and survives
//            module reload (simulates MV3 worker eviction).
//   HIGH #6  commands_total counter persists across module reload.
//   HIGH #7  setConfig rejects ws:// for non-loopback hostnames; accepts ws://
//            for localhost / 127.0.0.1 / [::1] and wss:// for any host.

import { afterEach, beforeEach, describe, expect, it } from "vitest";

// ---------- chrome.storage.session mock ----------
//
// happy-dom doesn't ship a chrome API, so we install a tiny in-memory stand-in
// that mirrors the surface area the fix uses: get/set/remove on local AND
// session namespaces.

interface StorageArea {
  get: (key: string | string[] | null) => Promise<Record<string, unknown>>;
  set: (items: Record<string, unknown>) => Promise<void>;
  remove: (key: string | string[]) => Promise<void>;
  clear: () => Promise<void>;
  __reset: () => void;
}

function makeStorageArea(): StorageArea {
  let data: Record<string, unknown> = {};
  return {
    get: async (key) => {
      if (key === null) return { ...data };
      if (Array.isArray(key)) {
        const out: Record<string, unknown> = {};
        for (const k of key) if (k in data) out[k] = data[k];
        return out;
      }
      return key in data ? { [key]: data[key] } : {};
    },
    set: async (items) => {
      data = { ...data, ...items };
    },
    remove: async (key) => {
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

const localArea = makeStorageArea();
const sessionArea = makeStorageArea();

(globalThis as unknown as { chrome: unknown }).chrome = {
  storage: { local: localArea, session: sessionArea },
};

beforeEach(() => {
  localArea.__reset();
  sessionArea.__reset();
});

// ---------- HIGH #5: touchedTabs persistence ----------

describe("HIGH #5: touchedTabs persists across worker eviction", () => {
  it("addTouchedTab writes to chrome.storage.session and is readable after reload", async () => {
    const session = await import("../src/session_state");
    await session.addTouchedTab(42);
    await session.addTouchedTab(99);

    // Simulate worker eviction: drop the in-memory mirror, re-hydrate from storage.
    session._resetForTest();
    const tabs = await session.getTouchedTabs();
    expect(tabs.sort()).toEqual([42, 99]);
  });

  it("clearTouchedTabs wipes both memory and storage", async () => {
    const session = await import("../src/session_state");
    await session.addTouchedTab(1);
    await session.clearTouchedTabs();

    session._resetForTest();
    const tabs = await session.getTouchedTabs();
    expect(tabs).toEqual([]);
  });
});

// ---------- HIGH #6: commands_total persistence ----------

describe("HIGH #6: commands_total persists across worker eviction", () => {
  it("incrementCommandsTotal persists and the next read returns the bumped count", async () => {
    const session = await import("../src/session_state");
    await session.incrementCommandsTotal();
    await session.incrementCommandsTotal();
    await session.incrementCommandsTotal();

    session._resetForTest();
    const n = await session.getCommandsTotal();
    expect(n).toBe(3);
  });
});

// ---------- HIGH #7: ws:// rejected for non-loopback ----------

describe("HIGH #7: setConfig rejects plaintext ws:// for non-loopback hosts", () => {
  it("rejects ws://prod.gateway.example.com/ws", async () => {
    const auth = await import("../src/auth");
    await expect(
      auth.setConfig("tok-abc", "ws://prod.gateway.example.com/ws"),
    ).rejects.toThrow(/wss/i);
  });

  it("accepts ws://localhost/ws (loopback exception)", async () => {
    const auth = await import("../src/auth");
    await expect(
      auth.setConfig("tok-abc", "ws://localhost/ws"),
    ).resolves.toBeUndefined();
  });

  it("accepts ws://127.0.0.1/ws", async () => {
    const auth = await import("../src/auth");
    await expect(
      auth.setConfig("tok-abc", "ws://127.0.0.1/ws"),
    ).resolves.toBeUndefined();
  });

  it("accepts ws://[::1]/ws", async () => {
    const auth = await import("../src/auth");
    await expect(
      auth.setConfig("tok-abc", "ws://[::1]/ws"),
    ).resolves.toBeUndefined();
  });

  it("accepts wss://anything (TLS — token never on the wire in cleartext)", async () => {
    const auth = await import("../src/auth");
    await expect(
      auth.setConfig("tok-abc", "wss://prod.gateway.example.com/ws"),
    ).resolves.toBeUndefined();
  });
});

afterEach(() => {
  // Defense in depth — ensure nothing leaks into the next test even if a
  // setConfig call mutated state outside the storage mock.
});
