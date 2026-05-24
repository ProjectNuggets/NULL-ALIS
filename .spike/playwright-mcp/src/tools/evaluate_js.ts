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

export const evaluateJsSchema = {
  type: "object",
  properties: {
    script: {
      type: "string",
      description:
        "JavaScript expression or statement block. The return value (last expression) is sent back as JSON. Async is supported — return a Promise.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["script"],
  additionalProperties: false,
} as const;

export const evaluateJsDescription =
  "Run arbitrary JavaScript in the current page's context and return its value. GATED: requires PLAYWRIGHT_MCP_ALLOW_EVAL=1 on the server. Off by default because page-context JS can exfiltrate cookies and pivot internally.";

export interface EvaluateJsArgs {
  script: string;
  session_id?: string;
}

export interface EvaluateJsResult {
  result: unknown;
}

export function isEvalEnabled(): boolean {
  return process.env.PLAYWRIGHT_MCP_ALLOW_EVAL === "1";
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
  const { page } = await pool.getOrCreate(session_id);
  // Wrap as an expression so the user can `return value` OR pass `1+1`.
  // We compile via `new Function` inside the page evaluator.
  const result = await page.evaluate((src: string) => {
    // eslint-disable-next-line @typescript-eslint/no-implied-eval
    const fn = new Function(`return (async () => { ${src} })()`);
    return fn();
  }, args.script);
  pool.touch(session_id);
  return { result };
}
