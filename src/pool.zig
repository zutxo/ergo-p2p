//! Pool - Multi-peer connection management and broadcasting.
//!
//! Manages a pool of peer connections for:
//! - Broadcasting transactions to multiple peers
//! - Coordinating network requests across connections
//! - Privacy-aware broadcast strategies
//!
//! Example - Create pool and connect to peers:
//!
//!     var pool = Pool.initWithDiscovery(allocator, NetworkMagic.mainnet, local_peer, &discovery);
//!     defer pool.deinit();
//!
//!     pool.setMaxConnections(8);
//!     const connected = try pool.connectFromDiscovery(8);
//!
//! Example - Broadcast transaction IDs:
//!
//!     const result = try pool.broadcastModifierIds(.Transaction, &tx_ids, .{ .staggered = .{ .delay_ms = 100 } });
//!     if (result.successRate() < 0.5) {
//!         // Handle low broadcast success...
//!     }

const std = @import("std");
const root = @import("ergo_p2p.zig");
const platform = root.platform;
const Connection = root.connection.Connection;
const Peer = root.Peer;
const NetworkMagic = root.NetworkMagic;
const Inv = root.Inv;
const ModifierType = root.ModifierType;
const Discovery = root.Discovery;
const PeerInfo = root.PeerInfo;

// ============================================================================
// Broadcast Strategy
// ============================================================================

/// Strategy for broadcasting messages to peers.
pub const BroadcastStrategy = union(enum) {
    /// Send to all connected peers simultaneously
    all: void,

    /// Send to peers one at a time with delay between
    staggered: struct {
        delay_ms: u32 = 100,
    },

    /// Send to a random subset of peers
    random_subset: struct {
        count: u32,
    },

    /// Send to first N peers (by connection order)
    first_n: struct {
        count: u32,
    },
};

// ============================================================================
// Connection Info
// ============================================================================

/// State of a managed connection.
///
/// Transitions:
/// - connecting -> connected: Handshake completed successfully.
/// - connecting -> disconnected: Connection or handshake failed.
/// - connected -> disconnected: Connection closed or error occurred.
///
/// N.B.: There is no transition from disconnected back to connecting.
/// Disconnected connections are cleaned up; reconnection creates a new entry.
pub const ConnectionState = enum {
    /// Connection attempt in progress
    connecting,
    /// Connected and handshake complete
    connected,
    /// Connection failed or closed
    disconnected,
};

/// Information about a managed connection.
pub const ConnectionInfo = struct {
    /// Unique connection ID
    id: u64,
    /// Host address
    host: []const u8,
    /// Port number
    port: u16,
    /// Connection state
    state: ConnectionState,
    /// The connection handling this peer
    connection: ?*Connection,
    /// Time of connection
    connected_at: ?i64,
    /// Remote peer info (after handshake)
    remote_peer: ?Peer,
    /// Allocator for owned data
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConnectionInfo) void {
        self.allocator.free(self.host);
        if (self.connection) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
    }
};

// ============================================================================
// Broadcast Result
// ============================================================================

/// Result of a broadcast operation.
pub const BroadcastResult = struct {
    /// Number of successful sends
    successful: u32,
    /// Number of failed sends
    failed: u32,
    /// Total peers attempted
    attempted: u32,

    pub fn successRate(self: BroadcastResult) f32 {
        if (self.attempted == 0) return 0.0;
        return @as(f32, @floatFromInt(self.successful)) / @as(f32, @floatFromInt(self.attempted));
    }
};

// ============================================================================
// Pool
// ============================================================================

/// Pool manages multiple peer connections for broadcasting.
///
/// Invariants:
/// - next_id is monotonically increasing (never reused).
/// - connectionCount() <= max_connections (enforced by connect()).
/// - All entries in connections have unique IDs matching their keys.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    network_magic: [4]u8,
    local_peer: Peer,

    /// Active connections indexed by unique ID.
    connections: std.AutoHashMap(u64, ConnectionInfo),

    /// Next connection ID. Monotonically increasing to ensure uniqueness.
    next_id: u64,

    /// Optional discovery for peer discovery.
    discovery: ?*Discovery,

    /// Maximum concurrent connections.
    /// 8 is a reasonable default: enough for transaction propagation
    /// redundancy while limiting memory and file descriptor usage.
    /// Each connection uses ~70KB (65KB read buffer + overhead).
    max_connections: u32,

    /// Creates a new Pool instance.
    pub fn init(allocator: std.mem.Allocator, network_magic: [4]u8, local_peer: Peer) Pool {
        const pool = Pool{
            .allocator = allocator,
            .network_magic = network_magic,
            .local_peer = local_peer,
            .connections = std.AutoHashMap(u64, ConnectionInfo).init(allocator),
            .next_id = 1,
            .discovery = null,
            .max_connections = 8,
        };
        // Postcondition: Fresh pool with no connections.
        std.debug.assert(pool.next_id == 1);
        std.debug.assert(pool.connections.count() == 0);
        std.debug.assert(pool.discovery == null);
        return pool;
    }

    /// Creates a Pool with an associated Discovery for peer discovery.
    pub fn initWithDiscovery(allocator: std.mem.Allocator, network_magic: [4]u8, local_peer: Peer, discovery: *Discovery) Pool {
        var relay = init(allocator, network_magic, local_peer);
        relay.discovery = discovery;
        // Postcondition: Discovery is associated.
        std.debug.assert(relay.discovery != null);
        std.debug.assert(relay.discovery == discovery);
        return relay;
    }

    pub fn deinit(self: *Pool) void {
        self.disconnectAll();
        // Postcondition: All connections released before hashmap deinit.
        std.debug.assert(self.connections.count() == 0);
        self.connections.deinit();
    }

    /// Sets the maximum number of concurrent connections.
    pub fn setMaxConnections(self: *Pool, max: u32) void {
        self.max_connections = max;
    }

    /// Returns the number of active connections.
    pub fn connectionCount(self: *const Pool) usize {
        var count: usize = 0;
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .connected) {
                count += 1;
            }
        }
        return count;
    }

    /// Returns all connection IDs.
    pub fn getConnectionIds(self: *const Pool) ![]u64 {
        var ids = std.ArrayList(u64).init(self.allocator);
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            try ids.append(entry.key_ptr.*);
        }
        return ids.toOwnedSlice();
    }

    /// Gets connection info by ID.
    pub fn getConnection(self: *Pool, id: u64) ?*ConnectionInfo {
        return self.connections.getPtr(id);
    }

    /// Connects to a peer and adds to the pool.
    pub fn connect(self: *Pool, host: []const u8, port: u16) !u64 {
        // Precondition: Host must be non-empty.
        std.debug.assert(host.len > 0);
        const prev_next_id = self.next_id;

        // Check connection limit
        if (self.connectionCount() >= self.max_connections) {
            return error.TooManyConnections;
        }

        // Allocate connection ID
        const id = self.next_id;
        self.next_id += 1;

        // Invariant: ID monotonically increases.
        std.debug.assert(self.next_id > prev_next_id);

        // Create conn
        const conn = try self.allocator.create(Connection);
        conn.* = Connection.init(self.allocator, self.network_magic, self.local_peer);
        errdefer {
            conn.deinit();
            self.allocator.destroy(conn);
        }

        // Create connection info
        const host_copy = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(host_copy);

        var conn_info = ConnectionInfo{
            .id = id,
            .host = host_copy,
            .port = port,
            .state = .connecting,
            .connection = conn,
            .connected_at = null,
            .remote_peer = null,
            .allocator = self.allocator,
        };

        // Attempt connection
        conn.connectTo(host, port) catch |err| {
            conn_info.state = .disconnected;
            try self.connections.put(id, conn_info);
            if (self.discovery) |discovery| {
                discovery.recordConnectionFailure(host, port);
            }
            return err;
        };

        // Perform handshake
        conn.performHandshake() catch |err| {
            conn_info.state = .disconnected;
            conn.disconnect();
            try self.connections.put(id, conn_info);
            if (self.discovery) |discovery| {
                discovery.recordConnectionFailure(host, port);
            }
            return err;
        };

        // Success!
        conn_info.state = .connected;
        conn_info.connected_at = platform.timestampMs();
        conn_info.remote_peer = conn.getRemotePeer();

        try self.connections.put(id, conn_info);

        // Update discovery
        if (self.discovery) |discovery| {
            discovery.recordConnectionSuccess(host, port, conn.getRemotePeer());
        }

        return id;
    }

    /// Connects to multiple peers from a list of PeerInfo.
    pub fn connectToPeers(self: *Pool, peers: []const PeerInfo, max_count: u32) !u32 {
        var connected: u32 = 0;
        const target = @min(max_count, @as(u32, @intCast(peers.len)));

        for (peers) |peer| {
            if (connected >= target) break;
            if (self.connectionCount() >= self.max_connections) break;

            _ = self.connect(peer.host, peer.port) catch continue;
            connected += 1;
        }

        return connected;
    }

    /// Connects to peers discovered by discovery.
    pub fn connectFromDiscovery(self: *Pool, count: u32) !u32 {
        const discovery = self.discovery orelse return error.NoDiscovery;

        const peers = try discovery.selectBestPeers(count);
        defer self.allocator.free(peers);

        return try self.connectToPeers(peers, count);
    }

    /// Disconnects a specific connection.
    pub fn disconnect(self: *Pool, id: u64) void {
        if (self.connections.fetchRemove(id)) |kv| {
            var conn = kv.value;

            // Update discovery
            if (self.discovery) |discovery| {
                discovery.recordDisconnect(conn.host, conn.port);
            }

            conn.deinit();
        }
    }

    /// Disconnects all connections.
    pub fn disconnectAll(self: *Pool) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            var conn = entry.value_ptr;

            // Update discovery
            if (self.discovery) |discovery| {
                discovery.recordDisconnect(conn.host, conn.port);
            }

            conn.deinit();
        }
        self.connections.clearRetainingCapacity();

        // Postcondition: All connections removed.
        std.debug.assert(self.connections.count() == 0);
    }

    /// Broadcasts an Inv message to connected peers.
    pub fn broadcastInv(self: *Pool, inv: Inv, strategy: BroadcastStrategy) !BroadcastResult {
        // Precondition: Inv must have elements to broadcast.
        std.debug.assert(inv.elements.len > 0);

        var result = BroadcastResult{
            .successful = 0,
            .failed = 0,
            .attempted = 0,
        };

        // Get list of connected peers to broadcast to
        const targets = try self.selectTargets(strategy);
        defer self.allocator.free(targets);

        for (targets, 0..) |id, i| {
            result.attempted += 1;

            const conn_info = self.connections.getPtr(id) orelse continue;
            if (conn_info.state != .connected) continue;

            const connection = conn_info.connection orelse continue;

            // Apply staggered delay
            if (strategy == .staggered and i > 0) {
                std.time.sleep(strategy.staggered.delay_ms * std.time.ns_per_ms);
            }

            // Send Inv
            // N.B.: We catch all errors here because broadcast is best-effort.
            // The result tracks success/failure counts; callers can decide
            // whether to retry based on successRate().
            connection.sendInv(inv) catch {
                result.failed += 1;
                conn_info.state = .disconnected;
                continue;
            };

            result.successful += 1;
        }

        // Postcondition: Accounting must balance.
        std.debug.assert(result.attempted == result.successful + result.failed);
        return result;
    }

    /// Broadcasts modifier IDs (as Inv) to connected peers.
    pub fn broadcastModifierIds(
        self: *Pool,
        type_id: ModifierType,
        ids: [][32]u8,
        strategy: BroadcastStrategy,
    ) !BroadcastResult {
        const inv = Inv{
            .type_id = type_id,
            .elements = ids,
        };
        return try self.broadcastInv(inv, strategy);
    }

    /// Sends a message to a specific connection.
    pub fn sendTo(self: *Pool, id: u64, code: root.MessageCode, payload: []const u8) !void {
        // Precondition: Payload must be within protocol limits.
        std.debug.assert(payload.len <= root.MaxPayloadSize);

        const conn_info = self.connections.getPtr(id) orelse return error.ConnectionNotFound;
        if (conn_info.state != .connected) return error.NotConnected;

        const connection = conn_info.connection orelse return error.NotConnected;
        // Invariant: Connected state implies connection object exists.
        std.debug.assert(conn_info.state == .connected);
        try connection.sendMessage(code, payload);
    }

    /// Sends GetPeers to all connections and collects responses.
    pub fn requestPeersFromAll(self: *Pool) !u32 {
        var discovered: u32 = 0;
        const disc = self.discovery orelse return 0;

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            const conn_info = entry.value_ptr;
            if (conn_info.state != .connected) continue;

            const connection = conn_info.connection orelse continue;

            // N.B.: Discovery failures are non-fatal; we continue with other peers.
            // Common causes: timeout waiting for Peers response, connection reset.
            const count = disc.discoverFromConnection(connection) catch {
                continue;
            };
            discovered += @intCast(count);
        }

        return discovered;
    }

    /// Selects target connection IDs based on strategy.
    fn selectTargets(self: *Pool, strategy: BroadcastStrategy) ![]u64 {
        var targets = std.ArrayList(u64).init(self.allocator);

        // Collect all connected peers
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .connected) {
                try targets.append(entry.key_ptr.*);
            }
        }

        // Apply strategy
        switch (strategy) {
            .all => {
                // Keep all
            },
            .staggered => {
                // Keep all, delay applied during send
            },
            .random_subset => |opts| {
                if (targets.items.len > opts.count) {
                    // Shuffle and truncate
                    var prng = std.Random.DefaultPrng.init(@intCast(platform.timestampMs()));
                    prng.random().shuffle(u64, targets.items);
                    targets.shrinkRetainingCapacity(opts.count);
                }
            },
            .first_n => |opts| {
                if (targets.items.len > opts.count) {
                    targets.shrinkRetainingCapacity(opts.count);
                }
            },
        }

        return targets.toOwnedSlice();
    }

    /// Gets status summary of all connections.
    pub fn getStatus(self: *const Pool) Status {
        var status = Status{
            .total = 0,
            .connected = 0,
            .connecting = 0,
            .disconnected = 0,
        };

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            status.total += 1;
            switch (entry.value_ptr.state) {
                .connected => status.connected += 1,
                .connecting => status.connecting += 1,
                .disconnected => status.disconnected += 1,
            }
        }

        // Postcondition: State counts must sum to total.
        std.debug.assert(status.total == status.connected + status.connecting + status.disconnected);
        return status;
    }

    pub const Status = struct {
        total: u32,
        connected: u32,
        connecting: u32,
        disconnected: u32,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "relay initialization" {
    const allocator = std.testing.allocator;

    const peer = try Peer.init("test", "test", root.DefaultVersion, &root.BasicFeatureSet);
    var relay = Pool.init(allocator, NetworkMagic.mainnet, peer);
    defer relay.deinit();

    try std.testing.expectEqual(@as(usize, 0), relay.connectionCount());
}

test "relay max connections" {
    const allocator = std.testing.allocator;

    const peer = try Peer.init("test", "test", root.DefaultVersion, &root.BasicFeatureSet);
    var relay = Pool.init(allocator, NetworkMagic.mainnet, peer);
    defer relay.deinit();

    relay.setMaxConnections(4);
    try std.testing.expectEqual(@as(u32, 4), relay.max_connections);
}

test "broadcast strategy selection" {
    const allocator = std.testing.allocator;

    const peer = try Peer.init("test", "test", root.DefaultVersion, &root.BasicFeatureSet);
    var relay = Pool.init(allocator, NetworkMagic.mainnet, peer);
    defer relay.deinit();

    // Test with no connections
    const targets = try relay.selectTargets(.all);
    defer allocator.free(targets);

    try std.testing.expectEqual(@as(usize, 0), targets.len);
}

test "broadcast result success rate" {
    const result1 = BroadcastResult{ .successful = 8, .failed = 2, .attempted = 10 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), result1.successRate(), 0.001);

    const result2 = BroadcastResult{ .successful = 0, .failed = 0, .attempted = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result2.successRate(), 0.001);

    // Test perfect success
    const result3 = BroadcastResult{ .successful = 5, .failed = 0, .attempted = 5 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result3.successRate(), 0.001);

    // Test complete failure
    const result4 = BroadcastResult{ .successful = 0, .failed = 5, .attempted = 5 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result4.successRate(), 0.001);
}

test "pool status tracking" {
    const allocator = std.testing.allocator;

    const peer = try Peer.init("test", "test", root.DefaultVersion, &root.BasicFeatureSet);
    var relay = Pool.init(allocator, NetworkMagic.mainnet, peer);
    defer relay.deinit();

    const status = relay.getStatus();
    try std.testing.expectEqual(@as(u32, 0), status.total);
    try std.testing.expectEqual(@as(u32, 0), status.connected);
    try std.testing.expectEqual(@as(u32, 0), status.connecting);
    try std.testing.expectEqual(@as(u32, 0), status.disconnected);
}

test "connection id generation is monotonic" {
    const allocator = std.testing.allocator;

    const peer = try Peer.init("test", "test", root.DefaultVersion, &root.BasicFeatureSet);
    var relay = Pool.init(allocator, NetworkMagic.mainnet, peer);
    defer relay.deinit();

    // Next ID should start at 1 and increment monotonically
    try std.testing.expectEqual(@as(u64, 1), relay.next_id);

    // Simulate ID allocation (would normally happen during connect)
    const id1 = relay.next_id;
    relay.next_id += 1;
    const id2 = relay.next_id;
    relay.next_id += 1;

    try std.testing.expect(id2 > id1);
    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
}

test "get connection ids empty pool" {
    const allocator = std.testing.allocator;

    const peer = try Peer.init("test", "test", root.DefaultVersion, &root.BasicFeatureSet);
    var relay = Pool.init(allocator, NetworkMagic.mainnet, peer);
    defer relay.deinit();

    const ids = try relay.getConnectionIds();
    defer allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "broadcast strategy types" {
    // Test that all strategy types can be constructed
    const all = BroadcastStrategy{ .all = {} };
    const staggered = BroadcastStrategy{ .staggered = .{ .delay_ms = 100 } };
    const random = BroadcastStrategy{ .random_subset = .{ .count = 3 } };
    const first = BroadcastStrategy{ .first_n = .{ .count = 5 } };

    // Verify the active tags are different
    try std.testing.expect(std.meta.activeTag(all) != std.meta.activeTag(staggered));
    try std.testing.expect(std.meta.activeTag(random) != std.meta.activeTag(first));

    // Test staggered default delay
    const staggered_default = BroadcastStrategy{ .staggered = .{} };
    try std.testing.expectEqual(@as(u32, 100), staggered_default.staggered.delay_ms);
}

test "connection state transitions" {
    // Test state enum values
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(ConnectionState.connecting));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(ConnectionState.connected));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(ConnectionState.disconnected));
}
