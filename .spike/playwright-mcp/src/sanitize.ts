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
//
// IPv6 parsing delegates to `ipaddr.js` because the prior hand-rolled string
// checks missed every canonical IPv6 form (IPv4-mapped, ULA, unspecified, etc.).
// See Wave 3 review CRITICAL #1, #2, #3 for the bypass classes this defends.

// ipaddr.js is published as CommonJS. Under Node's ESM loader the named
// exports get wrapped inside `default`, so the default import is the only
// portable form (works for both `tsc → dist/` ES2022 emit and the test
// runner's native ESM loader).
import ipaddr from "ipaddr.js";

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
  | "metadata_endpoint_blocked"
  | "unspecified_address_blocked"
  | "reserved_address_blocked";

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

/**
 * Normalize a hostname for comparison:
 *   - lowercase
 *   - strip trailing dot (DNS strips it at resolution → bypass class)
 *   - strip surrounding `[...]` brackets from IPv6 literals
 */
function normalizeHost(rawHost: string): { display: string; bareHost: string } {
  const lowered = rawHost.toLowerCase().replace(/\.$/, "");
  const bareHost =
    lowered.startsWith("[") && lowered.endsWith("]")
      ? lowered.slice(1, -1)
      : lowered;
  return { display: lowered, bareHost };
}

/**
 * Classify an IPv4 address against the deny categories. ipaddr.js range
 * categories: "unicast" (the open internet), "private" (RFC1918),
 * "loopback" (127/8), "linkLocal" (169.254/16), "unspecified" (0.0.0.0),
 * "carrierGradeNat" (100.64/10), "broadcast", "multicast", "reserved".
 * We allow only "unicast"; everything else is blocked with a specific reason.
 */
function classifyIPv4(v4: ipaddr.IPv4): SanitizeReject | null {
  const range = v4.range();
  const octets = v4.octets;

  // Distinguish 169.254.169.254 specifically (metadata) from the broader
  // 169.254/16 link-local block, so the agent gets a more actionable reason.
  if (range === "linkLocal") {
    if (octets[0] === 169 && octets[1] === 254 && octets[2] === 169 && octets[3] === 254) {
      return {
        ok: false,
        reason: "link_local_blocked",
        detail: `cloud metadata endpoint 169.254.169.254 is blocked`,
      };
    }
    return {
      ok: false,
      reason: "link_local_blocked",
      detail: `link-local IPv4 ${v4.toString()} is blocked`,
    };
  }
  if (range === "loopback") {
    return {
      ok: false,
      reason: "loopback_blocked",
      detail: `loopback IPv4 ${v4.toString()} is blocked — add to PLAYWRIGHT_MCP_ALLOWLIST to permit`,
    };
  }
  if (range === "private" || range === "carrierGradeNat") {
    return {
      ok: false,
      reason: "private_ip_blocked",
      detail: `private IPv4 ${v4.toString()} is blocked — add to PLAYWRIGHT_MCP_ALLOWLIST to permit`,
    };
  }
  if (range === "unspecified") {
    return {
      ok: false,
      reason: "unspecified_address_blocked",
      detail: `unspecified IPv4 ${v4.toString()} routes to local interfaces — blocked`,
    };
  }
  if (range === "unicast") return null;
  // multicast / broadcast / reserved / anything new — default-deny.
  return {
    ok: false,
    reason: "reserved_address_blocked",
    detail: `reserved IPv4 ${v4.toString()} (range=${range}) is blocked`,
  };
}

/**
 * Classify an IPv6 address. IPv4-mapped addresses (::ffff:a.b.c.d) recurse
 * through the IPv4 classifier so we don't have to duplicate the deny logic.
 *
 * ipaddr.js range categories for v6: "unicast", "unspecified" (::),
 * "loopback" (::1), "linkLocal" (fe80::/10), "uniqueLocal" (fc00::/7,
 * includes fd00::), "ipv4Mapped" (::ffff:0:0/96), "multicast", "rfc6145",
 * "rfc6052", "6to4", "teredo", "reserved". Allow only "unicast".
 */
function classifyIPv6(v6: InstanceType<typeof ipaddr.IPv6>): SanitizeReject | null {
  if (v6.isIPv4MappedAddress()) {
    return classifyIPv4(v6.toIPv4Address());
  }
  const range = v6.range();
  if (range === "unicast") return null;

  // Map ipaddr.js range names onto our public RejectionReason vocabulary.
  switch (range) {
    case "loopback":
      return {
        ok: false,
        reason: "loopback_blocked",
        detail: `IPv6 loopback ${v6.toNormalizedString()} is blocked`,
      };
    case "linkLocal":
      return {
        ok: false,
        reason: "link_local_blocked",
        detail: `IPv6 link-local ${v6.toNormalizedString()} is blocked`,
      };
    case "uniqueLocal":
      return {
        ok: false,
        reason: "private_ip_blocked",
        detail: `IPv6 unique-local ${v6.toNormalizedString()} is blocked (includes AWS IPv6 metadata fd00::ec2:254)`,
      };
    case "unspecified":
      return {
        ok: false,
        reason: "unspecified_address_blocked",
        detail: `IPv6 unspecified :: routes to local interfaces — blocked`,
      };
    default:
      return {
        ok: false,
        reason: "reserved_address_blocked",
        detail: `IPv6 ${v6.toNormalizedString()} (range=${range}) is blocked`,
      };
  }
}

/** Hostnames that are well-known cloud-metadata aliases at the DNS layer. */
function isMetadataAlias(displayHost: string): boolean {
  return displayHost === "metadata.google.internal" || displayHost === "metadata";
}

/** Hostnames that resolve to loopback at the DNS layer. */
function isLoopbackAlias(displayHost: string): boolean {
  return displayHost === "localhost" || displayHost.endsWith(".localhost");
}

/**
 * Validate a URL before handing it to Playwright. Returns a discriminated
 * union so callers can render the reason to the agent / user.
 *
 * Behavior:
 *   - non-http(s) schemes are rejected (file://, chrome://, javascript:, etc.)
 *   - loopback + link-local + RFC1918 + ULA + unspecified addresses are rejected
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

  const { display, bareHost } = normalizeHost(parsed.hostname);

  const allowlist = loadAllowlist();
  // Allowlist hits accept both the bracketed and bare forms so operators can
  // write `127.0.0.1` or `localhost` (or `[::1]`/`::1`) in the env var.
  if (allowlist.has(display) || allowlist.has(bareHost)) {
    return { ok: true, url: parsed };
  }

  // String-level checks first — these short-circuit before IP parsing for
  // hostnames that look nothing like an IP literal (localhost, metadata.*).
  if (isMetadataAlias(display)) {
    return {
      ok: false,
      reason: "metadata_endpoint_blocked",
      detail: `cloud metadata endpoint '${display}' is blocked`,
    };
  }
  if (isLoopbackAlias(display)) {
    return {
      ok: false,
      reason: "loopback_blocked",
      detail: `loopback host '${display}' is blocked — add to PLAYWRIGHT_MCP_ALLOWLIST to permit`,
    };
  }

  // IP-literal path: ipaddr.js handles every canonical form (IPv4 dotted,
  // IPv4-mapped IPv6, IPv6 ULA, IPv6 link-local, IPv6 unspecified, etc.)
  // including the canonicalized forms Node's URL parser emits.
  if (ipaddr.isValid(bareHost)) {
    const addr = ipaddr.parse(bareHost);
    const verdict =
      addr.kind() === "ipv6"
        ? classifyIPv6(addr as InstanceType<typeof ipaddr.IPv6>)
        : classifyIPv4(addr as ipaddr.IPv4);
    if (verdict) return verdict;
    return { ok: true, url: parsed };
  }

  // Non-IP hostname that survived the alias checks: treat as public unicast.
  // DNS rebinding (a public hostname that resolves to RFC1918) is OUT OF SCOPE
  // for the string sanitizer — that's defended at the request layer via the
  // route interceptor installed by the BrowserPool (CRITICAL #4 in Wave 3).
  return { ok: true, url: parsed };
}

/** Human-readable error suitable for an MCP tool error response. */
export function rejectionMessage(r: SanitizeReject): string {
  return `URL rejected (${r.reason}): ${r.detail}`;
}
