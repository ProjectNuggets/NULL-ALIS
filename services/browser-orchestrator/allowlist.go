package main

import "strings"

// allowedSubcommands: deny-by-default agent-browser verbs the exec endpoint may run (spec §8.6).
var allowedSubcommands = map[string]bool{
	"open": true, "goto": true, "navigate": true, "back": true, "forward": true, "reload": true,
	"click": true, "dblclick": true, "type": true, "fill": true, "press": true, "hover": true,
	"focus": true, "check": true, "uncheck": true, "select": true, "scroll": true,
	"snapshot": true, "screenshot": true, "get": true, "is": true, "find": true, "wait": true,
	"state": true, "close": true,
}

// valueFlags consume the following token as their value.
var valueFlags = map[string]bool{
	"--executable-path": true, "--state": true, "--timeout": true, "--engine": true,
	"--proxy": true, "--headers": true, "--session": true, "--session-name": true,
	"--profile": true, "--cdp": true,
}

// boolFlags consume only themselves.
var boolFlags = map[string]bool{
	"--headed": true, "--json": true, "--auto-connect": true, "--hide-scrollbars": true,
	"--no-sandbox": true, "--full-page": true,
}

// ExecAllowed reports whether the agent-browser invocation is permitted. Fail-closed:
// unknown flags are rejected; value-taking flags always consume their value (so a value
// can never masquerade as the verb); the first non-flag token must be allowlisted.
func ExecAllowed(args []string) bool {
	i := 0
	for i < len(args) {
		a := args[i]
		if len(a) > 0 && a[0] == '-' {
			if eq := strings.IndexByte(a, '='); eq >= 0 { // --flag=value
				name := a[:eq]
				if !valueFlags[name] && !boolFlags[name] {
					return false // unknown flag
				}
				i++
				continue
			}
			if valueFlags[a] {
				i += 2 // skip flag + its value
				continue
			}
			if boolFlags[a] {
				i++
				continue
			}
			return false // unknown flag → fail closed
		}
		// first non-flag token is the verb
		if !allowedSubcommands[a] {
			return false
		}
		if a == "get" && i+1 < len(args) && args[i+1] == "cdp-url" {
			return false // A5: deny DevTools endpoint disclosure
		}
		return true
	}
	return false
}
