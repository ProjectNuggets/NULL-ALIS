import type { BrowserPool } from "../browser.js";

export const TEXT_CAP_BYTES = 64 * 1024;

export const getTextSchema = {
  type: "object",
  properties: {
    selector: {
      type: "string",
      description: "Optional selector. Omit to extract text from the whole page (innerText of body).",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  additionalProperties: false,
} as const;

export const getTextDescription =
  "Extract visible text from the page (or from one element if `selector` is supplied). Capped at 64KB — `truncated:true` in the result means the page was longer and you should fetch a more specific selector if you need the rest.";

export interface GetTextArgs {
  selector?: string;
  session_id?: string;
}

export interface GetTextResult {
  text: string;
  truncated: boolean;
}

export async function getText(
  pool: BrowserPool,
  args: GetTextArgs,
): Promise<GetTextResult> {
  const session_id = args.session_id ?? "default";
  const { page } = await pool.getOrCreate(session_id);
  let raw: string;
  if (args.selector) {
    raw = (await page.locator(args.selector).innerText({ timeout: 10_000 })) ?? "";
  } else {
    raw = await page.evaluate(() => document.body?.innerText ?? "");
  }
  pool.touch(session_id);
  const truncated = Buffer.byteLength(raw, "utf8") > TEXT_CAP_BYTES;
  // Truncate by character count first, then byte-trim to stay under cap.
  let text = raw;
  if (truncated) {
    // Quick byte-aware truncation: slice until byte-length fits.
    const enc = new TextEncoder();
    const bytes = enc.encode(raw);
    text = new TextDecoder("utf-8", { fatal: false }).decode(
      bytes.slice(0, TEXT_CAP_BYTES),
    );
  }
  return { text, truncated };
}
