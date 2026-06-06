package main

import "strings"

// navigationVerbs are agent-browser subcommands that accept a URL as their
// first positional argument. The URL guard runs only on these verbs so
// non-navigation commands (snapshot, click, …) are unaffected.
var navigationVerbs = map[string]bool{
	"open": true, "goto": true, "navigate": true, "reload": true,
}

// navigationTarget returns the URL/host argument of a navigation verb, walking
// flags exactly like ExecAllowed so a flag between the verb and the target can't
// hide it. ok=false when the args are not a navigation command.
//
// The target is returned UNCONDITIONALLY (no ://-prefix requirement): scheme-less
// args like "localhost:8080" must reach URLAllowed, which fails closed on them.
func navigationTarget(args []string) (string, bool) {
	i := 0
	for i < len(args) {
		a := args[i]
		if len(a) > 0 && a[0] == '-' {
			if eq := strings.IndexByte(a, '='); eq >= 0 {
				i++
				continue
			}
			if valueFlags[a] {
				i += 2
				continue
			}
			i++ // boolFlags or unknown (ExecAllowed already vetted)
			continue
		}
		// a is the verb
		if !navigationVerbs[a] {
			return "", false
		}
		// next non-flag token is the target
		j := i + 1
		for j < len(args) {
			t := args[j]
			if len(t) > 0 && t[0] == '-' {
				if eq := strings.IndexByte(t, '='); eq >= 0 {
					j++
					continue
				}
				if valueFlags[t] {
					j += 2
					continue
				}
				j++
				continue
			}
			return t, true
		}
		return "", false // verb with no target
	}
	return "", false
}

// allowedSubcommands: deny-by-default agent-browser verbs the exec endpoint may run (spec §8.6).
var allowedSubcommands = map[string]bool{
	"open": true, "goto": true, "navigate": true, "back": true, "forward": true, "reload": true,
	"click": true, "dblclick": true, "type": true, "fill": true, "press": true, "hover": true,
	"focus": true, "check": true, "uncheck": true, "select": true, "scroll": true,
	"snapshot": true, "screenshot": true, "get": true, "is": true, "find": true, "wait": true,
	"state": true, "close": true,
}

// valueFlags consume the following token as their value. Dangerous flags
// (--proxy/--headers/--executable-path/--cdp/--profile/--session) are NOT here:
// they enable exfiltration/override of a logged-in session via browser_exec.
var valueFlags = map[string]bool{
	"--timeout": true,
}

// boolFlags consume only themselves.
var boolFlags = map[string]bool{
	"--json": true, "--full-page": true, "--hide-scrollbars": true,
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
