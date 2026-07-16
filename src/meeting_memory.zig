const std = @import("std");

pub const write_origin = "meeting_ingest";
pub const source_spoke = "minutes";
pub const memory_key_prefix = "meeting_ingest/";
pub const memory_key_len = memory_key_prefix.len + 64;
pub const sha256_prefix = "sha256=";
pub const sha256_text_len = sha256_prefix.len + 64;

pub const max_source_item_id_bytes = 512;
pub const max_meeting_id_bytes = 512;
pub const max_candidate_bytes = 16 * 1024;
pub const max_grant_id_bytes = 256;
pub const max_policy_version_bytes = 128;
pub const max_request_id_bytes = 128;

pub const ValidationError = error{
    InvalidUserId,
    EmptySourceItemId,
    SourceItemIdTooLong,
    SourceItemIdNotTrimmed,
    SourceItemIdContainsControl,
    SourceItemIdInvalidUtf8,
    EmptyMeetingId,
    MeetingIdTooLong,
    MeetingIdNotTrimmed,
    MeetingIdContainsControl,
    MeetingIdInvalidUtf8,
    EmptyCandidate,
    CandidateTooLong,
    CandidateContainsNul,
    CandidateInvalidUtf8,
    EmptyGrantId,
    GrantIdTooLong,
    GrantIdContainsNul,
    GrantIdInvalidUtf8,
    EmptyPolicyVersion,
    PolicyVersionTooLong,
    PolicyVersionContainsNul,
    InvalidPolicyVersion,
    EmptyRequestId,
    RequestIdTooLong,
    InvalidRequestId,
    RequestIdInvalidUtf8,
    InvalidGrantedAt,
    ConsentSourceMismatch,
    ConsentCandidateMismatch,
};

pub const SourceTupleInput = struct {
    user_id: i64,
    source_item_id: []const u8,
    meeting_id: []const u8,
};

/// Borrowed, validated Minutes source identity. The origin and spoke are not
/// caller-controlled fields: both are fixed by this module.
pub const SourceTuple = struct {
    user_id: i64,
    source_item_id: []const u8,
    meeting_id: []const u8,

    pub fn init(input: SourceTupleInput) ValidationError!SourceTuple {
        try validateUserId(input.user_id);
        try validateCanonicalId(
            input.source_item_id,
            max_source_item_id_bytes,
            error.EmptySourceItemId,
            error.SourceItemIdTooLong,
            error.SourceItemIdNotTrimmed,
            error.SourceItemIdContainsControl,
            error.SourceItemIdInvalidUtf8,
        );
        try validateCanonicalId(
            input.meeting_id,
            max_meeting_id_bytes,
            error.EmptyMeetingId,
            error.MeetingIdTooLong,
            error.MeetingIdNotTrimmed,
            error.MeetingIdContainsControl,
            error.MeetingIdInvalidUtf8,
        );
        return .{
            .user_id = input.user_id,
            .source_item_id = input.source_item_id,
            .meeting_id = input.meeting_id,
        };
    }
};

pub const CandidateKind = enum {
    durable_fact,
    decision,
    action_item,
};

/// A rejected or unknown DLP state cannot satisfy `Candidate.init`.
pub const DlpApproval = enum { approved };

pub const Candidate = struct {
    kind: CandidateKind,
    text_value: []const u8,
    dlp_approval: DlpApproval,

    pub fn init(kind: CandidateKind, text_value: []const u8, approval: DlpApproval) ValidationError!Candidate {
        try validateField(text_value, max_candidate_bytes, error.EmptyCandidate, error.CandidateTooLong, error.CandidateContainsNul);
        if (!std.unicode.utf8ValidateSlice(text_value)) return error.CandidateInvalidUtf8;
        return .{ .kind = kind, .text_value = text_value, .dlp_approval = approval };
    }

    pub fn text(self: Candidate) []const u8 {
        return self.text_value;
    }
};

pub const ConsentGrantInput = struct {
    grant_id: []const u8,
    policy_version: []const u8,
    granted_at_unix_ms: i64,
};

/// Only the authenticated user-control plane can mint this semantic state.
/// There is deliberately no model/unconfirmed enum variant or boolean default.
pub const ConfirmationAuthority = enum { authenticated_user_control };

pub const ConfirmedConsentGrant = struct {
    grant_digest: Digest,
    policy_version: []const u8,
    granted_at_unix_ms: i64,
    authority: ConfirmationAuthority,
    source_digest: Digest,
    candidate_digest: Digest,

    pub fn init(source: SourceTuple, candidate: Candidate, input: ConsentGrantInput) ValidationError!ConfirmedConsentGrant {
        try validateField(input.grant_id, max_grant_id_bytes, error.EmptyGrantId, error.GrantIdTooLong, error.GrantIdContainsNul);
        if (!std.unicode.utf8ValidateSlice(input.grant_id)) return error.GrantIdInvalidUtf8;
        try validateField(input.policy_version, max_policy_version_bytes, error.EmptyPolicyVersion, error.PolicyVersionTooLong, error.PolicyVersionContainsNul);
        if (!std.unicode.utf8ValidateSlice(input.policy_version)) return error.InvalidPolicyVersion;
        if (!isSafeSlug(input.policy_version)) return error.InvalidPolicyVersion;
        if (input.granted_at_unix_ms <= 0) return error.InvalidGrantedAt;

        const identity = deriveIdentity(source, candidate);
        return .{
            .grant_digest = deriveGrantDigest(identity.source_digest, identity.candidate_digest, input.grant_id),
            .policy_version = input.policy_version,
            .granted_at_unix_ms = input.granted_at_unix_ms,
            .authority = .authenticated_user_control,
            .source_digest = identity.source_digest,
            .candidate_digest = identity.candidate_digest,
        };
    }
};

pub const Digest = [32]u8;
pub const HexDigest = [64]u8;
pub const Sha256Text = [sha256_text_len]u8;
pub const MemoryKey = [memory_key_len]u8;

/// Canonical SQL/wire representation for every persisted digest in this
/// module. Keeping the prefix and lowercase-hex encoding here prevents each
/// storage adapter from inventing its own form.
pub fn formatSha256(digest: Digest) Sha256Text {
    const hex = hexDigest(digest);
    var result: Sha256Text = undefined;
    @memcpy(result[0..sha256_prefix.len], sha256_prefix);
    @memcpy(result[sha256_prefix.len..], &hex);
    return result;
}

pub const MemoryIdentity = struct {
    /// Item/source scope: user + fixed origin/spoke + source item + meeting.
    source_digest: Digest,
    /// Meeting scope: user + fixed origin/spoke + meeting (all source items).
    meeting_digest: Digest,
    candidate_digest: Digest,
    key_digest: Digest,
    memory_key: MemoryKey,

    pub fn memoryKey(self: *const MemoryIdentity) []const u8 {
        return &self.memory_key;
    }
};

pub const Provenance = struct {
    identity: MemoryIdentity,
    consent: ConfirmedConsentGrant,
    dlp_approval: DlpApproval,

    pub fn writeOrigin(_: *const Provenance) []const u8 {
        return write_origin;
    }

    pub fn sourceSpoke(_: *const Provenance) []const u8 {
        return source_spoke;
    }

    /// Serialize persistence metadata only. This type contains neither the
    /// candidate text nor raw source/grant identifiers, so those values cannot
    /// accidentally enter metadata JSON through a future formatter change.
    pub fn serializeJson(self: *const Provenance, allocator: std.mem.Allocator) ![]u8 {
        const source_digest_text = formatSha256(self.identity.source_digest);
        const meeting_digest_text = formatSha256(self.identity.meeting_digest);
        const candidate_digest_text = formatSha256(self.identity.candidate_digest);
        const grant_digest_text = formatSha256(self.consent.grant_digest);
        return std.json.Stringify.valueAlloc(allocator, .{
            .schema = "meeting-memory-provenance.v1",
            .write_origin = write_origin,
            .source_spoke = source_spoke,
            .source_digest = source_digest_text[0..],
            .meeting_digest = meeting_digest_text[0..],
            .candidate_digest = candidate_digest_text[0..],
            .memory_key = self.identity.memoryKey(),
            .consent = .{
                .policy_version = self.consent.policy_version,
                .granted_at_unix_ms = self.consent.granted_at_unix_ms,
                .authority = @tagName(self.consent.authority),
                .grant_digest = grant_digest_text[0..],
            },
            .dlp_approval = @tagName(self.dlp_approval),
        }, .{});
    }
};

pub const PreparedMemory = struct {
    source: SourceTuple,
    candidate: Candidate,
    provenance: Provenance,

    pub fn init(source: SourceTuple, candidate: Candidate, consent: ConfirmedConsentGrant) ValidationError!PreparedMemory {
        const identity = deriveIdentity(source, candidate);
        if (!std.mem.eql(u8, &identity.source_digest, &consent.source_digest)) return error.ConsentSourceMismatch;
        if (!std.mem.eql(u8, &identity.candidate_digest, &consent.candidate_digest)) return error.ConsentCandidateMismatch;
        return .{
            .source = source,
            .candidate = candidate,
            .provenance = .{
                .identity = identity,
                .consent = consent,
                .dlp_approval = candidate.dlp_approval,
            },
        };
    }
};

pub const ErasureCounts = struct {
    memory_source_links_deleted: u64 = 0,
    memories_deleted: u64 = 0,
    memory_events_deleted: u64 = 0,
    working_memory_deleted: u64 = 0,
    memory_edges_deleted: u64 = 0,
    memory_entities_deleted: u64 = 0,
    memory_embeddings_deleted: u64 = 0,
    memory_vectors_deleted: u64 = 0,
};

/// Validated, content-free authority for one meeting-scoped erasure. Raw
/// request and meeting identifiers are consumed only while deriving digests.
pub const ErasureRequest = struct {
    user_id: i64,
    meeting_digest: Digest,
    request_digest: Digest,

    pub fn init(user_id: i64, meeting_id: []const u8, request_id: []const u8) ValidationError!ErasureRequest {
        try validateUserId(user_id);
        try validateCanonicalId(
            meeting_id,
            max_meeting_id_bytes,
            error.EmptyMeetingId,
            error.MeetingIdTooLong,
            error.MeetingIdNotTrimmed,
            error.MeetingIdContainsControl,
            error.MeetingIdInvalidUtf8,
        );
        try validateField(request_id, max_request_id_bytes, error.EmptyRequestId, error.RequestIdTooLong, error.InvalidRequestId);
        if (!std.unicode.utf8ValidateSlice(request_id)) return error.RequestIdInvalidUtf8;
        if (!isSafeSlug(request_id)) return error.InvalidRequestId;

        const meeting_digest = deriveMeetingDigest(user_id, meeting_id);
        return .{
            .user_id = user_id,
            .meeting_digest = meeting_digest,
            .request_digest = deriveRequestDigest(meeting_digest, request_id),
        };
    }
};

/// A manifest is emitted only after a complete transaction. Partial erasure
/// is intentionally not representable as a successful manifest disposition.
pub const ErasureDisposition = enum {
    erased,
    already_absent,
};

pub const ErasureManifest = struct {
    meeting_digest: Digest,
    request_digest: Digest,
    counts: ErasureCounts,
    disposition: ErasureDisposition,

    pub fn init(request: ErasureRequest, counts: ErasureCounts, disposition: ErasureDisposition) ErasureManifest {
        return .{
            .meeting_digest = request.meeting_digest,
            .request_digest = request.request_digest,
            .counts = counts,
            .disposition = disposition,
        };
    }

    /// Content-free, deterministic JSON for Hub's aggregate erasure receipt.
    /// Only a scope digest and row/carrier counts cross this boundary.
    pub fn serializeJson(self: *const ErasureManifest, allocator: std.mem.Allocator) ![]u8 {
        const meeting_digest_text = formatSha256(self.meeting_digest);
        const request_digest_text = formatSha256(self.request_digest);
        return std.json.Stringify.valueAlloc(allocator, .{
            .schema = "minutes-brain-erasure.v1",
            .write_origin = write_origin,
            .source_spoke = source_spoke,
            .meeting_digest = meeting_digest_text[0..],
            .request_digest = request_digest_text[0..],
            .disposition = @tagName(self.disposition),
            .counts = self.counts,
        }, .{});
    }
};

fn validateField(
    value: []const u8,
    max_len: usize,
    empty_error: ValidationError,
    too_long_error: ValidationError,
    nul_error: ValidationError,
) ValidationError!void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return empty_error;
    if (value.len > max_len) return too_long_error;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return nul_error;
}

fn validateUserId(user_id: i64) ValidationError!void {
    if (user_id <= 0) return error.InvalidUserId;
}

fn validateCanonicalId(
    value: []const u8,
    max_len: usize,
    empty_error: ValidationError,
    too_long_error: ValidationError,
    not_trimmed_error: ValidationError,
    control_error: ValidationError,
    invalid_utf8_error: ValidationError,
) ValidationError!void {
    if (value.len == 0) return empty_error;
    if (value.len > max_len) return too_long_error;
    if (!std.unicode.utf8ValidateSlice(value)) return invalid_utf8_error;
    if (!std.mem.eql(u8, value, std.mem.trim(u8, value, " "))) return not_trimmed_error;
    var iterator = (std.unicode.Utf8View.init(value) catch return invalid_utf8_error).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f)) return control_error;
    }
}

fn isSafeSlug(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != ':' and byte != '-') return false;
    }
    return true;
}

fn deriveIdentity(source: SourceTuple, candidate: Candidate) MemoryIdentity {
    const source_digest = deriveSourceDigest(source);
    const meeting_digest = deriveMeetingDigest(source.user_id, source.meeting_id);

    var candidate_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&candidate_hasher, "domain", "zaki.minutes.candidate.v1");
    updateField(&candidate_hasher, "kind", @tagName(candidate.kind));
    updateField(&candidate_hasher, "text", candidate.text_value);
    var candidate_digest: Digest = undefined;
    candidate_hasher.final(&candidate_digest);

    var key_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&key_hasher, "domain", "zaki.minutes.memory-key.v1");
    updateField(&key_hasher, "source_digest", &source_digest);
    updateField(&key_hasher, "candidate_digest", &candidate_digest);
    var key_digest: Digest = undefined;
    key_hasher.final(&key_digest);

    const key_hex = hexDigest(key_digest);
    var key: MemoryKey = undefined;
    @memcpy(key[0..memory_key_prefix.len], memory_key_prefix);
    @memcpy(key[memory_key_prefix.len..], &key_hex);

    return .{
        .source_digest = source_digest,
        .meeting_digest = meeting_digest,
        .candidate_digest = candidate_digest,
        .key_digest = key_digest,
        .memory_key = key,
    };
}

fn deriveSourceDigest(source: SourceTuple) Digest {
    var source_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&source_hasher, "domain", "zaki.minutes.source-scope.v1");
    updateField(&source_hasher, "write_origin", write_origin);
    updateField(&source_hasher, "source_spoke", source_spoke);
    updateUserId(&source_hasher, source.user_id);
    updateField(&source_hasher, "source_item_id", source.source_item_id);
    updateField(&source_hasher, "meeting_id", source.meeting_id);
    var source_digest: Digest = undefined;
    source_hasher.final(&source_digest);
    return source_digest;
}

fn deriveMeetingDigest(user_id: i64, meeting_id: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&hasher, "domain", "zaki.minutes.meeting-scope.v1");
    updateField(&hasher, "write_origin", write_origin);
    updateField(&hasher, "source_spoke", source_spoke);
    updateUserId(&hasher, user_id);
    updateField(&hasher, "meeting_id", meeting_id);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn deriveRequestDigest(meeting_digest: Digest, request_id: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&hasher, "domain", "zaki.minutes.erasure-request.v1");
    updateField(&hasher, "meeting_digest", &meeting_digest);
    updateField(&hasher, "request_id", request_id);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn deriveGrantDigest(source_digest: Digest, candidate_digest: Digest, grant_id: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&hasher, "domain", "zaki.minutes.consent-grant.v1");
    updateField(&hasher, "source_digest", &source_digest);
    updateField(&hasher, "candidate_digest", &candidate_digest);
    updateField(&hasher, "grant_id", grant_id);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn updateField(hasher: *std.crypto.hash.sha2.Sha256, label: []const u8, value: []const u8) void {
    hasher.update(label);
    hasher.update(&.{0});
    var length_bytes: [8]u8 = undefined;
    var length: u64 = @intCast(value.len);
    var index: usize = length_bytes.len;
    while (index > 0) {
        index -= 1;
        length_bytes[index] = @truncate(length);
        length >>= 8;
    }
    hasher.update(&length_bytes);
    hasher.update(value);
}

fn updateUserId(hasher: *std.crypto.hash.sha2.Sha256, user_id: i64) void {
    var buffer: [20]u8 = undefined;
    const canonical = std.fmt.bufPrint(&buffer, "{d}", .{user_id}) catch unreachable;
    updateField(hasher, "user_id", canonical);
}

fn hexDigest(digest: Digest) HexDigest {
    const alphabet = "0123456789abcdef";
    var result: HexDigest = undefined;
    for (digest, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return result;
}

test "prepared meeting memory fixes provenance and derives a bounded key" {
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "transcript-7",
        .meeting_id = "meeting-9",
    });
    const candidate = try Candidate.init(.decision, "Ship the staged pilot", .approved);
    const grant = try ConfirmedConsentGrant.init(source, candidate, .{
        .grant_id = "grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });

    const prepared = try PreparedMemory.init(source, candidate, grant);

    try std.testing.expectEqualStrings("meeting_ingest", prepared.provenance.writeOrigin());
    try std.testing.expectEqualStrings("minutes", prepared.provenance.sourceSpoke());
    try std.testing.expectEqual(@as(i64, 42), prepared.source.user_id);
    try std.testing.expectEqualStrings("transcript-7", prepared.source.source_item_id);
    try std.testing.expectEqualStrings("meeting-9", prepared.source.meeting_id);
    try std.testing.expectEqualStrings("Ship the staged pilot", prepared.candidate.text());
    try std.testing.expectEqualStrings(memory_key_prefix, prepared.provenance.identity.memoryKey()[0..memory_key_prefix.len]);
    try std.testing.expectEqual(@as(usize, memory_key_len), prepared.provenance.identity.memoryKey().len);
}

test "source candidate and consent fields reject blank oversized and NUL input" {
    const valid_source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "item",
        .meeting_id = "meeting",
    });
    const valid_candidate = try Candidate.init(.durable_fact, "fact", .approved);
    const invalid_utf8 = [_]u8{0xff};

    try std.testing.expectError(error.InvalidUserId, SourceTuple.init(.{
        .user_id = 0,
        .source_item_id = "item",
        .meeting_id = "meeting",
    }));
    try std.testing.expectError(error.InvalidUserId, SourceTuple.init(.{
        .user_id = -1,
        .source_item_id = "item",
        .meeting_id = "meeting",
    }));

    try std.testing.expectError(error.EmptySourceItemId, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "",
        .meeting_id = "meeting",
    }));
    try std.testing.expectError(error.SourceItemIdNotTrimmed, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = " item",
        .meeting_id = "meeting",
    }));
    try std.testing.expectError(error.SourceItemIdContainsControl, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "item\x00other",
        .meeting_id = "meeting",
    }));
    try std.testing.expectError(error.SourceItemIdInvalidUtf8, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = &invalid_utf8,
        .meeting_id = "meeting",
    }));
    const long_source_item = [_]u8{'s'} ** (max_source_item_id_bytes + 1);
    try std.testing.expectError(error.SourceItemIdTooLong, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = &long_source_item,
        .meeting_id = "meeting",
    }));

    try std.testing.expectError(error.EmptyMeetingId, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "item",
        .meeting_id = "",
    }));
    try std.testing.expectError(error.MeetingIdNotTrimmed, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "item",
        .meeting_id = "meeting ",
    }));
    try std.testing.expectError(error.MeetingIdContainsControl, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "item",
        .meeting_id = "meeting\x00other",
    }));
    try std.testing.expectError(error.MeetingIdInvalidUtf8, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "item",
        .meeting_id = &invalid_utf8,
    }));
    const long_meeting = [_]u8{'m'} ** (max_meeting_id_bytes + 1);
    try std.testing.expectError(error.MeetingIdTooLong, SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "item",
        .meeting_id = &long_meeting,
    }));

    try std.testing.expectError(error.EmptyCandidate, Candidate.init(.durable_fact, "\r\n", .approved));
    try std.testing.expectError(error.CandidateContainsNul, Candidate.init(.durable_fact, "fact\x00tail", .approved));
    try std.testing.expectError(error.CandidateInvalidUtf8, Candidate.init(.durable_fact, &invalid_utf8, .approved));
    const long_candidate = [_]u8{'c'} ** (max_candidate_bytes + 1);
    try std.testing.expectError(error.CandidateTooLong, Candidate.init(.durable_fact, &long_candidate, .approved));

    try std.testing.expectError(error.EmptyGrantId, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "",
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.GrantIdContainsNul, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "grant\x00tail",
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.GrantIdInvalidUtf8, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = &invalid_utf8,
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));
    const long_grant = [_]u8{'g'} ** (max_grant_id_bytes + 1);
    try std.testing.expectError(error.GrantIdTooLong, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = &long_grant,
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));

    try std.testing.expectError(error.EmptyPolicyVersion, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = " \t",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.PolicyVersionContainsNul, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = "v1\x00tail",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.InvalidPolicyVersion, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = &invalid_utf8,
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.InvalidPolicyVersion, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = "minutes memory/v1",
        .granted_at_unix_ms = 1,
    }));
    const long_policy = [_]u8{'p'} ** (max_policy_version_bytes + 1);
    try std.testing.expectError(error.PolicyVersionTooLong, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = &long_policy,
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.InvalidGrantedAt, ConfirmedConsentGrant.init(valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = "v1",
        .granted_at_unix_ms = 0,
    }));
}

test "confirmed consent is bound to one source and candidate" {
    const source = try SourceTuple.init(.{
        .user_id = 7,
        .source_item_id = "item-a",
        .meeting_id = "meeting-a",
    });
    const other_source = try SourceTuple.init(.{
        .user_id = 7,
        .source_item_id = "item-b",
        .meeting_id = "meeting-b",
    });
    const candidate = try Candidate.init(.decision, "Use the staged rollout", .approved);
    const other_candidate = try Candidate.init(.decision, "Skip the staged rollout", .approved);
    const grant = try ConfirmedConsentGrant.init(source, candidate, .{
        .grant_id = "grant-bound-a",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });

    _ = try PreparedMemory.init(source, candidate, grant);
    try std.testing.expectError(error.ConsentSourceMismatch, PreparedMemory.init(other_source, candidate, grant));
    try std.testing.expectError(error.ConsentCandidateMismatch, PreparedMemory.init(source, other_candidate, grant));

    try std.testing.expect(!@hasField(ConfirmedConsentGrant, "grant_id_value"));
    try std.testing.expect(std.meta.stringToEnum(ConfirmationAuthority, "model") == null);
    try std.testing.expect(std.meta.stringToEnum(ConfirmationAuthority, "unconfirmed") == null);
}

test "memory identity is retry stable source scoped and content free" {
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "raw-transcript-secret-7",
        .meeting_id = "raw-meeting-secret-9",
    });
    const candidate = try Candidate.init(.action_item, "raw candidate text that must stay private", .approved);
    const grant = try ConfirmedConsentGrant.init(source, candidate, .{
        .grant_id = "raw-grant-secret-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const first = try PreparedMemory.init(source, candidate, grant);
    const retry = try PreparedMemory.init(source, candidate, grant);

    try std.testing.expectEqualSlices(u8, first.provenance.identity.memoryKey(), retry.provenance.identity.memoryKey());
    try std.testing.expectEqualSlices(u8, &first.provenance.identity.source_digest, &retry.provenance.identity.source_digest);
    try std.testing.expectEqualSlices(u8, &first.provenance.identity.meeting_digest, &retry.provenance.identity.meeting_digest);
    try std.testing.expectEqualSlices(u8, &first.provenance.identity.candidate_digest, &retry.provenance.identity.candidate_digest);

    const changed_sources = [_]SourceTuple{
        try SourceTuple.init(.{ .user_id = 43, .source_item_id = "raw-transcript-secret-7", .meeting_id = "raw-meeting-secret-9" }),
        try SourceTuple.init(.{ .user_id = 42, .source_item_id = "raw-transcript-secret-other", .meeting_id = "raw-meeting-secret-9" }),
        try SourceTuple.init(.{ .user_id = 42, .source_item_id = "raw-transcript-secret-7", .meeting_id = "raw-meeting-secret-other" }),
    };
    for (changed_sources, 0..) |changed_source, index| {
        const changed_grant = try ConfirmedConsentGrant.init(changed_source, candidate, .{
            .grant_id = "raw-grant-secret-3",
            .policy_version = "minutes-memory-v1",
            .granted_at_unix_ms = 1_784_200_000_000,
        });
        const changed = try PreparedMemory.init(changed_source, candidate, changed_grant);
        try std.testing.expect(!std.mem.eql(u8, first.provenance.identity.memoryKey(), changed.provenance.identity.memoryKey()));
        try std.testing.expect(!std.mem.eql(u8, &first.provenance.identity.source_digest, &changed.provenance.identity.source_digest));
        if (index == 1) {
            try std.testing.expectEqualSlices(u8, &first.provenance.identity.meeting_digest, &changed.provenance.identity.meeting_digest);
        } else {
            try std.testing.expect(!std.mem.eql(u8, &first.provenance.identity.meeting_digest, &changed.provenance.identity.meeting_digest));
        }
        try std.testing.expectEqualSlices(u8, &first.provenance.identity.candidate_digest, &changed.provenance.identity.candidate_digest);
    }

    const key = first.provenance.identity.memoryKey();
    try std.testing.expect(std.mem.indexOf(u8, key, source.source_item_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, key, source.meeting_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, key, candidate.text()) == null);
    try std.testing.expect(std.mem.indexOf(u8, key, "raw-grant-secret-3") == null);

    const persisted = formatSha256(first.provenance.identity.source_digest);
    try std.testing.expectEqual(@as(usize, 71), persisted.len);
    try std.testing.expectEqualStrings("sha256=", persisted[0..7]);
    for (persisted[7..]) |byte| {
        try std.testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
    }
}

test "meeting memory digest golden vector remains stable" {
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "transcript-7",
        .meeting_id = "meeting-9",
    });
    const candidate = try Candidate.init(.decision, "Ship the staged pilot", .approved);
    const grant = try ConfirmedConsentGrant.init(source, candidate, .{
        .grant_id = "grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const prepared = try PreparedMemory.init(source, candidate, grant);
    const source_text = formatSha256(prepared.provenance.identity.source_digest);
    const meeting_text = formatSha256(prepared.provenance.identity.meeting_digest);
    const candidate_text = formatSha256(prepared.provenance.identity.candidate_digest);
    const grant_text = formatSha256(prepared.provenance.consent.grant_digest);

    try std.testing.expectEqualStrings("sha256=6a6ed392f4bc7026bb0b0724a997967759089b9facc4cbca07e0588488896a43", &source_text);
    try std.testing.expectEqualStrings("sha256=7cc99b54f8ec2c09d62220e8591184830b4c9650b50bd418caf7d6e133fd4b3c", &meeting_text);
    try std.testing.expectEqualStrings("sha256=5f34b0af1d1f9a8ee28ed1f0c9bfd36ebfc8dfe11ad219f1bb5bdfb212fc2faf", &candidate_text);
    try std.testing.expectEqualStrings("sha256=8e692216a135fc577c4a53df44238fa41e4c818d3b2593a21248a2c2a4a4608e", &grant_text);
    try std.testing.expectEqualStrings("meeting_ingest/c117acfd660860fb202049c2487496d930a24e6180de50e3b25964e35916f425", prepared.provenance.identity.memoryKey());
}

test "provenance and erasure serializers expose digests but no raw content or identifiers" {
    const allocator = std.testing.allocator;
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "never-serialize-source-item-7",
        .meeting_id = "never-serialize-meeting-9",
    });
    const candidate = try Candidate.init(.decision, "never serialize this candidate or transcript sentence", .approved);
    const grant = try ConfirmedConsentGrant.init(source, candidate, .{
        .grant_id = "never-serialize-grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const prepared = try PreparedMemory.init(source, candidate, grant);

    const provenance_json = try prepared.provenance.serializeJson(allocator);
    defer allocator.free(provenance_json);
    try expectContentFree(provenance_json, &.{
        source.source_item_id,
        source.meeting_id,
        candidate.text(),
        "never-serialize-grant-3",
    });
    try std.testing.expect(std.mem.indexOf(u8, provenance_json, "\"write_origin\":\"meeting_ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, provenance_json, "\"source_spoke\":\"minutes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, provenance_json, "\"source_digest\":\"sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, provenance_json, "\"candidate_digest\":\"sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, provenance_json, "\"grant_digest\":\"sha256=") != null);
    var parsed_provenance = try std.json.parseFromSlice(std.json.Value, allocator, provenance_json, .{});
    defer parsed_provenance.deinit();

    const request = try ErasureRequest.init(source.user_id, source.meeting_id, "never-serialize-request-5");
    try std.testing.expectEqual(@as(i64, 42), request.user_id);
    try std.testing.expect(!@hasField(ErasureRequest, "meeting_id"));
    try std.testing.expect(!@hasField(ErasureRequest, "request_id"));

    const manifest = ErasureManifest.init(request, .{
        .memory_source_links_deleted = 2,
        .memories_deleted = 2,
        .memory_events_deleted = 3,
        .working_memory_deleted = 1,
        .memory_edges_deleted = 4,
        .memory_entities_deleted = 1,
        .memory_embeddings_deleted = 2,
        .memory_vectors_deleted = 2,
    }, .erased);
    const manifest_json = try manifest.serializeJson(allocator);
    defer allocator.free(manifest_json);
    try expectContentFree(manifest_json, &.{
        source.source_item_id,
        source.meeting_id,
        candidate.text(),
        "never-serialize-grant-3",
        "never-serialize-request-5",
    });
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"meeting_digest\":\"sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"request_digest\":\"sha256=") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"source_digest\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"memory_source_links_deleted\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"memories_deleted\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"memory_embeddings_deleted\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"memory_vectors_deleted\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_json, "\"disposition\":\"erased\"") != null);
    var parsed_manifest = try std.json.parseFromSlice(std.json.Value, allocator, manifest_json, .{});
    defer parsed_manifest.deinit();

    const retry_json = try manifest.serializeJson(allocator);
    defer allocator.free(retry_json);
    try std.testing.expectEqualStrings(manifest_json, retry_json);
}

test "erasure request validates its boundary and retains digests only" {
    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUserId, ErasureRequest.init(0, "meeting-9", "request-1"));
    try std.testing.expectError(error.EmptyMeetingId, ErasureRequest.init(42, "", "request-1"));
    try std.testing.expectError(error.MeetingIdNotTrimmed, ErasureRequest.init(42, " meeting-9", "request-1"));
    try std.testing.expectError(error.MeetingIdContainsControl, ErasureRequest.init(42, "meeting\x00-9", "request-1"));
    try std.testing.expectError(error.MeetingIdInvalidUtf8, ErasureRequest.init(42, &invalid_utf8, "request-1"));
    try std.testing.expectError(error.EmptyRequestId, ErasureRequest.init(42, "meeting-9", ""));
    try std.testing.expectError(error.InvalidRequestId, ErasureRequest.init(42, "meeting-9", "request id"));
    try std.testing.expectError(error.RequestIdInvalidUtf8, ErasureRequest.init(42, "meeting-9", &invalid_utf8));
    const long_request = [_]u8{'r'} ** (max_request_id_bytes + 1);
    try std.testing.expectError(error.RequestIdTooLong, ErasureRequest.init(42, "meeting-9", &long_request));

    const first = try ErasureRequest.init(42, "meeting-9", "request-1");
    const retry = try ErasureRequest.init(42, "meeting-9", "request-1");
    const other_request = try ErasureRequest.init(42, "meeting-9", "request-2");
    const other_meeting = try ErasureRequest.init(42, "meeting-10", "request-1");
    try std.testing.expectEqualSlices(u8, &first.meeting_digest, &retry.meeting_digest);
    try std.testing.expectEqualSlices(u8, &first.request_digest, &retry.request_digest);
    try std.testing.expectEqualSlices(u8, &first.meeting_digest, &other_request.meeting_digest);
    try std.testing.expect(!std.mem.eql(u8, &first.request_digest, &other_request.request_digest));
    try std.testing.expect(!std.mem.eql(u8, &first.meeting_digest, &other_meeting.meeting_digest));
    try std.testing.expect(!std.mem.eql(u8, &first.request_digest, &other_meeting.request_digest));
}

fn expectContentFree(serialized: []const u8, forbidden: []const []const u8) !void {
    for (forbidden) |value| {
        try std.testing.expect(std.mem.indexOf(u8, serialized, value) == null);
    }
}
