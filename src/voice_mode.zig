//! Voice-first agent mode — cross-channel audio support and voice-specific narration.
//!
//! **Metadata-only module (S6.7).** This file declares capability descriptors,
//! channel-to-capability maps, and narration mode selectors. It does NOT process
//! audio, spawn processes, or hold runtime state. Actual STT/TTS work lives in
//! `voice.zig` (WhisperTranscriber + synthesizeTextToTempAudio).
//!
//! Read this file to answer: "does channel X advertise audio input/output, and
//! what narration mode should that imply?" — and nothing else.
//!
//! ⚠️ Capability flags advertise intent, not working wire paths. Today only
//! Telegram has a functioning audio-send path; `voice_mode.zig` declaring
//! discord/whatsapp/slack as TTS-capable is a historical aspiration (tracked
//! as W4.5 / Sprint 7 — wire or revoke). Don't lean on this module for a
//! runtime check; call into `voice.zig` to find out if a send actually works.

const std = @import("std");
const voice = @import("voice.zig");
const observability = @import("observability.zig");

/// Per-channel audio capability descriptor.
pub const VoiceCapability = struct {
    stt: bool, // channel can receive audio input
    tts: bool, // channel can deliver audio output
};

/// Returns true if the given channel supports any audio capability (STT or TTS).
/// Replaces the hardcoded telegram-only check in agent/root.zig.
pub fn channelSupportsAudio(channel: []const u8) bool {
    const cap = resolveCapability(channel);
    return cap.stt or cap.tts;
}

/// Resolve audio capabilities for a named channel.
/// Known audio-capable channels: telegram, discord, whatsapp, slack.
/// Unknown channels default to no audio support.
pub fn resolveCapability(channel: []const u8) VoiceCapability {
    // S7.9 — capability honesty. Pre-S7.9 this function claimed
    // discord/whatsapp/slack were STT+TTS capable; an audit of the
    // channel implementations confirmed only `telegram.zig` has an
    // audio-send path (`sendAudio` / `sendVoice` Bot API calls). The
    // other three channels had no code to deliver the audio the
    // capability descriptor promised — tool callers would build an
    // attachment that silently dropped on send.
    //
    // Truth now matches wire: only telegram reports STT+TTS. When the
    // discord/whatsapp/slack audio send paths actually ship, add them
    // back one at a time with their matching attachment-dispatch code
    // landing in the same commit.
    if (std.ascii.eqlIgnoreCase(channel, "telegram")) return .{ .stt = true, .tts = true };
    // V1.11 hardening (2026-05-07): zaki_app gains STT after the
    // /api/v1/chat/stream `audio` field path landed — backend transcribes
    // and feeds the agent. TTS output to the app is NOT wired yet (would
    // need an `audio_reply` SSE event on the chat stream + FE player); set
    // to true ONLY when that delivery path lands. Honesty contract: this
    // descriptor reflects working wire paths, not intent.
    if (std.ascii.eqlIgnoreCase(channel, "zaki_app")) return .{ .stt = true, .tts = false };
    return .{ .stt = false, .tts = false };
}

/// Voice mode orchestration — tracks whether voice processing is active and
/// provides narration label constants for the observer bus.
pub const VoiceMode = struct {
    enabled: bool = false,

    /// Check if voice processing should be used for this channel.
    pub fn isActiveForChannel(self: VoiceMode, channel: ?[]const u8) bool {
        if (!self.enabled) return false;
        const ch = channel orelse return false;
        return channelSupportsAudio(ch);
    }

    /// Voice narration frame types for the observer bus.
    pub const NarrationLabel = struct {
        pub const listening: []const u8 = "Listening...";
        pub const thinking: []const u8 = "Thinking...";
        pub const speaking: []const u8 = "Speaking...";
    };
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "NarrationFrameType has listening variant" {
    const ft = observability.NarrationFrameType.listening;
    try std.testing.expectEqualStrings("listening", @tagName(ft));
}

test "NarrationFrameType has speaking variant" {
    const ft = observability.NarrationFrameType.speaking;
    try std.testing.expectEqualStrings("speaking", @tagName(ft));
}

test "channelSupportsAudio returns true for telegram" {
    try std.testing.expect(channelSupportsAudio("telegram"));
}

test "channelSupportsAudio returns false for discord (S7.9 — no audio-send path yet)" {
    try std.testing.expect(!channelSupportsAudio("discord"));
}

test "channelSupportsAudio returns false for whatsapp (S7.9 — no audio-send path yet)" {
    try std.testing.expect(!channelSupportsAudio("whatsapp"));
}

test "channelSupportsAudio returns false for cli" {
    try std.testing.expect(!channelSupportsAudio("cli"));
}

test "channelSupportsAudio returns false for unknown" {
    try std.testing.expect(!channelSupportsAudio("unknown"));
}

test "VoiceCapability struct has stt and tts fields" {
    const cap = VoiceCapability{ .stt = true, .tts = false };
    try std.testing.expect(cap.stt);
    try std.testing.expect(!cap.tts);
}

test "resolveCapability telegram returns full audio" {
    const cap = resolveCapability("telegram");
    try std.testing.expect(cap.stt);
    try std.testing.expect(cap.tts);
}

test "resolveCapability cli returns no audio" {
    const cap = resolveCapability("cli");
    try std.testing.expect(!cap.stt);
    try std.testing.expect(!cap.tts);
}

test "VoiceMode.isActiveForChannel returns false when disabled" {
    const vm = VoiceMode{ .enabled = false };
    try std.testing.expect(!vm.isActiveForChannel("telegram"));
}

test "VoiceMode.isActiveForChannel returns true when enabled for audio channel" {
    const vm = VoiceMode{ .enabled = true };
    try std.testing.expect(vm.isActiveForChannel("telegram"));
}

test "VoiceMode.isActiveForChannel returns false for null channel" {
    const vm = VoiceMode{ .enabled = true };
    try std.testing.expect(!vm.isActiveForChannel(null));
}

test "VoiceMode.isActiveForChannel returns false for non-audio channel" {
    const vm = VoiceMode{ .enabled = true };
    try std.testing.expect(!vm.isActiveForChannel("cli"));
}

test "VoiceMode.NarrationLabel constants are correct" {
    try std.testing.expectEqualStrings("Listening...", VoiceMode.NarrationLabel.listening);
    try std.testing.expectEqualStrings("Thinking...", VoiceMode.NarrationLabel.thinking);
    try std.testing.expectEqualStrings("Speaking...", VoiceMode.NarrationLabel.speaking);
}

test "channelSupportsAudio is case-insensitive (telegram)" {
    // S7.9 — case-insensitivity only exercises telegram now, since it's
    // the only channel with a real audio-send path. Discord/WhatsApp/Slack
    // return false regardless of case.
    try std.testing.expect(channelSupportsAudio("Telegram"));
    try std.testing.expect(channelSupportsAudio("TELEGRAM"));
    try std.testing.expect(!channelSupportsAudio("DISCORD"));
    try std.testing.expect(!channelSupportsAudio("WhatsApp"));
}

test "resolveCapability slack returns no audio (S7.9 — no audio-send path yet)" {
    const cap = resolveCapability("slack");
    try std.testing.expect(!cap.stt);
    try std.testing.expect(!cap.tts);
}

test "resolveCapability zaki_app: STT live (V1.11), TTS not yet" {
    // V1.11 hardening (2026-05-07): /api/v1/chat/stream now accepts an
    // `audio` field and transcribes server-side via the configured STT
    // provider, feeding the transcript to the agent. So zaki_app is
    // STT-capable as of this version. TTS to the app would need an
    // `audio_reply` SSE event on the chat stream + FE audio player —
    // not yet wired; flag stays false.
    const cap = resolveCapability("zaki_app");
    try std.testing.expect(cap.stt);
    try std.testing.expect(!cap.tts);
}
