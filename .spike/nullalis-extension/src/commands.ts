// Command dispatch — pure functions over `document`, designed to run inside a
// content script. Each command takes a typed args object and returns either a
// success result or throws a CommandError. The content script wrapper catches
// thrown errors and turns them into wire-level ExecuteInTabResult.error frames.
//
// Why "pure-over-document"? Because that lets us unit-test every command
// against happy-dom in vitest without mounting a chrome extension at all.

import type { Command, ToolName } from "./types";

const DEFAULT_DOM_CAP_BYTES = 1_000_000;

export class CommandError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = "CommandError";
  }
}

// ---------- Argument schemas (runtime checks) ----------
// We don't pull in zod — the surface is small and a hand-rolled checker keeps
// the bundle tiny.

function asString(args: Record<string, unknown>, key: string): string {
  const v = args[key];
  if (typeof v !== "string") {
    throw new CommandError("invalid_args", `expected string arg "${key}"`);
  }
  return v;
}

function asOptionalString(args: Record<string, unknown>, key: string): string | undefined {
  const v = args[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") {
    throw new CommandError("invalid_args", `expected string-or-missing arg "${key}"`);
  }
  return v;
}

function asOptionalNumber(args: Record<string, unknown>, key: string): number | undefined {
  const v = args[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new CommandError("invalid_args", `expected number-or-missing arg "${key}"`);
  }
  return v;
}

// ---------- Individual commands ----------

/**
 * Click the first element matching the CSS selector. Throws not_found if no
 * element matches.
 */
export function cmdClick(doc: Document, args: Record<string, unknown>): { clicked: string } {
  const selector = asString(args, "selector");
  const el = doc.querySelector(selector);
  if (!el) throw new CommandError("not_found", `no element matches ${selector}`);
  if (!(el instanceof HTMLElement)) {
    throw new CommandError("not_clickable", `element ${selector} is not an HTMLElement`);
  }
  el.click();
  return { clicked: selector };
}

/**
 * Type text into an input/textarea. Uses native value setter + dispatched
 * "input" event so frameworks (React, Vue) pick up the change.
 */
export function cmdType(doc: Document, args: Record<string, unknown>): { typed: number } {
  const selector = asString(args, "selector");
  const text = asString(args, "text");
  const el = doc.querySelector(selector);
  if (!el) throw new CommandError("not_found", `no element matches ${selector}`);
  if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) {
    throw new CommandError("not_typeable", `element ${selector} is not input/textarea`);
  }
  // React-friendly value setter: use the native prototype setter then dispatch
  // input + change so controlled inputs notice the change.
  const proto = el instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
  if (setter) setter.call(el, text);
  else el.value = text;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return { typed: text.length };
}

/**
 * Fill multiple form fields in one go. Each field is {selector, text}. Stops
 * on the first failing field and reports which one.
 */
export function cmdFillForm(
  doc: Document,
  args: Record<string, unknown>
): { filled: number } {
  const fields = args["fields"];
  if (!Array.isArray(fields)) {
    throw new CommandError("invalid_args", "fields must be an array");
  }
  let filled = 0;
  for (let i = 0; i < fields.length; i++) {
    const f = fields[i];
    if (!f || typeof f !== "object") {
      throw new CommandError("invalid_args", `fields[${i}] must be an object`);
    }
    cmdType(doc, f as Record<string, unknown>);
    filled++;
  }
  return { filled };
}

/**
 * innerText of selector (or document.body). Truncated to 100 KB to avoid
 * shipping a megabyte of marketing copy back through the gateway.
 */
export function cmdGetText(doc: Document, args: Record<string, unknown>): { text: string; truncated: boolean } {
  const selector = asOptionalString(args, "selector");
  const target: HTMLElement | null = selector
    ? (doc.querySelector(selector) as HTMLElement | null)
    : doc.body;
  if (!target) throw new CommandError("not_found", `no element matches ${selector}`);
  const full = target.innerText ?? "";
  const cap = 100_000;
  if (full.length > cap) {
    return { text: full.slice(0, cap), truncated: true };
  }
  return { text: full, truncated: false };
}

/**
 * outerHTML of selector (or document.body). Hard cap at 1MB to avoid runaway
 * payloads; truncated boolean lets the caller know to refine the selector.
 */
export function cmdGetDom(doc: Document, args: Record<string, unknown>): { html: string; truncated: boolean } {
  const selector = asOptionalString(args, "selector");
  const target = selector ? doc.querySelector(selector) : doc.body;
  if (!target) throw new CommandError("not_found", `no element matches ${selector}`);
  const html = target.outerHTML ?? "";
  if (html.length > DEFAULT_DOM_CAP_BYTES) {
    return { html: html.slice(0, DEFAULT_DOM_CAP_BYTES), truncated: true };
  }
  return { html, truncated: false };
}

/**
 * Wait for an element to appear. Uses MutationObserver + a polling fallback
 * for elements added before the observer attached.
 *
 * state:
 *   "attached"  — element exists in DOM (default)
 *   "visible"   — element exists AND has non-zero bounding box
 *   "detached"  — element does NOT exist
 */
export async function cmdWaitFor(doc: Document, args: Record<string, unknown>): Promise<{ found: boolean; ms: number }> {
  const selector = asString(args, "selector");
  const timeout = asOptionalNumber(args, "timeout_ms") ?? 10_000;
  const state = (asOptionalString(args, "state") ?? "attached") as "attached" | "visible" | "detached";

  const startedAt = Date.now();
  const check = (): boolean => {
    const el = doc.querySelector(selector);
    if (state === "attached") return el !== null;
    if (state === "detached") return el === null;
    if (state === "visible") {
      if (!el || !(el instanceof HTMLElement)) return false;
      const rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    }
    return false;
  };

  if (check()) return { found: true, ms: 0 };

  return new Promise((resolve) => {
    let observer: MutationObserver | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;

    const finish = (found: boolean) => {
      if (observer) observer.disconnect();
      if (timer) clearTimeout(timer);
      resolve({ found, ms: Date.now() - startedAt });
    };

    observer = new MutationObserver(() => {
      if (check()) finish(true);
    });
    observer.observe(doc.documentElement || doc.body, {
      childList: true,
      subtree: true,
      attributes: true,
    });

    timer = setTimeout(() => finish(check()), timeout);
  });
}

/**
 * Scroll the page. direction is "up" | "down" | "top" | "bottom"; pixels is
 * used for up/down (default 800).
 */
export function cmdScroll(doc: Document, args: Record<string, unknown>): { scrolled: string } {
  const direction = asString(args, "direction") as "up" | "down" | "top" | "bottom";
  const pixels = asOptionalNumber(args, "pixels") ?? 800;
  const win = doc.defaultView;
  if (!win) throw new CommandError("no_window", "document has no defaultView");
  switch (direction) {
    case "up":
      win.scrollBy({ top: -pixels, behavior: "instant" as ScrollBehavior });
      break;
    case "down":
      win.scrollBy({ top: pixels, behavior: "instant" as ScrollBehavior });
      break;
    case "top":
      win.scrollTo({ top: 0, behavior: "instant" as ScrollBehavior });
      break;
    case "bottom":
      win.scrollTo({ top: doc.body.scrollHeight, behavior: "instant" as ScrollBehavior });
      break;
    default:
      throw new CommandError("invalid_args", `unknown direction ${direction}`);
  }
  return { scrolled: direction };
}

// ---------- Dispatch table ----------

/**
 * The subset of commands that run in the content script (against `document`).
 * navigate / screenshot / list_tabs go through chrome.* in the background
 * service worker and are dispatched there, not here.
 */
export const CONTENT_COMMANDS: Record<string, (doc: Document, args: Record<string, unknown>) => unknown | Promise<unknown>> = {
  click: cmdClick,
  type: cmdType,
  fill_form: cmdFillForm,
  get_text: cmdGetText,
  get_dom: cmdGetDom,
  wait_for: cmdWaitFor,
  scroll: cmdScroll,
};

/** Tools that must run in the background service worker, not the content script. */
export const BACKGROUND_TOOLS: ReadonlySet<ToolName> = new Set<ToolName>([
  "navigate",
  "screenshot",
  "list_tabs",
]);

/**
 * Validate a command frame before we even attempt dispatch. Used by the
 * background worker so we can reject bad commands with a clean error code
 * without poking the active tab.
 */
export function validateCommand(c: Command): void {
  if (typeof c.command_id !== "string" || c.command_id.length === 0) {
    throw new CommandError("invalid_command", "missing command_id");
  }
  if (typeof c.tool !== "string") {
    throw new CommandError("invalid_command", "missing tool");
  }
  if (!c.args || typeof c.args !== "object") {
    throw new CommandError("invalid_command", "missing args object");
  }
  const known: Set<string> = new Set([
    ...Object.keys(CONTENT_COMMANDS),
    ...BACKGROUND_TOOLS,
  ]);
  if (!known.has(c.tool)) {
    throw new CommandError("unknown_tool", `unknown tool ${c.tool}`);
  }
}

/**
 * Run a command inside the content script. Throws CommandError on failure;
 * the content script wrapper turns thrown errors into wire-format errors.
 */
export async function runContentCommand(c: Command, doc: Document): Promise<unknown> {
  validateCommand(c);
  const fn = CONTENT_COMMANDS[c.tool];
  if (!fn) {
    throw new CommandError("unknown_tool", `tool ${c.tool} is not a content-script command`);
  }
  return await fn(doc, c.args);
}
