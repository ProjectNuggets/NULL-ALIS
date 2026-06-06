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

/** Loopback hostnames where plaintext ws:// is acceptable. */
const LOOPBACK_HOSTS = new Set<string>(["localhost", "127.0.0.1", "[::1]", "::1"]);

/**
 * Persist a new token + gateway URL. Validates the URL is ws:// or wss:// so
 * we never accidentally try to negotiate a plain-HTTP socket.
 *
 * Wave 3 review HIGH #7: ws:// (plaintext) is REJECTED for any non-loopback
 * hostname. The README's "always use wss:// in any non-loopback scenario"
 * rule is now enforced in code. A user pasting `ws://prod.gateway.example.com/ws`
 * (typo / phishing / misunderstanding) would otherwise send the bearer token
 * in cleartext on every reconnect handshake.
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

  // Loopback ws:// is allowed (dev / self-hosted localhost); everything
  // else MUST be wss:// so the token is encrypted in transit.
  let parsed: URL;
  try {
    parsed = new URL(trimmedUrl);
  } catch {
    throw new Error("gateway_url is not a valid URL");
  }
  if (parsed.protocol === "ws:") {
    const host = parsed.hostname.toLowerCase();
    const bracketed = `[${host}]`;
    if (!LOOPBACK_HOSTS.has(host) && !LOOPBACK_HOSTS.has(bracketed)) {
      throw new Error(
        `gateway_url must use wss:// for non-loopback hosts — refusing ws://${host} to keep the token off the wire in cleartext`,
      );
    }
  }

  const config: StoredConfig = { token: trimmedToken, gateway_url: trimmedUrl };
  await chrome.storage.local.set({ [KEY]: config });
}

/** Wipe the stored token + URL. The popup uses this to force a re-auth. */
export async function clearConfig(): Promise<void> {
  await chrome.storage.local.remove(KEY);
}
