---
tags: [prose, prose/docs, prose/security]
authored: 2026-06-06
status: CANONICAL — single authoritative SSRF deny-class spec for all sanitizers in this repo.
---

# SSRF block-list — canonical deny classes

**Single source of truth.** Both the extension-lane sanitizer
(`src/extension_ws/url_sanitize.zig`) and the in-cluster orchestrator-lane
sanitizer (`services/browser-orchestrator/urlguard.go`) implement these
deny classes. **Any change here MUST update both sanitizers and their parity
tests** (`url_sanitize` tests in `src/extension_ws/url_sanitize.zig` and
`TestURLGuard` in `services/browser-orchestrator/urlguard_test.go`).

The pod NetworkPolicy (`deploy/k8s/browser/networkpolicy.yaml`) is the
enforced backstop at the network layer; these sanitizers are upfront
defense-in-depth at the application layer.

---

## Deny classes

### 1. Non-HTTP(S) scheme

Only `http://` and `https://` are accepted. All other schemes are rejected
with `scheme_blocked`:

- `file://` — local filesystem read
- `javascript:` — code injection
- `chrome://` — browser internals
- `data:` — inline content bypass
- `ftp://`, `wss://`, etc. — any non-http(s) scheme

### 2. IPv4 loopback — 127.0.0.0/8

All 127.x.x.x addresses (`127.0.0.1` through `127.255.255.255`). RFC 5735.

### 3. IPv4 RFC1918 private ranges

- `10.0.0.0/8` — class A private
- `172.16.0.0/12` — class B private (172.16.x.x – 172.31.x.x)
- `192.168.0.0/16` — class C private

### 4. Link-local and cloud metadata — 169.254.0.0/16

All 169.254.x.x addresses, including the canonical AWS/GCP/Azure metadata
endpoint `169.254.169.254`. Reason code: `link_local_blocked` (or
`metadata_endpoint_blocked` for 169.254.169.254 specifically, for
operational clarity).

### 5. CGNAT — 100.64.0.0/10 (RFC 6598)

Carrier-grade NAT range. Not covered by RFC1918 but similarly non-public.

### 6. IPv4 unspecified — 0.0.0.0/8

Addresses beginning with 0 (including `0.0.0.0` and decimal-encoded `0`).
Routes to local interfaces on most kernels.

### 7. IPv6 loopback — ::1

The single IPv6 loopback address.

### 8. IPv6 link-local — fe80::/10

All link-local unicast addresses (fe80:: through febf::).

### 9. IPv6 unique-local (ULA) — fc00::/7

Covers fc00::/8 and fd00::/8, including AWS IPv6 metadata aliases
`fd00::ec2:254` and `fd00:ec2::254`.

### 10. IPv6 unspecified — ::

The all-zeros IPv6 address.

### 11. IPv6 link-local multicast — ff02::/16

Link-local multicast (and all multicast — ff00::/8 generally).

### 12. IPv4-mapped IPv6

`::ffff:X.X.X.X` form. The mapped IPv4 address is extracted and re-classified
through the IPv4 deny classes above. Examples:

- `::ffff:127.0.0.1` → loopback (blocked)
- `::ffff:169.254.169.254` → link-local / metadata (blocked)
- `::ffff:10.0.0.1` → RFC1918 (blocked)

### 13. Decimal- and hex-encoded IPv4

Numeric or hex-prefixed host fields that encode an IPv4 address without
dotted notation. Both sanitizers decode and re-classify:

- Decimal: `http://2130706433/` → 127.0.0.1 (blocked)
- Hex: `http://0x7f000001/` → 127.0.0.1 (blocked)
- Bare `0`: `http://0/` → 0.0.0.0 (blocked)

Dotted `inet_aton(3)`-style forms — octal, hex, and short (1–3 part)
host fields — are likewise decoded the way the OS resolver
(`getaddrinfo`/`inet_aton`) does, then re-classified by both sanitizers.
A host that is not fully numeric (e.g. `example.com`, `face.com`) stays a
hostname.

- Short form: `http://127.1/` → 127.0.0.1 (blocked)
- Hex octet: `http://0x7f.0.0.1/` → 127.0.0.1 (blocked)
- Hex + short: `http://0x7f.1/` → 127.0.0.1 (blocked)
- Octal-looking zero octets: `http://127.000.000.001/` → 127.0.0.1 (blocked)
- Octal first octet: `http://0177.0.0.1/` → 127.0.0.1 (blocked)
- All-hex: `http://0x0.0x0.0x0.0x0/` → 0.0.0.0 (blocked)

### 14. Host aliases

DNS names known to resolve to blocked ranges:

- `localhost` — loopback
- `*.localhost` — e.g., `foo.localhost`, `bar.localhost`
- `metadata` — GCP metadata shortname
- `metadata.google.internal` — GCP metadata FQDN
- Trailing-dot variants (e.g., `localhost.`, `metadata.google.internal.`) —
  DNS strips the trailing dot before lookup, so the deny check normalizes
  and matches the bare form

---

## Operator allowlist (escape hatch)

Both sanitizers support an operator-controlled allowlist that lets a hostname
bypass the deny check:

- Extension lane: `GatewayConfig.extension_browser_allowlist` (array of
  hostnames in `config.json`).
- Orchestrator lane: `BROWSER_ORCHESTRATOR_ALLOWLIST` environment variable
  (comma-separated). Not wired for orchestrator in V1 — the pod NetworkPolicy
  serves as the egress control.

The allowlist does NOT bypass the scheme check. `file://` is always rejected.

---

## Parity tests

Tests covering every deny class above must exist in both:

- `src/extension_ws/url_sanitize.zig` (Zig `test` blocks — run via `zig build test`)
- `services/browser-orchestrator/urlguard_test.go` (`TestURLGuard` — run via
  `GOTOOLCHAIN=local go test ./... -run TestURLGuard`)

---

## Relationship to the pod NetworkPolicy

`deploy/k8s/browser/networkpolicy.yaml` locks egress at the Kubernetes
network layer — worker pods cannot reach RFC1918 or metadata endpoints
even if a sanitizer bug lets a URL through. The sanitizers are the
**upfront defense-in-depth** layer that provides:

1. A fast, logged rejection before a network packet is sent.
2. A machine-readable rejection reason surfaced to the agent/operator.
3. Defense against classes the NetworkPolicy cannot cover (e.g., DNS
   rebinding — a public hostname that resolves to a private IP at
   connection time; mitigated here by alias checks and supplemented by
   `connect(2)`-level blocking from the NetworkPolicy egress rules).
