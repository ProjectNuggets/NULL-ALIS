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

/** Is this host one of the blocked SSRF classes? `host` is already lowercased. */
function isBlockedHost(rawHost: string): boolean {
  const host = unbracket(rawHost.toLowerCase());

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

  // IPv4 dotted-quad ranges.
  const v4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
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
