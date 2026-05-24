#!/usr/bin/env python3
"""
Smoke probe — drive the playwright MCP server from a Python client.

Run:
  cd .spike/playwright-mcp && npm run build
  python3 tests/manual_probe.py

Speaks raw JSON-RPC over stdio (no MCP SDK dependency) so the test stays
hermetic — anyone with stdlib Python can run it. Walks the same path nullalis
(the Zig agent) walks: initialize -> tools/list -> tools/call(navigate) ->
tools/call(screenshot) -> exit.
"""

import json
import os
import subprocess
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVER_JS = HERE.parent / "dist" / "server.js"


def main() -> int:
    if not SERVER_JS.exists():
        print(f"ERR: {SERVER_JS} not found — run `npm run build` first", file=sys.stderr)
        return 1

    env = os.environ.copy()
    # Allow the public example.com hit. (Loopback isn't needed for this probe.)
    env.setdefault("PLAYWRIGHT_HEADLESS", "true")

    proc = subprocess.Popen(
        ["node", str(SERVER_JS)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        bufsize=0,
    )

    # Mirror stderr to our stderr so server logs are visible.
    def pump_stderr() -> None:
        assert proc.stderr is not None
        for line in iter(proc.stderr.readline, b""):
            sys.stderr.write("[server] " + line.decode(errors="replace"))

    threading.Thread(target=pump_stderr, daemon=True).start()

    def send(req: dict) -> dict:
        assert proc.stdin is not None and proc.stdout is not None
        proc.stdin.write((json.dumps(req) + "\n").encode())
        proc.stdin.flush()
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("server closed stdout unexpectedly")
        return json.loads(line)

    try:
        init = send({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "manual_probe", "version": "0.1.0"},
            },
        })
        print("initialize ->", json.dumps(init)[:200])
        assert "result" in init, init
        assert init["result"]["serverInfo"]["name"] == "nullalis-playwright-mcp"

        # MCP requires initialized notification before further requests
        proc.stdin.write((json.dumps({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        }) + "\n").encode())
        proc.stdin.flush()

        listed = send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = listed["result"]["tools"]
        print(f"tools/list -> {len(tools)} tools: {[t['name'] for t in tools]}")
        assert len(tools) >= 11, f"expected >= 11 tools, got {len(tools)}"

        nav = send({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "navigate", "arguments": {"url": "https://example.com/"}},
        })
        print("navigate ->", json.dumps(nav)[:300])
        body = json.loads(nav["result"]["content"][0]["text"])
        assert body.get("status") == 200, body
        assert "example" in body.get("title", "").lower(), body

        shot = send({
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": {"name": "screenshot", "arguments": {}},
        })
        body = json.loads(shot["result"]["content"][0]["text"])
        print(f"screenshot -> {body['bytes']} bytes PNG ({len(body['png_base64'])} b64 chars)")
        assert body["bytes"] > 100

        print("OK — manual probe passed")
        return 0
    finally:
        try:
            proc.stdin.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
