// Popup UI — opened by clicking the extension's toolbar icon.
//
// Responsibilities:
//   - Show connection state (connected / disconnected / last error)
//   - Show the gateway URL the extension is configured for (anti-phishing)
//   - Let the user paste a token + gateway URL, or clear it
//   - Show the most recent command + total commands executed
//   - Big red STOP button that severs WS + reloads agent-touched tabs

import { useEffect, useState } from "react";
import type { ConnectionStatus, PopupRequest, PopupResponse } from "../types";

async function send(req: PopupRequest): Promise<PopupResponse> {
  return await chrome.runtime.sendMessage(req);
}

async function fetchStatus(): Promise<ConnectionStatus | null> {
  const r = await send({ type: "get_status" });
  if (r.ok && "status" in r) return r.status;
  return null;
}

const badgeStyle = (connected: boolean): React.CSSProperties => ({
  fontSize: 11,
  fontWeight: 500,
  padding: "2px 8px",
  borderRadius: 999,
  background: connected ? "#0e7c4a" : "#5a1c1c",
  color: "#fff",
});

const styles: Record<string, React.CSSProperties> = {
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 12,
  },
  brand: {
    fontWeight: 600,
    fontSize: 14,
    letterSpacing: "-0.01em",
  },
  section: {
    marginBottom: 12,
    paddingBottom: 12,
    borderBottom: "1px solid #1f2330",
  },
  label: {
    display: "block",
    fontSize: 11,
    textTransform: "uppercase",
    letterSpacing: "0.04em",
    color: "#8a93a6",
    marginBottom: 4,
  },
  input: {
    width: "100%",
    boxSizing: "border-box",
    padding: "6px 8px",
    border: "1px solid #2a2f3d",
    borderRadius: 4,
    background: "#15181f",
    color: "#f5f5f5",
    fontSize: 12,
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
    marginBottom: 6,
  },
  row: {
    display: "flex",
    gap: 6,
    marginTop: 4,
  },
  btn: {
    flex: 1,
    padding: "6px 10px",
    border: "1px solid #2a2f3d",
    borderRadius: 4,
    background: "#1c212c",
    color: "#f5f5f5",
    fontSize: 12,
    cursor: "pointer",
  },
  stop: {
    width: "100%",
    padding: "10px 12px",
    border: "1px solid #7a1a1a",
    borderRadius: 4,
    background: "#c0392b",
    color: "#fff",
    fontWeight: 600,
    fontSize: 13,
    cursor: "pointer",
    marginTop: 4,
  },
  meta: {
    fontSize: 11,
    color: "#8a93a6",
  },
  url: {
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
    fontSize: 11,
    color: "#a8b3cf",
    wordBreak: "break-all",
  },
  error: {
    fontSize: 11,
    color: "#e57373",
    marginTop: 4,
  },
};

export function App(): JSX.Element {
  const [status, setStatus] = useState<ConnectionStatus | null>(null);
  const [token, setToken] = useState("");
  const [gatewayUrl, setGatewayUrl] = useState("wss://gateway.nullalis.local/ext/ws");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void fetchStatus().then(setStatus);
    // Poll for status updates so the user sees commands flowing in real-time.
    const t = setInterval(() => {
      void fetchStatus().then((s) => {
        if (s) setStatus(s);
      });
    }, 1_000);
    return () => clearInterval(t);
  }, []);

  const onSave = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const r = await send({ type: "set_token", token, gateway_url: gatewayUrl });
      if (!r.ok) setError("error" in r ? r.error : "unknown error");
      else {
        setToken("");
        setStatus(await fetchStatus());
      }
    } finally {
      setBusy(false);
    }
  };

  const onClear = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await send({ type: "clear_token" });
      setStatus(await fetchStatus());
    } finally {
      setBusy(false);
    }
  };

  const onConnect = async (): Promise<void> => {
    setBusy(true);
    try {
      await send({ type: "connect" });
      setStatus(await fetchStatus());
    } finally {
      setBusy(false);
    }
  };

  const onDisconnect = async (): Promise<void> => {
    setBusy(true);
    try {
      await send({ type: "disconnect" });
      setStatus(await fetchStatus());
    } finally {
      setBusy(false);
    }
  };

  const onStop = async (): Promise<void> => {
    setBusy(true);
    try {
      await send({ type: "stop_all" });
      setStatus(await fetchStatus());
    } finally {
      setBusy(false);
    }
  };

  const connected = status?.connected ?? false;
  const authenticated = status?.authenticated ?? false;
  const hasToken = status?.has_token ?? false;

  // Badge: green only when fully authenticated. A "connected" socket that
  // hasn't been auth_ack'd is a UX signal the user should see — pre-Wave-3-fix
  // the extension would have started executing commands here, now it
  // explicitly waits. (Wave 3 review CRITICAL #5.)
  const badgeLabel = authenticated
    ? "authenticated"
    : connected
      ? "connecting…"
      : hasToken
        ? "disconnected"
        : "no token";

  return (
    <div>
      <header style={styles.header}>
        <span style={styles.brand}>nullalis</span>
        <span style={badgeStyle(authenticated)}>{badgeLabel}</span>
      </header>

      <section style={styles.section}>
        <span style={styles.label}>gateway</span>
        <div style={styles.url}>{status?.gateway_url ?? "(none configured)"}</div>
        {status?.last_error && <div style={styles.error}>last error: {status.last_error}</div>}
      </section>

      {!hasToken && (
        <section style={styles.section}>
          <label style={styles.label} htmlFor="gw-url">
            gateway url
          </label>
          <input
            id="gw-url"
            style={styles.input}
            value={gatewayUrl}
            onChange={(e) => setGatewayUrl(e.target.value)}
            placeholder="wss://gateway.nullalis.local/ext/ws"
            spellCheck={false}
          />
          <label style={styles.label} htmlFor="tok">
            token
          </label>
          <input
            id="tok"
            style={styles.input}
            type="password"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            placeholder="paste your nullalis extension token"
            spellCheck={false}
          />
          <button
            style={styles.btn}
            onClick={() => void onSave()}
            disabled={busy || token.length === 0}
          >
            save and connect
          </button>
          {error && <div style={styles.error}>{error}</div>}
        </section>
      )}

      {hasToken && (
        <section style={styles.section}>
          <div style={styles.row}>
            {connected ? (
              <button style={styles.btn} onClick={() => void onDisconnect()} disabled={busy}>
                disconnect
              </button>
            ) : (
              <button style={styles.btn} onClick={() => void onConnect()} disabled={busy}>
                connect
              </button>
            )}
            <button style={styles.btn} onClick={() => void onClear()} disabled={busy}>
              clear token
            </button>
          </div>
        </section>
      )}

      <section style={styles.section}>
        <span style={styles.label}>activity</span>
        <div style={styles.meta}>
          commands executed: {status?.commands_total ?? 0}
        </div>
        {status?.last_command ? (
          <div style={styles.meta}>
            last: <code>{status.last_command.tool}</code> ({status.last_command.command_id.slice(0, 8)})
          </div>
        ) : (
          <div style={styles.meta}>no commands yet</div>
        )}
      </section>

      <button style={styles.stop} onClick={() => void onStop()} disabled={busy}>
        STOP — sever and reload agent tabs
      </button>
    </div>
  );
}
