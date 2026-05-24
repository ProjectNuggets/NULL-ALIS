import type { BrowserPool, SessionInfo } from "../browser.js";

// ── close_session ──────────────────────────────────────────────────────

export const closeSessionSchema = {
  type: "object",
  properties: {
    session_id: { type: "string", description: "Session to close. Default 'default'." },
  },
  additionalProperties: false,
} as const;

export const closeSessionDescription =
  "Close the BrowserContext for this session_id, freeing cookies, storage, and the live Chromium tab. Idempotent — closing an unknown session returns existed:false instead of erroring.";

export interface CloseSessionArgs {
  session_id?: string;
}

export interface CloseSessionResult {
  existed: boolean;
}

export async function closeSession(
  pool: BrowserPool,
  args: CloseSessionArgs,
): Promise<CloseSessionResult> {
  const session_id = args.session_id ?? "default";
  const existed = await pool.closeSession(session_id);
  return { existed };
}

// ── list_sessions ──────────────────────────────────────────────────────

export const listSessionsSchema = {
  type: "object",
  properties: {},
  additionalProperties: false,
} as const;

export const listSessionsDescription =
  "List every active session: id, age, idle time, and the last URL visited. Useful before close_session to find leaked sessions, or just to see what's in flight.";

export interface ListSessionsResult {
  sessions: SessionInfo[];
}

export function listSessions(pool: BrowserPool): ListSessionsResult {
  return { sessions: pool.listSessions() };
}
