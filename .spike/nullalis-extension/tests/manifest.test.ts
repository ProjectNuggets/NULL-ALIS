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

  it("declares the content script narrowly for http/https only", () => {
    // We deliberately do NOT use <all_urls>: the agent automates the user's
    // logged-in browser sessions, which are always http(s). Excluding file://,
    // data:, blob:, ftp:, view-source: keeps the in-page injection surface to
    // the actually-targeted protocol set. See docs/SECURITY.md.
    const scripts = manifest.content_scripts ?? [];
    expect(scripts.length).toBe(1);
    expect(scripts[0].matches).toEqual(["http://*/*", "https://*/*"]);
    expect(scripts[0].matches).not.toContain("<all_urls>");
    expect(scripts[0].js).toContain("src/content.ts");
    expect(scripts[0].run_at).toBe("document_idle");
  });

  it("has the minimum required permissions and NO more", () => {
    const required = ["activeTab", "scripting", "tabs", "storage"];
    expect(manifest.permissions).toEqual(required);
  });

  it("declares NO broad host_permissions in v1", () => {
    // We rely entirely on activeTab — the content script attaches via the
    // declarative content_scripts entry, not a runtime host permission.
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
