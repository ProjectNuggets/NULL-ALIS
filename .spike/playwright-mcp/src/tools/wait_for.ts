import type { BrowserPool } from "../browser.js";

export const waitForSchema = {
  type: "object",
  properties: {
    selector: { type: "string", description: "Element selector to wait for." },
    timeout_ms: {
      type: "number",
      description: "Max wait in ms. Default 10000.",
    },
    state: {
      type: "string",
      enum: ["visible", "hidden", "attached", "detached"],
      description: "Which state to wait for. Default 'visible'.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["selector"],
  additionalProperties: false,
} as const;

export const waitForDescription =
  "Wait until an element reaches the requested state. Useful after a click that triggers a network call or animation. Errors out (not just returns false) if the timeout is reached — that's an honest signal to the agent that the page didn't behave as expected.";

export interface WaitForArgs {
  selector: string;
  timeout_ms?: number;
  state?: "visible" | "hidden" | "attached" | "detached";
  session_id?: string;
}

export interface WaitForResult {
  found: true;
  ms_waited: number;
}

export async function waitFor(
  pool: BrowserPool,
  args: WaitForArgs,
): Promise<WaitForResult> {
  const session_id = args.session_id ?? "default";
  const { page } = await pool.getOrCreate(session_id);
  const start = Date.now();
  await page.locator(args.selector).waitFor({
    timeout: args.timeout_ms ?? 10_000,
    state: args.state ?? "visible",
  });
  pool.touch(session_id);
  return { found: true, ms_waited: Date.now() - start };
}
