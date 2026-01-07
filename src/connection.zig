//! Connection - Single peer connection handler for Ergo P2P protocol.
//!
//! Handles TCP connections, handshake, and message I/O with a single Ergo node.

const std = @import("std");
const root = @import("ergo_p2p.zig");
const vlq = root.vlq;
const blake2b = root.blake2b;

pub const NetworkMagic = root.NetworkMagic;
pub const MessageCode = root.MessageCode;
pub const ModifierType = root.ModifierType;
pub const Version = root.Version;
pub const Feature = root.Feature;
pub const Peer = root.Peer;
pub const Frame = root.Frame;
pub const Message = root.Message;

// Re-export message types
pub const GetPeers = root.GetPeers;
pub const Peers = root.Peers;
pub const Inv = root.Inv;
pub const ModifierRequest = root.ModifierRequest;
pub const ModifierResponse = root.ModifierResponse;

pub const Error = error{
    NotConnected,
    AlreadyConnected,
    HandshakeFailed,
    HandshakeTimeout,
    InvalidMagic,
    InvalidChecksum,
    ConnectionReset,
    ConnectionRefused,
    Timeout,
    PayloadTooLarge,
} || std.posix.ConnectError || std.posix.ReadError || std.posix.WriteError || root.Error;

/// Default connection timeout in milliseconds.
/// 10 seconds balances reliability for slow/distant nodes against fast failure for
/// unreachable peers. Longer timeouts increase latency when rotating through peers.
pub const DefaultConnectTimeout = 10_000;

/// Default read timeout in milliseconds.
/// 30 seconds allows for network jitter and slow peers while preventing indefinite
/// hangs. Most messages arrive within milliseconds; this catches dead connections.
pub const DefaultReadTimeout = 30_000;

/// Default handshake timeout in milliseconds.
/// Handshakes are lightweight (< 1KB); 10 seconds is generous. Slower peers likely
/// indicate network issues that will cause problems during normal operation.
pub const DefaultHandshakeTimeout = 10_000;

/// Connection manages a single peer connection.
///
/// Invariants:
/// - read_pos <= read_len <= read_buffer.len
/// - If connected is true, socket must be non-null.
/// - If socket is null, connected must be false.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    network_magic: [4]u8,
    local_peer: Peer,
    remote_peer: ?Peer,
    socket: ?std.posix.socket_t,
    connected: bool,

    /// Buffered I/O state.
    /// 64KB matches typical TCP receive window and allows reading full max-size
    /// messages (4MB limit / 64 reads) without excessive syscall overhead.
    /// Larger buffers waste memory; smaller buffers increase read() calls.
    read_buffer: [65536]u8,
    read_pos: usize,
    read_len: usize,

    /// Creates a new Connection instance.
    pub fn init(allocator: std.mem.Allocator, network_magic: [4]u8, local_peer: Peer) Connection {
        const conn = Connection{
            .allocator = allocator,
            .network_magic = network_magic,
            .local_peer = local_peer,
            .remote_peer = null,
            .socket = null,
            .connected = false,
            .read_buffer = undefined,
            .read_pos = 0,
            .read_len = 0,
        };
        // Postcondition: New connection is not connected and has empty buffers.
        std.debug.assert(!conn.connected);
        std.debug.assert(conn.socket == null);
        std.debug.assert(conn.read_pos == 0);
        std.debug.assert(conn.read_len == 0);
        return conn;
    }

    /// Creates a Connection with default settings for mainnet.
    pub fn initDefault(allocator: std.mem.Allocator) Connection {
        return init(allocator, NetworkMagic.mainnet, Peer.default());
    }

    /// Cleans up resources.
    pub fn deinit(self: *Connection) void {
        self.disconnect();
        if (self.remote_peer) |*peer| {
            peer.deinit();
            self.remote_peer = null;
        }
        // Postcondition: All resources released, connection unusable.
        std.debug.assert(!self.connected);
        std.debug.assert(self.socket == null);
    }

    /// Returns true if connected to a peer.
    pub fn isConnected(self: *const Connection) bool {
        // Invariant: Buffer positions must always be valid.
        std.debug.assert(self.read_pos <= self.read_len);
        std.debug.assert(self.read_len <= self.read_buffer.len);
        return self.connected and self.socket != null;
    }

    /// Returns the remote peer info (available after handshake).
    pub fn getRemotePeer(self: *const Connection) ?Peer {
        return self.remote_peer;
    }

    /// Connects to a peer at the given address.
    pub fn connect(self: *Connection, address: std.net.Address) !void {
        // Precondition: Must not already be connected.
        std.debug.assert(!self.connected);
        if (self.connected) {
            return Error.AlreadyConnected;
        }

        // Create socket
        const sock = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.STREAM,
            std.posix.IPPROTO.TCP,
        );
        errdefer std.posix.close(sock);

        // Set socket options
        try setSocketTimeout(sock, DefaultConnectTimeout);

        // Connect
        std.posix.connect(sock, &address.any, address.getOsSockLen()) catch |err| {
            return switch (err) {
                error.ConnectionRefused => Error.ConnectionRefused,
                error.ConnectionResetByPeer => Error.ConnectionReset,
                else => err,
            };
        };

        self.socket = sock;
        self.connected = true;
        self.read_pos = 0;
        self.read_len = 0;

        // Postcondition: Socket established, buffers reset.
        std.debug.assert(self.connected);
        std.debug.assert(self.socket != null);
        std.debug.assert(self.read_pos == 0);
        std.debug.assert(self.read_len == 0);
    }

    /// Connects to a peer using host and port strings.
    pub fn connectTo(self: *Connection, host: []const u8, port: u16) !void {
        const address = try std.net.Address.parseIp4(host, port);
        try self.connect(address);
    }

    /// Disconnects from the current peer.
    pub fn disconnect(self: *Connection) void {
        if (self.socket) |sock| {
            std.posix.close(sock);
            self.socket = null;
        }
        self.connected = false;
        self.read_pos = 0;
        self.read_len = 0;

        // Postcondition: Connection fully cleaned up.
        std.debug.assert(!self.connected);
        std.debug.assert(self.socket == null);
        std.debug.assert(self.read_pos == 0);
        std.debug.assert(self.read_len == 0);
    }

    /// Performs the full handshake sequence.
    pub fn performHandshake(self: *Connection) !void {
        // Precondition: Must be connected to handshake.
        std.debug.assert(self.isConnected());
        try self.sendHandshake();
        try self.receiveHandshake();
        // Postcondition: Remote peer info now available.
        std.debug.assert(self.remote_peer != null);
    }

    /// Sends the handshake to the peer.
    pub fn sendHandshake(self: *Connection) !void {
        // Precondition: Must be connected.
        std.debug.assert(self.socket != null);
        if (!self.isConnected()) {
            return Error.NotConnected;
        }

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        var w = vlq.writer(buf.writer());

        // Write timestamp (milliseconds since epoch)
        const timestamp: u64 = @intCast(std.time.milliTimestamp());
        try w.writeUnsignedLong(timestamp);

        // Write local peer info
        try self.local_peer.serialize(&w);

        // Send handshake (no frame wrapping - raw bytes)
        try self.writeAll(buf.items);
    }

    /// Receives and parses the handshake from the peer.
    pub fn receiveHandshake(self: *Connection) !void {
        // Precondition: Must be connected.
        std.debug.assert(self.socket != null);
        if (!self.isConnected()) {
            return Error.NotConnected;
        }

        // Set handshake timeout
        if (self.socket) |sock| {
            try setSocketTimeout(sock, DefaultHandshakeTimeout);
        }

        var r = self.reader();

        // Read timestamp (we don't use it, but need to consume it)
        _ = try r.readUnsignedLong();

        // Read peer info
        if (self.remote_peer) |*old_peer| {
            old_peer.deinit();
        }
        self.remote_peer = try Peer.deserialize(&r, self.allocator);

        // Postcondition: Remote peer info now available.
        std.debug.assert(self.remote_peer != null);

        // Restore normal timeout
        if (self.socket) |sock| {
            try setSocketTimeout(sock, DefaultReadTimeout);
        }
    }

    /// Sends a protocol message.
    pub fn sendMessage(self: *Connection, code: MessageCode, payload: []const u8) !void {
        // Precondition: Must be connected and payload within protocol limits.
        std.debug.assert(payload.len <= root.MaxPayloadSize);
        if (!self.isConnected()) {
            return Error.NotConnected;
        }

        const frame = Frame.create(self.network_magic, code, payload);
        // Paired assertion: Frame checksum valid before wire transmission.
        std.debug.assert(frame.verifyChecksum());

        var buf: [root.FrameHeaderSize]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Write header
        try writer.writeAll(&frame.magic);
        try writer.writeByte(@intFromEnum(frame.code));
        try writer.writeInt(u32, frame.length, .big);
        try writer.writeAll(&frame.checksum);

        // Send header
        try self.writeAll(&buf);

        // Send payload
        if (payload.len > 0) {
            try self.writeAll(payload);
        }
    }

    /// Sends a GetPeers message.
    pub fn sendGetPeers(self: *Connection) !void {
        try self.sendMessage(.GetPeers, &.{});
    }

    /// Sends an Inv message.
    pub fn sendInv(self: *Connection, inv: Inv) !void {
        // Precondition: Must be connected.
        std.debug.assert(self.isConnected());
        const payload = try inv.toBytes(self.allocator);
        defer self.allocator.free(payload);
        try self.sendMessage(.Inv, payload);
    }

    /// Sends a ModifierRequest message.
    pub fn sendModifierRequest(self: *Connection, request: ModifierRequest) !void {
        const payload = try request.toBytes(self.allocator);
        defer self.allocator.free(payload);
        try self.sendMessage(.ModifierRequest, payload);
    }

    /// Requests modifiers by type and IDs.
    pub fn requestModifiers(self: *Connection, type_id: ModifierType, ids: [][32]u8) !void {
        const request = ModifierRequest{
            .type_id = type_id,
            .elements = ids,
        };
        try self.sendModifierRequest(request);
    }

    /// Sends a SyncInfo message (empty - we have no headers).
    pub fn sendSyncInfo(self: *Connection) !void {
        const sync_info = root.SyncInfo.empty();
        const payload = try sync_info.toBytes(self.allocator);
        defer self.allocator.free(payload);
        try self.sendMessage(.SyncInfo, payload);
    }

    /// Receives a message from the peer.
    pub fn receiveMessage(self: *Connection) !Message {
        // Precondition: Must be connected to receive.
        std.debug.assert(self.socket != null);
        if (!self.isConnected()) {
            return Error.NotConnected;
        }

        // Read frame header
        var header_buf: [root.FrameHeaderSize]u8 = undefined;
        try self.readExact(&header_buf);
        // Postcondition: readExact guarantees full header read.
        std.debug.assert(header_buf.len == root.FrameHeaderSize);

        // Safety: header_buf is exactly FrameHeaderSize (13 bytes) and readExact()
        // guarantees all bytes are filled. Slices [0..4], [5..9], [9..13] are within bounds.
        // Magic mismatch means peer is on wrong network and should be disconnected.
        var magic: [4]u8 = undefined;
        @memcpy(&magic, header_buf[0..4]);
        if (!std.mem.eql(u8, &magic, &self.network_magic)) {
            return Error.InvalidMagic;
        }

        const code = header_buf[4];
        const length = std.mem.readInt(u32, header_buf[5..9], .big);
        var checksum: [4]u8 = undefined;
        @memcpy(&checksum, header_buf[9..13]);

        if (length > root.MaxPayloadSize) {
            return Error.PayloadTooLarge;
        }

        // Read payload
        const payload = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(payload);

        if (length > 0) {
            try self.readExact(payload);

            // Verify checksum
            const expected_checksum = blake2b.checksum(payload);
            if (!std.mem.eql(u8, &checksum, &expected_checksum)) {
                self.allocator.free(payload);
                return Error.InvalidChecksum;
            }
        }

        // Deserialize message
        const msg = root.deserializeMessage(code, payload, self.allocator) catch |err| {
            self.allocator.free(payload);
            return err;
        };

        self.allocator.free(payload);
        return msg;
    }

    /// Receives a message with timeout (returns null on timeout).
    pub fn receiveMessageTimeout(self: *Connection, timeout_ms: u32) !?Message {
        if (self.socket) |sock| {
            try setSocketTimeout(sock, timeout_ms);
        }

        const msg = self.receiveMessage() catch |err| {
            // Restore default timeout
            // N.B.: Timeout reset failure is non-fatal here since we're already
            // returning an error. Next operation will set its own timeout anyway.
            if (self.socket) |sock| {
                setSocketTimeout(sock, DefaultReadTimeout) catch {};
            }
            if (err == error.WouldBlock) {
                return null;
            }
            return err;
        };

        // Restore default timeout
        if (self.socket) |sock| {
            try setSocketTimeout(sock, DefaultReadTimeout);
        }

        return msg;
    }

    // ========================================================================
    // Internal I/O
    // ========================================================================

    /// Creates a VLQ reader over the socket.
    fn reader(self: *Connection) vlq.Reader(SocketReader) {
        return vlq.reader(SocketReader{ .conn = self });
    }

    /// Writes all bytes to the socket.
    fn writeAll(self: *Connection, data: []const u8) !void {
        // Precondition: Socket must exist.
        std.debug.assert(self.socket != null);
        const sock = self.socket orelse return Error.NotConnected;
        var written: usize = 0;
        while (written < data.len) {
            // Loop invariant: Progress is being made.
            std.debug.assert(written <= data.len);
            const n = std.posix.write(sock, data[written..]) catch |err| {
                self.connected = false;
                return switch (err) {
                    error.ConnectionResetByPeer => Error.ConnectionReset,
                    error.BrokenPipe => Error.ConnectionReset,
                    else => err,
                };
            };
            if (n == 0) {
                self.connected = false;
                return Error.ConnectionReset;
            }
            written += n;
        }
    }

    /// Reads exactly len bytes from the socket.
    fn readExact(self: *Connection, buf: []u8) !void {
        // Precondition: Buffer positions must be valid.
        std.debug.assert(self.read_pos <= self.read_len);
        std.debug.assert(self.read_len <= self.read_buffer.len);

        var total_read: usize = 0;
        while (total_read < buf.len) {
            // Loop invariant: Progress toward filling buf.
            std.debug.assert(total_read <= buf.len);

            // First, use any buffered data.
            // Safety: Invariant guarantees read_pos <= read_len <= read_buffer.len.
            // to_copy is bounded by both available buffer data and remaining request,
            // so all slice indices are guaranteed within bounds.
            if (self.read_pos < self.read_len) {
                const available = self.read_len - self.read_pos;
                const to_copy = @min(available, buf.len - total_read);
                @memcpy(buf[total_read..][0..to_copy], self.read_buffer[self.read_pos..][0..to_copy]);
                self.read_pos += to_copy;
                total_read += to_copy;
                continue;
            }

            // Need to read more from socket
            const sock = self.socket orelse return Error.NotConnected;
            const n = std.posix.read(sock, &self.read_buffer) catch |err| {
                // Safety: WouldBlock indicates socket timeout, not connection failure.
                // We propagate it to let callers implement non-blocking polling.
                // Connection state remains valid; only true errors mark disconnected.
                if (err == error.WouldBlock) {
                    return err;
                }
                self.connected = false;
                return switch (err) {
                    error.ConnectionResetByPeer => Error.ConnectionReset,
                    else => err,
                };
            };
            if (n == 0) {
                self.connected = false;
                return Error.ConnectionReset;
            }
            self.read_pos = 0;
            self.read_len = n;

            // Postcondition: Buffer state valid after socket read.
            std.debug.assert(self.read_pos <= self.read_len);
            std.debug.assert(self.read_len <= self.read_buffer.len);
        }
    }

    /// Internal reader type for VLQ integration.
    const SocketReader = struct {
        conn: *Connection,

        pub fn readByte(self: SocketReader) !u8 {
            var buf: [1]u8 = undefined;
            try self.conn.readExact(&buf);
            return buf[0];
        }

        pub fn readAll(self: SocketReader, buf: []u8) !usize {
            try self.conn.readExact(buf);
            return buf.len;
        }
    };
};

/// Sets socket read/write timeout.
fn setSocketTimeout(sock: std.posix.socket_t, timeout_ms: u32) !void {
    const timeout = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
}

// ============================================================================
// Tests
// ============================================================================

test "connection initialization" {
    const allocator = std.testing.allocator;
    var conn = Connection.initDefault(allocator);
    defer conn.deinit();

    try std.testing.expect(!conn.isConnected());
    try std.testing.expectEqual(NetworkMagic.mainnet, conn.network_magic);
    try std.testing.expectEqual(@as(?Peer, null), conn.getRemotePeer());
}

test "connection with custom peer" {
    const allocator = std.testing.allocator;
    const peer = try Peer.init("test-agent", "test-peer", Version{ .major = 5, .minor = 0, .patch = 24 }, &root.BasicFeatureSet);
    var conn = Connection.init(allocator, NetworkMagic.testnet, peer);
    defer conn.deinit();

    try std.testing.expectEqual(NetworkMagic.testnet, conn.network_magic);
    try std.testing.expectEqualStrings("test-agent", conn.local_peer.agent_name);
}

test "frame serialization" {
    const payload = "test payload";
    const frame = Frame.create(NetworkMagic.mainnet, .GetPeers, payload);

    try std.testing.expect(frame.verifyChecksum());
    try std.testing.expectEqual(@as(u32, 12), frame.length);
    try std.testing.expectEqual(MessageCode.GetPeers, frame.code);
}

test "frame with empty payload" {
    const frame = Frame.create(NetworkMagic.mainnet, .GetPeers, &.{});

    try std.testing.expect(frame.verifyChecksum());
    try std.testing.expectEqual(@as(u32, 0), frame.length);
    try std.testing.expectEqual(MessageCode.GetPeers, frame.code);
}

test "frame checksum verification" {
    // Create a valid frame
    const payload = "test data";
    var frame = Frame.create(NetworkMagic.mainnet, .Inv, payload);
    try std.testing.expect(frame.verifyChecksum());

    // Corrupt the checksum
    frame.checksum[0] ^= 0xFF;
    try std.testing.expect(!frame.verifyChecksum());
}

test "connection disconnect cleans up state" {
    const allocator = std.testing.allocator;
    var conn = Connection.initDefault(allocator);

    // Initial state
    try std.testing.expect(!conn.isConnected());

    // Disconnect on unconnected connection should be safe (no-op)
    conn.disconnect();
    try std.testing.expect(!conn.isConnected());
    try std.testing.expectEqual(@as(?std.posix.socket_t, null), conn.socket);
    try std.testing.expectEqual(@as(usize, 0), conn.read_pos);
    try std.testing.expectEqual(@as(usize, 0), conn.read_len);

    conn.deinit();
}

test "connection timeout constants" {
    // Verify timeout constants are reasonable
    try std.testing.expect(DefaultConnectTimeout >= 1000); // At least 1 second
    try std.testing.expect(DefaultConnectTimeout <= 60_000); // At most 1 minute
    try std.testing.expect(DefaultReadTimeout >= 1000);
    try std.testing.expect(DefaultReadTimeout <= 120_000);
    try std.testing.expect(DefaultHandshakeTimeout >= 1000);
    try std.testing.expect(DefaultHandshakeTimeout <= 60_000);
}

test "frame different message types" {
    // Test various message types create valid frames
    const payload = "sample";

    const types = [_]MessageCode{
        .GetPeers,
        .Peers,
        .Inv,
        .ModifierRequest,
        .ModifierResponse,
        .SyncInfo,
    };

    for (types) |code| {
        const frame = Frame.create(NetworkMagic.mainnet, code, payload);
        try std.testing.expect(frame.verifyChecksum());
        try std.testing.expectEqual(code, frame.code);
        try std.testing.expectEqual(@as(u32, @intCast(payload.len)), frame.length);
    }
}

test "connection buffer invariants" {
    const allocator = std.testing.allocator;
    var conn = Connection.initDefault(allocator);
    defer conn.deinit();

    // Buffer invariants should hold on init
    try std.testing.expect(conn.read_pos <= conn.read_len);
    try std.testing.expect(conn.read_len <= conn.read_buffer.len);
    try std.testing.expectEqual(@as(usize, 0), conn.read_pos);
    try std.testing.expectEqual(@as(usize, 0), conn.read_len);
    try std.testing.expectEqual(@as(usize, 65536), conn.read_buffer.len);
}
