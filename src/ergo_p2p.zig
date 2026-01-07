//! Ergo P2P Protocol Implementation
//!
//! This module provides the core types and serialization for the Ergo
//! blockchain peer-to-peer protocol.
//!
//! Example - Connect to a node and receive messages:
//!
//!     const ergo = @import("ergo_p2p");
//!
//!     var conn = ergo.Connection.init(allocator, ergo.NetworkMagic.mainnet, local_peer);
//!     defer conn.deinit();
//!
//!     try conn.connectTo("213.239.193.208", 9030);
//!     try conn.performHandshake();
//!
//!     while (conn.isConnected()) {
//!         if (try conn.receiveMessageTimeout(1000)) |msg| {
//!             defer msg.deinit();
//!             // Process message...
//!         }
//!     }
//!
//! Example - Broadcast a transaction:
//!
//!     var pool = ergo.Pool.initWithDiscovery(allocator, network, peer, &discovery);
//!     defer pool.deinit();
//!
//!     _ = try pool.connectFromDiscovery(8);
//!     const result = try pool.broadcastModifierIds(.Transaction, &tx_ids, .all);
//!

const std = @import("std");
pub const vlq = @import("vlq.zig");
pub const blake2b = @import("blake2b.zig");
pub const connection = @import("connection.zig");
pub const platform = @import("platform.zig");
pub const modifiers = @import("modifiers.zig");
pub const discovery = @import("discovery.zig");
pub const pool = @import("pool.zig");
pub const explorer = @import("explorer.zig");
pub const test_vectors = @import("test_vectors.zig");

// Re-export key modifier types
pub const Header = modifiers.Header;
pub const AutolykosSolution = modifiers.AutolykosSolution;
pub const HeaderVersion = modifiers.HeaderVersion;
pub const ParsedModifier = modifiers.ParsedModifier;
pub const parseModifier = modifiers.parseModifier;
pub const Transaction = modifiers.Transaction;
pub const Input = modifiers.Input;
pub const BoxCandidate = modifiers.BoxCandidate;
pub const Token = modifiers.Token;
pub const SpendingProof = modifiers.SpendingProof;

// Re-export discovery types
pub const Discovery = discovery.Discovery;
pub const PeerInfo = discovery.PeerInfo;
pub const PeerSource = discovery.PeerSource;
pub const PeerState = discovery.PeerState;

// Re-export pool types
pub const Pool = pool.Pool;
pub const BroadcastStrategy = pool.BroadcastStrategy;
pub const BroadcastResult = pool.BroadcastResult;
pub const PoolConnectionInfo = pool.ConnectionInfo;
pub const PoolConnectionState = pool.ConnectionState;

// Re-export connection types
pub const Connection = connection.Connection;

// Re-export explorer types
pub const Explorer = explorer.Explorer;
pub const ExplorerConfig = explorer.Config;

// ============================================================================
// Network Constants
// ============================================================================

/// Network magic bytes for identifying network type.
pub const NetworkMagic = struct {
    pub const mainnet: [4]u8 = .{ 1, 0, 2, 4 };
    pub const testnet: [4]u8 = .{ 2, 0, 2, 3 };

    pub fn name(magic: [4]u8) []const u8 {
        if (std.mem.eql(u8, &magic, &mainnet)) return "mainnet";
        if (std.mem.eql(u8, &magic, &testnet)) return "testnet";
        return "unknown";
    }
};

/// Default protocol version (matches ergonnection-go).
pub const DefaultVersion = Version{ .major = 5, .minor = 0, .patch = 24 };

/// Default agent name.
pub const DefaultAgentName = "ergo-p2p";

/// Basic feature set for protocol negotiation.
/// Specifies: UTXO state, transaction verification, no PoPoW suffix, 1 block stored.
pub const BasicFeatureSet = [_]Feature{
    .{ .id = 16, .data = &.{ 0, 1, 0, 1 } },
};

// ============================================================================
// Message Codes
// ============================================================================

/// Protocol message codes.
pub const MessageCode = enum(u8) {
    GetPeers = 1,
    Peers = 2,
    ModifierRequest = 22,
    ModifierResponse = 33,
    Inv = 55,
    SyncInfo = 65,
    _,

    pub fn name(self: MessageCode) []const u8 {
        return switch (self) {
            .GetPeers => "GetPeers",
            .Peers => "Peers",
            .ModifierRequest => "ModifierRequest",
            .ModifierResponse => "ModifierResponse",
            .Inv => "Inv",
            .SyncInfo => "SyncInfo",
            _ => "Unknown",
        };
    }
};

/// Modifier type IDs.
pub const ModifierType = enum(u8) {
    Transaction = 2,
    BlockTransactions = 102,
    ADProofs = 104,
    Extension = 108,
    Header = 101,
    _,

    pub fn name(self: ModifierType) []const u8 {
        return switch (self) {
            .Transaction => "Transaction",
            .Header => "Header",
            .BlockTransactions => "BlockTransactions",
            .ADProofs => "ADProofs",
            .Extension => "Extension",
            _ => "Unknown",
        };
    }
};

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    InvalidMagic,
    InvalidChecksum,
    InvalidMessageCode,
    PayloadTooLarge,
    StringTooLong,
    InvalidVersion,
    EndOfStream,
    UnexpectedEof,
    OutOfMemory,
} || vlq.Error;

// ============================================================================
// Version
// ============================================================================

/// Semantic version with major, minor, and patch components.
pub const Version = struct {
    major: u8,
    minor: u8,
    patch: u8,

    /// Parses a version string in "major.minor.patch" format.
    pub fn parse(str: []const u8) !Version {
        var it = std.mem.splitScalar(u8, str, '.');
        const major_str = it.next() orelse return Error.InvalidVersion;
        const minor_str = it.next() orelse return Error.InvalidVersion;
        const patch_str = it.next() orelse return Error.InvalidVersion;
        if (it.next() != null) return Error.InvalidVersion;

        return .{
            .major = std.fmt.parseInt(u8, major_str, 10) catch return Error.InvalidVersion,
            .minor = std.fmt.parseInt(u8, minor_str, 10) catch return Error.InvalidVersion,
            .patch = std.fmt.parseInt(u8, patch_str, 10) catch return Error.InvalidVersion,
        };
    }

    /// Formats version as "major.minor.patch".
    pub fn format(self: Version, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }

    /// Compares two versions. Returns -1, 0, or 1.
    pub fn compare(self: Version, other: Version) i2 {
        if (self.major != other.major) {
            return if (self.major < other.major) -1 else 1;
        }
        if (self.minor != other.minor) {
            return if (self.minor < other.minor) -1 else 1;
        }
        if (self.patch != other.patch) {
            return if (self.patch < other.patch) -1 else 1;
        }
        return 0;
    }

    pub fn serialize(self: Version, w: anytype) !void {
        try w.writeByte(self.major);
        try w.writeByte(self.minor);
        try w.writeByte(self.patch);
    }

    pub fn deserialize(r: anytype) !Version {
        return .{
            .major = try r.readByte(),
            .minor = try r.readByte(),
            .patch = try r.readByte(),
        };
    }
};

// ============================================================================
// Feature
// ============================================================================

/// Peer capability flag with variable-length data.
pub const Feature = struct {
    id: u8,
    data: []const u8,

    pub fn serialize(self: Feature, w: anytype) !void {
        try w.writeByte(self.id);
        try w.writeUnsignedShort(@truncate(self.data.len));
        try w.write(self.data);
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Feature {
        const id = try r.readByte();
        const length = try r.readUnsignedShort();
        const data = try r.readNBytes(allocator, length);
        return .{ .id = id, .data = data };
    }

    pub fn deinit(self: *Feature, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

// ============================================================================
// Address
// ============================================================================

/// Network address (IPv4 or IPv6 with port).
pub const Address = struct {
    ip: []const u8, // 4 bytes for IPv4, 16 bytes for IPv6
    port: u16,

    pub fn isIPv4(self: Address) bool {
        return self.ip.len == 4;
    }

    pub fn isIPv6(self: Address) bool {
        return self.ip.len == 16;
    }

    pub fn format(self: Address, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.isIPv4()) {
            try writer.print("{d}.{d}.{d}.{d}:{d}", .{
                self.ip[0], self.ip[1], self.ip[2], self.ip[3], self.port,
            });
        } else {
            try writer.print("[{x}]:{d}", .{ std.fmt.fmtSliceHexLower(self.ip), self.port });
        }
    }

    pub fn serialize(self: Address, w: anytype) !void {
        // Protocol encodes length as addressLength + 4
        try w.writeByte(@truncate(self.ip.len + 4));
        try w.write(self.ip);
        try w.writeUnsignedInt(@as(u32, self.port));
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Address {
        const address_length = try r.readByte();
        const ip_length = address_length - 4;
        const ip = try r.readNBytes(allocator, ip_length);
        const port: u16 = @truncate(try r.readUnsignedInt());
        return .{ .ip = ip, .port = port };
    }

    pub fn deinit(self: *Address, allocator: std.mem.Allocator) void {
        allocator.free(self.ip);
    }
};

// ============================================================================
// Peer
// ============================================================================

/// Information about a peer node in the Ergo network.
pub const Peer = struct {
    agent_name: []const u8,
    peer_name: []const u8,
    version: Version,
    features: []Feature,
    public_address: ?Address,

    allocator: ?std.mem.Allocator = null,

    pub fn init(
        agent_name: []const u8,
        peer_name: []const u8,
        version: Version,
        features: []const Feature,
    ) !Peer {
        if (agent_name.len > 255) return Error.StringTooLong;
        if (peer_name.len > 255) return Error.StringTooLong;
        return .{
            .agent_name = agent_name,
            .peer_name = peer_name,
            .version = version,
            .features = @constCast(features),
            .public_address = null,
        };
    }

    /// Creates a default peer for connection.
    pub fn default() Peer {
        return .{
            .agent_name = DefaultAgentName,
            .peer_name = DefaultAgentName,
            .version = DefaultVersion,
            .features = @constCast(&BasicFeatureSet),
            .public_address = null,
        };
    }

    pub fn hasPublicAddress(self: Peer) bool {
        return self.public_address != null;
    }

    pub fn serialize(self: Peer, w: anytype) !void {
        // Agent name (length-prefixed UTF-8)
        try w.writeByte(@truncate(self.agent_name.len));
        try w.write(self.agent_name);

        // Version (3 bytes)
        try self.version.serialize(w);

        // Peer name (length-prefixed UTF-8)
        try w.writeByte(@truncate(self.peer_name.len));
        try w.write(self.peer_name);

        // Public address
        try w.writeBoolean(self.hasPublicAddress());
        if (self.public_address) |addr| {
            try addr.serialize(w);
        }

        // Features
        try w.writeByte(@truncate(self.features.len));
        for (self.features) |feature| {
            try feature.serialize(w);
        }
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Peer {
        // Agent name
        const agent_name_len = try r.readByte();
        const agent_name = try r.readNBytes(allocator, agent_name_len);
        errdefer allocator.free(agent_name);

        // Version
        const version = try Version.deserialize(r);

        // Peer name
        const peer_name_len = try r.readByte();
        const peer_name = try r.readNBytes(allocator, peer_name_len);
        errdefer allocator.free(peer_name);

        // Public address
        const has_public_address = try r.readBoolean();
        var public_address: ?Address = null;
        if (has_public_address) {
            public_address = try Address.deserialize(r, allocator);
        }
        errdefer if (public_address) |*addr| addr.deinit(allocator);

        // Features
        const feature_count = try r.readByte();
        var features = try allocator.alloc(Feature, feature_count);
        errdefer allocator.free(features);

        var i: usize = 0;
        errdefer for (features[0..i]) |*f| f.deinit(allocator);
        while (i < feature_count) : (i += 1) {
            features[i] = try Feature.deserialize(r, allocator);
        }

        return .{
            .agent_name = agent_name,
            .peer_name = peer_name,
            .version = version,
            .features = features,
            .public_address = public_address,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Peer) void {
        if (self.allocator) |allocator| {
            allocator.free(self.agent_name);
            allocator.free(self.peer_name);
            for (self.features) |*f| {
                f.deinit(allocator);
            }
            allocator.free(self.features);
            if (self.public_address) |*addr| {
                addr.deinit(allocator);
            }
        }
    }
};

// ============================================================================
// Message Frame
// ============================================================================

/// Message frame header size: magic(4) + code(1) + length(4) + checksum(4) = 13 bytes.
pub const FrameHeaderSize = 13;

/// Maximum payload size (4MB).
pub const MaxPayloadSize = 4 * 1024 * 1024;

/// Protocol message frame.
pub const Frame = struct {
    magic: [4]u8,
    code: MessageCode,
    length: u32,
    checksum: [4]u8,
    payload: []const u8,

    /// Creates a frame from a message payload.
    pub fn create(magic: [4]u8, code: MessageCode, payload: []const u8) Frame {
        return .{
            .magic = magic,
            .code = code,
            .length = @truncate(payload.len),
            .checksum = blake2b.checksum(payload),
            .payload = payload,
        };
    }

    /// Verifies the checksum matches the payload.
    pub fn verifyChecksum(self: Frame) bool {
        const expected = blake2b.checksum(self.payload);
        return std.mem.eql(u8, &self.checksum, &expected);
    }

    /// Serializes the frame to a writer.
    pub fn serialize(self: Frame, writer: anytype) !void {
        try writer.writeAll(&self.magic);
        try writer.writeByte(@intFromEnum(self.code));
        try writer.writeInt(u32, self.length, .big);
        try writer.writeAll(&self.checksum);
        try writer.writeAll(self.payload);
    }

    /// Deserializes a frame header (not including payload).
    pub fn deserializeHeader(reader: anytype, expected_magic: [4]u8) !Frame {
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &expected_magic)) {
            return Error.InvalidMagic;
        }

        const code_byte = try reader.readByte();
        const code: MessageCode = @enumFromInt(code_byte);
        const length = try reader.readInt(u32, .big);

        if (length > MaxPayloadSize) {
            return Error.PayloadTooLarge;
        }

        var checksum: [4]u8 = undefined;
        _ = try reader.readAll(&checksum);

        return .{
            .magic = magic,
            .code = code,
            .length = length,
            .checksum = checksum,
            .payload = &.{},
        };
    }

    /// Deserializes a complete frame including payload.
    pub fn deserialize(reader: anytype, expected_magic: [4]u8, allocator: std.mem.Allocator) !struct { frame: Frame, owned_payload: []u8 } {
        var frame = try deserializeHeader(reader, expected_magic);
        const payload = try allocator.alloc(u8, frame.length);
        errdefer allocator.free(payload);

        _ = try reader.readAll(payload);
        frame.payload = payload;

        return .{ .frame = frame, .owned_payload = payload };
    }
};

// ============================================================================
// Messages
// ============================================================================

/// GetPeers message - requests peer list from connected peer.
pub const GetPeers = struct {
    pub const code = MessageCode.GetPeers;

    pub fn serialize(_: GetPeers, _: anytype) !void {
        // Empty payload
    }

    pub fn toBytes(_: GetPeers, _: std.mem.Allocator) ![]u8 {
        return &.{};
    }

    pub fn deserialize(_: anytype) GetPeers {
        return .{};
    }
};

/// Peers message - response containing peer list.
pub const Peers = struct {
    peer_list: []Peer,
    allocator: ?std.mem.Allocator = null,

    pub const code = MessageCode.Peers;

    pub fn serialize(self: Peers, w: anytype) !void {
        try w.writeInt(@as(i32, @intCast(self.peer_list.len)));
        for (self.peer_list) |peer| {
            try peer.serialize(w);
        }
    }

    pub fn toBytes(self: Peers, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = vlq.writer(buf.writer());
        try self.serialize(&w);
        return buf.toOwnedSlice();
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Peers {
        const count = try r.readInt();
        if (count < 0) return Error.OutOfMemory;

        var peers = try allocator.alloc(Peer, @intCast(count));
        errdefer allocator.free(peers);

        var i: usize = 0;
        errdefer for (peers[0..i]) |*p| p.deinit();
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            peers[i] = try Peer.deserialize(r, allocator);
        }

        return .{ .peer_list = peers, .allocator = allocator };
    }

    pub fn deinit(self: *Peers) void {
        if (self.allocator) |allocator| {
            for (self.peer_list) |*p| {
                p.deinit();
            }
            allocator.free(self.peer_list);
        }
    }
};

/// Inv message - inventory announcement.
pub const Inv = struct {
    type_id: ModifierType,
    elements: [][32]u8,
    allocator: ?std.mem.Allocator = null,

    pub const code = MessageCode.Inv;

    pub fn serialize(self: Inv, w: anytype) !void {
        try w.writeByte(@intFromEnum(self.type_id));
        try w.writeUnsignedInt(@truncate(self.elements.len));
        for (self.elements) |element| {
            try w.write(&element);
        }
    }

    pub fn toBytes(self: Inv, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = vlq.writer(buf.writer());
        try self.serialize(&w);
        return buf.toOwnedSlice();
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Inv {
        const type_id: ModifierType = @enumFromInt(try r.readByte());
        const count = try r.readUnsignedInt();

        const elements = try allocator.alloc([32]u8, count);
        errdefer allocator.free(elements);

        for (elements) |*element| {
            try r.readFully(element);
        }

        return .{ .type_id = type_id, .elements = elements, .allocator = allocator };
    }

    pub fn deinit(self: *Inv) void {
        if (self.allocator) |allocator| {
            allocator.free(self.elements);
        }
    }
};

/// ModifierRequest message - request for modifier data.
pub const ModifierRequest = struct {
    type_id: ModifierType,
    elements: [][32]u8,
    allocator: ?std.mem.Allocator = null,

    pub const code = MessageCode.ModifierRequest;

    pub fn serialize(self: ModifierRequest, w: anytype) !void {
        try w.writeByte(@intFromEnum(self.type_id));
        try w.writeUnsignedInt(@truncate(self.elements.len));
        for (self.elements) |element| {
            try w.write(&element);
        }
    }

    pub fn toBytes(self: ModifierRequest, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = vlq.writer(buf.writer());
        try self.serialize(&w);
        return buf.toOwnedSlice();
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !ModifierRequest {
        const type_id: ModifierType = @enumFromInt(try r.readByte());
        const count = try r.readUnsignedInt();

        const elements = try allocator.alloc([32]u8, count);
        errdefer allocator.free(elements);

        for (elements) |*element| {
            try r.readFully(element);
        }

        return .{ .type_id = type_id, .elements = elements, .allocator = allocator };
    }

    pub fn deinit(self: *ModifierRequest) void {
        if (self.allocator) |allocator| {
            allocator.free(self.elements);
        }
    }
};

/// Raw modifier data (for unknown or unparsed modifiers).
pub const RawModifier = struct {
    type_id: ModifierType,
    id: [32]u8,
    data: []const u8,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *RawModifier) void {
        if (self.allocator) |allocator| {
            allocator.free(self.data);
        }
    }
};

/// ModifierResponse message - response containing modifier data.
pub const ModifierResponse = struct {
    type_id: ModifierType,
    modifiers: []RawModifier,
    allocator: ?std.mem.Allocator = null,

    pub const code = MessageCode.ModifierResponse;

    pub fn serialize(self: ModifierResponse, w: anytype) !void {
        try w.writeByte(@intFromEnum(self.type_id));
        try w.writeUnsignedInt(@truncate(self.modifiers.len));
        for (self.modifiers) |modifier| {
            try w.write(&modifier.id);
            try w.writeUnsignedInt(@truncate(modifier.data.len));
            try w.write(modifier.data);
        }
    }

    pub fn toBytes(self: ModifierResponse, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = vlq.writer(buf.writer());
        try self.serialize(&w);
        return buf.toOwnedSlice();
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !ModifierResponse {
        const type_id: ModifierType = @enumFromInt(try r.readSignedByte());
        const count = try r.readUnsignedInt();

        const raw_mods = try allocator.alloc(RawModifier, count);
        errdefer allocator.free(raw_mods);

        var i: usize = 0;
        errdefer for (raw_mods[0..i]) |*m| m.deinit();
        while (i < count) : (i += 1) {
            var id: [32]u8 = undefined;
            try r.readFully(&id);
            const data_length = try r.readUnsignedInt();
            const data = try r.readNBytes(allocator, data_length);

            raw_mods[i] = .{
                .type_id = type_id,
                .id = id,
                .data = data,
                .allocator = allocator,
            };
        }

        return .{ .type_id = type_id, .modifiers = raw_mods, .allocator = allocator };
    }

    pub fn deinit(self: *ModifierResponse) void {
        if (self.allocator) |allocator| {
            for (self.modifiers) |*m| {
                m.deinit();
            }
            allocator.free(self.modifiers);
        }
    }
};

/// SyncInfo message (old format) - announces our sync state.
pub const SyncInfo = struct {
    last_header_ids: [][32]u8,
    allocator: ?std.mem.Allocator = null,

    pub const code = MessageCode.SyncInfo;

    /// Creates an empty SyncInfo (we have no headers).
    pub fn empty() SyncInfo {
        return .{ .last_header_ids = &.{} };
    }

    pub fn serialize(self: SyncInfo, w: anytype) !void {
        try w.writeUnsignedShort(@truncate(self.last_header_ids.len));
        for (self.last_header_ids) |id| {
            try w.write(&id);
        }
    }

    pub fn toBytes(self: SyncInfo, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = vlq.writer(buf.writer());
        try self.serialize(&w);
        return buf.toOwnedSlice();
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !SyncInfo {
        const count = try r.readUnsignedShort();
        const ids = try allocator.alloc([32]u8, count);
        errdefer allocator.free(ids);

        for (ids) |*id| {
            try r.readFully(id);
        }

        return .{ .last_header_ids = ids, .allocator = allocator };
    }

    pub fn deinit(self: *SyncInfo) void {
        if (self.allocator) |allocator| {
            allocator.free(self.last_header_ids);
        }
    }
};

/// Union of all message types.
pub const Message = union(MessageCode) {
    GetPeers: GetPeers,
    Peers: Peers,
    ModifierRequest: ModifierRequest,
    ModifierResponse: ModifierResponse,
    Inv: Inv,
    SyncInfo: SyncInfo,

    pub fn deinit(self: *Message) void {
        switch (self.*) {
            .Peers => |*p| p.deinit(),
            .Inv => |*i| i.deinit(),
            .ModifierRequest => |*m| m.deinit(),
            .ModifierResponse => |*m| m.deinit(),
            .SyncInfo => |*s| s.deinit(),
            else => {},
        }
    }
};

/// Deserializes a message from code and payload.
pub fn deserializeMessage(code_byte: u8, payload: []const u8, allocator: std.mem.Allocator) !Message {
    const code: MessageCode = @enumFromInt(code_byte);
    var fbs = std.io.fixedBufferStream(payload);
    var r = vlq.reader(fbs.reader());

    return switch (code) {
        .GetPeers => .{ .GetPeers = GetPeers.deserialize(&r) },
        .Peers => .{ .Peers = try Peers.deserialize(&r, allocator) },
        .Inv => .{ .Inv = try Inv.deserialize(&r, allocator) },
        .ModifierRequest => .{ .ModifierRequest = try ModifierRequest.deserialize(&r, allocator) },
        .ModifierResponse => .{ .ModifierResponse = try ModifierResponse.deserialize(&r, allocator) },
        .SyncInfo => .{ .SyncInfo = try SyncInfo.deserialize(&r, allocator) },
        _ => return error.InvalidMessageCode,
    };
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Converts bytes to hex string.
pub fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0F];
    }
}

/// Formats a 32-byte ID as hex.
pub fn formatId(id: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(id, .lower);
}

// ============================================================================
// Tests
// ============================================================================

test "version parsing" {
    const v = try Version.parse("5.0.24");
    try std.testing.expectEqual(@as(u8, 5), v.major);
    try std.testing.expectEqual(@as(u8, 0), v.minor);
    try std.testing.expectEqual(@as(u8, 24), v.patch);
}

test "version comparison" {
    const v1 = Version{ .major = 5, .minor = 0, .patch = 24 };
    const v2 = Version{ .major = 5, .minor = 1, .patch = 0 };
    const v3 = Version{ .major = 5, .minor = 0, .patch = 24 };

    try std.testing.expectEqual(@as(i2, -1), v1.compare(v2));
    try std.testing.expectEqual(@as(i2, 1), v2.compare(v1));
    try std.testing.expectEqual(@as(i2, 0), v1.compare(v3));
}

test "version serialization round trip" {
    const v = Version{ .major = 5, .minor = 0, .patch = 24 };
    var buf: [3]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs.writer());
    try v.serialize(&w);

    fbs.pos = 0;
    var r = vlq.reader(fbs.reader());
    const v2 = try Version.deserialize(&r);

    try std.testing.expectEqual(v.major, v2.major);
    try std.testing.expectEqual(v.minor, v2.minor);
    try std.testing.expectEqual(v.patch, v2.patch);
}

test "frame checksum" {
    const payload = "Hello, Ergo!";
    const frame = Frame.create(NetworkMagic.mainnet, .GetPeers, payload);
    try std.testing.expect(frame.verifyChecksum());
}

test "network magic names" {
    try std.testing.expectEqualStrings("mainnet", NetworkMagic.name(NetworkMagic.mainnet));
    try std.testing.expectEqualStrings("testnet", NetworkMagic.name(NetworkMagic.testnet));
}

test "inv serialization round trip" {
    const allocator = std.testing.allocator;

    var elements: [2][32]u8 = undefined;
    @memset(&elements[0], 0xAA);
    @memset(&elements[1], 0xBB);

    const inv = Inv{
        .type_id = .Transaction,
        .elements = &elements,
    };

    const bytes = try inv.toBytes(allocator);
    defer allocator.free(bytes);

    var fbs = std.io.fixedBufferStream(bytes);
    var r = vlq.reader(fbs.reader());
    var inv2 = try Inv.deserialize(&r, allocator);
    defer inv2.deinit();

    try std.testing.expectEqual(inv.type_id, inv2.type_id);
    try std.testing.expectEqual(inv.elements.len, inv2.elements.len);
    try std.testing.expectEqual(inv.elements[0], inv2.elements[0]);
    try std.testing.expectEqual(inv.elements[1], inv2.elements[1]);
}

// Reference all sub-module tests to ensure they're included in test runs.
comptime {
    _ = vlq;
    _ = blake2b;
    _ = connection;
    _ = pool;
    _ = modifiers;
    _ = Discovery;
}
