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
  /**
   * Server-issued opt-in to write password / credit-card fields (M1). The
   * content script default-DENIES writes to input[type=password] and
   * autocomplete=cc-* unless this is explicitly true. Defaults to false.
   */
  allow_sensitive?: boolean;
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

/**
 * Server -> extension: per-connection anti-replay challenge (Plan-8).
 * Sent by the gateway immediately after the WS upgrade, BEFORE it waits
 * for the auth frame. The extension must echo `nonce` verbatim in its
 * subsequent `auth` frame. A captured `auth` frame replayed on a fresh
 * connection carries a stale nonce and is rejected by the gateway.
 */
export interface Challenge {
  type: "challenge";
  nonce: string;
}

/**
 * Authentication frame sent by the extension after it receives the
 * server `challenge` frame. Echoes the server-issued `nonce` alongside
 * the long-lived token (Plan-8 anti-replay).
 */
export interface AuthFrame {
  type: "auth";
  token: string;
  extension_version: string;
  /** Server-issued per-connection nonce, echoed back verbatim. */
  nonce: string;
}

/** Server may reject the auth and close. */
export interface AuthAck {
  type: "auth_ack";
  ok: boolean;
  error?: string;
}

export type ServerMessage = Command | Ping | Pong | AuthAck | Challenge;
export type ClientMessage = CommandResult | Ping | Pong | AuthFrame;

// ---------- Background <-> popup messaging (chrome.runtime.sendMessage) ----------

export type PopupRequest =
  | { type: "get_status" }
  | { type: "set_token"; token: string; gateway_url: string }
  | { type: "clear_token" }
  | { type: "connect" }
  | { type: "disconnect" }
  | { type: "stop_all" }
  /** Grant the agent consent on the currently-active tab (C1/H1). Issued
   *  from the popup on a user gesture so activeTab is granted for that tab. */
  | { type: "enable_active_tab" }
  /** Revoke consent for a specific tab (C1/H1). */
  | { type: "disable_tab"; tab_id: number };

export interface ConnectionStatus {
  /** Whether the extension currently has an open WS to the gateway. */
  connected: boolean;
  /**
   * Whether the gateway has successfully `auth_ack`-ed the open socket.
   * Distinct from `connected`: a connected-but-unauthenticated socket exists
   * during the brief window between WS open and auth_ack, AND while a
   * misbehaving gateway is silently dropping the auth frame. Commands are
   * NEVER dispatched while this is false. (Wave 3 review CRITICAL #5.)
   */
  authenticated: boolean;
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
  /**
   * Tab ids the user has explicitly enabled the agent on (C1/H1). The agent
   * refuses every command targeting a tab not in this set. Cleared on STOP and
   * on disconnect.
   */
  consented_tabs: number[];
  /** The active tab's id, so the popup can offer "enable this tab". */
  active_tab_id: number | null;
  /** Whether the agent is latched-stopped (H4). While true no command runs and
   *  the socket will not auto-reconnect; cleared only by an explicit connect. */
  stopped: boolean;
}

export type PopupResponse =
  | { ok: true; status: ConnectionStatus }
  | { ok: true }
  | { ok: true; tab_id: number }
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
