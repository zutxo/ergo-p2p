//! Conformance test vectors from Ergo Scala reference implementation.
//!
//! These test vectors are extracted from the Ergo reference implementation tests
//! to ensure byte-perfect protocol compatibility:
//! - HandshakeSpecification.scala
//! - InvSpecification.scala
//! - ModifiersSpecification.scala
//! - RequestModifiersSpecification.scala

const std = @import("std");
const root = @import("ergo_p2p.zig");

// ============================================================================
// Handshake Test Vectors
// ============================================================================

/// Handshake test vector from HandshakeSpecification.scala
pub const handshake = struct {
    /// Full handshake bytes (hex decoded)
    pub const bytes = [_]u8{
        0xbc, 0xd2, 0x91, 0x9c, 0xee, 0x2e, // time (partial - 1610134874428)
        0x07, // agent name length
        'e', 'r', 'g', 'o', 'r', 'e', 'f', // agent name
        0x03, 0x03, 0x06, // version 3.3.6
        0x12, // node name length (18)
        'e', 'r', 'g', 'o', '-', 'm', 'a', 'i', 'n', 'n', 'e', 't', '-', '3', '.', '3', '.', '6',
        0x00, // no public address
        0x02, // 2 features
        // Feature 1: Mode (ID 16)
        0x10, 0x00, 0x04, 0x00, 0x01, 0x00, 0x01,
        // Feature 2: Local Address (ID 2)
        0x02, 0x06, 0x7f, 0x00, 0x00, 0x01, 0xae, 0x46,
    };

    /// Expected timestamp in milliseconds
    pub const time: u64 = 1610134874428;

    /// Expected agent name
    pub const agent_name = "ergoref";

    /// Expected version
    pub const version = root.Version{ .major = 3, .minor = 3, .patch = 6 };

    /// Expected node name
    pub const node_name = "ergo-mainnet-3.3.6";

    /// Expected feature count
    pub const feature_count: u8 = 2;
};

// ============================================================================
// Message Frame Test Vectors
// ============================================================================

/// Inv message test vector from InvSpecification.scala
pub const inv_message = struct {
    /// Full message including header and payload
    pub const full_bytes = [_]u8{
        // Header (13 bytes)
        0x01, 0x00, 0x02, 0x04, // mainnet magic
        0x37, // message code (55 = Inv)
        0x00, 0x00, 0x00, 0x22, // length (34 bytes)
        0x6a, 0xbf, 0xdb, 0xf5, // checksum
        // Payload
        0x65, // type ID (101 = Header)
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, // ID 1 (partial)
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, // 32 bytes total for ID
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, // ID 2
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        0x02, 0x02,
    };

    /// Network magic bytes
    pub const magic = [4]u8{ 0x01, 0x00, 0x02, 0x04 };

    /// Message code (Inv = 55)
    pub const code: u8 = 55;

    /// Payload length
    pub const length: u32 = 34;

    /// Expected checksum (first 4 bytes of Blake2b256)
    pub const checksum = [4]u8{ 0x6a, 0xbf, 0xdb, 0xf5 };

    /// Modifier type (Header = 101)
    pub const type_id = root.ModifierType.Header;
};

/// RequestModifier message test vector
pub const request_modifier_message = struct {
    /// Full message including header and payload
    pub const full_bytes = [_]u8{
        // Header (13 bytes)
        0x01, 0x00, 0x02, 0x04, // mainnet magic
        0x16, // message code (22 = ModifierRequest)
        0x00, 0x00, 0x00, 0x22, // length (34 bytes)
        0x6a, 0xbf, 0xdb, 0xf5, // checksum
        // Payload (same as Inv)
        0x65, // type ID (101 = Header)
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01,
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        0x02, 0x02,
    };

    /// Message code (ModifierRequest = 22)
    pub const code: u8 = 22;
};

// ============================================================================
// Network Constants
// ============================================================================

/// Network magic bytes
pub const network_magic = struct {
    pub const mainnet = [4]u8{ 0x01, 0x00, 0x02, 0x04 };
    pub const testnet = [4]u8{ 0x02, 0x00, 0x02, 0x03 };
};

/// Protocol version requirements
pub const version_requirements = struct {
    /// Minimum version for EIP-37 hard fork compliance
    pub const min_eip37 = root.Version{ .major = 4, .minor = 0, .patch = 100 };

    /// JIT soft fork version
    pub const jit_softfork = root.Version{ .major = 5, .minor = 0, .patch = 0 };

    /// UTXO snapshot activation version
    pub const utxo_snapshot = root.Version{ .major = 5, .minor = 0, .patch = 12 };

    /// NiPoPoW activation version
    pub const nipopow = root.Version{ .major = 5, .minor = 0, .patch = 13 };
};

// ============================================================================
// Protocol Constants
// ============================================================================

pub const protocol = struct {
    /// Maximum handshake size in bytes
    pub const max_handshake_size: usize = 8096;

    /// Maximum inventory objects per message
    pub const max_inv_objects: usize = 400;

    /// Maximum modifiers message size (with 4x reserve for ADProofs)
    pub const max_modifiers_size: usize = 8_194_304;

    /// Frame header size: magic(4) + code(1) + length(4) + checksum(4)
    pub const frame_header_size: usize = 13;

    /// Checksum size (first 4 bytes of Blake2b256)
    pub const checksum_size: usize = 4;
};

// ============================================================================
// Message Codes
// ============================================================================

pub const message_codes = struct {
    pub const GetPeers: u8 = 1;
    pub const Peers: u8 = 2;
    pub const RequestModifier: u8 = 22;
    pub const Modifiers: u8 = 33;
    pub const Inv: u8 = 55;
    pub const SyncInfo: u8 = 65;
    pub const Handshake: u8 = 75;
    pub const GetSnapshotsInfo: u8 = 76;
    pub const SnapshotsInfo: u8 = 77;
    pub const GetManifest: u8 = 78;
    pub const Manifest: u8 = 79;
    pub const GetUtxoSnapshotChunk: u8 = 80;
    pub const UtxoSnapshotChunk: u8 = 81;
    pub const GetNipopowProof: u8 = 90;
    pub const NipopowProof: u8 = 91;
};

// ============================================================================
// Conformance Tests
// ============================================================================

test "network magic matches reference" {
    try std.testing.expectEqual(network_magic.mainnet, root.NetworkMagic.mainnet);
    try std.testing.expectEqual(network_magic.testnet, root.NetworkMagic.testnet);
}

test "message codes match reference" {
    try std.testing.expectEqual(message_codes.GetPeers, @intFromEnum(root.MessageCode.GetPeers));
    try std.testing.expectEqual(message_codes.Peers, @intFromEnum(root.MessageCode.Peers));
    try std.testing.expectEqual(message_codes.RequestModifier, @intFromEnum(root.MessageCode.ModifierRequest));
    try std.testing.expectEqual(message_codes.Modifiers, @intFromEnum(root.MessageCode.ModifierResponse));
    try std.testing.expectEqual(message_codes.Inv, @intFromEnum(root.MessageCode.Inv));
    try std.testing.expectEqual(message_codes.SyncInfo, @intFromEnum(root.MessageCode.SyncInfo));
}

test "frame header size matches reference" {
    try std.testing.expectEqual(protocol.frame_header_size, root.FrameHeaderSize);
}

test "inv message checksum matches reference" {
    // Extract payload from test vector (after header)
    const payload = inv_message.full_bytes[13..];

    // Compute checksum
    const computed = root.blake2b.checksum(payload);

    try std.testing.expectEqual(inv_message.checksum, computed);
}

test "version comparison for EIP-37 compliance" {
    const v1 = root.Version{ .major = 4, .minor = 0, .patch = 99 };
    const v2 = root.Version{ .major = 4, .minor = 0, .patch = 100 };
    const v3 = root.Version{ .major = 5, .minor = 0, .patch = 0 };

    // v1 < min_eip37
    try std.testing.expect(v1.compare(version_requirements.min_eip37) < 0);
    // v2 == min_eip37
    try std.testing.expect(v2.compare(version_requirements.min_eip37) == 0);
    // v3 > min_eip37
    try std.testing.expect(v3.compare(version_requirements.min_eip37) > 0);
}
