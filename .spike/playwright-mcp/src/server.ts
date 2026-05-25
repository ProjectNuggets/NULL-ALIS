#!/usr/bin/env node
// nullalis Playwright MCP server.
//
// Wire shape: JSON-RPC 2.0 over stdio, protocol version "2024-11-05" — same as
// what `src/mcp_server.zig` speaks. The Anthropic @modelcontextprotocol/sdk
// handles framing + handshake; we register tool handlers and own the browser
// pool.
//
// Entry: `node dist/server.js` (or `npm start`). Stderr-only logging so stdout
// stays exclusively a JSON-RPC channel — speaking on stdout would break the
// client immediately.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { BrowserPool } from "./browser.js";
import { click, clickDescription, clickSchema, type ClickArgs } from "./tools/click.js";
import {
  closeSession,
  closeSessionDescription,
  closeSessionSchema,
  type CloseSessionArgs,
  listSessions,
  listSessionsDescription,
  listSessionsSchema,
} from "./tools/session.js";
import {
  evaluateJs,
  evaluateJsDescription,
  evaluateJsSchema,
  isEvalEnabled,
  type EvaluateJsArgs,
} from "./tools/evaluate_js.js";
import {
  fillForm,
  fillFormDescription,
  fillFormSchema,
  type FillFormArgs,
} from "./tools/fill_form.js";
import {
  getDom,
  getDomDescription,
  getDomSchema,
  type GetDomArgs,
} from "./tools/get_dom.js";
import {
  getText,
  getTextDescription,
  getTextSchema,
  type GetTextArgs,
} from "./tools/get_text.js";
import {
  navigate,
  navigateDescription,
  navigateSchema,
  type NavigateArgs,
} from "./tools/navigate.js";
import {
  screenshot,
  screenshotDescription,
  screenshotSchema,
  type ScreenshotArgs,
} from "./tools/screenshot.js";
import {
  scroll,
  scrollDescription,
  scrollSchema,
  type ScrollArgs,
} from "./tools/scroll.js";
import { type as typeText, typeDescription, typeSchema, type TypeArgs } from "./tools/type.js";
import {
  waitFor,
  waitForDescription,
  waitForSchema,
  type WaitForArgs,
} from "./tools/wait_for.js";

const SERVER_NAME = "nullalis-playwright-mcp";
const SERVER_VERSION = "0.1.0";

/** Shutdown timeout — past this we hard-exit even if Playwright is wedged. */
const SHUTDOWN_TIMEOUT_MS = 5_000;

function log(...parts: unknown[]): void {
  // Stderr only — stdout is reserved for the JSON-RPC channel.
  process.stderr.write(`[${SERVER_NAME}] ${parts.map(String).join(" ")}\n`);
}

/**
 * Strip filesystem-revealing bits from an error message before it leaves the
 * server. Playwright errors routinely embed absolute install paths
 * (`/Users/nova/.../node_modules/playwright-core/lib/...`) which leak the
 * server's filesystem layout, OS userid, and Node version — all of which help
 * an attacker shape the next exploit on a multi-tenant deployment.
 *
 * We do TWO passes (Wave 3 review HIGH #3):
 *   1. Collapse any `/.../node_modules/<pkg>/<path>` chain to `<node_modules>`.
 *   2. Strip the server's install-path prefix when present.
 * Exported so tests can pin the property.
 */
export function sanitizeErrorMessage(raw: string): string {
  let out = raw;
  // Pass 1: strip any absolute path that contains a /node_modules/ segment,
  // including everything before AND after, down to a path-delimiting char.
  // Replacement is a neutral token that contains neither "node_modules" nor
  // any filesystem fragment.
  out = out.replace(/\/[\w/.@~+-]*\/node_modules\/[\w/.@~+-]+/g, "<dep>");
  // Pass 2: strip the project install-path prefix. We use process.cwd() as
  // a best-effort prefix for "this server's filesystem root" — anything
  // starting with cwd gets the prefix elided.
  const cwd = process.cwd();
  if (cwd && cwd.length > 1) {
    out = out.split(cwd).join("<install-path>");
    // Also strip a parent of cwd if the cwd is a worktree under a larger
    // repo (the leak target tends to be the *outer* repo path).
    const parent = cwd.replace(/\/[^/]+$/, "");
    if (parent && parent.length > 1) {
      out = out.split(parent).join("<install-path>");
    }
  }
  return out;
}

interface ToolEntry {
  name: string;
  description: string;
  inputSchema: object;
  hidden?: boolean; // Hide from tools/list while keeping the dispatch wired.
}

/** Build the registry. evaluate_js is hidden when not env-allowed (§14.5 honesty). */
function buildToolRegistry(): ToolEntry[] {
  return [
    { name: "navigate", description: navigateDescription, inputSchema: navigateSchema },
    { name: "click", description: clickDescription, inputSchema: clickSchema },
    { name: "type", description: typeDescription, inputSchema: typeSchema },
    { name: "fill_form", description: fillFormDescription, inputSchema: fillFormSchema },
    { name: "screenshot", description: screenshotDescription, inputSchema: screenshotSchema },
    { name: "get_text", description: getTextDescription, inputSchema: getTextSchema },
    { name: "get_dom", description: getDomDescription, inputSchema: getDomSchema },
    { name: "wait_for", description: waitForDescription, inputSchema: waitForSchema },
    {
      name: "evaluate_js",
      description: evaluateJsDescription,
      inputSchema: evaluateJsSchema,
      hidden: !isEvalEnabled(),
    },
    { name: "scroll", description: scrollDescription, inputSchema: scrollSchema },
    {
      name: "close_session",
      description: closeSessionDescription,
      inputSchema: closeSessionSchema,
    },
    {
      name: "list_sessions",
      description: listSessionsDescription,
      inputSchema: listSessionsSchema,
    },
  ];
}

/** MCP `tools/call` result envelope helper. */
function textResult(payload: unknown, isError = false): {
  content: Array<{ type: "text"; text: string }>;
  isError: boolean;
} {
  return {
    content: [{ type: "text", text: JSON.stringify(payload) }],
    isError,
  };
}

/** Dispatch a tools/call by name. Returns the MCP envelope. */
async function dispatch(
  pool: BrowserPool,
  name: string,
  args: Record<string, unknown>,
): Promise<{ content: Array<{ type: "text"; text: string }>; isError: boolean }> {
  try {
    switch (name) {
      case "navigate":
        return textResult(await navigate(pool, args as unknown as NavigateArgs));
      case "click":
        return textResult(await click(pool, args as unknown as ClickArgs));
      case "type":
        return textResult(await typeText(pool, args as unknown as TypeArgs));
      case "fill_form":
        return textResult(await fillForm(pool, args as unknown as FillFormArgs));
      case "screenshot":
        return textResult(await screenshot(pool, args as unknown as ScreenshotArgs));
      case "get_text":
        return textResult(await getText(pool, args as unknown as GetTextArgs));
      case "get_dom":
        return textResult(await getDom(pool, args as unknown as GetDomArgs));
      case "wait_for":
        return textResult(await waitFor(pool, args as unknown as WaitForArgs));
      case "evaluate_js":
        return textResult(await evaluateJs(pool, args as unknown as EvaluateJsArgs));
      case "scroll":
        return textResult(await scroll(pool, args as unknown as ScrollArgs));
      case "close_session":
        return textResult(await closeSession(pool, args as unknown as CloseSessionArgs));
      case "list_sessions":
        return textResult(listSessions(pool));
      default:
        return textResult({ error: `unknown tool: ${name}` }, true);
    }
  } catch (err) {
    const raw = err instanceof Error ? err.message : String(err);
    // Wave 3 review HIGH #3: never leak raw filesystem paths to the agent.
    // The raw message still goes to stderr for operator-side debugging.
    const message = sanitizeErrorMessage(raw);
    if (message !== raw) log(`[error sanitized]`, raw);
    return textResult({ error: message }, true);
  }
}

/**
 * Construct + wire the MCP server. Exported so tests can drive it without
 * spawning a subprocess. Returns an object with the server, the pool, and a
 * `stop` helper.
 */
export async function createServer(
  poolOpts: { headless?: boolean; idle_timeout_ms?: number; disable_reaper?: boolean } = {},
): Promise<{
  server: Server;
  pool: BrowserPool;
  registry: ToolEntry[];
  stop: () => Promise<void>;
}> {
  const headless = poolOpts.headless ?? process.env.PLAYWRIGHT_HEADLESS !== "false";
  const pool = new BrowserPool({
    headless,
    idle_timeout_ms: poolOpts.idle_timeout_ms,
    disable_reaper: poolOpts.disable_reaper,
  });
  const registry = buildToolRegistry();

  const server = new Server(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { capabilities: { tools: { listChanged: false } } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return {
      tools: registry
        .filter((t) => !t.hidden)
        .map((t) => ({
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema,
        })),
    };
  });

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args } = req.params;
    return dispatch(pool, name, (args ?? {}) as Record<string, unknown>);
  });

  return {
    server,
    pool,
    registry,
    stop: async () => {
      await server.close();
      await pool.shutdown();
    },
  };
}

/** Process entry. Bind transport, wire shutdown signals. */
async function main(): Promise<void> {
  const { server, pool } = await createServer();
  log(
    `starting (headless=${process.env.PLAYWRIGHT_HEADLESS !== "false"}, eval=${isEvalEnabled()}, allowlist=${process.env.PLAYWRIGHT_MCP_ALLOWLIST ?? "<none>"})`,
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
  log("connected — awaiting JSON-RPC on stdio");

  const shutdown = async (signal: string): Promise<void> => {
    log(`received ${signal}, shutting down`);
    // Wave 3 review HIGH #4:
    //   - Exit code MUST reflect success/failure so the orchestrator (k8s,
    //     Docker) restarts on a real shutdown failure instead of treating it
    //     as a clean exit.
    //   - A wedged Chromium can hang server.close()/pool.shutdown() forever;
    //     we Promise.race against a 5s cap and force-exit on timeout.
    let shutdownError: unknown = null;
    let timedOut = false;
    const work = (async () => {
      await server.close();
      await pool.shutdown();
    })();
    const timeout = new Promise<void>((resolve) => {
      setTimeout(() => {
        timedOut = true;
        resolve();
      }, SHUTDOWN_TIMEOUT_MS).unref?.();
    });
    try {
      await Promise.race([work, timeout]);
    } catch (err) {
      shutdownError = err;
      log(`shutdown error: ${err instanceof Error ? err.message : String(err)}`);
    }
    if (timedOut) {
      log(`shutdown exceeded ${SHUTDOWN_TIMEOUT_MS}ms, force-exiting`);
      process.exit(1);
    }
    process.exit(shutdownError ? 1 : 0);
  };
  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
}

// ES modules don't have require.main — use import.meta.url instead.
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  main().catch((err) => {
    log(`fatal: ${err instanceof Error ? err.stack ?? err.message : String(err)}`);
    process.exit(1);
  });
}
