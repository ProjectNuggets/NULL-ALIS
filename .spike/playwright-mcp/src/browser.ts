// BrowserPool — one shared Chromium, one BrowserContext per session_id.
//
// Why this shape:
//   - Launching Chromium costs ~500ms. Pooling at the browser level means the
//     second navigate in a session is sub-200ms instead of cold-launch.
//   - BrowserContext gives us cookie / storage / cache isolation per session
//     without a full browser process per session. This is the same shape
//     Playwright recommends for multi-tenant workloads.
//   - Idle cleanup is critical: a long-running server with sticky sessions
//     leaks memory (each context holds a real Chromium tab + IPC pipe). We
//     close contexts that haven't been touched in 5 minutes.

import {
  type Browser,
  type BrowserContext,
  type Page,
  chromium,
} from "playwright";
import { sanitizeUrl } from "./sanitize.js";

/** Default idle timeout. Operators can override via env. */
const DEFAULT_IDLE_TIMEOUT_MS = 5 * 60 * 1000;

/** How often the reaper runs. */
const REAPER_INTERVAL_MS = 30_000;

export interface SessionInfo {
  session_id: string;
  age_ms: number;
  last_url: string | null;
  idle_ms: number;
}

interface SessionState {
  context: BrowserContext;
  page: Page;
  created_at: number;
  last_used: number;
  last_url: string | null;
  /**
   * In-flight tool calls against this session. The reaper refuses to reap a
   * session while this is > 0 — otherwise a long-running call (wait_for with
   * a big timeout, networkidle navigate on a slow site) gets a confusing
   * "Target closed" error mid-call. Wave 3 review HIGH #8.
   */
  in_flight: number;
}

export interface BrowserPoolOptions {
  /** When true (default), launch Chromium headless. */
  headless?: boolean;
  /** Per-session idle timeout in ms. Default 5 minutes. */
  idle_timeout_ms?: number;
  /** Disable the background reaper. Useful for tests that drive cleanup manually. */
  disable_reaper?: boolean;
}

/**
 * Singleton-per-process pool. Construct once at server startup, share across
 * tool handlers. Calls are serialized at the JS layer naturally (single-threaded
 * event loop) so we don't need locks for the Map mutations.
 */
export class BrowserPool {
  private browser: Browser | null = null;
  private readonly sessions = new Map<string, SessionState>();
  /**
   * In-flight counter for sessions that don't have a SessionState yet — the
   * first tool call increments here before getOrCreate runs. We fold the
   * value into SessionState.in_flight as soon as the slot exists. Wave 3
   * review HIGH #8.
   */
  private readonly pendingCalls = new Map<string, number>();
  private readonly idle_timeout_ms: number;
  private readonly headless: boolean;
  private reaper_handle: NodeJS.Timeout | null = null;
  private shutting_down = false;

  constructor(opts: BrowserPoolOptions = {}) {
    this.headless = opts.headless ?? true;
    this.idle_timeout_ms = opts.idle_timeout_ms ?? DEFAULT_IDLE_TIMEOUT_MS;
    if (!opts.disable_reaper) {
      this.reaper_handle = setInterval(
        () => void this.reapIdle(),
        REAPER_INTERVAL_MS,
      );
      // Don't keep the process alive just for the reaper.
      this.reaper_handle.unref();
    }
  }

  /** Lazy-launch Chromium on first session request. */
  private async ensureBrowser(): Promise<Browser> {
    if (this.browser && this.browser.isConnected()) return this.browser;
    this.browser = await chromium.launch({
      headless: this.headless,
      // Disable extensions, default browser checks, and other noise that
      // doesn't matter for a server-side automation context.
      args: ["--disable-extensions", "--no-default-browser-check"],
    });
    return this.browser;
  }

  /**
   * Get (or lazy-create) the BrowserContext + Page for this session. The page
   * persists across calls; tools that need a fresh page should call
   * `closeSession` first.
   */
  async getOrCreate(session_id: string): Promise<{ context: BrowserContext; page: Page }> {
    if (this.shutting_down) {
      throw new Error("BrowserPool is shutting down");
    }
    const existing = this.sessions.get(session_id);
    if (existing) {
      existing.last_used = Date.now();
      return { context: existing.context, page: existing.page };
    }
    const browser = await this.ensureBrowser();
    const context = await browser.newContext({
      // Reasonable defaults — operators can override via env later if needed.
      viewport: { width: 1280, height: 800 },
      userAgent:
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 nullalis-playwright-mcp",
    });
    // SSRF defense layer 2: sanitize every outgoing request URL, not just the
    // user-input one. Catches:
    //   - redirects (302 → http://169.254.169.254/...)
    //   - sub-resources (<img src=metadata-host>, <iframe src=loopback>, etc.)
    //   - JS-initiated fetches (fetch(), XHR, WebSocket upgrades)
    //   - DNS rebinding (public hostname resolving to RFC1918 at request time —
    //     the URL string we see post-resolution still hits the sanitizer)
    // Performance cost: one URL parse + one IP classification per request.
    // Wave 3 review CRITICAL #4.
    await context.route("**", async (route) => {
      const url = route.request().url();
      const verdict = sanitizeUrl(url);
      if (!verdict.ok) {
        try {
          await route.abort("blockedbyclient");
        } catch {
          // Route already handled by another listener / page closed mid-flight.
        }
        return;
      }
      try {
        await route.continue();
      } catch {
        // Same: tolerate races against page/context teardown.
      }
    });
    const page = await context.newPage();
    const now = Date.now();
    // Roll any pending in_flight counter (recorded by beginCall before the
    // session existed) into the new SessionState.
    const pending = this.pendingCalls.get(session_id) ?? 0;
    if (pending > 0) this.pendingCalls.delete(session_id);
    const state: SessionState = {
      context,
      page,
      created_at: now,
      last_used: now,
      last_url: null,
      in_flight: pending,
    };
    this.sessions.set(session_id, state);
    return { context, page };
  }

  /**
   * Tool entry — increment the in-flight counter so the reaper doesn't sweep
   * a session out from under a running call. Pair with `endCall` in a finally.
   * Safe to call before `getOrCreate` (we lazy-create the slot if needed) so
   * tools can wrap their entire body.
   *
   * Wave 3 review HIGH #8.
   */
  beginCall(session_id: string): void {
    const s = this.sessions.get(session_id);
    if (s) {
      s.in_flight += 1;
      return;
    }
    // Session not yet created — record the pending counter so the inevitable
    // getOrCreate sees a non-zero in_flight. We don't allocate a SessionState
    // yet; instead we stash a placeholder in pendingCalls and roll it in.
    const prev = this.pendingCalls.get(session_id) ?? 0;
    this.pendingCalls.set(session_id, prev + 1);
  }

  /** Tool exit — decrement. Safe to call even if the session was reaped. */
  endCall(session_id: string): void {
    const s = this.sessions.get(session_id);
    if (s && s.in_flight > 0) {
      s.in_flight -= 1;
      return;
    }
    const pending = this.pendingCalls.get(session_id);
    if (pending && pending > 0) {
      const next = pending - 1;
      if (next === 0) this.pendingCalls.delete(session_id);
      else this.pendingCalls.set(session_id, next);
    }
  }

  /** Update the last-URL tracker after a navigate. */
  noteUrl(session_id: string, url: string): void {
    const s = this.sessions.get(session_id);
    if (s) {
      s.last_url = url;
      s.last_used = Date.now();
    }
  }

  /** Bump idle clock — call from tool handlers that don't navigate. */
  touch(session_id: string): void {
    const s = this.sessions.get(session_id);
    if (s) s.last_used = Date.now();
  }

  /** Close one session's BrowserContext. No-op if unknown. */
  async closeSession(session_id: string): Promise<boolean> {
    const s = this.sessions.get(session_id);
    if (!s) return false;
    this.sessions.delete(session_id);
    try {
      await s.context.close();
    } catch {
      // Already-closed context is fine; the caller asked us to free it.
    }
    return true;
  }

  /** Snapshot of all active sessions for the list_sessions tool. */
  listSessions(): SessionInfo[] {
    const now = Date.now();
    const out: SessionInfo[] = [];
    for (const [session_id, s] of this.sessions.entries()) {
      out.push({
        session_id,
        age_ms: now - s.created_at,
        last_url: s.last_url,
        idle_ms: now - s.last_used,
      });
    }
    return out;
  }

  /**
   * Close any session whose idle window exceeds the threshold. Returns the
   * number of sessions reaped. Exposed for tests so the time-based check can
   * be driven deterministically.
   */
  async reapIdle(now: number = Date.now()): Promise<number> {
    let reaped = 0;
    for (const [session_id, s] of [...this.sessions.entries()]) {
      // Wave 3 review HIGH #8: do NOT reap a session that's currently
      // servicing a tool call. The reaper would otherwise destroy the
      // BrowserContext mid-call (long wait_for, networkidle navigate on a
      // slow site) and the agent would see a confusing "Target closed".
      if (s.in_flight > 0) continue;
      if (now - s.last_used >= this.idle_timeout_ms) {
        await this.closeSession(session_id);
        reaped += 1;
      }
    }
    return reaped;
  }

  /** Shut down everything. Idempotent. */
  async shutdown(): Promise<void> {
    if (this.shutting_down) return;
    this.shutting_down = true;
    if (this.reaper_handle) {
      clearInterval(this.reaper_handle);
      this.reaper_handle = null;
    }
    for (const session_id of [...this.sessions.keys()]) {
      await this.closeSession(session_id);
    }
    if (this.browser) {
      try {
        await this.browser.close();
      } catch {
        // best-effort
      }
      this.browser = null;
    }
  }
}
