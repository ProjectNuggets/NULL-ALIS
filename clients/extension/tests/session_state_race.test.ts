// META HIGH #4 (2026-05-25) regression — session_state.ts counter
// race-safety.
//
// Pre-fix: `incrementCommandsTotal` did read-modify-write on
// `commandsTotalMirror` + storage. Two near-simultaneous calls that
// scheduled their `await chrome.storage.session.set(...)` before either
// read could observe the other's write lost an increment. JS's
// single-threaded event loop saves us within a single tick, but
// `await` points serialize and the storage call IS the await point,
// so an interleaving like:
//
//   call A: read mirror=0 → await get → cur=0 → next=1 → write
//   call B: read mirror=0 (interleaved before A's write set the mirror) →
//           await get → cur=0 → next=1 → write
//
// loses one increment. Same shape applies to addTouchedTab.
//
// Post-fix: a mutex-via-promise serialized queue. All read-modify-write
// goes through `runExclusive` so the next call doesn't start until the
// prior one's storage round-trip has settled.

import { afterEach, beforeEach, describe, expect, it } from "vitest";

// ---------- chrome.storage.session mock with a controllable "slow" set ----------
//
// The race only manifests when the storage `set` returns asynchronously
// (so the next call can interleave). Our mock makes `set` a real
// await-able Promise, returning on a microtask queue tick. Each set
// also dumps the data to a closure-shared `store` so a race that
// would happen in real Chrome happens here too.

interface StorageArea {
  get: (key: string | string[] | null) => Promise<Record<string, unknown>>;
  set: (items: Record<string, unknown>) => Promise<void>;
  remove: (key: string | string[]) => Promise<void>;
  clear: () => Promise<void>;
  __reset: () => void;
}

function makeRacyStorageArea(): StorageArea {
  let data: Record<string, unknown> = {};
  return {
    get: async (key) => {
      // Yield once so callers can interleave (simulates IPC roundtrip).
      await Promise.resolve();
      if (key === null) return { ...data };
      if (Array.isArray(key)) {
        const out: Record<string, unknown> = {};
        for (const k of key) if (k in data) out[k] = data[k];
        return out;
      }
      return key in data ? { [key]: data[key] } : {};
    },
    set: async (items) => {
      await Promise.resolve();
      data = { ...data, ...items };
    },
    remove: async (key) => {
      await Promise.resolve();
      const keys = Array.isArray(key) ? key : [key];
      for (const k of keys) delete data[k];
    },
    clear: async () => {
      await Promise.resolve();
      data = {};
    },
    __reset: () => {
      data = {};
    },
  };
}

const localArea = makeRacyStorageArea();
const sessionArea = makeRacyStorageArea();

(globalThis as unknown as { chrome: unknown }).chrome = {
  storage: { local: localArea, session: sessionArea },
};

beforeEach(() => {
  localArea.__reset();
  sessionArea.__reset();
});

afterEach(() => {
  localArea.__reset();
  sessionArea.__reset();
});

describe("META HIGH #4: incrementCommandsTotal is race-safe", () => {
  it("100 parallel increments produce exactly 100 (no lost updates)", async () => {
    const session = await import("../src/session_state");
    session._resetForTest();

    // Fire 100 increments concurrently — under the unfixed code,
    // some interleavings drop increments and the final count is
    // < 100.
    const promises: Promise<number>[] = [];
    for (let i = 0; i < 100; i++) {
      promises.push(session.incrementCommandsTotal());
    }
    await Promise.all(promises);

    // Verify via a cold read (simulate worker eviction) to confirm
    // storage actually holds 100, not just the in-memory mirror.
    session._resetForTest();
    const n = await session.getCommandsTotal();
    expect(n).toBe(100);
  });

  it("returned values from each call are unique and form 1..N", async () => {
    // Stronger property: each call returns ITS post-increment value,
    // and the union of returned values is exactly {1, 2, ..., N}.
    // A racy implementation would return duplicates (e.g. two calls
    // both return 1 because both saw cur=0).
    const session = await import("../src/session_state");
    session._resetForTest();

    const N = 50;
    const promises: Promise<number>[] = [];
    for (let i = 0; i < N; i++) {
      promises.push(session.incrementCommandsTotal());
    }
    const results = await Promise.all(promises);
    const sorted = results.slice().sort((a, b) => a - b);
    const expected = Array.from({ length: N }, (_, i) => i + 1);
    expect(sorted).toEqual(expected);
  });
});

describe("META HIGH #4: addTouchedTab is race-safe", () => {
  it("100 parallel addTouchedTab calls preserve every tab id", async () => {
    const session = await import("../src/session_state");
    session._resetForTest();

    const promises: Promise<void>[] = [];
    for (let i = 1; i <= 100; i++) {
      promises.push(session.addTouchedTab(i));
    }
    await Promise.all(promises);

    session._resetForTest();
    const tabs = await session.getTouchedTabs();
    expect(tabs.length).toBe(100);
    // Sort + verify every id 1..100 is present.
    const sorted = tabs.slice().sort((a, b) => a - b);
    const expected = Array.from({ length: 100 }, (_, i) => i + 1);
    expect(sorted).toEqual(expected);
  });
});
