package main

import "testing"

func TestURLGuard(t *testing.T) {
	cases := []struct {
		url string
		ok  bool
	}{
		{"https://example.com", true},
		{"http://example.com/path?q=1", true},
		{"http://169.254.169.254/latest/meta-data", false},
		{"http://127.0.0.1/", false},
		{"http://localhost/", false},
		{"http://10.0.0.5/", false},
		{"http://192.168.1.1/", false},
		{"http://172.16.0.1/", false},
		{"http://[::1]/", false},
		{"http://[fd00::1]/", false},
		{"http://0x7f000001/", false},
		{"http://2130706433/", false},
		{"file:///etc/passwd", false},
		{"http://metadata.google.internal/", false},
		{"", false},
	}
	for _, c := range cases {
		if got := URLAllowed(c.url); got != c.ok {
			t.Errorf("URLAllowed(%q) = %v, want %v", c.url, got, c.ok)
		}
	}
}
