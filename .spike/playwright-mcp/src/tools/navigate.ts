import type { BrowserPool } from "../browser.js";
import { rejectionMessage, sanitizeUrl, type SanitizeWarning } from "../sanitize.js";

export const navigateSchema = {
  type: "object",
  properties: {
    url: { type: "string", description: "Absolute URL to navigate to. Must be http: or https:." },
    wait_until: {
      type: "string",
      enum: ["load", "domcontentloaded", "networkidle"],
      description:
        "Playwright wait condition. 'load' (default) waits for the load event; 'networkidle' waits for the network to quiet — slower but better for SPAs.",
    },
    session_id: {
      type: "string",
      description: "Per-session BrowserContext key. Defaults to 'default'.",
    },
  },
  required: ["url"],
  additionalProperties: false,
} as const;

export const navigateDescription =
  "Navigate the session's browser to an HTTP/HTTPS URL. SSRF-defended: file://, loopback, link-local, and private IPs are rejected by default (override via PLAYWRIGHT_MCP_ALLOWLIST). Returns the final HTTP status, the post-redirect URL, and the document title.";

export interface NavigateArgs {
  url: string;
  wait_until?: "load" | "domcontentloaded" | "networkidle";
  session_id?: string;
}

export interface NavigateResult {
  status: number;
  final_url: string;
  title: string;
  /**
   * Soft signals from the sanitizer. Present only when non-empty so existing
   * callers parsing the result aren't surprised. Wave 3 review HIGH #9:
   * `punycode_hostname` flags visually-deceptive (homograph) hosts.
   */
  warnings?: SanitizeWarning[];
}

export async function navigate(
  pool: BrowserPool,
  args: NavigateArgs,
): Promise<NavigateResult> {
  const sanitized = sanitizeUrl(args.url);
  if (!sanitized.ok) {
    throw new Error(rejectionMessage(sanitized));
  }
  const session_id = args.session_id ?? "default";
  pool.beginCall(session_id);
  try {
    const { page } = await pool.getOrCreate(session_id);
    const resp = await page.goto(sanitized.url.toString(), {
      waitUntil: args.wait_until ?? "load",
      timeout: 30_000,
    });
    // page.goto returns null for same-document navigations; surface 0 in that case
    // so the agent can tell the difference from a real load.
    const status = resp ? resp.status() : 0;
    pool.noteUrl(session_id, page.url());
    const result: NavigateResult = {
      status,
      final_url: page.url(),
      title: await page.title(),
    };
    if (sanitized.warnings && sanitized.warnings.length > 0) {
      result.warnings = sanitized.warnings;
    }
    return result;
  } finally {
    pool.endCall(session_id);
  }
}
