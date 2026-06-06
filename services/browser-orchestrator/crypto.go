package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"

	"golang.org/x/crypto/hkdf"
)

// DeriveUserKey returns a per-user 32-byte key (hex-encoded, 64 chars) derived
// from the master key with the user id as salt. One key never decrypts another
// user's vault (spec §8.5). The hex string is passed to the worker pod as
// AGENT_BROWSER_ENCRYPTION_KEY so agent-browser encrypts/decrypts its --state vault.
func DeriveUserKey(master []byte, userID string) string {
	h := hkdf.New(sha256.New, master, []byte(userID), []byte("agent-browser-state-v1"))
	out := make([]byte, 32)
	_, _ = io.ReadFull(h, out)
	return hex.EncodeToString(out)
}
