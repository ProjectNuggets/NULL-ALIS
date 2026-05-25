import type { BrowserPool } from "../browser.js";

export const fillFormSchema = {
  type: "object",
  properties: {
    fields: {
      type: "array",
      description: "Ordered list of {selector, value} pairs. Filled one at a time.",
      items: {
        type: "object",
        properties: {
          selector: { type: "string" },
          value: { type: "string" },
        },
        required: ["selector", "value"],
        additionalProperties: false,
      },
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["fields"],
  additionalProperties: false,
} as const;

export const fillFormDescription =
  "Fill multiple form fields in order using Playwright's `locator.fill` (which clears the field first, unlike `type`). NOT atomic across fields — if field N fails, fields 0..N-1 are already filled. Returns the count of successfully filled fields.";

export interface FillFormArgs {
  fields: Array<{ selector: string; value: string }>;
  session_id?: string;
}

export interface FillFormResult {
  filled: number;
}

export async function fillForm(
  pool: BrowserPool,
  args: FillFormArgs,
): Promise<FillFormResult> {
  const session_id = args.session_id ?? "default";
  pool.beginCall(session_id);
  try {
    const { page } = await pool.getOrCreate(session_id);
    let filled = 0;
    for (const { selector, value } of args.fields) {
      await page.locator(selector).fill(value, { timeout: 10_000 });
      filled += 1;
    }
    pool.touch(session_id);
    return { filled };
  } finally {
    pool.endCall(session_id);
  }
}
