// H2 — navigate URL allowlist (SSRF defense) tests.
//
// checkNavigateUrl is a pure function (no chrome.* / no DOM), so we exercise it
// directly: allowed public http(s), and the full block-list of schemes + hosts.

import { describe, expect, it } from "vitest";
import { checkNavigateUrl } from "../src/url_guard";

describe("checkNavigateUrl — allowed", () => {
  const allowed = [
    "https://example.com/",
    "https://example.com/path?q=1#frag",
    "http://example.org/page",
    "https://sub.domain.co.uk/x",
    "https://93.184.216.34/", // a public IP
    "https://example.com:8443/",
  ];
  for (const url of allowed) {
    it(`allows ${url}`, () => {
      expect(checkNavigateUrl(url).ok).toBe(true);
    });
  }
});

describe("checkNavigateUrl — blocked schemes", () => {
  const blocked = [
    "javascript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "file:///etc/passwd",
    "chrome://settings",
    "about:blank",
    "view-source:https://example.com",
    "blob:https://example.com/uuid",
    "ftp://example.com/file",
    "ws://example.com/socket",
  ];
  for (const url of blocked) {
    it(`blocks ${url}`, () => {
      const r = checkNavigateUrl(url);
      expect(r.ok).toBe(false);
      expect(r.reason).toBeTruthy();
    });
  }
});

describe("checkNavigateUrl — blocked hosts (SSRF classes)", () => {
  const blocked = [
    "http://localhost/",
    "https://localhost:3000/admin",
    "http://127.0.0.1/",
    "http://127.5.5.5/",
    "http://0.0.0.0/",
    "http://10.0.0.1/",
    "http://10.255.255.255/",
    "http://192.168.1.1/",
    "http://172.16.0.1/",
    "http://172.31.255.255/",
    "http://169.254.169.254/latest/meta-data/", // cloud metadata
    "http://[::1]/",
    "http://[fc00::1]/",
    "http://[fd12:3456::1]/",
    "http://[fe80::1]/",
    "http://printer.local/",
    "http://metadata/",
    "http://metadata.google.internal/computeMetadata/v1/",
  ];
  for (const url of blocked) {
    it(`blocks ${url}`, () => {
      const r = checkNavigateUrl(url);
      expect(r.ok).toBe(false);
      expect(r.reason).toBeTruthy();
    });
  }

  it("does NOT block 172.32.x (outside RFC1918) or 11.x", () => {
    expect(checkNavigateUrl("http://172.32.0.1/").ok).toBe(true);
    expect(checkNavigateUrl("http://11.0.0.1/").ok).toBe(true);
  });

  it("does NOT block a public host that merely contains 'local'", () => {
    expect(checkNavigateUrl("https://locale.example.com/").ok).toBe(true);
  });
});

describe("checkNavigateUrl — malformed", () => {
  it("rejects a non-absolute URL", () => {
    expect(checkNavigateUrl("/relative/path").ok).toBe(false);
  });
  it("rejects empty string", () => {
    expect(checkNavigateUrl("").ok).toBe(false);
  });
});
