const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Ed25519 = std.crypto.sign.Ed25519;

pub const write_origin = "meeting_ingest";
pub const source_spoke = "minutes";
pub const memory_key_prefix = "meeting_ingest/";
pub const memory_key_len = memory_key_prefix.len + 64;
pub const memory_key_regex = "^meeting_ingest/[0-9a-f]{64}$";
pub const sha256_prefix = "sha256=";
pub const sha256_text_len = sha256_prefix.len + 64;
pub const ed25519_prefix = "ed25519=";
pub const ed25519_signature_text_len = ed25519_prefix.len + (Ed25519.Signature.encoded_length * 2);

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
    PreparedMemoryIntegrityMismatch,
    ErasureRequestIntegrityMismatch,
    InvalidErasedAt,
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
    integrity_digest: Digest,
    policy_version: []const u8,
    granted_at_unix_ms: i64,
    authority: ConfirmationAuthority,
    source_digest: Digest,
    candidate_digest: Digest,

    pub fn init(pseudonymizer: *const Pseudonymizer, source: SourceTuple, candidate: Candidate, input: ConsentGrantInput) ValidationError!ConfirmedConsentGrant {
        try validateField(input.grant_id, max_grant_id_bytes, error.EmptyGrantId, error.GrantIdTooLong, error.GrantIdContainsNul);
        if (!std.unicode.utf8ValidateSlice(input.grant_id)) return error.GrantIdInvalidUtf8;
        try validateField(input.policy_version, max_policy_version_bytes, error.EmptyPolicyVersion, error.PolicyVersionTooLong, error.PolicyVersionContainsNul);
        if (!std.unicode.utf8ValidateSlice(input.policy_version)) return error.InvalidPolicyVersion;
        if (!isSafeSlug(input.policy_version)) return error.InvalidPolicyVersion;
        if (input.granted_at_unix_ms <= 0) return error.InvalidGrantedAt;

        const identity = deriveIdentity(pseudonymizer, source, candidate);
        const authority: ConfirmationAuthority = .authenticated_user_control;
        const grant_digest = deriveGrantDigest(
            pseudonymizer,
            identity.source_digest,
            identity.candidate_digest,
            input.grant_id,
            input.policy_version,
            input.granted_at_unix_ms,
            authority,
            candidate.dlp_approval,
        );
        return .{
            .grant_digest = grant_digest,
            .integrity_digest = deriveConsentIntegrity(
                pseudonymizer,
                grant_digest,
                identity.source_digest,
                identity.candidate_digest,
                input.policy_version,
                input.granted_at_unix_ms,
                authority,
                candidate.dlp_approval,
            ),
            .policy_version = input.policy_version,
            .granted_at_unix_ms = input.granted_at_unix_ms,
            .authority = authority,
            .source_digest = identity.source_digest,
            .candidate_digest = identity.candidate_digest,
        };
    }
};

pub const Digest = [32]u8;
pub const HexDigest = [64]u8;
pub const Sha256Text = [sha256_text_len]u8;
pub const MemoryKey = [memory_key_len]u8;
pub const Ed25519SignatureText = [ed25519_signature_text_len]u8;

/// Deployment-scoped keyed pseudonymization for every identity-bearing
/// Minutes digest. The raw key never leaves this value; `keyId` is a stable,
/// one-way identifier used to bind persisted state to the configured key.
pub const Pseudonymizer = struct {
    key: [HmacSha256.key_length]u8,
    key_id: Digest,

    pub fn init(key: [HmacSha256.key_length]u8) Pseudonymizer {
        return .{ .key = key, .key_id = derivePseudonymKeyId(key) };
    }

    pub fn keyId(self: *const Pseudonymizer) Sha256Text {
        return formatSha256(self.key_id);
    }

    fn hasher(self: *const Pseudonymizer) HmacSha256 {
        return HmacSha256.init(&self.key);
    }
};

pub const ReceiptCryptoError = error{
    InvalidReceiptSigningKey,
    InvalidReceiptPublicKey,
    InvalidReceiptKeyId,
    InvalidReceiptSignature,
    UnknownReceiptKeyId,
    ReceiptSignatureVerificationFailed,
};

/// Content-free Ed25519 attestation persisted with one erasure receipt.
pub const SignedErasureReceipt = struct {
    key_id: Sha256Text,
    signature: Ed25519SignatureText,

    pub fn keyId(self: *const SignedErasureReceipt) []const u8 {
        return &self.key_id;
    }

    pub fn signatureText(self: *const SignedErasureReceipt) []const u8 {
        return &self.signature;
    }
};

/// Holds only the current private seed-derived key pair. Previous keys belong
/// exclusively in the public verifier keyring, so rotation cannot accidentally
/// continue issuing receipts with a retired key.
pub const ErasureReceiptSigner = struct {
    key_pair: Ed25519.KeyPair,
    key_id: Sha256Text,

    pub fn init(seed: [Ed25519.KeyPair.seed_length]u8) ReceiptCryptoError!ErasureReceiptSigner {
        const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch
            return error.InvalidReceiptSigningKey;
        return .{
            .key_pair = key_pair,
            .key_id = receiptKeyId(key_pair.public_key.toBytes()),
        };
    }

    pub fn publicKeyBytes(self: *const ErasureReceiptSigner) [Ed25519.PublicKey.encoded_length]u8 {
        return self.key_pair.public_key.toBytes();
    }

    pub fn keyId(self: *const ErasureReceiptSigner) []const u8 {
        return &self.key_id;
    }

    pub fn signDigest(self: *const ErasureReceiptSigner, digest: Digest) ReceiptCryptoError!SignedErasureReceipt {
        const message = receiptSigningMessage(digest);
        var noise: [Ed25519.noise_length]u8 = undefined;
        std.crypto.random.bytes(&noise);
        const signature = self.key_pair.sign(&message, noise) catch
            return error.InvalidReceiptSigningKey;
        const bytes = signature.toBytes();
        var text: Ed25519SignatureText = undefined;
        @memcpy(text[0..ed25519_prefix.len], ed25519_prefix);
        encodeLowerHex(text[ed25519_prefix.len..], &bytes);
        return .{ .key_id = self.key_id, .signature = text };
    }
};

const ReceiptVerifierKey = struct {
    public_key: Ed25519.PublicKey,
    key_id: Sha256Text,
};

/// Public-only keyring for two-phase receipt-key rotation. `secondary` may be
/// the next key during phase one or the prior key during phase two, allowing
/// old and new pods to verify each other's receipts during a rolling deploy.
pub const ErasureReceiptVerifierKeyring = struct {
    current: ReceiptVerifierKey,
    secondary: ?ReceiptVerifierKey,

    pub fn init(
        current_public_key_bytes: [Ed25519.PublicKey.encoded_length]u8,
        secondary_public_key_bytes: ?[Ed25519.PublicKey.encoded_length]u8,
    ) ReceiptCryptoError!ErasureReceiptVerifierKeyring {
        const current = try verifierKey(current_public_key_bytes);
        const secondary = if (secondary_public_key_bytes) |bytes|
            try verifierKey(bytes)
        else
            null;
        return .{ .current = current, .secondary = secondary };
    }

    pub fn verifyDigest(
        self: *const ErasureReceiptVerifierKeyring,
        digest: Digest,
        key_id: []const u8,
        signature_text: []const u8,
    ) ReceiptCryptoError!void {
        if (!isCanonicalSha256Text(key_id)) return error.InvalidReceiptKeyId;
        const public_key = if (std.mem.eql(u8, key_id, &self.current.key_id))
            self.current.public_key
        else if (self.secondary) |secondary|
            if (std.mem.eql(u8, key_id, &secondary.key_id)) secondary.public_key else return error.UnknownReceiptKeyId
        else
            return error.UnknownReceiptKeyId;

        if (signature_text.len != ed25519_signature_text_len or
            !std.mem.eql(u8, signature_text[0..ed25519_prefix.len], ed25519_prefix))
        {
            return error.InvalidReceiptSignature;
        }
        var bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
        decodeLowerHex(signature_text[ed25519_prefix.len..], &bytes) catch
            return error.InvalidReceiptSignature;
        const signature = Ed25519.Signature.fromBytes(bytes);
        const message = receiptSigningMessage(digest);
        signature.verify(&message, public_key) catch
            return error.ReceiptSignatureVerificationFailed;
    }

    /// Prevent retiring a verification key while one of its signed receipts
    /// is still inside the configured retention window.
    pub fn recognizesKeyId(self: *const ErasureReceiptVerifierKeyring, key_id: []const u8) bool {
        if (!isCanonicalSha256Text(key_id)) return false;
        if (std.mem.eql(u8, key_id, &self.current.key_id)) return true;
        return if (self.secondary) |secondary|
            std.mem.eql(u8, key_id, &secondary.key_id)
        else
            false;
    }
};

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
    /// Identifies the deployment pseudonym key without exposing it.
    pseudonym_key_id: Digest,
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
        const pseudonym_key_id_text = formatSha256(self.identity.pseudonym_key_id);
        return std.json.Stringify.valueAlloc(allocator, .{
            .schema = "meeting-memory-provenance.v1",
            .write_origin = write_origin,
            .source_spoke = source_spoke,
            .pseudonym_key_id = pseudonym_key_id_text[0..],
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

    pub fn init(pseudonymizer: *const Pseudonymizer, source: SourceTuple, candidate: Candidate, consent: ConfirmedConsentGrant) ValidationError!PreparedMemory {
        const identity = deriveIdentity(pseudonymizer, source, candidate);
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

    /// Rebuild and compare every derived field immediately before persistence.
    ///
    /// The input structs borrow slices, so constructor-time validation alone is
    /// insufficient: a caller can reuse or mutate a backing buffer after
    /// `init`. This boundary check validates the current bytes and
    /// constant-time-compares all digest-bearing provenance with a freshly
    /// derived identity. The consent integrity digest also binds the current
    /// policy, timestamp, authority, and DLP state to the grant digest.
    pub fn validateForStore(self: PreparedMemory, pseudonymizer: *const Pseudonymizer) ValidationError!PreparedMemory {
        const source = try SourceTuple.init(.{
            .user_id = self.source.user_id,
            .source_item_id = self.source.source_item_id,
            .meeting_id = self.source.meeting_id,
        });
        const candidate = try Candidate.init(
            self.candidate.kind,
            self.candidate.text_value,
            self.candidate.dlp_approval,
        );
        try validateConsentEnvelope(self.provenance.consent);

        const identity = deriveIdentity(pseudonymizer, source, candidate);
        if (!digestEql(identity.pseudonym_key_id, self.provenance.identity.pseudonym_key_id) or
            !digestEql(identity.source_digest, self.provenance.identity.source_digest) or
            !digestEql(identity.meeting_digest, self.provenance.identity.meeting_digest) or
            !digestEql(identity.candidate_digest, self.provenance.identity.candidate_digest) or
            !digestEql(identity.key_digest, self.provenance.identity.key_digest) or
            !std.mem.eql(u8, &identity.memory_key, &self.provenance.identity.memory_key) or
            !digestEql(identity.source_digest, self.provenance.consent.source_digest) or
            !digestEql(identity.candidate_digest, self.provenance.consent.candidate_digest) or
            self.provenance.dlp_approval != candidate.dlp_approval)
        {
            return error.PreparedMemoryIntegrityMismatch;
        }

        const expected_integrity = deriveConsentIntegrity(
            pseudonymizer,
            self.provenance.consent.grant_digest,
            identity.source_digest,
            identity.candidate_digest,
            self.provenance.consent.policy_version,
            self.provenance.consent.granted_at_unix_ms,
            self.provenance.consent.authority,
            candidate.dlp_approval,
        );
        if (!digestEql(expected_integrity, self.provenance.consent.integrity_digest)) {
            return error.PreparedMemoryIntegrityMismatch;
        }

        return .{
            .source = source,
            .candidate = candidate,
            .provenance = .{
                .identity = identity,
                .consent = self.provenance.consent,
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
    integrity_digest: Digest,

    pub fn init(pseudonymizer: *const Pseudonymizer, user_id: i64, meeting_id: []const u8, request_id: []const u8) ValidationError!ErasureRequest {
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

        const meeting_digest = deriveMeetingDigest(pseudonymizer, user_id, meeting_id);
        const request_digest = deriveRequestDigest(pseudonymizer, meeting_digest, request_id);
        return .{
            .user_id = user_id,
            .meeting_digest = meeting_digest,
            .request_digest = request_digest,
            .integrity_digest = deriveErasureRequestIntegrity(pseudonymizer, user_id, meeting_digest, request_digest),
        };
    }

    /// Revalidate the content-free erasure authority immediately before any
    /// state lookup or tombstone write. The seal binds the authenticated user
    /// and both derived scopes so a copied or mutated value cannot pair one
    /// tenant with another tenant's meeting digest.
    pub fn validateForErase(self: ErasureRequest, pseudonymizer: *const Pseudonymizer) ValidationError!ErasureRequest {
        try validateUserId(self.user_id);
        const expected = deriveErasureRequestIntegrity(
            pseudonymizer,
            self.user_id,
            self.meeting_digest,
            self.request_digest,
        );
        if (!digestEql(expected, self.integrity_digest)) {
            return error.ErasureRequestIntegrityMismatch;
        }
        return self;
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
    erased_at_unix_us: i64,

    pub fn init(
        request: ErasureRequest,
        counts: ErasureCounts,
        disposition: ErasureDisposition,
        erased_at_unix_us: i64,
    ) ValidationError!ErasureManifest {
        if (erased_at_unix_us <= 0) return error.InvalidErasedAt;
        return .{
            .meeting_digest = request.meeting_digest,
            .request_digest = request.request_digest,
            .counts = counts,
            .disposition = disposition,
            .erased_at_unix_us = erased_at_unix_us,
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
            .erased_at_unix_us = self.erased_at_unix_us,
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

fn validateConsentEnvelope(consent: ConfirmedConsentGrant) ValidationError!void {
    try validateField(
        consent.policy_version,
        max_policy_version_bytes,
        error.EmptyPolicyVersion,
        error.PolicyVersionTooLong,
        error.PolicyVersionContainsNul,
    );
    if (!std.unicode.utf8ValidateSlice(consent.policy_version) or
        !isSafeSlug(consent.policy_version)) return error.InvalidPolicyVersion;
    if (consent.granted_at_unix_ms <= 0) return error.InvalidGrantedAt;
    if (consent.authority != .authenticated_user_control) {
        return error.PreparedMemoryIntegrityMismatch;
    }
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

fn deriveIdentity(pseudonymizer: *const Pseudonymizer, source: SourceTuple, candidate: Candidate) MemoryIdentity {
    const source_digest = deriveSourceDigest(pseudonymizer, source);
    const meeting_digest = deriveMeetingDigest(pseudonymizer, source.user_id, source.meeting_id);

    // Candidate text is meeting-derived PII and may be guessable. A plain
    // digest would act as an offline confirmation oracle in database dumps;
    // use the deployment pseudonym key just like source/scope identifiers.
    var candidate_hasher = pseudonymizer.hasher();
    updateField(&candidate_hasher, "domain", "zaki.minutes.candidate.v1");
    updateField(&candidate_hasher, "kind", @tagName(candidate.kind));
    updateField(&candidate_hasher, "text", candidate.text_value);
    var candidate_digest: Digest = undefined;
    candidate_hasher.final(&candidate_digest);

    var key_hasher = pseudonymizer.hasher();
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
        .pseudonym_key_id = pseudonymizer.key_id,
        .source_digest = source_digest,
        .meeting_digest = meeting_digest,
        .candidate_digest = candidate_digest,
        .key_digest = key_digest,
        .memory_key = key,
    };
}

fn deriveSourceDigest(pseudonymizer: *const Pseudonymizer, source: SourceTuple) Digest {
    var source_hasher = pseudonymizer.hasher();
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

fn deriveMeetingDigest(pseudonymizer: *const Pseudonymizer, user_id: i64, meeting_id: []const u8) Digest {
    var hasher = pseudonymizer.hasher();
    updateField(&hasher, "domain", "zaki.minutes.meeting-scope.v1");
    updateField(&hasher, "write_origin", write_origin);
    updateField(&hasher, "source_spoke", source_spoke);
    updateUserId(&hasher, user_id);
    updateField(&hasher, "meeting_id", meeting_id);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

/// Minimal pseudonymous account scope used by durable anti-resurrection
/// tombstones. It contains no raw meeting, transcript, candidate, or grant ID.
pub fn userScopeDigest(pseudonymizer: *const Pseudonymizer, user_id: i64) ValidationError!Digest {
    try validateUserId(user_id);
    var hasher = pseudonymizer.hasher();
    updateField(&hasher, "domain", "zaki.minutes.user-scope.v1");
    updateField(&hasher, "write_origin", write_origin);
    updateField(&hasher, "source_spoke", source_spoke);
    updateUserId(&hasher, user_id);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn derivePseudonymKeyId(key: [HmacSha256.key_length]u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&hasher, "domain", "zaki.minutes.pseudonym-key-id.v1");
    updateField(&hasher, "key", &key);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn receiptKeyId(public_key: [Ed25519.PublicKey.encoded_length]u8) Sha256Text {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateField(&hasher, "domain", "zaki.minutes.erasure-receipt-key-id.v1");
    updateField(&hasher, "public_key", &public_key);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return formatSha256(digest);
}

fn verifierKey(bytes: [Ed25519.PublicKey.encoded_length]u8) ReceiptCryptoError!ReceiptVerifierKey {
    const public_key = Ed25519.PublicKey.fromBytes(bytes) catch
        return error.InvalidReceiptPublicKey;
    return .{ .public_key = public_key, .key_id = receiptKeyId(bytes) };
}

const receipt_signing_domain = "zaki.minutes.erasure-receipt-signature.v1";
const receipt_signing_message_len = receipt_signing_domain.len + 1 + @sizeOf(Digest);

fn receiptSigningMessage(digest: Digest) [receipt_signing_message_len]u8 {
    var message: [receipt_signing_message_len]u8 = undefined;
    @memcpy(message[0..receipt_signing_domain.len], receipt_signing_domain);
    message[receipt_signing_domain.len] = 0;
    @memcpy(message[receipt_signing_domain.len + 1 ..], &digest);
    return message;
}

fn encodeLowerHex(output: []u8, bytes: []const u8) void {
    std.debug.assert(output.len == bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        output[index * 2] = alphabet[byte >> 4];
        output[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn decodeLowerHex(input: []const u8, output: []u8) error{InvalidLowerHex}!void {
    if (input.len != output.len * 2) return error.InvalidLowerHex;
    for (output, 0..) |*byte, index| {
        const high = lowerHexNibble(input[index * 2]) orelse return error.InvalidLowerHex;
        const low = lowerHexNibble(input[index * 2 + 1]) orelse return error.InvalidLowerHex;
        byte.* = (high << 4) | low;
    }
}

fn lowerHexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return null;
}

/// Recognize only keys that the dedicated Minutes writer can actually derive.
/// A prefix match would reserve arbitrary pre-existing user keys such as
/// `meeting_ingest/notes` even while the dormant feature is disabled.
pub fn isCanonicalMemoryKey(value: []const u8) bool {
    if (value.len != memory_key_len or
        !std.mem.eql(u8, value[0..memory_key_prefix.len], memory_key_prefix)) return false;
    for (value[memory_key_prefix.len..]) |byte| {
        if (lowerHexNibble(byte) == null) return false;
    }
    return true;
}

/// Detect a canonical key carried inside a larger string. Traversal payloads
/// are durable JSON and legacy callers may embed a key in prose or in a nested
/// property name, so checking only whether the whole string starts with the
/// key would leave an erasure carrier behind.
pub fn containsCanonicalMemoryKey(value: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, value, cursor, memory_key_prefix)) |start| {
        if (value.len - start >= memory_key_len and
            isCanonicalMemoryKey(value[start .. start + memory_key_len])) return true;
        cursor = start + memory_key_prefix.len;
    }
    return false;
}

fn isCanonicalSha256Text(value: []const u8) bool {
    if (value.len != sha256_text_len or
        !std.mem.eql(u8, value[0..sha256_prefix.len], sha256_prefix)) return false;
    for (value[sha256_prefix.len..]) |byte| {
        if (lowerHexNibble(byte) == null) return false;
    }
    return true;
}

fn deriveRequestDigest(pseudonymizer: *const Pseudonymizer, meeting_digest: Digest, request_id: []const u8) Digest {
    var hasher = pseudonymizer.hasher();
    updateField(&hasher, "domain", "zaki.minutes.erasure-request.v1");
    updateField(&hasher, "meeting_digest", &meeting_digest);
    updateField(&hasher, "request_id", request_id);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn deriveErasureRequestIntegrity(pseudonymizer: *const Pseudonymizer, user_id: i64, meeting_digest: Digest, request_digest: Digest) Digest {
    var hasher = pseudonymizer.hasher();
    updateField(&hasher, "domain", "zaki.minutes.erasure-request-integrity.v1");
    updateField(&hasher, "write_origin", write_origin);
    updateField(&hasher, "source_spoke", source_spoke);
    updateUserId(&hasher, user_id);
    updateField(&hasher, "meeting_digest", &meeting_digest);
    updateField(&hasher, "request_digest", &request_digest);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn deriveGrantDigest(
    pseudonymizer: *const Pseudonymizer,
    source_digest: Digest,
    candidate_digest: Digest,
    grant_id: []const u8,
    policy_version: []const u8,
    granted_at_unix_ms: i64,
    authority: ConfirmationAuthority,
    dlp_approval: DlpApproval,
) Digest {
    var hasher = pseudonymizer.hasher();
    updateField(&hasher, "domain", "zaki.minutes.consent-grant.v1");
    updateField(&hasher, "source_digest", &source_digest);
    updateField(&hasher, "candidate_digest", &candidate_digest);
    updateField(&hasher, "grant_id", grant_id);
    updateField(&hasher, "policy_version", policy_version);
    updateI64(&hasher, "granted_at_unix_ms", granted_at_unix_ms);
    updateField(&hasher, "authority", @tagName(authority));
    updateField(&hasher, "dlp_approval", @tagName(dlp_approval));
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn deriveConsentIntegrity(
    pseudonymizer: *const Pseudonymizer,
    grant_digest: Digest,
    source_digest: Digest,
    candidate_digest: Digest,
    policy_version: []const u8,
    granted_at_unix_ms: i64,
    authority: ConfirmationAuthority,
    dlp_approval: DlpApproval,
) Digest {
    var hasher = pseudonymizer.hasher();
    updateField(&hasher, "domain", "zaki.minutes.consent-integrity.v1");
    updateField(&hasher, "grant_digest", &grant_digest);
    updateField(&hasher, "source_digest", &source_digest);
    updateField(&hasher, "candidate_digest", &candidate_digest);
    updateField(&hasher, "policy_version", policy_version);
    updateI64(&hasher, "granted_at_unix_ms", granted_at_unix_ms);
    updateField(&hasher, "authority", @tagName(authority));
    updateField(&hasher, "dlp_approval", @tagName(dlp_approval));
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn updateField(hasher: anytype, label: []const u8, value: []const u8) void {
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

fn updateUserId(hasher: anytype, user_id: i64) void {
    var buffer: [20]u8 = undefined;
    const canonical = std.fmt.bufPrint(&buffer, "{d}", .{user_id}) catch unreachable;
    updateField(hasher, "user_id", canonical);
}

fn updateI64(hasher: anytype, label: []const u8, value: i64) void {
    var buffer: [20]u8 = undefined;
    const canonical = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    updateField(hasher, label, canonical);
}

fn digestEql(a: Digest, b: Digest) bool {
    return std.crypto.timing_safe.eql(Digest, a, b);
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

const test_pseudonymizer = blk: {
    @setEvalBranchQuota(100_000);
    break :blk Pseudonymizer.init([_]u8{0xa5} ** 32);
};

test "prepared meeting memory fixes provenance and derives a bounded key" {
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "transcript-7",
        .meeting_id = "meeting-9",
    });
    const candidate = try Candidate.init(.decision, "Ship the staged pilot", .approved);
    const grant = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });

    const prepared = try PreparedMemory.init(&test_pseudonymizer, source, candidate, grant);

    try std.testing.expectEqualStrings("meeting_ingest", prepared.provenance.writeOrigin());
    try std.testing.expectEqualStrings("minutes", prepared.provenance.sourceSpoke());
    try std.testing.expectEqual(@as(i64, 42), prepared.source.user_id);
    try std.testing.expectEqualStrings("transcript-7", prepared.source.source_item_id);
    try std.testing.expectEqualStrings("meeting-9", prepared.source.meeting_id);
    try std.testing.expectEqualStrings("Ship the staged pilot", prepared.candidate.text());
    try std.testing.expectEqualStrings(memory_key_prefix, prepared.provenance.identity.memoryKey()[0..memory_key_prefix.len]);
    try std.testing.expectEqual(@as(usize, memory_key_len), prepared.provenance.identity.memoryKey().len);
}

test "meeting memory key recognition is canonical and finds nested carriers" {
    const key = "meeting_ingest/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(isCanonicalMemoryKey(key));
    try std.testing.expect(containsCanonicalMemoryKey(key));
    try std.testing.expect(containsCanonicalMemoryKey("before meeting_ingest/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef after"));
    try std.testing.expect(!isCanonicalMemoryKey("meeting_ingest/notes"));
    try std.testing.expect(!isCanonicalMemoryKey("meeting_ingest/0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isCanonicalMemoryKey("meeting_ingest/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"));
    try std.testing.expect(!containsCanonicalMemoryKey("before meeting_ingest/notes after"));
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

    try std.testing.expectError(error.EmptyGrantId, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = "",
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.GrantIdContainsNul, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = "grant\x00tail",
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.GrantIdInvalidUtf8, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = &invalid_utf8,
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));
    const long_grant = [_]u8{'g'} ** (max_grant_id_bytes + 1);
    try std.testing.expectError(error.GrantIdTooLong, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = &long_grant,
        .policy_version = "v1",
        .granted_at_unix_ms = 1,
    }));

    try std.testing.expectError(error.EmptyPolicyVersion, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = " \t",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.PolicyVersionContainsNul, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = "v1\x00tail",
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.InvalidPolicyVersion, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = &invalid_utf8,
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.InvalidPolicyVersion, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = "minutes memory/v1",
        .granted_at_unix_ms = 1,
    }));
    const long_policy = [_]u8{'p'} ** (max_policy_version_bytes + 1);
    try std.testing.expectError(error.PolicyVersionTooLong, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
        .grant_id = "grant",
        .policy_version = &long_policy,
        .granted_at_unix_ms = 1,
    }));
    try std.testing.expectError(error.InvalidGrantedAt, ConfirmedConsentGrant.init(&test_pseudonymizer, valid_source, valid_candidate, .{
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
    const grant = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "grant-bound-a",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });

    _ = try PreparedMemory.init(&test_pseudonymizer, source, candidate, grant);
    try std.testing.expectError(error.ConsentSourceMismatch, PreparedMemory.init(&test_pseudonymizer, other_source, candidate, grant));
    try std.testing.expectError(error.ConsentCandidateMismatch, PreparedMemory.init(&test_pseudonymizer, source, other_candidate, grant));

    try std.testing.expect(!@hasField(ConfirmedConsentGrant, "grant_id_value"));
    try std.testing.expect(std.meta.stringToEnum(ConfirmationAuthority, "model") == null);
    try std.testing.expect(std.meta.stringToEnum(ConfirmationAuthority, "unconfirmed") == null);
}

test "store validation rejects mutable backing buffers and provenance splices" {
    var meeting_id = [_]u8{ 'm', 'e', 'e', 't', 'i', 'n', 'g', '-', 'a' };
    var candidate_text = [_]u8{ 'S', 'h', 'i', 'p', ' ', 'p', 'i', 'l', 'o', 't' };
    var policy = [_]u8{ 'm', 'i', 'n', 'u', 't', 'e', 's', '-', 'v', '1' };
    const mutable_source = try SourceTuple.init(.{
        .user_id = 7,
        .source_item_id = "item-a",
        .meeting_id = &meeting_id,
    });
    const mutable_candidate = try Candidate.init(.decision, &candidate_text, .approved);
    const mutable_grant = try ConfirmedConsentGrant.init(&test_pseudonymizer, mutable_source, mutable_candidate, .{
        .grant_id = "grant-a",
        .policy_version = &policy,
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const prepared = try PreparedMemory.init(&test_pseudonymizer, mutable_source, mutable_candidate, mutable_grant);
    _ = try prepared.validateForStore(&test_pseudonymizer);

    candidate_text[0] = 'X';
    try std.testing.expectError(error.PreparedMemoryIntegrityMismatch, prepared.validateForStore(&test_pseudonymizer));
    candidate_text[0] = 'S';
    meeting_id[meeting_id.len - 1] = 'b';
    try std.testing.expectError(error.PreparedMemoryIntegrityMismatch, prepared.validateForStore(&test_pseudonymizer));
    meeting_id[meeting_id.len - 1] = 'a';
    policy[policy.len - 1] = '2';
    try std.testing.expectError(error.PreparedMemoryIntegrityMismatch, prepared.validateForStore(&test_pseudonymizer));

    const source_b = try SourceTuple.init(.{
        .user_id = 7,
        .source_item_id = "item-b",
        .meeting_id = "meeting-b",
    });
    const candidate_b = try Candidate.init(.decision, "Do not ship pilot", .approved);
    const grant_b = try ConfirmedConsentGrant.init(&test_pseudonymizer, source_b, candidate_b, .{
        .grant_id = "grant-b",
        .policy_version = "minutes-v1",
        .granted_at_unix_ms = 1_784_200_000_001,
    });
    const prepared_b = try PreparedMemory.init(&test_pseudonymizer, source_b, candidate_b, grant_b);
    var spliced = prepared_b;
    spliced.provenance = prepared.provenance;
    try std.testing.expectError(error.PreparedMemoryIntegrityMismatch, spliced.validateForStore(&test_pseudonymizer));
}

test "grant digest binds the complete consent envelope" {
    const source = try SourceTuple.init(.{
        .user_id = 7,
        .source_item_id = "item-a",
        .meeting_id = "meeting-a",
    });
    const candidate = try Candidate.init(.decision, "Ship pilot", .approved);
    const first = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "same-grant",
        .policy_version = "minutes-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const changed_policy = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "same-grant",
        .policy_version = "minutes-v2",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const changed_time = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "same-grant",
        .policy_version = "minutes-v1",
        .granted_at_unix_ms = 1_784_200_000_001,
    });
    try std.testing.expect(!digestEql(first.grant_digest, changed_policy.grant_digest));
    try std.testing.expect(!digestEql(first.grant_digest, changed_time.grant_digest));
}

test "memory identity is retry stable source scoped and content free" {
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "raw-transcript-secret-7",
        .meeting_id = "raw-meeting-secret-9",
    });
    const candidate = try Candidate.init(.action_item, "raw candidate text that must stay private", .approved);
    const grant = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "raw-grant-secret-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const first = try PreparedMemory.init(&test_pseudonymizer, source, candidate, grant);
    const retry = try PreparedMemory.init(&test_pseudonymizer, source, candidate, grant);

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
        const changed_grant = try ConfirmedConsentGrant.init(&test_pseudonymizer, changed_source, candidate, .{
            .grant_id = "raw-grant-secret-3",
            .policy_version = "minutes-memory-v1",
            .granted_at_unix_ms = 1_784_200_000_000,
        });
        const changed = try PreparedMemory.init(&test_pseudonymizer, changed_source, candidate, changed_grant);
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
    const grant = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const prepared = try PreparedMemory.init(&test_pseudonymizer, source, candidate, grant);
    const source_text = formatSha256(prepared.provenance.identity.source_digest);
    const meeting_text = formatSha256(prepared.provenance.identity.meeting_digest);
    const candidate_text = formatSha256(prepared.provenance.identity.candidate_digest);
    const grant_text = formatSha256(prepared.provenance.consent.grant_digest);

    try std.testing.expectEqualStrings("sha256=3873c97c647019e49517b3f5e5f4c9d1f3cb36100113fb0dd9a28f5c49beb758", &source_text);
    try std.testing.expectEqualStrings("sha256=cbaa49c215656710bb71d822bb8efb9067d9e505b6184647a644757d0f630739", &meeting_text);
    try std.testing.expectEqualStrings("sha256=dab7369ecdd2b37740ef85f317a1a21f559ace88381c89ac5fc7cd92085077b6", &candidate_text);
    try std.testing.expectEqualStrings("sha256=b8c09b2b709191e93872b1f459fb7d8372e5108dfd6013b6979195edd2b8a990", &grant_text);
    try std.testing.expectEqualStrings("meeting_ingest/599ea54af8a238ce1f18d9014dd6bd57ae0f96a035b738edd07c7543923e367b", prepared.provenance.identity.memoryKey());
}

test "provenance and erasure serializers expose digests but no raw content or identifiers" {
    const allocator = std.testing.allocator;
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "never-serialize-source-item-7",
        .meeting_id = "never-serialize-meeting-9",
    });
    const candidate = try Candidate.init(.decision, "never serialize this candidate or transcript sentence", .approved);
    const grant = try ConfirmedConsentGrant.init(&test_pseudonymizer, source, candidate, .{
        .grant_id = "never-serialize-grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const prepared = try PreparedMemory.init(&test_pseudonymizer, source, candidate, grant);

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

    const request = try ErasureRequest.init(&test_pseudonymizer, source.user_id, source.meeting_id, "never-serialize-request-5");
    try std.testing.expectEqual(@as(i64, 42), request.user_id);
    try std.testing.expect(!@hasField(ErasureRequest, "meeting_id"));
    try std.testing.expect(!@hasField(ErasureRequest, "request_id"));

    const manifest = try ErasureManifest.init(request, .{
        .memory_source_links_deleted = 2,
        .memories_deleted = 2,
        .memory_events_deleted = 3,
        .working_memory_deleted = 1,
        .memory_edges_deleted = 4,
        .memory_entities_deleted = 1,
        .memory_embeddings_deleted = 2,
        .memory_vectors_deleted = 2,
    }, .erased, 1_784_200_000_123_456);
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
    try std.testing.expectError(error.InvalidUserId, ErasureRequest.init(&test_pseudonymizer, 0, "meeting-9", "request-1"));
    try std.testing.expectError(error.EmptyMeetingId, ErasureRequest.init(&test_pseudonymizer, 42, "", "request-1"));
    try std.testing.expectError(error.MeetingIdNotTrimmed, ErasureRequest.init(&test_pseudonymizer, 42, " meeting-9", "request-1"));
    try std.testing.expectError(error.MeetingIdContainsControl, ErasureRequest.init(&test_pseudonymizer, 42, "meeting\x00-9", "request-1"));
    try std.testing.expectError(error.MeetingIdInvalidUtf8, ErasureRequest.init(&test_pseudonymizer, 42, &invalid_utf8, "request-1"));
    try std.testing.expectError(error.EmptyRequestId, ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", ""));
    try std.testing.expectError(error.InvalidRequestId, ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", "request id"));
    try std.testing.expectError(error.RequestIdInvalidUtf8, ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", &invalid_utf8));
    const long_request = [_]u8{'r'} ** (max_request_id_bytes + 1);
    try std.testing.expectError(error.RequestIdTooLong, ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", &long_request));

    const first = try ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", "request-1");
    const retry = try ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", "request-1");
    const other_request = try ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", "request-2");
    const other_meeting = try ErasureRequest.init(&test_pseudonymizer, 42, "meeting-10", "request-1");
    try std.testing.expectEqualSlices(u8, &first.meeting_digest, &retry.meeting_digest);
    try std.testing.expectEqualSlices(u8, &first.request_digest, &retry.request_digest);
    try std.testing.expectEqualSlices(u8, &first.meeting_digest, &other_request.meeting_digest);
    try std.testing.expect(!std.mem.eql(u8, &first.request_digest, &other_request.request_digest));
    try std.testing.expect(!std.mem.eql(u8, &first.meeting_digest, &other_meeting.meeting_digest));
    try std.testing.expect(!std.mem.eql(u8, &first.request_digest, &other_meeting.request_digest));
}

test "erasure request seal rejects every mutable authority field" {
    const request = try ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", "request-1");
    _ = try request.validateForErase(&test_pseudonymizer);

    var changed_user = request;
    changed_user.user_id = 43;
    try std.testing.expectError(error.ErasureRequestIntegrityMismatch, changed_user.validateForErase(&test_pseudonymizer));

    var changed_meeting = request;
    changed_meeting.meeting_digest[0] ^= 0xff;
    try std.testing.expectError(error.ErasureRequestIntegrityMismatch, changed_meeting.validateForErase(&test_pseudonymizer));

    var changed_request = request;
    changed_request.request_digest[0] ^= 0xff;
    try std.testing.expectError(error.ErasureRequestIntegrityMismatch, changed_request.validateForErase(&test_pseudonymizer));
}

test "erasure manifest binds the database erasure timestamp" {
    const allocator = std.testing.allocator;
    const request = try ErasureRequest.init(&test_pseudonymizer, 42, "meeting-9", "request-1");
    const erased_at_unix_us: i64 = 1_784_200_000_123_456;
    const manifest = try ErasureManifest.init(request, .{}, .already_absent, erased_at_unix_us);
    try std.testing.expectEqual(erased_at_unix_us, manifest.erased_at_unix_us);

    const serialized = try manifest.serializeJson(allocator);
    defer allocator.free(serialized);
    try std.testing.expect(std.mem.indexOf(
        u8,
        serialized,
        "\"erased_at_unix_us\":1784200000123456",
    ) != null);

    try std.testing.expectError(
        error.InvalidErasedAt,
        ErasureManifest.init(request, .{}, .already_absent, 0),
    );
}

fn expectContentFree(serialized: []const u8, forbidden: []const []const u8) !void {
    for (forbidden) |value| {
        try std.testing.expect(std.mem.indexOf(u8, serialized, value) == null);
    }
}

test "pseudonymizer separates identical account scopes by key" {
    const first = Pseudonymizer.init([_]u8{0x11} ** 32);
    const second = Pseudonymizer.init([_]u8{0x22} ** 32);

    const first_scope = try userScopeDigest(&first, 42);
    const second_scope = try userScopeDigest(&second, 42);
    try std.testing.expect(!digestEql(first_scope, second_scope));
    try std.testing.expect(!std.mem.eql(u8, &first.keyId(), &second.keyId()));
}

test "pseudonym key separates meeting identity and seals store validation" {
    const first = Pseudonymizer.init([_]u8{0x11} ** 32);
    const second = Pseudonymizer.init([_]u8{0x22} ** 32);
    const source = try SourceTuple.init(.{
        .user_id = 42,
        .source_item_id = "transcript-7",
        .meeting_id = "meeting-9",
    });
    const candidate = try Candidate.init(.decision, "Ship the staged pilot", .approved);
    const first_grant = try ConfirmedConsentGrant.init(&first, source, candidate, .{
        .grant_id = "grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const second_grant = try ConfirmedConsentGrant.init(&second, source, candidate, .{
        .grant_id = "grant-3",
        .policy_version = "minutes-memory-v1",
        .granted_at_unix_ms = 1_784_200_000_000,
    });
    const first_prepared = try PreparedMemory.init(&first, source, candidate, first_grant);
    const second_prepared = try PreparedMemory.init(&second, source, candidate, second_grant);
    const first_request = try ErasureRequest.init(&first, source.user_id, source.meeting_id, "request-1");
    const second_request = try ErasureRequest.init(&second, source.user_id, source.meeting_id, "request-1");

    try std.testing.expect(!digestEql(first_prepared.provenance.identity.source_digest, second_prepared.provenance.identity.source_digest));
    try std.testing.expect(!digestEql(first_prepared.provenance.identity.meeting_digest, second_prepared.provenance.identity.meeting_digest));
    // Candidate text is sensitive, often low-entropy meeting PII. Its
    // persisted fingerprint must be keyed too, otherwise an operator or dump
    // reader could confirm guessed decisions/action items offline.
    try std.testing.expect(!digestEql(first_prepared.provenance.identity.candidate_digest, second_prepared.provenance.identity.candidate_digest));
    try std.testing.expect(!digestEql(first_grant.grant_digest, second_grant.grant_digest));
    try std.testing.expect(!digestEql(first_grant.integrity_digest, second_grant.integrity_digest));
    try std.testing.expect(!digestEql(first_request.meeting_digest, second_request.meeting_digest));
    try std.testing.expect(!digestEql(first_request.request_digest, second_request.request_digest));
    try std.testing.expect(!digestEql(first_request.integrity_digest, second_request.integrity_digest));
    try std.testing.expect(!std.mem.eql(u8, first_prepared.provenance.identity.memoryKey(), second_prepared.provenance.identity.memoryKey()));
    try std.testing.expectError(error.PreparedMemoryIntegrityMismatch, first_prepared.validateForStore(&second));
    try std.testing.expectError(error.ErasureRequestIntegrityMismatch, first_request.validateForErase(&second));
}

test "erasure receipt signatures verify current and secondary keys only" {
    const current = try ErasureReceiptSigner.init([_]u8{0x31} ** 32);
    const secondary = try ErasureReceiptSigner.init([_]u8{0x27} ** 32);
    const keyring = try ErasureReceiptVerifierKeyring.init(
        current.publicKeyBytes(),
        secondary.publicKeyBytes(),
    );
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("canonical receipt", &digest, .{});

    const current_receipt = try current.signDigest(digest);
    const secondary_receipt = try secondary.signDigest(digest);
    try keyring.verifyDigest(digest, current_receipt.keyId(), current_receipt.signatureText());
    try keyring.verifyDigest(digest, secondary_receipt.keyId(), secondary_receipt.signatureText());
    try std.testing.expect(keyring.recognizesKeyId(current_receipt.keyId()));
    try std.testing.expect(keyring.recognizesKeyId(secondary_receipt.keyId()));

    var tampered = digest;
    tampered[0] ^= 0xff;
    try std.testing.expectError(
        error.ReceiptSignatureVerificationFailed,
        keyring.verifyDigest(tampered, current_receipt.keyId(), current_receipt.signatureText()),
    );
    try std.testing.expectError(
        error.ReceiptSignatureVerificationFailed,
        keyring.verifyDigest(digest, secondary_receipt.keyId(), current_receipt.signatureText()),
    );
    var unknown_key_id = current_receipt.key_id;
    unknown_key_id[unknown_key_id.len - 1] = if (unknown_key_id[unknown_key_id.len - 1] == '0') '1' else '0';
    try std.testing.expectError(
        error.UnknownReceiptKeyId,
        keyring.verifyDigest(digest, &unknown_key_id, current_receipt.signatureText()),
    );
    try std.testing.expect(!keyring.recognizesKeyId(&unknown_key_id));
    var noncanonical_signature = current_receipt.signature;
    noncanonical_signature[noncanonical_signature.len - 1] = 'A';
    try std.testing.expectError(
        error.InvalidReceiptSignature,
        keyring.verifyDigest(digest, current_receipt.keyId(), &noncanonical_signature),
    );
    try std.testing.expect(!@hasDecl(ErasureReceiptVerifierKeyring, "signDigest"));
}
