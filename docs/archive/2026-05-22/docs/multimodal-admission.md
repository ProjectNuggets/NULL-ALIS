---
tags: [prose, prose/docs]
---

# V1 Multimodal Admission Matrix (W2.7)

Status: binding verdicts. W2.7 is strictly an **admission gate**, not a build project.
Date: 2026-04-18

## Admission rule

A multimodal path is admitted to V1 only if **all** are true:
1. End-to-end today (inbound → context → memory → outbound), or reachable via minimal wiring without a new subsystem.
2. Attributable (source visible on stored memory).
3. Serves the second-brain loop (capture / remember / recall / reflect / act / trace).
4. No new product pane or provider family required.

If any condition fails → **Freeze** (code stays, flag-off or dead-path, not advertised).

## Verdicts

| Path | Verdict | Rationale |
|---|---|---|
| **Voice input (STT) — Telegram voice messages** | **Admit** | [src/voice.zig](../src/voice.zig) `transcribeTelegramVoice` (~line 691) is end-to-end wired to Telegram ingress, Whisper-compatible backend, file-based pipeline. No new subsystem needed. Attribution: the inbound message includes channel+lane. Serves capture. |
| **Voice input (STT) — web app / app.chatzaki.com** | **Freeze (admit later)** | No evidence of web-app STT wiring in nullalis. Implementation would require new frontend audio upload endpoint + BFF route. That's a new subsystem by any definition. Defer to post-V1 multimodal package. |
| **TTS output — Telegram** | **Admit** | [src/voice.zig](../src/voice.zig) `synthesizeTextToTempAudio` and `tts_prepare` stage visible in Nova's live runtime logs (2026-04-17 turn profile). End-to-end. Gated by `voice_replies` preset. No new work. |
| **TTS output — web app** | **Freeze (admit later)** | Same reason as web STT: frontend playback path not visible in nullalis scope. Defer. |
| **Image input + image understanding** | **Admit** | [src/multimodal.zig](../src/multimodal.zig) provides `parseImageMarkers`, `readLocalImage`, `prepareMessagesForProvider`, base64 encoding. LLM providers (Anthropic, OpenAI, Google) already receive image messages when markers are present. Attribution flows via provenance metadata on stored content. No new subsystem. |
| **Image-based context ingestion (screenshots uploaded, diagrams pasted, photos attached)** | **Admit** | Same pipeline as image input. Served by [src/multimodal.zig](../src/multimodal.zig). Image markers in memory content are already parseable. |
| **Image generation — narrow user-triggered** | **Freeze** | No existing user-triggered generation tool. Adding it requires: (a) provider family selection (DALL-E, Stable Diffusion, etc.) — a new provider family, rule 2 violation; (b) a tool that would appear in the LLM catalog as "generate image" without the narrow scope safeguards. Defer until the narrow contract is designed. |
| **Image generation — proactive / background** | **Freeze** | Out-of-scope per binding plan. No admission possible under V1 rules. |
| **Screenshot tool (`tools/screenshot.zig`)** | **Freeze** | Captures the runtime's local screen via `screencapture` (macOS) / `import` (Linux). Under per-pod k8s deployment the "local screen" is an empty headless pod — the tool cannot produce user-relevant content. The second-brain loop is served by user-uploaded images, not pod-side capture. Remove from V1 tool registry behind `-Dv1`. |
| **Image info tool (`tools/image.zig:ImageInfoTool`)** | **Admit** | Read-only metadata extraction (format, dimensions). Supports attribution on user-uploaded images. Not a generation path. Trivially small (400 LoC). |
| **Voice mode state (`src/voice_mode.zig`)** | **Admit** | 148 LoC thin wrapper for the admitted TTS path. Follows voice.zig's admission. |

## Summary

**Admitted to V1 (default-on in `-Dv1=true` builds):**
- Telegram STT (inbound)
- Telegram TTS (outbound)
- Image input + image understanding
- Image-based context ingestion
- `image_info` tool (read-only metadata)
- Voice mode state

**Frozen (defer to post-V1 or narrow targeted package):**
- Web-app STT
- Web-app TTS
- Image generation (all forms)
- `screenshot` tool

## What W2.7 did NOT do

- No new subsystems built.
- No new provider families wired.
- No new product panes designed.
- No admitted path got new features — only kept as-is.
- No admission raised to W3.x UI work; UI-side multimodal polish is a Wave 3 concern driven by this matrix.

## Next-step feeds

- **W3.1 (thread pane)**: admitted voice/image paths render in the thread with provenance. Frozen paths absent.
- **W3.2 (memory pane)**: image-sourced memories render with their source image reference.
- **Follow-up — screenshot tool removal under `-Dv1=true`**: add to the broader subsystem-gating follow-up list (currently open from W1.5).
- **Follow-up — web-app STT/TTS**: post-V1 multimodal package; requires frontend + BFF work plus a new endpoint. Do not attempt inside V1.
