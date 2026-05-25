import type { BrowserPool } from "../browser.js";

export const screenshotSchema = {
  type: "object",
  properties: {
    full_page: {
      type: "boolean",
      description: "When true, capture the entire scrollable page; otherwise just the viewport.",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  additionalProperties: false,
} as const;

export const screenshotDescription =
  "Capture a PNG screenshot of the current page. Returned as base64. The nullalis frontend renders this as a live preview so the user sees what the agent is doing. Times out after 30s.";

export interface ScreenshotArgs {
  full_page?: boolean;
  session_id?: string;
}

export interface ScreenshotResult {
  png_base64: string;
  bytes: number;
}

// Wave 3 review HIGH #2: explicit timeout. Playwright's default is 30s,
// but the value belongs in the tool description (and the source) so it's
// visible to the agent and to operators reviewing the surface.
const SCREENSHOT_TIMEOUT_MS = 30_000;

export async function screenshot(
  pool: BrowserPool,
  args: ScreenshotArgs,
): Promise<ScreenshotResult> {
  const session_id = args.session_id ?? "default";
  pool.beginCall(session_id);
  try {
    const { page } = await pool.getOrCreate(session_id);
    const buf = await page.screenshot({
      fullPage: args.full_page ?? false,
      type: "png",
      timeout: SCREENSHOT_TIMEOUT_MS,
    });
    pool.touch(session_id);
    return {
      png_base64: buf.toString("base64"),
      bytes: buf.byteLength,
    };
  } finally {
    pool.endCall(session_id);
  }
}
