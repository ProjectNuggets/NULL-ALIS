// Wire types shared between gateway, background service worker, content script,
// and popup UI. Keeping them in one file makes the protocol auditable in one
// glance — important for a tool that operates the user's browser.

// ---------- Gateway <-> extension wire protocol ----------

export type ToolName =
  | "navigate"
  | "click"
  | "type"
  | "fill_form"
  | "screenshot"
  | "get_text"
  | "get_dom"
  | "wait_for"
  | "scroll"
  | "list_tabs";

/** Gateway -> extension: a single command to execute in the active tab. */
export interface Command {
  command_id: string;
  tool: ToolName;
  args: Record<string, unknown>;
  /** Optional per-command timeout. Defaults to 30s. */
  timeout_ms?: number;
}

/** Extension -> gateway: result of executing a single command. */
export interface CommandResult {
  command_id: string;
  ok: boolean;
  result?: unknown;
  error?: { code: string; message: string };
  duration_ms: number;
}

/** Heartbeat in either direction. */
export interface Ping {
  type: "ping";
}
export interface Pong {
  type: "pong";
}

/** Authentication frame sent by the extension immediately after the socket opens. */
export interface AuthFrame {
  type: "auth";
  token: string;
  extension_version: string;
}

/** Server may reject the auth and close. */
export interface AuthAck {
  type: "auth_ack";
  ok: boolean;
  error?: string;
}

export type ServerMessage = Command | Ping | Pong | AuthAck;
export type ClientMessage = CommandResult | Ping | Pong | AuthFrame;

// ---------- Background <-> popup messaging (chrome.runtime.sendMessage) ----------

export type PopupRequest =
  | { type: "get_status" }
  | { type: "set_token"; token: string; gateway_url: string }
  | { type: "clear_token" }
  | { type: "connect" }
  | { type: "disconnect" }
  | { type: "stop_all" };

export interface ConnectionStatus {
  /** Whether the extension currently has an open WS to the gateway. */
  connected: boolean;
  /** Last error message if the most recent connection attempt failed. */
  last_error: string | null;
  /** Gateway URL the extension is configured to talk to. */
  gateway_url: string | null;
  /** Whether a token is configured (we do NOT return the token itself). */
  has_token: boolean;
  /** Most recent command the agent issued, for the popup activity feed. */
  last_command: { tool: ToolName; command_id: string; at_ms: number } | null;
  /** Number of commands executed since the extension loaded. */
  commands_total: number;
}

export type PopupResponse =
  | { ok: true; status: ConnectionStatus }
  | { ok: true }
  | { ok: false; error: string };

// ---------- Background <-> content script messaging ----------

/** Background asks content script to execute a command in its tab. */
export interface ExecuteInTab {
  type: "execute_in_tab";
  command: Command;
}

/** Content script returns the result. */
export interface ExecuteInTabResult {
  type: "execute_in_tab_result";
  command_id: string;
  ok: boolean;
  result?: unknown;
  error?: { code: string; message: string };
}

/** Background asks content script to show a toast that the agent is acting. */
export interface ShowToast {
  type: "show_toast";
  message: string;
  /** Auto-dismiss after this many ms. 0 means stay until next toast. */
  ttl_ms?: number;
}

export type BgToContentMessage = ExecuteInTab | ShowToast;
export type ContentToBgMessage = ExecuteInTabResult;

// ---------- Storage shape (chrome.storage.local) ----------

export interface StoredConfig {
  /** Bearer token issued by the nullalis gateway. */
  token: string;
  /** Gateway WebSocket URL — e.g. wss://gateway.nullalis.local/ext/ws */
  gateway_url: string;
}
