// Token + gateway URL persistence. Lives in chrome.storage.local, which is
// per-profile and not synced — the token never leaves this machine.
//
// We expose async getters/setters that work both in the service worker and in
// the popup. The popup also has a "clear token" path that wipes both fields.

import type { StoredConfig } from "./types";

const KEY = "nullalis_config_v1";

/**
 * Read the stored config. Returns null if the user has not pasted a token yet.
 * Safe to call from background or popup contexts.
 */
export async function getConfig(): Promise<StoredConfig | null> {
  const raw = await chrome.storage.local.get(KEY);
  const v = raw[KEY] as StoredConfig | undefined;
  if (!v || typeof v !== "object") return null;
  if (typeof v.token !== "string" || v.token.length === 0) return null;
  if (typeof v.gateway_url !== "string" || v.gateway_url.length === 0) return null;
  return v;
}

/**
 * Persist a new token + gateway URL. Validates the URL is ws:// or wss:// so
 * we never accidentally try to negotiate a plain-HTTP socket.
 */
export async function setConfig(token: string, gatewayUrl: string): Promise<void> {
  const trimmedToken = token.trim();
  const trimmedUrl = gatewayUrl.trim();

  if (trimmedToken.length === 0) {
    throw new Error("token must not be empty");
  }
  if (!/^wss?:\/\//.test(trimmedUrl)) {
    throw new Error("gateway_url must start with ws:// or wss://");
  }

  const config: StoredConfig = { token: trimmedToken, gateway_url: trimmedUrl };
  await chrome.storage.local.set({ [KEY]: config });
}

/** Wipe the stored token + URL. The popup uses this to force a re-auth. */
export async function clearConfig(): Promise<void> {
  await chrome.storage.local.remove(KEY);
}
