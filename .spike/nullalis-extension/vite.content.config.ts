import { defineConfig } from "vite";

// Dedicated build for the on-demand content script.
//
// WHY a separate config (C1/H1 — per-tab consent + programmatic injection):
// The main crxjs build (vite.config.ts) used to declare `src/content.ts` as a
// DECLARATIVE content_scripts entry that auto-injected into EVERY http(s) page.
// crxjs emits that content script as an ESM module loaded via a tiny loader that
// `import()`s the real module from a `web_accessible_resource`. That shape is
// incompatible with the security model we want:
//   - declarative injection = no per-tab consent (runs everywhere, always),
//   - WAR-exposed ESM module = extra page-reachable surface,
//   - hashed filename + ESM = cannot be handed to chrome.scripting.executeScript.
//
// Instead we inject the content script ON DEMAND, only into tabs the user has
// explicitly enabled from the popup (a user gesture grants activeTab). For that,
// chrome.scripting.executeScript({ target:{tabId}, files:["content.js"] }) needs
// a SINGLE, SELF-CONTAINED, CLASSIC (non-ESM) script at a STABLE path. This
// config produces exactly that: `dist/content.js`, IIFE format, all deps
// (commands.ts) inlined, no code-splitting, no imports. No WAR required.
//
// The build runs as a second pass AFTER the crxjs build (see package.json
// `build` script) with emptyOutDir:false so it adds content.js to the existing
// dist/ without wiping the crxjs output.
export default defineConfig({
  build: {
    outDir: "dist",
    emptyOutDir: false,
    sourcemap: false,
    // Keep the classic-script output as small/inspectable as the rest.
    minify: false,
    lib: {
      entry: "src/content.ts",
      formats: ["iife"],
      // The IIFE needs a global name even though we don't reference it; the
      // content script only registers a chrome.runtime.onMessage listener as a
      // side effect.
      name: "__nullalisContent",
      fileName: () => "content.js",
    },
    rollupOptions: {
      output: {
        // Single self-contained file — no shared chunks, no dynamic imports.
        inlineDynamicImports: true,
        entryFileNames: "content.js",
      },
    },
  },
});
