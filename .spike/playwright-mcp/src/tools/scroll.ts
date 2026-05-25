import type { BrowserPool } from "../browser.js";

export const scrollSchema = {
  type: "object",
  properties: {
    direction: {
      type: "string",
      enum: ["up", "down", "top", "bottom"],
      description: "'up'/'down' scroll by `pixels`; 'top'/'bottom' jump to the edge.",
    },
    pixels: {
      type: "number",
      description: "Pixels to scroll for 'up'/'down'. Default 600 (~one screen).",
    },
    session_id: { type: "string", description: "Per-session key. Default 'default'." },
  },
  required: ["direction"],
  additionalProperties: false,
} as const;

export const scrollDescription =
  "Scroll the viewport. Use this to load lazy-rendered content or to expose elements that are off-screen before clicking them. Times out after 10s if the page event loop hangs.";

export interface ScrollArgs {
  direction: "up" | "down" | "top" | "bottom";
  pixels?: number;
  session_id?: string;
}

export interface ScrollResult {
  scrolled: true;
  scroll_y: number;
}

// Wave 3 review HIGH #2: explicit timeout on page.evaluate. Scroll's
// evaluator is bounded (window.scroll*), but a hostile page can hijack the
// event loop with a sync handler. Cap at 10s so a wedged page doesn't pin
// the tool indefinitely.
const SCROLL_EVALUATE_TIMEOUT_MS = 10_000;

function timeoutRejection(ms: number): Promise<never> {
  return new Promise<never>((_, reject) => {
    setTimeout(
      () => reject(new Error(`timeout: scroll evaluator did not return within ${ms}ms`)),
      ms,
    ).unref?.();
  });
}

export async function scroll(
  pool: BrowserPool,
  args: ScrollArgs,
): Promise<ScrollResult> {
  const session_id = args.session_id ?? "default";
  pool.beginCall(session_id);
  try {
    const { page } = await pool.getOrCreate(session_id);
    const pixels = args.pixels ?? 600;
    const scroll_y = await Promise.race([
      page.evaluate(
        ({ direction, pixels }) => {
          switch (direction) {
            case "up":
              window.scrollBy(0, -pixels);
              break;
            case "down":
              window.scrollBy(0, pixels);
              break;
            case "top":
              window.scrollTo(0, 0);
              break;
            case "bottom":
              window.scrollTo(0, document.body.scrollHeight);
              break;
          }
          return window.scrollY;
        },
        { direction: args.direction, pixels },
      ),
      timeoutRejection(SCROLL_EVALUATE_TIMEOUT_MS),
    ]);
    pool.touch(session_id);
    return { scrolled: true, scroll_y };
  } finally {
    pool.endCall(session_id);
  }
}
