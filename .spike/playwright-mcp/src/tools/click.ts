import type { BrowserPool } from "../browser.js";

export const clickSchema = {
  type: "object",
  properties: {
    selector: {
      type: "string",
      description:
        "CSS or Playwright selector (text=, role=, etc.) of the element to click.",
    },
    timeout_ms: {
      type: "number",
      description: "How long to wait for the element to be actionable. Default 10000.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["selector"],
  additionalProperties: false,
} as const;

export const clickDescription =
  "Click an element matching the selector. Precondition: navigate first. Fails if the element isn't found or isn't actionable within the timeout.";

export interface ClickArgs {
  selector: string;
  timeout_ms?: number;
  session_id?: string;
}

export interface ClickResult {
  clicked: true;
}

export async function click(pool: BrowserPool, args: ClickArgs): Promise<ClickResult> {
  const session_id = args.session_id ?? "default";
  const { page } = await pool.getOrCreate(session_id);
  await page.click(args.selector, { timeout: args.timeout_ms ?? 10_000 });
  pool.touch(session_id);
  return { clicked: true };
}
