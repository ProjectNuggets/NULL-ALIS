// Tests for content-script command dispatch. happy-dom gives us a real
// document/window so we can exercise click / type / get_text / etc. without
// any chrome.* APIs.

import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  CommandError,
  cmdClick,
  cmdFillForm,
  cmdGetDom,
  cmdGetText,
  cmdScroll,
  cmdType,
  cmdWaitFor,
  validateCommand,
  runContentCommand,
  BACKGROUND_TOOLS,
} from "../src/commands";
import type { Command } from "../src/types";

function setBody(html: string): void {
  document.body.innerHTML = html;
}

describe("commands.validateCommand", () => {
  it("accepts a valid content command", () => {
    expect(() =>
      validateCommand({ command_id: "1", tool: "click", args: { selector: "#x" } } as Command)
    ).not.toThrow();
  });
  it("rejects missing command_id", () => {
    expect(() =>
      validateCommand({ command_id: "", tool: "click", args: {} } as Command)
    ).toThrow(CommandError);
  });
  it("rejects unknown tool", () => {
    expect(() =>
      validateCommand({ command_id: "1", tool: "nuke" as unknown as Command["tool"], args: {} })
    ).toThrow(/unknown tool/);
  });
  it("recognizes background-only tools", () => {
    expect(BACKGROUND_TOOLS.has("navigate")).toBe(true);
    expect(BACKGROUND_TOOLS.has("screenshot")).toBe(true);
    expect(BACKGROUND_TOOLS.has("list_tabs")).toBe(true);
    expect(BACKGROUND_TOOLS.has("click")).toBe(false);
  });
});

describe("commands.cmdClick", () => {
  beforeEach(() => setBody(""));
  it("clicks an element and returns the selector", () => {
    setBody('<button id="b">go</button>');
    const clicks: number[] = [];
    document.getElementById("b")!.addEventListener("click", () => clicks.push(1));
    const r = cmdClick(document, { selector: "#b" });
    expect(r.clicked).toBe("#b");
    expect(clicks.length).toBe(1);
  });
  it("throws not_found when no element matches", () => {
    try {
      cmdClick(document, { selector: "#missing" });
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(CommandError);
      expect((err as CommandError).code).toBe("not_found");
    }
  });
});

describe("commands.cmdType", () => {
  beforeEach(() => setBody(""));
  it("sets value and fires input + change events", () => {
    setBody('<input id="q" />');
    const events: string[] = [];
    const el = document.getElementById("q") as HTMLInputElement;
    el.addEventListener("input", () => events.push("input"));
    el.addEventListener("change", () => events.push("change"));
    const r = cmdType(document, { selector: "#q", text: "hello" });
    expect(r.typed).toBe(5);
    expect(el.value).toBe("hello");
    expect(events).toEqual(["input", "change"]);
  });
  it("rejects non-input targets", () => {
    setBody('<div id="d"></div>');
    try {
      cmdType(document, { selector: "#d", text: "x" });
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(CommandError);
      expect((err as CommandError).code).toBe("not_typeable");
    }
  });
});

describe("commands.cmdType sensitive-field guard (M1)", () => {
  beforeEach(() => setBody(""));
  it("blocks writing input[type=password] without allow_sensitive", () => {
    setBody('<input id="p" type="password" />');
    try {
      cmdType(document, { selector: "#p", text: "hunter2" });
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(CommandError);
      expect((err as CommandError).code).toBe("sensitive_field_blocked");
    }
    // Value must NOT have been written.
    expect((document.getElementById("p") as HTMLInputElement).value).toBe("");
  });

  it("blocks autocomplete=cc-number without allow_sensitive", () => {
    setBody('<input id="c" autocomplete="cc-number" />');
    try {
      cmdType(document, { selector: "#c", text: "4111111111111111" });
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(CommandError);
      expect((err as CommandError).code).toBe("sensitive_field_blocked");
    }
  });

  it("allows password write when allowSensitive=true and flags sensitive", () => {
    setBody('<input id="p" type="password" />');
    const r = cmdType(document, { selector: "#p", text: "hunter2" }, true);
    expect(r.sensitive).toBe(true);
    expect((document.getElementById("p") as HTMLInputElement).value).toBe("hunter2");
  });

  it("non-sensitive field reports sensitive=false", () => {
    setBody('<input id="q" />');
    const r = cmdType(document, { selector: "#q", text: "hi" });
    expect(r.sensitive).toBe(false);
  });

  it("runContentCommand honors Command.allow_sensitive", async () => {
    setBody('<input id="p" type="password" />');
    // Without the flag → blocked.
    await expect(
      runContentCommand(
        { command_id: "1", tool: "type", args: { selector: "#p", text: "x" } },
        document,
      ),
    ).rejects.toBeInstanceOf(CommandError);
    // With the flag → allowed.
    const ok = await runContentCommand(
      { command_id: "2", tool: "type", args: { selector: "#p", text: "x" }, allow_sensitive: true },
      document,
    );
    expect(ok).toEqual({ typed: 1, sensitive: true });
  });
});

describe("commands.cmdFillForm", () => {
  beforeEach(() => setBody(""));
  it("fills multiple fields in order", () => {
    setBody('<input id="a" /><input id="b" />');
    const r = cmdFillForm(document, {
      fields: [
        { selector: "#a", text: "alpha" },
        { selector: "#b", text: "beta" },
      ],
    });
    expect(r.filled).toBe(2);
    expect((document.getElementById("a") as HTMLInputElement).value).toBe("alpha");
    expect((document.getElementById("b") as HTMLInputElement).value).toBe("beta");
  });
  it("rejects non-array fields", () => {
    expect(() => cmdFillForm(document, { fields: "not-an-array" })).toThrow(CommandError);
  });
});

describe("commands.cmdGetText", () => {
  beforeEach(() => setBody(""));
  it("returns innerText of selector", () => {
    setBody('<p id="p">hello world</p>');
    const r = cmdGetText(document, { selector: "#p" });
    expect(r.text).toBe("hello world");
    expect(r.truncated).toBe(false);
  });
  it("defaults to body when no selector", () => {
    setBody("<p>one</p><p>two</p>");
    const r = cmdGetText(document, {});
    expect(r.text.length).toBeGreaterThan(0);
  });
});

describe("commands.cmdGetDom", () => {
  beforeEach(() => setBody(""));
  it("returns outerHTML of selector", () => {
    setBody('<div id="d"><span>x</span></div>');
    const r = cmdGetDom(document, { selector: "#d" });
    expect(r.html).toContain("<span>x</span>");
    expect(r.truncated).toBe(false);
  });
});

describe("commands.cmdScroll", () => {
  beforeEach(() => setBody(""));
  it("calls window.scrollBy for down direction", () => {
    const spy = vi.spyOn(window, "scrollBy").mockImplementation(() => {});
    cmdScroll(document, { direction: "down", pixels: 400 });
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });
  it("rejects unknown direction", () => {
    expect(() => cmdScroll(document, { direction: "sideways" })).toThrow(CommandError);
  });
});

describe("commands.cmdWaitFor", () => {
  beforeEach(() => setBody(""));
  it("resolves immediately when element already attached", async () => {
    setBody('<div id="x"></div>');
    const r = await cmdWaitFor(document, { selector: "#x", timeout_ms: 100 });
    expect(r.found).toBe(true);
  });
  it("resolves after MutationObserver fires", async () => {
    setBody("");
    const p = cmdWaitFor(document, { selector: "#late", timeout_ms: 1_000 });
    queueMicrotask(() => {
      const el = document.createElement("div");
      el.id = "late";
      document.body.appendChild(el);
    });
    const r = await p;
    expect(r.found).toBe(true);
  });
  it("returns found=false on timeout", async () => {
    setBody("");
    const r = await cmdWaitFor(document, { selector: "#never", timeout_ms: 30 });
    expect(r.found).toBe(false);
  });
});

describe("commands.runContentCommand", () => {
  it("dispatches via the command table", async () => {
    setBody('<input id="q" />');
    const result = await runContentCommand(
      { command_id: "1", tool: "type", args: { selector: "#q", text: "hi" } },
      document
    );
    expect(result).toEqual({ typed: 2, sensitive: false });
  });
  it("rejects background-only tool", async () => {
    await expect(
      runContentCommand(
        { command_id: "1", tool: "navigate", args: { url: "https://example.com" } },
        document
      )
    ).rejects.toBeInstanceOf(CommandError);
  });
});
