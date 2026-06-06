package main

// allowedSubcommands is the deny-by-default set of agent-browser verbs the exec
// endpoint may run (spec §8.6). eval/run-code/connect/cdp and anything not listed
// are rejected. Leading flags (e.g. --executable-path X) are skipped to find the verb.
var allowedSubcommands = map[string]bool{
	"open": true, "goto": true, "navigate": true, "back": true, "forward": true, "reload": true,
	"click": true, "dblclick": true, "type": true, "fill": true, "press": true, "hover": true,
	"focus": true, "check": true, "uncheck": true, "select": true, "scroll": true,
	"snapshot": true, "screenshot": true, "get": true, "is": true, "find": true, "wait": true,
	"state": true, "close": true,
}

// ExecAllowed reports whether the agent-browser invocation's verb is allowlisted.
func ExecAllowed(args []string) bool {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if len(a) > 0 && a[0] == '-' {
			if i+1 < len(args) && (len(args[i+1]) == 0 || args[i+1][0] != '-') && !allowedSubcommands[args[i+1]] {
				i++
			}
			continue
		}
		return allowedSubcommands[a]
	}
	return false
}
