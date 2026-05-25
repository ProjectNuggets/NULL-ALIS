import type { BrowserPool } from "../browser.js";

// SECURITY NOTE: this tool is gated behind PLAYWRIGHT_MCP_ALLOW_EVAL=1.
//
// Reasoning: arbitrary JS in the page context can:
//   - exfiltrate cookies / localStorage from any site visited in this session
//   - call fetch() to internal endpoints from inside an already-loaded origin
//     (bypassing some CORS protections)
//   - run heavy computation that DoS's the worker
//
// We default-deny in line with AGENTS.md §3.5. Operators who really need it
// (debugging, scraping with custom logic) opt in with the env var. The server
// also refuses to list the tool when it's disabled so the model doesn't see
// an advertised capability it can't actually call (§14.5 honesty).
//
// TIMEOUT (Wave 3 review HIGH #1):
//   page.evaluate has no built-in timeout — an agent-supplied script that
//   does `while(true)` or `await new Promise(()=>{})` would pin the tool
//   forever and (combined with the reaper-vs-in-flight race) wedge a session
//   permanently. We Promise.race it against a 30s cap (overrideable via
//   timeout_ms up to 30s) and surface a `timeout` error so the agent can
//   pick a different approach.

const DEFAULT_EVAL_TIMEOUT_MS = 30_000;
const MAX_EVAL_TIMEOUT_MS = 30_000;

export const evaluateJsSchema = {
  type: "object",
  properties: {
    script: {
      type: "string",
      description:
        "JavaScript expression or statement block. The return value (last expression) is sent back as JSON. Async is supported — return a Promise.",
    },
    timeout_ms: {
      type: "number",
      description:
        "Max time to wait for the script to resolve in ms. Default 30000, cap 30000.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["script"],
  additionalProperties: false,
} as const;

export const evaluateJsDescription =
  "Run arbitrary JavaScript in the current page's context and return its value. GATED: requires PLAYWRIGHT_MCP_ALLOW_EVAL=1 on the server. Off by default because page-context JS can exfiltrate cookies and pivot internally. Times out after 30s (configurable down via timeout_ms) — long-running or never-resolving scripts surface as a `timeout` error.";

export interface EvaluateJsArgs {
  script: string;
  timeout_ms?: number;
  session_id?: string;
}

export interface EvaluateJsResult {
  result: unknown;
}

export function isEvalEnabled(): boolean {
  return process.env.PLAYWRIGHT_MCP_ALLOW_EVAL === "1";
}

/**
 * Reject after `ms` with a `timeout` error. We thread the cap reason in the
 * message so the agent's surfaced error explains what happened.
 */
function timeoutRejection(ms: number): Promise<never> {
  return new Promise<never>((_, reject) => {
    setTimeout(
      () =>
        reject(
          new Error(
            `timeout: evaluate_js script did not resolve within ${ms}ms`,
          ),
        ),
      ms,
    ).unref?.();
  });
}

export async function evaluateJs(
  pool: BrowserPool,
  args: EvaluateJsArgs,
): Promise<EvaluateJsResult> {
  if (!isEvalEnabled()) {
    throw new Error(
      "evaluate_js is disabled — set PLAYWRIGHT_MCP_ALLOW_EVAL=1 on the server to enable",
    );
  }
  const session_id = args.session_id ?? "default";
  const requested = args.timeout_ms ?? DEFAULT_EVAL_TIMEOUT_MS;
  const ms = Math.min(Math.max(1, requested), MAX_EVAL_TIMEOUT_MS);
  pool.beginCall(session_id);
  try {
    const { page } = await pool.getOrCreate(session_id);
    // Wrap as an expression so the user can `return value` OR pass `1+1`.
    // We compile via `new Function` inside the page evaluator.
    const result = await Promise.race([
      page.evaluate((src: string) => {
        // eslint-disable-next-line @typescript-eslint/no-implied-eval
        const fn = new Function(`return (async () => { ${src} })()`);
        return fn();
      }, args.script),
      timeoutRejection(ms),
    ]);
    pool.touch(session_id);
    return { result };
  } finally {
    pool.endCall(session_id);
  }
}
