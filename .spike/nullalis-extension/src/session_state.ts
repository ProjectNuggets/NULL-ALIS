// Persistent worker state — backed by chrome.storage.session so it survives
// MV3 service-worker eviction (Wave 3 review HIGH #5, #6).
//
// MV3 evicts idle workers after ~30s. Module-level `Set<number>` / `let n=0`
// state is lost on eviction; the popup poll then shows wrong counts and the
// STOP button reloads zero tabs (§14.5 honesty violation — the button
// advertises an action it can't honor).
//
// chrome.storage.session is in-memory across the browser session (cleared on
// browser restart), survives worker eviction, and is per-extension scope —
// exactly the shape we want for "tabs the agent touched this browser session"
// and "commands run this browser session".
//
// We keep a thin in-memory mirror so synchronous reads in the hot path are
// fast, but every write is persisted, and `_resetForTest` lets unit tests
// simulate worker eviction by forcing a fresh hydrate from storage.

const TOUCHED_KEY = "nullalis_touched_tabs_v1";
const COMMANDS_TOTAL_KEY = "nullalis_commands_total_v1";

// In-memory mirrors. We treat `null` as "not yet hydrated".
let touchedMirror: Set<number> | null = null;
let commandsTotalMirror: number | null = null;

/** Force a fresh hydrate on the next read. Used to simulate worker eviction. */
export function _resetForTest(): void {
  touchedMirror = null;
  commandsTotalMirror = null;
}

async function hydrateTouched(): Promise<Set<number>> {
  if (touchedMirror !== null) return touchedMirror;
  const raw = await chrome.storage.session.get(TOUCHED_KEY);
  const arr = raw[TOUCHED_KEY];
  // Validate shape — we don't trust whatever a prior worker wrote.
  const list = Array.isArray(arr)
    ? arr.filter((n): n is number => typeof n === "number" && Number.isInteger(n))
    : [];
  touchedMirror = new Set<number>(list);
  return touchedMirror;
}

async function hydrateCommandsTotal(): Promise<number> {
  if (commandsTotalMirror !== null) return commandsTotalMirror;
  const raw = await chrome.storage.session.get(COMMANDS_TOTAL_KEY);
  const v = raw[COMMANDS_TOTAL_KEY];
  commandsTotalMirror = typeof v === "number" && Number.isFinite(v) ? v : 0;
  return commandsTotalMirror;
}

/** Record that the agent touched `tabId`. Persists to storage.session. */
export async function addTouchedTab(tabId: number): Promise<void> {
  const set = await hydrateTouched();
  set.add(tabId);
  await chrome.storage.session.set({ [TOUCHED_KEY]: [...set] });
}

/** Snapshot of touched tabs. */
export async function getTouchedTabs(): Promise<number[]> {
  const set = await hydrateTouched();
  return [...set];
}

/** Wipe both memory and storage. STOP handler calls this after reloads. */
export async function clearTouchedTabs(): Promise<void> {
  touchedMirror = new Set<number>();
  await chrome.storage.session.remove(TOUCHED_KEY);
}

/** Bump commands_total by 1 and persist. Returns the new value. */
export async function incrementCommandsTotal(): Promise<number> {
  const cur = await hydrateCommandsTotal();
  const next = cur + 1;
  commandsTotalMirror = next;
  await chrome.storage.session.set({ [COMMANDS_TOTAL_KEY]: next });
  return next;
}

/** Read current commands_total. */
export async function getCommandsTotal(): Promise<number> {
  return hydrateCommandsTotal();
}
