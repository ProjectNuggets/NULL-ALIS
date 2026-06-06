// Manifest sanity tests — catches accidental MV2 regressions, missing
// permissions, missing entry points, or invalid host_permissions globs.

import { describe, expect, it } from "vitest";
import manifest from "../manifest.json";

describe("manifest.json", () => {
  it("is manifest_version 3", () => {
    expect(manifest.manifest_version).toBe(3);
  });

  it("has a name, version, description", () => {
    expect(typeof manifest.name).toBe("string");
    expect(manifest.name.length).toBeGreaterThan(0);
    expect(typeof manifest.version).toBe("string");
    // semver-ish — at least one dot
    expect(manifest.version.includes(".")).toBe(true);
    expect(typeof manifest.description).toBe("string");
    expect(manifest.description.length).toBeGreaterThan(20);
  });

  it("declares a service worker (module type)", () => {
    expect(manifest.background?.service_worker).toBe("src/background.ts");
    expect(manifest.background?.type).toBe("module");
  });

  it("declares a popup", () => {
    expect(manifest.action?.default_popup).toBe("src/popup/index.html");
  });

  it("declares NO declarative content_scripts (C1/H1 — on-demand injection only)", () => {
    // The content script is no longer auto-injected into every http(s) page.
    // It is injected ON DEMAND into consented tabs via
    // chrome.scripting.executeScript. A declarative content_scripts block would
    // re-introduce all-URLs reach without per-tab consent.
    const m = manifest as Record<string, unknown>;
    expect(m.content_scripts).toBeUndefined();
  });

  it("declares NO web_accessible_resources (L1/L2)", () => {
    // We removed the WAR block: the on-demand content script is a self-contained
    // classic IIFE injected via executeScript, not a page-reachable ESM module.
    const m = manifest as Record<string, unknown>;
    expect(m.web_accessible_resources).toBeUndefined();
  });

  it("has the least-privilege permission set and NO more (C1/H1)", () => {
    // `tabs` was DROPPED: we use activeTab + on-demand scripting injection.
    // captureVisibleTab / tabs.query(active) get their data from activeTab on
    // the consented tab; tabs.update/create/reload/sendMessage/onRemoved need
    // no extra permission.
    const required = ["activeTab", "scripting", "storage"];
    expect(manifest.permissions).toEqual(required);
    expect(manifest.permissions).not.toContain("tabs");
  });

  it("declares an explicit, locked-down content_security_policy (L2)", () => {
    const csp = manifest.content_security_policy?.extension_pages ?? "";
    expect(csp).toContain("script-src 'self'");
    expect(csp).toContain("object-src 'self'");
  });

  it("declares NO broad host_permissions in v1", () => {
    // We rely entirely on activeTab + on-demand injection — no runtime host
    // permission.
    expect(manifest.host_permissions).toEqual([]);
  });

  it("declares icons at 16/48/128 sizes", () => {
    expect(manifest.icons?.["16"]).toBeDefined();
    expect(manifest.icons?.["48"]).toBeDefined();
    expect(manifest.icons?.["128"]).toBeDefined();
  });

  it("requires a modern Chrome version", () => {
    expect(parseInt(manifest.minimum_chrome_version ?? "0", 10)).toBeGreaterThanOrEqual(116);
  });
});
