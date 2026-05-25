// SSRF defense — file://, link-local, loopback, private IPs are rejected.
// Pure unit-level tests on sanitizeUrl + an end-to-end through navigate to
// confirm the tool surface honors the deny list.

import { expect, test } from "@playwright/test";
import { sanitizeUrl } from "../src/sanitize.js";
import { BrowserPool } from "../src/browser.js";
import { navigate } from "../src/tools/navigate.js";

test("file:// is rejected", () => {
  const r = sanitizeUrl("file:///etc/passwd");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("scheme_blocked");
});

test("javascript: is rejected", () => {
  const r = sanitizeUrl("javascript:alert(1)");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("scheme_blocked");
});

test("169.254.169.254 (cloud metadata) is rejected", () => {
  const r = sanitizeUrl("http://169.254.169.254/latest/meta-data/");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("link_local_blocked");
});

test("metadata.google.internal is rejected", () => {
  const r = sanitizeUrl("http://metadata.google.internal/computeMetadata/v1/");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("metadata_endpoint_blocked");
});

test("localhost is rejected by default", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://localhost:8080/admin");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("loopback_blocked");
});

test("127.0.0.1 is rejected by default", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://127.0.0.1/");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("loopback_blocked");
});

test("10.0.0.1 (RFC1918) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://10.0.0.1/");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("private_ip_blocked");
});

test("172.20.5.5 (RFC1918) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://172.20.5.5/");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("private_ip_blocked");
});

test("192.168.1.1 (RFC1918) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://192.168.1.1/");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("private_ip_blocked");
});

test("public http URL is accepted", () => {
  const r = sanitizeUrl("http://example.com/foo");
  expect(r.ok).toBe(true);
});

test("https URL is accepted", () => {
  const r = sanitizeUrl("https://example.com/");
  expect(r.ok).toBe(true);
});

test("malformed URL is rejected", () => {
  const r = sanitizeUrl("not a url");
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.reason).toBe("invalid_url");
});

test("allowlist bypass works for localhost", () => {
  process.env.PLAYWRIGHT_MCP_ALLOWLIST = "127.0.0.1,localhost";
  try {
    const r1 = sanitizeUrl("http://127.0.0.1/");
    expect(r1.ok).toBe(true);
    const r2 = sanitizeUrl("http://localhost/admin");
    expect(r2.ok).toBe(true);
  } finally {
    delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  }
});

test("navigate tool surfaces sanitizer rejection as a thrown error", async () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const pool = new BrowserPool({ headless: true, disable_reaper: true });
  try {
    await expect(
      navigate(pool, { url: "file:///etc/passwd" }),
    ).rejects.toThrow(/scheme_blocked/);
    await expect(
      navigate(pool, { url: "http://169.254.169.254/" }),
    ).rejects.toThrow(/link_local_blocked/);
  } finally {
    await pool.shutdown();
  }
});

// ---------------------------------------------------------------------------
// CRITICAL Wave-3-review regression tests. Each url below was VERIFIED to
// bypass the pre-fix sanitizer (allowed when it should have been blocked).
// Keep these as `expect(r.ok).toBe(false)` so any future regression fails loud.
// ---------------------------------------------------------------------------

test("CRITICAL: IPv4-mapped IPv6 → cloud metadata (::ffff:169.254.169.254) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[::ffff:169.254.169.254]/latest/meta-data/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: IPv4-mapped IPv6 → loopback (::ffff:7f00:1) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[::ffff:7f00:1]/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: IPv4-mapped IPv6 → RFC1918 (::ffff:a00:1) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[::ffff:a00:1]/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: IPv6 ULA fd00::ec2:254 (AWS IPv6 metadata alias) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[fd00::ec2:254]/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: IPv6 ULA fd00:ec2::254 is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[fd00:ec2::254]/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: IPv6 loopback ::1 is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[::1]/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: IPv6 link-local fe80::1 is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[fe80::1]/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: localhost. (trailing dot) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://localhost./admin");
  expect(r.ok).toBe(false);
});

test("CRITICAL: metadata.google.internal. (trailing dot) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://metadata.google.internal./computeMetadata/v1/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: bare 0 (canonicalizes to 0.0.0.0) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://0/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: 0.0.0.0 (unspecified IPv4) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://0.0.0.0/");
  expect(r.ok).toBe(false);
});

test("CRITICAL: [::] (unspecified IPv6) is rejected", () => {
  delete process.env.PLAYWRIGHT_MCP_ALLOWLIST;
  const r = sanitizeUrl("http://[::]/");
  expect(r.ok).toBe(false);
});
