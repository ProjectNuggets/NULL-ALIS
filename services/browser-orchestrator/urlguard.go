package main

import (
	"net/netip"
	"net/url"
	"strconv"
	"strings"
)

// URLAllowed returns true if raw is a safe public URL that the orchestrator
// may navigate to. It mirrors the deny classes in src/extension_ws/url_sanitize.zig:
//
//   - Scheme: only http/https accepted.
//   - Host aliases: localhost, *.localhost, metadata, metadata.google.internal (case-insensitive).
//   - IPv4 loopback (127/8), RFC1918 (10/8, 172.16/12, 192.168/16),
//     link-local (169.254/16), CGNAT (100.64/10), unspecified (0.0.0.0).
//   - IPv6 loopback (::1), link-local (fe80::/10), ULA (fc00::/7),
//     unspecified (::), link-local multicast.
//   - IPv4-mapped IPv6 (::ffff:...) — recursed through IPv4 classifier via Unmap().
//   - Decimal-encoded IPv4 (2130706433) and hex-encoded (0x7f000001).
//   - A normal public hostname (not an alias, not an IP) is allowed.
func URLAllowed(raw string) bool {
	if raw == "" {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return false
	}
	if u.Host == "" {
		return false
	}

	// Strip port and IPv6 brackets to get the bare hostname.
	host := u.Hostname() // net/url already strips port and brackets
	if host == "" {
		return false
	}

	// Normalize: lowercase, strip trailing dot.
	host = strings.ToLower(host)
	host = strings.TrimSuffix(host, ".")
	if host == "" {
		return false
	}

	// Reject known DNS aliases before trying numeric parsing.
	if isBlockedAlias(host) {
		return false
	}

	// Try to parse as an IP address (handles IPv4 dotted, IPv6 literals).
	if addr, err := netip.ParseAddr(host); err == nil {
		return !isBlockedIP(addr)
	}

	// Try decimal / hex / octal-encoded IPv4 (e.g. 2130706433, 0x7f000001).
	// strconv.ParseUint(s, 0, 64) accepts 0x prefix (hex) and plain decimal.
	// We only attempt this if the string looks like a number or 0x-prefixed hex.
	if looksNumeric(host) {
		n, err := strconv.ParseUint(host, 0, 64)
		if err == nil && n <= 0xFFFFFFFF {
			// Convert to 4-octet IPv4 and re-check via netip.
			ip4 := netip.AddrFrom4([4]byte{
				byte(n >> 24),
				byte(n >> 16),
				byte(n >> 8),
				byte(n),
			})
			return !isBlockedIP(ip4)
		}
		// If it looks numeric but doesn't parse, fail closed.
		return false
	}

	// Catch non-canonical (inet_aton-style) IPv4: dotted octal/hex/short forms
	// like 127.1, 0x7f.0.0.1, 127.000.000.001 that getaddrinfo/Chrome resolve to
	// loopback/0.0.0.0 but netip.ParseAddr rejects. A real DNS hostname (e.g.
	// example.com) makes parseLegacyIPv4 return ok=false → falls through to the
	// public-hostname allow.
	if a, ok := parseLegacyIPv4(host); ok {
		return !isBlockedIP(a)
	}

	// Normal public hostname — allowed. DNS rebinding is out of scope;
	// the pod NetworkPolicy is the enforced backstop.
	return true
}

// parseLegacyIPv4 mirrors getaddrinfo/inet_aton: 1-4 dot-separated parts, each
// decimal / octal(0 prefix) / hex(0x prefix); short forms fill the low octets.
// Returns ok=false when the host is NOT a fully-numeric form (→ treat as a DNS
// hostname). This catches 127.1, 0x7f.0.0.1, 127.000.000.001, etc.
func parseLegacyIPv4(host string) (netip.Addr, bool) {
	parts := strings.Split(host, ".")
	if len(parts) == 0 || len(parts) > 4 {
		return netip.Addr{}, false
	}
	nums := make([]uint64, 0, 4)
	for _, p := range parts {
		if p == "" {
			return netip.Addr{}, false
		}
		n, err := strconv.ParseUint(p, 0, 64) // base 0: 0x→hex, 0→octal, else decimal
		if err != nil {
			return netip.Addr{}, false
		}
		nums = append(nums, n)
	}
	var v uint64
	switch len(nums) {
	case 1:
		v = nums[0]
	case 2:
		if nums[0] > 0xff || nums[1] > 0xffffff {
			return netip.Addr{}, false
		}
		v = nums[0]<<24 | nums[1]
	case 3:
		if nums[0] > 0xff || nums[1] > 0xff || nums[2] > 0xffff {
			return netip.Addr{}, false
		}
		v = nums[0]<<24 | nums[1]<<16 | nums[2]
	case 4:
		for _, n := range nums {
			if n > 0xff {
				return netip.Addr{}, false
			}
		}
		v = nums[0]<<24 | nums[1]<<16 | nums[2]<<8 | nums[3]
	}
	if v > 0xffffffff {
		return netip.Addr{}, false
	}
	return netip.AddrFrom4([4]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)}), true
}

// isBlockedAlias returns true for hostname aliases known to resolve to
// loopback or cloud-metadata endpoints.
func isBlockedAlias(host string) bool {
	switch host {
	case "localhost", "metadata", "metadata.google.internal":
		return true
	}
	// *.localhost
	if strings.HasSuffix(host, ".localhost") {
		return true
	}
	return false
}

// looksNumeric returns true if the string could be a decimal or 0x-prefixed
// hex encoding of an IPv4 address (and therefore needs numeric parsing).
func looksNumeric(s string) bool {
	if len(s) == 0 {
		return false
	}
	// 0x… hex prefix
	if len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		for _, c := range s[2:] {
			if !isHexDigit(c) {
				return false
			}
		}
		return true
	}
	// Plain decimal (all digits)
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func isHexDigit(c rune) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// isBlockedIP returns true if addr is in a blocked range (loopback, private,
// link-local, metadata, CGNAT, unspecified, ULA, multicast).
func isBlockedIP(addr netip.Addr) bool {
	// Unmap IPv4-mapped IPv6 (::ffff:x.x.x.x) so the IPv4 rules apply.
	addr = addr.Unmap()

	if addr.IsLoopback() {
		return true
	}
	if addr.IsUnspecified() {
		return true
	}
	// IsPrivate covers RFC1918 (10/8, 172.16/12, 192.168/16) and
	// IPv6 ULA (fc00::/7) per Go 1.17+.
	if addr.IsPrivate() {
		return true
	}
	if addr.IsLinkLocalUnicast() {
		return true
	}
	if addr.IsLinkLocalMulticast() {
		return true
	}
	if addr.IsMulticast() {
		return true
	}

	// CGNAT 100.64.0.0/10 (RFC6598) — not covered by IsPrivate in Go stdlib.
	cgnat := netip.MustParsePrefix("100.64.0.0/10")
	if cgnat.Contains(addr) {
		return true
	}

	// 169.254.0.0/16 link-local / metadata — also covered by IsLinkLocalUnicast
	// for IPv4 in Go, but be explicit for clarity and belt-and-suspenders.
	linkLocal4 := netip.MustParsePrefix("169.254.0.0/16")
	if linkLocal4.Contains(addr) {
		return true
	}

	// IPv6 ULA fc00::/7 — covered by IsPrivate in Go 1.17+, but be explicit
	// for the fd00::1 test case (Go's IsPrivate uses fc00::/7 per RFC4193).
	// No-op if IsPrivate already caught it; here for documentation.

	return false
}
