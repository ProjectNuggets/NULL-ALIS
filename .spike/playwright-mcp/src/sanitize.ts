// URL sanitization — SSRF defense at the boundary.
//
// nullalis drives this server with URLs that may come (transitively) from
// user prompts or from web content. Without a deny-list, an attacker can
// pivot us into:
//   - cloud metadata endpoints (169.254.169.254, fd00:ec2::254 on AWS)
//   - kubernetes / docker internal services (10.x, 172.16-31.x, 192.168.x)
//   - the loopback interface (127.0.0.1, ::1, localhost)
//   - file:// reads of the server's filesystem
//
// Default-deny matches AGENTS.md §3.5 (secure-by-default, least privilege).
// Operators who *do* need access (e.g. a staging app on localhost) opt in via
// the PLAYWRIGHT_MCP_ALLOWLIST env var.

/**
 * Reasons a URL might be rejected. Surfaced to the agent (and the user
 * watching) so it can pick a different approach instead of silently failing.
 */
export type RejectionReason =
  | "invalid_url"
  | "scheme_blocked"
  | "loopback_blocked"
  | "link_local_blocked"
  | "private_ip_blocked"
  | "metadata_endpoint_blocked";

export interface SanitizeOk {
  ok: true;
  url: URL;
}

export interface SanitizeReject {
  ok: false;
  reason: RejectionReason;
  detail: string;
}

export type SanitizeResult = SanitizeOk | SanitizeReject;

/** Parse the comma-separated allowlist env var into a Set of bare hostnames. */
function loadAllowlist(): Set<string> {
  const raw = process.env.PLAYWRIGHT_MCP_ALLOWLIST ?? "";
  return new Set(
    raw
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter((s) => s.length > 0),
  );
}

const ALLOWED_SCHEMES = new Set(["http:", "https:"]);

/** IPv4 dotted quad as four numbers, or null if not parseable. */
function parseIPv4(host: string): [number, number, number, number] | null {
  const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m) return null;
  const parts = m.slice(1, 5).map((n) => Number(n)) as [
    number,
    number,
    number,
    number,
  ];
  if (parts.some((p) => p < 0 || p > 255)) return null;
  return parts;
}

/** True for RFC1918 private ranges + carrier-grade NAT. */
function isPrivateIPv4(host: string): boolean {
  const ip = parseIPv4(host);
  if (!ip) return false;
  const [a, b] = ip;
  if (a === 10) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
  return false;
}

function isLoopback(host: string): boolean {
  const h = host.toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost")) return true;
  const ip = parseIPv4(h);
  if (ip && ip[0] === 127) return true;
  if (h === "::1" || h === "[::1]") return true;
  return false;
}

function isLinkLocal(host: string): boolean {
  const ip = parseIPv4(host);
  if (ip && ip[0] === 169 && ip[1] === 254) return true;
  // IPv6 link-local: fe80::/10
  const lower = host.toLowerCase().replace(/^\[|\]$/g, "");
  if (lower.startsWith("fe80:") || lower.startsWith("fe80::")) return true;
  return false;
}

function isMetadataEndpoint(host: string): boolean {
  // AWS / GCP / Azure all live on 169.254.169.254 — caught by link-local — but
  // the metadata.google.internal alias is DNS-resolved at the OS layer, so we
  // catch the well-known name here too.
  return host === "metadata.google.internal" || host === "metadata";
}

/**
 * Validate a URL before handing it to Playwright. Returns a discriminated
 * union so callers can render the reason to the agent / user.
 *
 * Behavior:
 *   - non-http(s) schemes are rejected (file://, chrome://, javascript:, etc.)
 *   - loopback + link-local + RFC1918 IPs are rejected
 *   - well-known metadata hostnames are rejected
 *   - hostnames in PLAYWRIGHT_MCP_ALLOWLIST bypass loopback + private checks
 */
export function sanitizeUrl(input: string): SanitizeResult {
  let parsed: URL;
  try {
    parsed = new URL(input);
  } catch {
    return { ok: false, reason: "invalid_url", detail: `not a valid URL: ${input}` };
  }

  if (!ALLOWED_SCHEMES.has(parsed.protocol)) {
    return {
      ok: false,
      reason: "scheme_blocked",
      detail: `scheme '${parsed.protocol}' is not allowed (only http:, https:)`,
    };
  }

  const host = parsed.hostname.toLowerCase();
  const allowlist = loadAllowlist();
  if (allowlist.has(host)) {
    return { ok: true, url: parsed };
  }

  if (isMetadataEndpoint(host)) {
    return {
      ok: false,
      reason: "metadata_endpoint_blocked",
      detail: `cloud metadata endpoint '${host}' is blocked`,
    };
  }
  if (isLinkLocal(host)) {
    return {
      ok: false,
      reason: "link_local_blocked",
      detail: `link-local address '${host}' is blocked (includes cloud metadata 169.254.169.254)`,
    };
  }
  if (isLoopback(host)) {
    return {
      ok: false,
      reason: "loopback_blocked",
      detail: `loopback host '${host}' is blocked — add to PLAYWRIGHT_MCP_ALLOWLIST to permit`,
    };
  }
  if (isPrivateIPv4(host)) {
    return {
      ok: false,
      reason: "private_ip_blocked",
      detail: `private IP '${host}' is blocked — add to PLAYWRIGHT_MCP_ALLOWLIST to permit`,
    };
  }

  return { ok: true, url: parsed };
}

/** Human-readable error suitable for an MCP tool error response. */
export function rejectionMessage(r: SanitizeReject): string {
  return `URL rejected (${r.reason}): ${r.detail}`;
}
