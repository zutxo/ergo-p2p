//! Blake2b-256 hashing for Ergo protocol.
//!
//! Ergo uses Blake2b-256 for:
//! - Message checksums (first 4 bytes of hash)
//! - Modifier IDs (full 32-byte hash)
//! - Transaction IDs
//! - Header IDs

const std = @import("std");

/// Blake2b with 256-bit output from Zig standard library.
pub const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Computes Blake2b-256 hash of the input data.
pub fn hash(data: []const u8) [32]u8 {
    var h = Blake2b256.init(.{});
    h.update(data);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// Computes Blake2b-256 hash and returns first 4 bytes (checksum).
pub fn checksum(data: []const u8) [4]u8 {
    const h = hash(data);
    return h[0..4].*;
}

/// Computes modifier ID (Blake2b-256 hash).
pub fn modifierId(data: []const u8) [32]u8 {
    return hash(data);
}

/// Computes transaction ID (Blake2b-256 hash of serialized tx).
pub fn transactionId(data: []const u8) [32]u8 {
    return hash(data);
}

/// Computes header ID (Blake2b-256 hash of serialized header).
pub fn headerId(data: []const u8) [32]u8 {
    return hash(data);
}

/// Converts a 32-byte hash to a hex string.
pub fn hashToHex(h: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

/// Converts a hex string to a 32-byte hash.
pub fn hexToHash(hex: []const u8) ![32]u8 {
    if (hex.len != 64) {
        return error.InvalidHexLength;
    }
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, hex) catch return error.InvalidHexCharacter;
    return result;
}

/// Streaming hasher for incremental hashing.
pub const Hasher = struct {
    state: Blake2b256,

    pub fn init() Hasher {
        return .{ .state = Blake2b256.init(.{}) };
    }

    pub fn update(self: *Hasher, data: []const u8) void {
        self.state.update(data);
    }

    pub fn final(self: *Hasher) [32]u8 {
        var out: [32]u8 = undefined;
        self.state.final(&out);
        return out;
    }

    pub fn finalChecksum(self: *Hasher) [4]u8 {
        const h = self.final();
        return h[0..4].*;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "blake2b-256 empty string" {
    const result = hash("");
    const expected = "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8";
    const hex = hashToHex(result);
    try std.testing.expectEqualStrings(expected, &hex);
}

test "blake2b-256 test vector" {
    const result = hash("abc");
    const expected = "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319";
    const hex = hashToHex(result);
    try std.testing.expectEqualStrings(expected, &hex);
}

test "blake2b-256 longer input" {
    const input = "The quick brown fox jumps over the lazy dog";
    const result = hash(input);
    const expected = "01718cec35cd3d796dd00020e0bfecb473ad23457d063b75eff29c0ffa2e58a9";
    const hex = hashToHex(result);
    try std.testing.expectEqualStrings(expected, &hex);
}

test "checksum returns first 4 bytes" {
    const full = hash("test");
    const cs = checksum("test");
    try std.testing.expectEqual(full[0], cs[0]);
    try std.testing.expectEqual(full[1], cs[1]);
    try std.testing.expectEqual(full[2], cs[2]);
    try std.testing.expectEqual(full[3], cs[3]);
}

test "hex to hash round trip" {
    const original = hash("roundtrip");
    const hex = hashToHex(original);
    const restored = try hexToHash(&hex);
    try std.testing.expectEqual(original, restored);
}

test "streaming hasher" {
    var h = Hasher.init();
    h.update("Hello, ");
    h.update("Ergo!");
    const result1 = h.final();

    const result2 = hash("Hello, Ergo!");
    try std.testing.expectEqual(result1, result2);
}
