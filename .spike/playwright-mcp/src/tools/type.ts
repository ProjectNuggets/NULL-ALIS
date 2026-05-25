import type { BrowserPool } from "../browser.js";

// CAPS (Wave 3 review HIGH #2):
//   Without limits, an agent can pass `delay_ms: 60000` and 10000 chars and
//   pin the tool for 7 days. Cap delay at 1000ms (plenty for human-realistic
//   keystroke pacing) and text at 10000 chars (4-5 typewritten pages — well
//   past any realistic form field). Explicit page.type timeout caps the
//   per-call wall time even when the page is hostile to the selector.

const MAX_DELAY_MS = 1_000;
const MAX_TEXT_LENGTH = 10_000;
const PAGE_TYPE_TIMEOUT_MS = 30_000;

export const typeSchema = {
  type: "object",
  properties: {
    selector: { type: "string", description: "Selector for the input/textarea to type into." },
    text: {
      type: "string",
      description:
        "Text to type. Sent as keystrokes (not paste). Capped at 10000 chars.",
    },
    delay_ms: {
      type: "number",
      description:
        "Delay between keystrokes in ms. 0 (default) sends the string at machine speed; capped at 1000ms.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["selector", "text"],
  additionalProperties: false,
} as const;

export const typeDescription =
  "Type text into an input or contenteditable element. Precondition: navigate first and ensure the element is in the DOM. Uses keyboard events — sites that hook 'input' / 'change' will see them. Caps: text <= 10000 chars, delay_ms <= 1000.";

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
  if (typeof args.text !== "string") {
    throw new Error("type requires a string text argument");
  }
  if (args.text.length > MAX_TEXT_LENGTH) {
    throw new Error(
      `type text.length ${args.text.length} exceeds cap of ${MAX_TEXT_LENGTH}`,
    );
  }
  const delay = args.delay_ms ?? 0;
  if (delay > MAX_DELAY_MS) {
    throw new Error(`type delay_ms ${delay} exceeds cap of ${MAX_DELAY_MS}`);
  }
  if (delay < 0) {
    throw new Error("type delay_ms must be non-negative");
  }
  const session_id = args.session_id ?? "default";
  pool.beginCall(session_id);
  try {
    const { page } = await pool.getOrCreate(session_id);
    await page.type(args.selector, args.text, {
      delay,
      timeout: PAGE_TYPE_TIMEOUT_MS,
    });
    pool.touch(session_id);
    return { typed: true };
  } finally {
    pool.endCall(session_id);
  }
}
