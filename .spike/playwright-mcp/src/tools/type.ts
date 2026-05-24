import type { BrowserPool } from "../browser.js";

export const typeSchema = {
  type: "object",
  properties: {
    selector: { type: "string", description: "Selector for the input/textarea to type into." },
    text: { type: "string", description: "Text to type. Sent as keystrokes (not paste)." },
    delay_ms: {
      type: "number",
      description: "Delay between keystrokes in ms. 0 (default) sends the string at machine speed; raise for sites with input throttling.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["selector", "text"],
  additionalProperties: false,
} as const;

export const typeDescription =
  "Type text into an input or contenteditable element. Precondition: navigate first and ensure the element is in the DOM. Uses keyboard events — sites that hook 'input' / 'change' will see them.";

export interface TypeArgs {
  selector: string;
  text: string;
  delay_ms?: number;
  session_id?: string;
}

export interface TypeResult {
  typed: true;
}

export async function type(pool: BrowserPool, args: TypeArgs): Promise<TypeResult> {
  const session_id = args.session_id ?? "default";
  const { page } = await pool.getOrCreate(session_id);
  await page.type(args.selector, args.text, { delay: args.delay_ms ?? 0 });
  pool.touch(session_id);
  return { typed: true };
}
