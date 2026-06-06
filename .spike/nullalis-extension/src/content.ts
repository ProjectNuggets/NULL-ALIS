// Content script — runs in the page's DOM context. Receives ExecuteInTab and
// ShowToast messages from the background, dispatches commands against the
// real `document`, returns results.
//
// Important: content scripts share the page's window but live in an isolated
// JS world. They can read/write the DOM but cannot see page-script variables.

import { runContentCommand } from "./commands";
import type {
  BgToContentMessage,
  ExecuteInTabResult,
} from "./types";

// C1/H1 — re-injection guard. This script is injected ON DEMAND via
// chrome.scripting.executeScript when the user enables the agent on a tab.
// If the user re-enables (or the background re-injects after a navigation),
// executeScript runs the file again in the same page. Without a guard we'd
// register a second onMessage listener and double-handle every command. The
// flag lives on `window` (the content script's isolated world), so it persists
// for the page's lifetime but resets on navigation — exactly the scope we want.
declare global {
  interface Window {
    __nullalisContentLoaded__?: boolean;
  }
}

// ---------- Toast UI (injected once per page) ----------

const TOAST_ID = "__nullalis_agent_toast__";

function ensureToastEl(): HTMLDivElement {
  let el = document.getElementById(TOAST_ID) as HTMLDivElement | null;
  if (el) return el;
  el = document.createElement("div");
  el.id = TOAST_ID;
  // Inline styles so we don't fight with the host page's CSS. Position fixed
  // top-right with a high z-index so it stays visible even over modals.
  Object.assign(el.style, {
    position: "fixed",
    top: "12px",
    right: "12px",
    zIndex: "2147483647", // max int — beats any sane page z-index
    padding: "8px 12px",
    background: "rgba(15, 17, 21, 0.92)",
    color: "#f5f5f5",
    font: "12px/1.4 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
    borderRadius: "6px",
    boxShadow: "0 4px 16px rgba(0,0,0,0.24)",
    pointerEvents: "none",
    maxWidth: "320px",
    opacity: "0",
    transition: "opacity 120ms ease-out",
  } as Partial<CSSStyleDeclaration>);
  document.documentElement.appendChild(el);
  return el;
}

let toastHideTimer: ReturnType<typeof setTimeout> | null = null;

function showToast(message: string, ttlMs: number): void {
  try {
    const el = ensureToastEl();
    el.textContent = message;
    el.style.opacity = "1";
    if (toastHideTimer) clearTimeout(toastHideTimer);
    if (ttlMs > 0) {
      toastHideTimer = setTimeout(() => {
        el.style.opacity = "0";
      }, ttlMs);
    }
  } catch {
    // Toast is purely informational; if the host page is unusual (e.g. an XML
    // viewer, a sandboxed iframe), silently drop.
  }
}

// ---------- Message handler ----------

function installListener(): void {
  if (window.__nullalisContentLoaded__) return;
  window.__nullalisContentLoaded__ = true;

  chrome.runtime.onMessage.addListener(
  (
    msg: BgToContentMessage,
    sender,
    sendResponse: (r: ExecuteInTabResult | undefined) => void
  ) => {
    // C2 — only THIS extension's background may drive the content script.
    // A message whose sender.id isn't our own extension id (or has no id at
    // all — e.g. a page that somehow reached this listener) is ignored.
    if (sender.id !== chrome.runtime.id) {
      return false;
    }
    if (msg.type === "show_toast") {
      showToast(msg.message, msg.ttl_ms ?? 2_500);
      return false;
    }
    if (msg.type === "execute_in_tab") {
      const cmd = msg.command;
      // Run async; keep the channel open by returning true.
      (async () => {
        try {
          const result = await runContentCommand(cmd, document);
          sendResponse({
            type: "execute_in_tab_result",
            command_id: cmd.command_id,
            ok: true,
            result,
          });
        } catch (err) {
          const code = (err as { code?: string }).code ?? "runtime";
          const message = err instanceof Error ? err.message : String(err);
          sendResponse({
            type: "execute_in_tab_result",
            command_id: cmd.command_id,
            ok: false,
            error: { code, message },
          });
        }
      })();
      return true; // async sendResponse
    }
    return false;
  }
  );
}

installListener();
