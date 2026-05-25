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
};

/** Tabs the agent has touched in this worker lifetime — used by STOP to reload them. */
const touchedTabs = new Set<number>();

// ---------- Connection lifecycle ----------

async function ensureConnection(): Promise<void> {
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
  // still hits the gate. If this fires the WsClient gate failed too — log
  // it loudly so we notice.
  if (!wsClient || !wsClient.isAuthenticated()) {
    console.warn(
      "[nullalis-bg] DROPPING command — wsClient not authenticated",
      { command_id: msg.command_id, tool: msg.tool },
    );
    return;
  }
  void executeCommand(msg);
}

async function executeCommand(c: Command): Promise<void> {
  const startedAt = Date.now();
  status.last_command = { tool: c.tool, command_id: c.command_id, at_ms: startedAt };
  status.commands_total++;

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

  try {
    let result: unknown;
    if (BACKGROUND_TOOLS.has(c.tool as ToolName)) {
      result = await runBackgroundCommand(c);
    } else {
      result = await forwardToContentScript(c);
    }
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
  }
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
  const newTab = args.new_tab === true;
  if (newTab) {
    const tab = await chrome.tabs.create({ url });
    if (tab.id !== undefined) touchedTabs.add(tab.id);
    return { tab_id: tab.id ?? -1, url };
  }
  const active = await getActiveTab();
  await chrome.tabs.update(active.id!, { url });
  touchedTabs.add(active.id!);
  return { tab_id: active.id!, url };
}

async function cmdScreenshot(args: Record<string, unknown>): Promise<{ data_url: string; full_page: boolean }> {
  // chrome.tabs.captureVisibleTab is viewport-only. Full-page would require
  // scroll-and-stitch which we defer to v1.1.
  const fullPage = args.full_page === true;
  const dataUrl = await chrome.tabs.captureVisibleTab({ format: "png" });
  return { data_url: dataUrl, full_page: fullPage };
}

async function cmdListTabs(): Promise<Array<{ id: number; title: string; url: string; active: boolean }>> {
  // V1 returns only the active tab — multi-tab visibility is a v1.1 permission gate.
  const active = await getActiveTab();
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

// ---------- Forwarding to content script ----------

async function forwardToContentScript(c: Command): Promise<unknown> {
  const tab = await getActiveTab();
  touchedTabs.add(tab.id!);

  // Announce in-page so the user sees what's happening.
  void notifyToast(tab.id!, `nullalis agent → ${c.tool}`);

  const message: BgToContentMessage = { type: "execute_in_tab", command: c };
  const response = await chrome.tabs.sendMessage(tab.id!, message).catch((e: unknown) => {
    throw new CommandError(
      "content_script_unreachable",
      `failed to message tab ${tab.id}: ${e instanceof Error ? e.message : String(e)}`
    );
  });

  const r = response as ExecuteInTabResult | undefined;
  if (!r || r.type !== "execute_in_tab_result") {
    throw new CommandError("malformed_content_response", "content script returned no result");
  }
  if (!r.ok) {
    throw new CommandError(r.error?.code ?? "content_error", r.error?.message ?? "content script error");
  }
  return r.result;
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
    _sender,
    sendResponse: (r: PopupResponse) => void
  ) => {
    // We only handle popup requests here; content responses come back via the
    // sendMessage promise chain in forwardToContentScript.
    if ("type" in req && (req as ContentToBgMessage).type === "execute_in_tab_result") {
      return false;
    }
    void handlePopupRequest(req as PopupRequest).then(sendResponse).catch((err: unknown) => {
      sendResponse({ ok: false, error: err instanceof Error ? err.message : String(err) });
    });
    return true; // async response
  }
);

async function handlePopupRequest(req: PopupRequest): Promise<PopupResponse> {
  switch (req.type) {
    case "get_status": {
      // Re-read config in case the popup updated it in another worker tick.
      const cfg = await getConfig();
      status.has_token = cfg !== null;
      status.gateway_url = cfg?.gateway_url ?? null;
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
      await ensureConnection();
      return { ok: true };
    }
    case "disconnect": {
      teardownConnection();
      return { ok: true };
    }
    case "stop_all": {
      teardownConnection();
      // Reload every tab the agent touched in this lifetime, so any partial
      // state (typing a query, a half-filled form) is discarded.
      for (const tabId of touchedTabs) {
        try {
          await chrome.tabs.reload(tabId);
        } catch {
          // Tab may be closed already — fine.
        }
      }
      touchedTabs.clear();
      return { ok: true };
    }
  }
}

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
