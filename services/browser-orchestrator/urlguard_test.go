package main

import "testing"

func TestURLGuard(t *testing.T) {
	cases := []struct {
		url  string
		ok   bool
		note string
	}{
		// Public URLs — must pass
		{"https://example.com", true, "public https"},
		{"http://example.com/path?q=1", true, "public http with path"},

		// Scheme deny
		{"file:///etc/passwd", false, "file:// scheme"},
		{"", false, "empty string"},

		// IPv4 loopback (127/8)
		{"http://127.0.0.1/", false, "IPv4 loopback"},

		// IPv4 RFC1918
		{"http://10.0.0.5/", false, "RFC1918 10/8"},
		{"http://192.168.1.1/", false, "RFC1918 192.168/16"},
		{"http://172.16.0.1/", false, "RFC1918 172.16/12"},

		// IPv4 link-local / metadata (169.254/16)
		{"http://169.254.169.254/latest/meta-data", false, "cloud metadata 169.254.169.254"},
		{"http://169.254.0.1/", false, "link-local non-metadata"},

		// IPv4 CGNAT (100.64/10, RFC 6598)
		{"http://100.64.0.1/", false, "CGNAT 100.64/10"},
		{"http://100.127.255.255/", false, "CGNAT top of range"},

		// IPv4 unspecified
		{"http://0.0.0.0/", false, "unspecified 0.0.0.0"},
		{"http://0/", false, "bare 0 (decimal-encoded 0.0.0.0)"},

		// DNS aliases
		{"http://localhost/", false, "localhost alias"},
		{"http://localhost./admin", false, "localhost. trailing-dot bypass"},
		{"http://foo.localhost/", false, "*.localhost wildcard"},
		{"http://metadata.google.internal/", false, "GCP metadata FQDN"},
		{"http://metadata.google.internal./computeMetadata/v1/", false, "GCP metadata trailing-dot bypass"},
		{"http://metadata/", false, "bare metadata alias"},

		// IPv6 loopback
		{"http://[::1]/", false, "IPv6 loopback ::1"},

		// IPv6 link-local (fe80::/10)
		{"http://[fe80::1]/", false, "IPv6 link-local fe80::1"},

		// IPv6 ULA (fc00::/7 — includes fd00::/8 AWS metadata aliases)
		{"http://[fd00::1]/", false, "IPv6 ULA fd00::1"},
		{"http://[fd00::ec2:254]/", false, "IPv6 ULA AWS metadata alias fd00::ec2:254"},
		{"http://[fd00:ec2::254]/", false, "IPv6 ULA AWS metadata alias fd00:ec2::254"},

		// IPv6 unspecified
		{"http://[::]/", false, "IPv6 unspecified ::"},

		// IPv4-mapped IPv6 — recurse through IPv4 classifier
		{"http://[::ffff:127.0.0.1]/", false, "IPv4-mapped loopback ::ffff:127.0.0.1"},
		{"http://[::ffff:169.254.169.254]/latest/meta-data/", false, "IPv4-mapped metadata ::ffff:169.254.169.254"},
		{"http://[::ffff:10.0.0.1]/", false, "IPv4-mapped RFC1918 ::ffff:10.0.0.1"},

		// Decimal / hex-encoded IPv4
		{"http://0x7f000001/", false, "hex-encoded 127.0.0.1"},
		{"http://2130706433/", false, "decimal-encoded 127.0.0.1"},

		// Non-canonical (inet_aton-style) dotted octal/hex/short-form IPv4
		{"http://127.1/", false, "short-form 127.1 → 127.0.0.1"},
		{"http://0x7f.0.0.1/", false, "hex octet 0x7f.0.0.1"},
		{"http://0x7f.1/", false, "hex short-form 0x7f.1"},
		{"http://127.000.000.001/", false, "octal-padded 127.000.000.001"},
		{"http://0x0.0x0.0x0.0x0/", false, "all-hex zero → 0.0.0.0"},
		{"http://0177.0.0.1/", false, "octal first octet 0177 → 127.0.0.1"},
		{"http://example.com@127.1/", false, "userinfo @ short-form loopback"},
		{"http://face.com/", true, "public hostname face.com"},
		{"http://1.2.3.4/", true, "public IPv4 1.2.3.4"},
	}
	for _, c := range cases {
		t.Run(c.note, func(t *testing.T) {
			if got := URLAllowed(c.url); got != c.ok {
				t.Errorf("URLAllowed(%q) = %v, want %v", c.url, got, c.ok)
			}
		})
	}
}
