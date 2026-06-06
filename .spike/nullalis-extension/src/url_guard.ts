// H2 — navigate URL allowlist (SSRF defense).
//
// `navigate` is the one command that takes an attacker-influenceable URL and
// hands it straight to the browser. A malicious/compromised gateway could try
// to:
//   - run script via javascript:/data: URLs,
//   - read local files via file:,
//   - reach chrome:// internals or view-source:,
//   - pivot to internal/metadata services the user's machine can reach but the
//     gateway cannot (classic SSRF — cloud metadata endpoints, RFC1918 admin
//     panels, link-local 169.254.x, loopback-only dashboards).
//
// We mirror the gateway's SSRF block-list classes but keep it deliberately
// simple: scheme allowlist (http/https only) + a host block-list covering
// loopback, RFC1918, link-local, metadata, and *.local. This is a pure
// function so it unit-tests without any chrome.* APIs.

export interface UrlGuardResult {
  ok: boolean;
  /** Present when ok=false. */
  reason?: string;
}

/** Strip an IPv6 bracket wrapper, e.g. "[::1]" -> "::1". */
function unbracket(host: string): string {
  if (host.startsWith("[") && host.endsWith("]")) {
    return host.slice(1, -1);
  }
  return host;
}

/**
 * Classify a bare IPv4 dotted-quad as a blocked SSRF range (loopback / RFC1918
 * / link-local / metadata / "this host"). Returns false for anything that isn't
 * a dotted-quad or is a public address. Shared by the bare-v4 path and the
 * IPv4-mapped-IPv6 path so the two stay in lock-step.
 */
function isBlockedV4(host: string): boolean {
  const v4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!v4) return false;
  const a = Number(v4[1]);
  const b = Number(v4[2]);
  // 127.0.0.0/8 — loopback.
  if (a === 127) return true;
  // 10.0.0.0/8 — RFC1918.
  if (a === 10) return true;
  // 192.168.0.0/16 — RFC1918.
  if (a === 192 && b === 168) return true;
  // 172.16.0.0/12 — RFC1918 (172.16 – 172.31).
  if (a === 172 && b >= 16 && b <= 31) return true;
  // 169.254.0.0/16 — link-local (includes the 169.254.169.254 metadata IP).
  if (a === 169 && b === 254) return true;
  // 0.0.0.0/8 — "this host".
  if (a === 0) return true;
  return false;
}

/**
 * If `host` is an IPv4-mapped IPv6 address (::ffff:<v4>), return the embedded
 * dotted-quad so the v4 classifier can run on it; otherwise null.
 *
 * The WHATWG URL parser normalizes `[::ffff:127.0.0.1]` to the hex hextet form
 * `::ffff:7f00:1`, but a raw/unparsed host may carry the dotted form
 * `::ffff:127.0.0.1`. We handle BOTH:
 *   - dotted form: take the trailing dotted-quad verbatim.
 *   - hex form: decode the last two hextets (the low 32 bits) to a dotted quad.
 * `host` is already unbracketed + lowercased.
 */
function mappedV4(host: string): string | null {
  if (!host.startsWith("::ffff:")) return null;
  const rest = host.slice("::ffff:".length);

  // Dotted form, e.g. "::ffff:127.0.0.1".
  if (/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(rest)) {
    return rest;
  }

  // Hex form, e.g. "::ffff:7f00:1" — last two hextets hold the v4's 32 bits.
  const hextets = rest.split(":");
  if (hextets.length !== 2) return null;
  const hi = parseInt(hextets[0], 16);
  const lo = parseInt(hextets[1], 16);
  if (!Number.isInteger(hi) || !Number.isInteger(lo)) return null;
  if (hi < 0 || hi > 0xffff || lo < 0 || lo > 0xffff) return null;
  return `${(hi >> 8) & 0xff}.${hi & 0xff}.${(lo >> 8) & 0xff}.${lo & 0xff}`;
}

/** Is this host one of the blocked SSRF classes? `host` is already lowercased. */
function isBlockedHost(rawHost: string): boolean {
  let host = unbracket(rawHost.toLowerCase());

  // Strip a single trailing dot — the FQDN root label. `localhost.` and
  // `printer.local.` resolve identically to their dot-less forms, so we must
  // classify them the same way (gateway parity: url_sanitize.zig / urlguard.go).
  // Bare IPv4 never carries a trailing dot once parsed, but strip defensively.
  if (host.endsWith(".")) {
    host = host.slice(0, -1);
  }

  // Exact loopback / unspecified names + addresses.
  if (host === "localhost" || host === "::1" || host === "::" || host === "0.0.0.0") {
    return true;
  }

  // *.local and *.localhost mDNS / internal names.
  if (host === "local" || host.endsWith(".local") || host.endsWith(".localhost")) {
    return true;
  }

  // Cloud metadata endpoints (AWS/GCP/Azure use 169.254.169.254 + names).
  if (host === "metadata" || host.startsWith("metadata.") || host.includes("metadata.google")) {
    return true;
  }

  // IPv4-mapped IPv6 (::ffff:127.0.0.1 / ::ffff:7f00:1) — re-classify the
  // embedded v4 so a mapped loopback/metadata/RFC1918 address can't slip past.
  const embedded = mappedV4(host);
  if (embedded && isBlockedV4(embedded)) {
    return true;
  }

  // IPv4 dotted-quad ranges.
  if (isBlockedV4(host)) {
    return true;
  }

  // IPv6 unique-local fc00::/7 (fc.. / fd..) and link-local fe80::/10.
  if (host.startsWith("fc") || host.startsWith("fd")) {
    // fc00::/7 — match the leading nibble pair of a hextet.
    if (/^f[cd][0-9a-f]{0,2}:/.test(host) || host === "fc00" || host.startsWith("fc00:") || host.startsWith("fd")) {
      return true;
    }
  }
  if (host.startsWith("fe8") || host.startsWith("fe9") || host.startsWith("fea") || host.startsWith("feb")) {
    // fe80::/10 — fe80..febf.
    return true;
  }

  return false;
}

/**
 * Validate a navigate target. Allows ONLY http: / https: to public hosts.
 * Returns {ok:false, reason} for any blocked scheme or host.
 */
export function checkNavigateUrl(rawUrl: string): UrlGuardResult {
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return { ok: false, reason: "not a valid absolute URL" };
  }

  // Scheme allowlist — http/https only. Everything else (javascript:, data:,
  // file:, chrome:, about:, view-source:, blob:, ftp:, ...) is rejected.
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return { ok: false, reason: `scheme ${parsed.protocol} is not allowed (http/https only)` };
  }

  if (parsed.hostname.length === 0) {
    return { ok: false, reason: "URL has no host" };
  }

  if (isBlockedHost(parsed.hostname)) {
    return { ok: false, reason: `host ${parsed.hostname} is blocked (loopback/private/link-local/metadata)` };
  }

  return { ok: true };
}
