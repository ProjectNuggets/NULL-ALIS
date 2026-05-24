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
  "Scroll the viewport. Use this to load lazy-rendered content or to expose elements that are off-screen before clicking them.";

export interface ScrollArgs {
  direction: "up" | "down" | "top" | "bottom";
  pixels?: number;
  session_id?: string;
}

export interface ScrollResult {
  scrolled: true;
  scroll_y: number;
}

export async function scroll(
  pool: BrowserPool,
  args: ScrollArgs,
): Promise<ScrollResult> {
  const session_id = args.session_id ?? "default";
  const { page } = await pool.getOrCreate(session_id);
  const pixels = args.pixels ?? 600;
  const scroll_y = await page.evaluate(
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
  );
  pool.touch(session_id);
  return { scrolled: true, scroll_y };
}
