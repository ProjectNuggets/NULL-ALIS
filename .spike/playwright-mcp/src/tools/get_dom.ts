import type { BrowserPool } from "../browser.js";

export const DOM_CAP_BYTES = 1024 * 1024;

export const getDomSchema = {
  type: "object",
  properties: {
    selector: {
      type: "string",
      description: "Optional selector. Omit to get the full document body's outerHTML.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  additionalProperties: false,
} as const;

export const getDomDescription =
  "Return raw HTML (outerHTML) of the page or the matched element. Capped at 1MB — `truncated:true` signals the page was larger and you should pass a more specific selector.";

export interface GetDomArgs {
  selector?: string;
  session_id?: string;
}

export interface GetDomResult {
  html: string;
  truncated: boolean;
}

export async function getDom(
  pool: BrowserPool,
  args: GetDomArgs,
): Promise<GetDomResult> {
  const session_id = args.session_id ?? "default";
  const { page } = await pool.getOrCreate(session_id);
  let raw: string;
  if (args.selector) {
    raw =
      (await page.locator(args.selector).evaluate((el) => (el as Element).outerHTML, undefined, {
        timeout: 10_000,
      })) ?? "";
  } else {
    raw = await page.evaluate(() => document.body?.outerHTML ?? "");
  }
  pool.touch(session_id);
  const truncated = Buffer.byteLength(raw, "utf8") > DOM_CAP_BYTES;
  let html = raw;
  if (truncated) {
    const enc = new TextEncoder();
    const bytes = enc.encode(raw);
    html = new TextDecoder("utf-8", { fatal: false }).decode(
      bytes.slice(0, DOM_CAP_BYTES),
    );
  }
  return { html, truncated };
}
