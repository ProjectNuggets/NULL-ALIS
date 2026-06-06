package main

import "testing"

func TestAllowlist(t *testing.T) {
	cases := []struct {
		args []string
		ok   bool
	}{
		{[]string{"open", "https://example.com"}, true},
		{[]string{"snapshot"}, true},
		{[]string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://x"}, true},
		{[]string{"--executable-path", "/usr/local/bin/chromium-ns", "--state", "/p.enc", "open", "https://x"}, true},
		{[]string{"click", "@e1"}, true},
		{[]string{"get", "text", "body"}, true},
		// bypass vectors that MUST be denied:
		{[]string{"--executable-path", "open", "eval", "x"}, false},
		{[]string{"--flag", "snapshot", "connect"}, false}, // unknown flag --flag
		{[]string{"eval", "fetch('/x')"}, false},
		{[]string{"connect", "9222"}, false},
		{[]string{"get", "cdp-url"}, false},
		{[]string{}, false},
	}
	for _, c := range cases {
		if got := ExecAllowed(c.args); got != c.ok {
			t.Errorf("ExecAllowed(%v) = %v, want %v", c.args, got, c.ok)
		}
	}
}
