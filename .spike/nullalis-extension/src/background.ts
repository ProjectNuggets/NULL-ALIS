// MV3 service worker — the only long-lived(ish) component of the extension.
//
// Responsibilities:
//   1. Hold the WebSocket to the gateway (subject to MV3's idle-eviction; we
//      reconnect via WsClient when revived).
//   2. Dispatch each incoming Command:
//        - chrome.* commands (navigate, screenshot, list_tabs) handled inline
//        - content-script commands forwarded to the active tab
//   3. Talk to the popup for status + token management.
//   4. Provide the global STOP action that severs WS + reloads agent-touched tabs.
//
// Note: MV3 evicts idle workers after ~30 s. chrome.runtime listeners revive
// the worker on demand; we re-initialize state from chrome.storage on every
// awakening. We do NOT depend on top-level mutable state surviving eviction.

import { getConfig, setConfig, clearConfig } from "./auth";
import { WsClient } from "./ws_client";
import { BACKGROUND_TOOLS, CommandError, validateCommand } from "./commands";
import { checkNavigateUrl } from "./url_guard";
import {
  addConsentedTab,
  addTouchedTab,
  clearConsentedTabs,
  clearStopped,
  drainTouchedTabs,
  getCommandsTotal,
  getConsentedTabs,
  incrementCommandsTotal,
  isStopped,
  isTabConsented,
  removeConsentedTab,
  setStopped,
} from "./session_state";

// C1/H1 — the content script is no longer declared in manifest.json. It is
// injected on demand into consented tabs via chrome.scripting.executeScript.
// This is the stable classic-IIFE file emitted by vite.content.config.ts.
const CONTENT_SCRIPT_FILE = "content.js";

// H3 — default per-command timeout when the server doesn't specify one.
const DEFAULT_COMMAND_TIMEOUT_MS = 30_000;
import type {
  BgToContentMessage,
  Command,
  CommandResult,
  ConnectionStatus,
  ContentToBgMessage,
  ExecuteInTabResult,
  PopupRequest,
  PopupResponse,
  ServerMessage,
  ToolName,
} from "./types";

const EXTENSION_VERSION = chrome.runtime.getManifest().version;

// ---------- Worker-scope state (best-effort, may be evicted) ----------

let wsClient: WsClient | null = null;
const status: ConnectionStatus = {
  connected: false,
  authenticated: false,
  last_error: null,
  gateway_url: null,
  has_token: false,
  last_command: null,
  commands_total: 0,
  consented_tabs: [],
  active_tab_id: null,
  stopped: false,
};

// Touched-tabs + commands_total are now persisted via chrome.storage.session
// (see ./session_state). MV3 evicts idle workers after ~30s; in-memory state
// would otherwise reset and the STOP button would reload zero tabs while the
// popup poll would show wrong counts. Wave 3 review HIGH #5, #6.

// H4 — in-flight command tracking. STOP must abort/await everything currently
// running before it reloads touched tabs and severs the socket. Each command's
// settled promise is registered here; its AbortController lets a long-running
// content-script round-trip be cancelled.
const inFlight = new Map<string, { promise: Promise<void>; abort: AbortController }>();

// ---------- Connection lifecycle ----------

async function ensureConnection(): Promise<void> {
  // H4 — refuse to (re)connect while the STOP latch is set. The latch is
  // cleared ONLY by an explicit user `connect` from the popup (handled in
  // handlePopupRequest before calling ensureConnection), so an auto-reconnect
  // path (onStartup / onInstalled / module-load) can never silently revive a
  // stopped agent.
  if (await isStopped()) {
    teardownConnection();
    return;
  }
  const cfg = await getConfig();
  status.has_token = cfg !== null;
  status.gateway_url = cfg?.gateway_url ?? null;
  if (!cfg) {
    // No token configured — popup will prompt the user.
    teardownConnection();
    return;
  }
  if (wsClient && wsClient.isConnected()) return;

  teardownConnection();
  wsClient = new WsClient({
    url: cfg.gateway_url,
    token: cfg.token,
    extensionVersion: EXTENSION_VERSION,
    onMessage: handleServerMessage,
    onStateChange: (connected, err) => {
      status.connected = connected;
      status.last_error = err ?? null;
      if (!connected) {
        // Auth state can only be true while the socket is up; drop it when
        // we lose the connection so the popup doesn't show stale "authenticated".
        status.authenticated = false;
      }
    },
    onAuthStateChange: (state, reason) => {
      // Surface auth handshake outcome in the popup so the user sees what
      // happened (red badge "auth_failed: invalid_token" vs green "authenticated").
      // Wave 3 review CRITICAL #5.
      if (state === "authenticated") {
        status.authenticated = true;
        status.last_error = null;
      } else {
        // "auth_failed" / "auth_timeout" — surface the reason
        status.authenticated = false;
        status.last_error = reason ? `${state}: ${reason}` : state;
      }
    },
  });
  wsClient.start();
}

function teardownConnection(): void {
  if (wsClient) {
    wsClient.stop();
    wsClient = null;
  }
  status.connected = false;
  status.authenticated = false;
}

// ---------- Server frame handling ----------

function handleServerMessage(msg: ServerMessage): void {
  // Auth-ack / pong / ping pass through; only Commands need dispatch.
  if ("type" in msg) {
    // Control frame — nothing to do at this layer (pings handled in WsClient).
    return;
  }
  // Double-defense (Wave 3 review CRITICAL #5): even though WsClient drops
  // pre-auth_ack frames internally, we re-check here so any code path that
  // bypasses WsClient (future refactors, direct injection in tests, etc.)
  // still hits the gate. M3 — downgraded from console.warn to console.debug:
  // this is an expected race on reconnect, not an alarm, and warn-level noise
  // (and any args it carries) shouldn't land in user-visible logs.
  if (!wsClient || !wsClient.isAuthenticated()) {
    console.debug("[nullalis-bg] dropping command — wsClient not authenticated");
    return;
  }
  void executeCommand(msg);
}

async function executeCommand(c: Command): Promise<void> {
  const startedAt = Date.now();

  // H4 — refuse to dispatch while latched-stopped. A command that arrives in
  // the window between STOP and the socket actually closing must NOT run.
  if (await isStopped()) {
    sendResult({
      command_id: c.command_id,
      ok: false,
      error: { code: "stopped", message: "agent is stopped; press connect to resume" },
      duration_ms: Date.now() - startedAt,
    });
    return;
  }

  status.last_command = { tool: c.tool, command_id: c.command_id, at_ms: startedAt };
  // Persist the counter via storage.session so it survives worker eviction.
  // Wave 3 review HIGH #6. We also update the in-memory mirror in `status`
  // so synchronous popup reads aren't stale until the next get_status call.
  status.commands_total = await incrementCommandsTotal();

  try {
    validateCommand(c);
  } catch (err) {
    sendResult({
      command_id: c.command_id,
      ok: false,
      error: errorPayload(err),
      duration_ms: Date.now() - startedAt,
    });
    return;
  }

  // H3 + H4 — run the actual work racing a per-command timeout, and register
  // the settled promise + an AbortController so STOP can await/cancel it.
  const abort = new AbortController();
  const timeoutMs = typeof c.timeout_ms === "number" && c.timeout_ms > 0
    ? c.timeout_ms
    : DEFAULT_COMMAND_TIMEOUT_MS;

  const run = (async (): Promise<void> => {
    try {
      const result = await raceTimeout(dispatchCommand(c, abort.signal), timeoutMs, abort);
      sendResult({
        command_id: c.command_id,
        ok: true,
        result,
        duration_ms: Date.now() - startedAt,
      });
    } catch (err) {
      sendResult({
        command_id: c.command_id,
        ok: false,
        error: errorPayload(err),
        duration_ms: Date.now() - startedAt,
      });
    } finally {
      inFlight.delete(c.command_id);
    }
  })();

  inFlight.set(c.command_id, { promise: run, abort });
  await run;
}

/** Dispatch a validated command to its background or content-script handler. */
async function dispatchCommand(c: Command, signal: AbortSignal): Promise<unknown> {
  if (BACKGROUND_TOOLS.has(c.tool as ToolName)) {
    return await runBackgroundCommand(c);
  }
  return await forwardToContentScript(c, signal);
}

/**
 * H3 — resolve `work`, or reject with a `timeout` CommandError after `ms`.
 * The AbortController is fired on timeout so the underlying round-trip can
 * stop trying; the timer is always cleared so no dangling promise/timer leaks.
 */
function raceTimeout<T>(work: Promise<T>, ms: number, abort: AbortController): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      abort.abort();
      reject(new CommandError("timeout", `command exceeded ${ms}ms`));
    }, ms);
  });
  return Promise.race([work, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  }) as Promise<T>;
}

function sendResult(r: CommandResult): void {
  if (!wsClient) return;
  wsClient.send(r);
}

function errorPayload(err: unknown): { code: string; message: string } {
  if (err instanceof CommandError) return { code: err.code, message: err.message };
  if (err instanceof Error) return { code: "runtime", message: err.message };
  return { code: "unknown", message: String(err) };
}

// ---------- Background-side commands ----------

async function runBackgroundCommand(c: Command): Promise<unknown> {
  switch (c.tool as ToolName) {
    case "navigate":
      return await cmdNavigate(c.args);
    case "screenshot":
      return await cmdScreenshot(c.args);
    case "list_tabs":
      return await cmdListTabs();
    default:
      throw new CommandError("unknown_tool", `${c.tool} is not a background tool`);
  }
}

async function cmdNavigate(args: Record<string, unknown>): Promise<{ tab_id: number; url: string }> {
  const url = typeof args.url === "string" ? args.url : null;
  if (!url) throw new CommandError("invalid_args", "navigate requires url");

  // H2 — SSRF allowlist: http/https public hosts only. Reject javascript:,
  // data:, file:, chrome:, about:, view-source:, blob:, and loopback / RFC1918
  // / link-local / metadata / *.local hosts.
  const guard = checkNavigateUrl(url);
  if (!guard.ok) {
    throw new CommandError("url_blocked", guard.reason ?? "navigate target is blocked");
  }

  const newTab = args.new_tab === true;
  if (newTab) {
    // A brand-new tab the agent creates is implicitly consented — the user
    // asked (via an already-consented tab's command stream) to open it, and we
    // record it so the agent can keep driving it and STOP can reload it.
    const tab = await chrome.tabs.create({ url });
    if (tab.id !== undefined) {
      await addTouchedTab(tab.id);
      await addConsentedTab(tab.id);
    }
    return { tab_id: tab.id ?? -1, url };
  }
  // Same-tab navigation requires consent on the active tab.
  const active = await requireConsentedActiveTab();
  await chrome.tabs.update(active.id!, { url });
  await addTouchedTab(active.id!);
  return { tab_id: active.id!, url };
}

async function cmdScreenshot(args: Record<string, unknown>): Promise<{ data_url: string; full_page: boolean }> {
  // chrome.tabs.captureVisibleTab is viewport-only. Full-page would require
  // scroll-and-stitch which we defer to v1.1.
  // C1/H1 — screenshots reveal tab contents, so they require consent on the
  // active tab just like any other tab-touching command.
  await requireConsentedActiveTab();
  const fullPage = args.full_page === true;
  const dataUrl = await chrome.tabs.captureVisibleTab({ format: "png" });
  return { data_url: dataUrl, full_page: fullPage };
}

async function cmdListTabs(): Promise<Array<{ id: number; title: string; url: string; active: boolean }>> {
  // V1 returns only the active tab — multi-tab visibility is a v1.1 permission
  // gate. C1/H1 — list_tabs exposes the active tab's title+url, so it is gated
  // on consent for that tab too.
  const active = await requireConsentedActiveTab();
  return [
    {
      id: active.id ?? -1,
      title: active.title ?? "",
      url: active.url ?? "",
      active: true,
    },
  ];
}

async function getActiveTab(): Promise<chrome.tabs.Tab> {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab || tab.id === undefined) {
    throw new CommandError("no_active_tab", "no active tab in last focused window");
  }
  return tab;
}

/**
 * C1/H1 — resolve the active tab and assert the user has explicitly enabled
 * the agent on it. Every command that touches a tab funnels through here (or
 * the equivalent check in forwardToContentScript), so no command can act on a
 * non-consented tab. Throws `consent_required` otherwise.
 */
async function requireConsentedActiveTab(): Promise<chrome.tabs.Tab> {
  const tab = await getActiveTab();
  if (!(await isTabConsented(tab.id!))) {
    throw new CommandError(
      "consent_required",
      `agent is not enabled on tab ${tab.id}; enable it from the nullalis popup`,
    );
  }
  return tab;
}

// ---------- Forwarding to content script ----------

async function forwardToContentScript(c: Command, signal: AbortSignal): Promise<unknown> {
  // C1/H1 — content-script commands are the agent reading/writing the page;
  // they require consent on the active tab.
  const tab = await requireConsentedActiveTab();
  await addTouchedTab(tab.id!);

  // M1 — when the command carries allow_sensitive, surface it in the toast so
  // the user is told the agent may be writing a password / card field.
  const toast = c.allow_sensitive === true
    ? `nullalis agent → ${c.tool} (sensitive fields allowed)`
    : `nullalis agent → ${c.tool}`;
  void notifyToast(tab.id!, toast);

  const message: BgToContentMessage = { type: "execute_in_tab", command: c };
  // H3/H4 — if the command times out or STOP aborts, stop awaiting the tab.
  const response = await Promise.race([
    chrome.tabs.sendMessage(tab.id!, message).catch((e: unknown) => {
      throw new CommandError(
        "content_script_unreachable",
        `failed to message tab ${tab.id}: ${e instanceof Error ? e.message : String(e)}`,
      );
    }),
    abortRace(signal),
  ]);

  const r = response as ExecuteInTabResult | undefined;
  if (!r || r.type !== "execute_in_tab_result") {
    throw new CommandError("malformed_content_response", "content script returned no result");
  }
  if (!r.ok) {
    throw new CommandError(r.error?.code ?? "content_error", r.error?.message ?? "content script error");
  }
  return r.result;
}

/** Reject as soon as `signal` aborts (timeout or STOP). Never resolves. */
function abortRace(signal: AbortSignal): Promise<never> {
  return new Promise<never>((_resolve, reject) => {
    if (signal.aborted) {
      reject(new CommandError("aborted", "command aborted"));
      return;
    }
    signal.addEventListener(
      "abort",
      () => reject(new CommandError("aborted", "command aborted")),
      { once: true },
    );
  });
}

/**
 * C1/H1 — inject the on-demand content script into a consented tab. Called from
 * the popup's enable_active_tab handler. Idempotent: the content script guards
 * against double listener registration (src/content.ts).
 */
async function injectContentScript(tabId: number): Promise<void> {
  await chrome.scripting.executeScript({
    target: { tabId },
    files: [CONTENT_SCRIPT_FILE],
  });
}

async function notifyToast(tabId: number, message: string): Promise<void> {
  const msg: BgToContentMessage = { type: "show_toast", message, ttl_ms: 3_000 };
  try {
    await chrome.tabs.sendMessage(tabId, msg);
  } catch {
    // Toast is best-effort. If the content script isn't loaded (e.g. chrome://
    // page), we silently swallow — the command will fail with its own error.
  }
}

// ---------- Popup messaging ----------

chrome.runtime.onMessage.addListener(
  (
    req: PopupRequest | ContentToBgMessage,
    sender,
    sendResponse: (r: PopupResponse) => void
  ) => {
    // We only handle popup requests here; content responses come back via the
    // sendMessage promise chain in forwardToContentScript.
    if ("type" in req && (req as ContentToBgMessage).type === "execute_in_tab_result") {
      return false;
    }

    // C2 — sender validation. Popup-control requests (set_token, clear_token,
    // stop_all, connect, disconnect, enable_active_tab, ...) must originate
    // from THIS extension's own pages (the popup), never from a content script
    // or another extension. A content-script sender has `sender.tab` set; a
    // legitimate extension-page sender has none and a runtime URL under our own
    // origin. Reject anything that doesn't match.
    if (!isTrustedExtensionSender(sender)) {
      sendResponse({ ok: false, error: "forbidden: untrusted sender" });
      return false;
    }

    void handlePopupRequest(req as PopupRequest).then(sendResponse).catch((err: unknown) => {
      sendResponse({ ok: false, error: err instanceof Error ? err.message : String(err) });
    });
    return true; // async response
  }
);

/**
 * C2 — is this message from our own extension page (the popup), not a content
 * script or a different extension? Requires:
 *   - sender.id === our extension id, AND
 *   - sender.tab is undefined (content scripts always carry a tab), AND
 *   - sender.url is under our own extension origin.
 */
function isTrustedExtensionSender(sender: chrome.runtime.MessageSender): boolean {
  if (sender.id !== chrome.runtime.id) return false;
  if (sender.tab !== undefined) return false;
  const ownOrigin = chrome.runtime.getURL("");
  return typeof sender.url === "string" && sender.url.startsWith(ownOrigin);
}

async function handlePopupRequest(req: PopupRequest): Promise<PopupResponse> {
  switch (req.type) {
    case "get_status": {
      // Re-read config in case the popup updated it in another worker tick.
      const cfg = await getConfig();
      status.has_token = cfg !== null;
      status.gateway_url = cfg?.gateway_url ?? null;
      // Hydrate commands_total from storage.session — this worker may be a
      // fresh revive after eviction, so the in-memory mirror could be 0
      // even if the previous worker ran many commands. Wave 3 review HIGH #6.
      status.commands_total = await getCommandsTotal();
      // C1/H1 + H4 — surface consent + latch state to the popup.
      status.consented_tabs = await getConsentedTabs();
      status.stopped = await isStopped();
      status.active_tab_id = await getActiveTabIdSafe();
      return { ok: true, status };
    }
    case "set_token": {
      await setConfig(req.token, req.gateway_url);
      await ensureConnection();
      return { ok: true };
    }
    case "clear_token": {
      await clearConfig();
      teardownConnection();
      status.has_token = false;
      status.gateway_url = null;
      return { ok: true };
    }
    case "connect": {
      // H4 — an explicit user connect is the ONLY thing that clears the STOP
      // latch. Clear it first, then (re)connect.
      await clearStopped();
      await ensureConnection();
      return { ok: true };
    }
    case "disconnect": {
      teardownConnection();
      // C1/H1 — dropping the connection revokes all per-tab consent.
      await clearConsentedTabs();
      return { ok: true };
    }
    case "stop_all": {
      await stopAll();
      return { ok: true };
    }
    case "enable_active_tab": {
      // C1/H1 — the click that opened+used the popup is a user gesture, so
      // activeTab is granted for the active tab. Record consent and inject the
      // content script so the agent can drive it.
      const tab = await getActiveTab();
      const tabId = tab.id!;
      await addConsentedTab(tabId);
      try {
        await injectContentScript(tabId);
      } catch (err) {
        // Injection can fail on restricted pages (chrome://, the Web Store).
        // Roll back consent so we never claim a tab is enabled when it isn't.
        await removeConsentedTab(tabId);
        throw new CommandError(
          "inject_failed",
          `cannot enable agent on this tab: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
      return { ok: true, tab_id: tabId };
    }
    case "disable_tab": {
      // C1/H1 — explicit per-tab revocation.
      await removeConsentedTab(req.tab_id);
      return { ok: true };
    }
  }
}

/**
 * H4 — latched, in-flight-cancelling STOP.
 *
 * 1. Set the latch (refuses all further dispatch + reconnect).
 * 2. Abort + await every in-flight command so none can resurrect touched-tab
 *    state after we drain it.
 * 3. Route the touched-tab drain through the session-state mutex (runExclusive)
 *    so it can't interleave with a straggler addTouchedTab.
 * 4. Reload touched tabs, clear consent, and sever the socket.
 */
async function stopAll(): Promise<void> {
  await setStopped();

  // Abort + await in-flight commands. Each promise is the command's own
  // try/finally wrapper so awaiting never rejects here.
  const pending = [...inFlight.values()];
  for (const { abort } of pending) abort.abort();
  await Promise.allSettled(pending.map((p) => p.promise));

  // Sever the socket so no new frames arrive while we reload.
  teardownConnection();

  // Drain touched tabs atomically w.r.t. addTouchedTab, then reload.
  const tabIds = await drainTouchedTabs();
  for (const tabId of tabIds) {
    try {
      await chrome.tabs.reload(tabId);
    } catch {
      // Tab may be closed already — fine.
    }
  }

  // C1/H1 — STOP revokes all consent.
  await clearConsentedTabs();
}

/** Best-effort active-tab id for the popup; null if none. */
async function getActiveTabIdSafe(): Promise<number | null> {
  try {
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    return tab?.id ?? null;
  } catch {
    return null;
  }
}

// ---------- Tab lifecycle ----------

// C1/H1 — when a tab closes, drop it from the consented set so a future tab
// reusing the same id can't inherit stale consent.
chrome.tabs.onRemoved.addListener((tabId) => {
  void removeConsentedTab(tabId);
});

// ---------- Boot ----------

// Reconnect when the service worker first wakes (install, browser start, idle revive).
chrome.runtime.onStartup.addListener(() => {
  void ensureConnection();
});
chrome.runtime.onInstalled.addListener(() => {
  void ensureConnection();
});

// Best-effort initial connect when this module loads.
void ensureConnection();
