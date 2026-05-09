# F-G1 — Zig stdlib TLS SIGILL on Apple Silicon

**Status:** workaround shipped (V1.14.4 + V1.14.5 F-G1.5); upstream issue pending file
**Severity:** CRITICAL for any Zig 0.15.2 program doing TLS handshakes with certain CA chains on M-series Macs
**Affected:** Zig 0.15.2, macOS 15.6.1 (24G90) on Apple Silicon (M1/M2/M3 — M3 verified at Mac15,14)
**Workaround in nullalis:** `NULLALIS_FORCE_CURL_STREAM=0/1` env var; auto-default to `1` on `macos+aarch64` since V1.14.5

---

## Symptom

`nullalis gateway` boots cleanly and responds to /health probes. The first chat request to a `https://api.together.xyz/v1/chat/completions` SSE endpoint causes the gateway process to **die silently** — no panic in stderr, no abort signal, no log output past `provider_reliable: stream.attempt`.

The Python adapter sees `requests` raise:
```
ChunkedEncodingError: Response ended prematurely
```
Followed on the next attempt by:
```
NewConnectionError: Connection refused
```

## What actually happened

macOS captured the truth in `~/Library/Logs/DiagnosticReports/nullalis-<ts>.ips`:

```
exception: {"codes":"0x0000000000000000, 0x0000000000000000",
            "rawCodes":[0,0],
            "type":"EXC_CRASH",
            "signal":"SIGILL"}
ESR: "Address size fault"
```

Triggered thread (`queue=None`, `triggered=false` per Apple's reporter ambiguity but unambiguous from frame chain):
```
crypto.pcurves.p256.P256.add
crypto.pcurves.p256.P256.pcMul16__anon_373264
crypto.pcurves.p256.P256.mulPublic
crypto.ecdsa.Ecdsa(crypto.pcurves.p256.P256, crypto.sha2.Sha2x32(...)).Verifier.verifyPrehashed
crypto.ecdsa.Ecdsa(crypto.pcurves.p256.P256, crypto.sha2.Sha2x32(...)).Verifier.verify
crypto.tls.Client.CertificatePublicKey.verifySignature
crypto.tls.Client.init
http_native.root.TlsIoState.init
http_native.root.stream_tls_body__anon_578570
http_native.root.root_stream_body__anon_219368
http_native.root.stream_body__anon_198182
providers.sse.native_stream
providers.sse.curlStream
providers.compatible.OpenAiCompatibleProvider.streamChatImpl
providers.root.Provider.streamChat
providers.reliable.ReliableProvider.tryStreamProvider
providers.reliable.ReliableProvider.streamChatImpl
```

The crash fires inside Zig stdlib's elliptic-curve point arithmetic during ECDSA signature verification of the server certificate chain — specifically the `P256.add` routine called by `pcMul16` (16-window scalar multiplication) inside `mulPublic` (the public-key signature-check entry point).

## Why "silent death"

`SIGILL` immediately terminates the process — no Zig `@panic` formatter runs, no stack trace gets printed to stderr. Our `provider_reliable.zig` retry layer's `catch → curl_stream_fallback` never fires because there's no error to catch — the process is already dead.

The gateway parent looks like it just stopped. In a daemonized deploy this would manifest as "the gateway disappeared after the first user message."

## Reproducibility

- **3 of 3 attempts** crashed at the same point on M3 (Mac15,14, macOS 15.6.1)
- Trigger does NOT depend on request body size (40K-token context AND ~50-byte "ping" body both crash equally)
- Trigger does NOT depend on the gateway's prior state (fresh boot, never-seen tenant: same crash on first chat)
- Trigger DOES depend on the server cert chain — Together's K2.6 endpoint at `api.together.xyz` is the verified reproducer; other endpoints (Anthropic, OpenAI, Together's non-K2.6 endpoints) untested but presumed similar since the failing code path is generic ECDSA-over-P256

## Likely root cause hypotheses

The `pcMul16` routine is a hand-tuned 16-window scalar multiplication using a precomputed table of point multiples. Hypotheses, in descending plausibility:

1. **Apple Silicon-specific arithmetic bug** in Zig stdlib's P256 implementation. ARMv8 has different vector / pointer-arithmetic semantics than x86_64. The `Address size fault` ESR strongly suggests a pointer arithmetic issue (computing an address that doesn't fit in 64 bits or violates alignment).
2. **Stack overflow in deep curve arithmetic** — `pcMul16` allocates large temporaries on stack; Zig's default thread stack on macOS may be smaller than what the routine requires.
3. **Optimization-induced UB** — ReleaseFast eliminates safety checks, and undefined-behavior bug in the elliptic-curve code only manifests on aggressive optimization. Worth testing under `-Doptimize=ReleaseSafe` to confirm.
4. **Compiler codegen bug** — Zig's LLVM backend on ARM64 generated invalid instructions for one of the curve primitives.

Hypothesis 1 is favored because the failure is platform-specific and consistently in the same routine.

## Workaround (shipped)

`NULLALIS_FORCE_CURL_STREAM` env var, set to `1` to bypass the native TLS path and route through `curl` subprocess (uses Apple's LibreSSL). Set to `0` on macOS arm64 to opt OUT of the auto-default.

V1.14.4 (commit `f6299d4`): env var added.
V1.14.5 F-G1.5 (commit `3a9054f`): platform-aware auto-default — macOS arm64 defaults to TRUE, Linux + macOS x86_64 default to FALSE. Boot banner logs which path is active.

Cost: ~5-10ms extra per request for `fork+exec`. Negligible vs LLM roundtrips (100-30000ms).

## Reproducer for upstream

The minimum self-contained reproducer is non-trivial in Zig 0.15.2 because `std.crypto.tls.Client.init` requires Reader+Writer+Options with read/write buffers (see `nullalis/src/http_native/root.zig:49-59` for our shape). Easiest path is to clone nullalis and run its gateway:

```bash
# On Apple Silicon:
git clone https://github.com/ProjectNuggets/NULL-ALIS.git nullalis
cd nullalis
zig build -Doptimize=ReleaseFast
./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000 &
# Send any chat to Together via the gateway:
curl -sN -X POST -H "X-Internal-Token: <see config>" -H "X-Zaki-User-Id: 1" \
  -H "Content-Type: application/json" \
  -d '{"message":"ping","session_key":"agent:zaki-bot:user:1:main"}' \
  http://127.0.0.1:3000/api/v1/chat/stream
# Gateway dies; check ~/Library/Logs/DiagnosticReports/nullalis-*.ips
```

For a minimal pure-Zig reproducer, the structure would be:

```zig
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stream = try std.net.tcpConnectToHost(allocator, "api.together.xyz", 443);
    defer stream.close();

    var ca_bundle = std.crypto.Certificate.Bundle{};
    defer ca_bundle.deinit(allocator);
    try ca_bundle.rescan(allocator);

    // Set up Reader + Writer per Client.init signature
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(&[_]u8{});
    var stream_writer = stream.writer(&[_]u8{});

    // SIGILL fires inside this on Apple Silicon
    var tls_client = try std.crypto.tls.Client.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = "api.together.xyz" },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = &read_buf,
            .write_buffer = &write_buf,
            .allow_truncation_attacks = true,
        },
    );
    _ = &tls_client;
}
```

(Untested standalone — nullalis's `http_native/root.zig` is the verified reproducer.)

## Upstream issue draft

**Title:** SIGILL in `std.crypto.pcurves.p256.P256.add` during ECDSA verification on Apple Silicon

**Body skeleton:**
- Zig version: 0.15.2 (homebrew, /opt/homebrew/Cellar/zig/0.15.2/bin/zig)
- macOS: 15.6.1 (24G90), Mac15,14 (M3)
- Build mode: ReleaseFast
- Trigger: TLS handshake against api.together.xyz:443
- Crash: `EXC_CRASH/SIGILL`, ESR `0x56000000` "Address size fault"
- Frame chain: pcurves.p256.P256.add → pcMul16 → mulPublic → ecdsa.Verifier.verifyPrehashed → tls.Client.init
- Reproducer: nullalis gateway (link to repo + commit hash 3a9054f)
- Workaround in nullalis: route through curl subprocess (Apple LibreSSL works fine)
- Crash report: attach `~/Library/Logs/DiagnosticReports/nullalis-2026-05-09-123800.ips` excerpt
- Question: is this a known issue? Is there a hand-tuned ARM64 P256 implementation in plan?

**File at:** https://github.com/ziglang/zig/issues

## Removal criteria for the workaround

Remove `forceCurlStreamPath()` auto-default and the env var when ALL of:
1. Upstream Zig issue is closed with a confirmed fix
2. We've upgraded to a Zig release containing the fix
3. Manual verification on M-series hardware shows the gateway can run a chat WITHOUT `NULLALIS_FORCE_CURL_STREAM=0` set

Until then: ship as-is. The curl path is faster than the bug.

## Related

- Commit `f6299d4`: F-G1 initial fix (env var)
- Commit `3a9054f`: F-G1.5 platform-aware auto-default + boot banner
- Crash reports: `~/Library/Logs/DiagnosticReports/nullalis-2026-05-09-122556.ips`,
  `nullalis-2026-05-09-122733.ips`, `nullalis-2026-05-09-123800.ips`
- nullalis V1.14.4 booth-readiness sprint that surfaced the bug:
  `docs/REVIEW-v1.14.4-2026-05-09.md`
