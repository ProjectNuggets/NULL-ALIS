import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { crx } from "@crxjs/vite-plugin";
import manifest from "./manifest.json" with { type: "json" };

// nullalis browser extension — Vite + @crxjs/vite-plugin handles MV3 bundling:
// service worker, content script, popup HTML, and asset hashing all out of one
// manifest. See docs/DEVELOPER.md for the load-unpacked workflow.
export default defineConfig({
  plugins: [
    react(),
    // crxjs reads manifest.json, wires entry points, and emits a Chrome-loadable
    // dist/. The cast to `any` works around a known crxjs/Vite types skew that
    // only affects the build-time plugin signature, not runtime behavior.
    crx({ manifest: manifest as any }),
  ],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // Plan-8 — no sourcemaps in the shipped CRX/zip. Sourcemaps expose
    // the full original TypeScript (including the auth/handshake logic)
    // in the packaged extension that ships to every user's browser.
    // `npm run build` and `npm run package` both run `vite build`, so
    // this scopes off-sourcemaps to the shipped artifact; `npm run dev`
    // (the Vite dev server) is unaffected and still serves maps for
    // local debugging.
    sourcemap: false,
    rollupOptions: {
      // crxjs injects all extension entry points from manifest.json.
      // We do not add HTML inputs here — the popup HTML is wired by the plugin.
    },
  },
  server: {
    port: 5173,
    strictPort: true,
    hmr: {
      port: 5174,
    },
  },
  test: {
    environment: "happy-dom",
    globals: true,
    include: ["tests/**/*.test.ts"],
  },
});
