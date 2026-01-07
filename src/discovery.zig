//! Discovery - Peer discovery and management for Ergo P2P network.
//!
//! Handles:
//! - Bootstrap peer list (hardcoded known nodes)
//! - Peer exchange via GetPeers/Peers messages
//! - Peer storage and selection
//! - Connection tracking and scoring

const std = @import("std");
const root = @import("ergo_p2p.zig");
const platform = root.platform;
const Connection = root.connection.Connection;
const Peer = root.Peer;
const NetworkMagic = root.NetworkMagic;

// ============================================================================
// Constants
// ============================================================================

/// Maximum attempts when waiting for Peers response during discovery.
/// 10 attempts * 3s timeout = 30s max wait. Beyond this, peer is likely
/// unresponsive or doesn't support peer exchange.
const MAX_DISCOVERY_ATTEMPTS: u32 = 10;

/// Age thresholds for peer recency scoring (in hours).
/// Peers seen more recently get higher scores in selection algorithm.
const PEER_FRESH_HOURS: i64 = 1; // Very recent - highest bonus
const PEER_RECENT_HOURS: i64 = 24; // Within a day - medium bonus
const PEER_STALE_HOURS: i64 = 168; // Within a week - small bonus

/// Maximum backoff exponent for retry attempts.
/// Capped at 2^10 = 1024 seconds (~17 minutes) to prevent unbounded growth.
/// After this many failures, peer is likely permanently unreachable but we
/// still retry periodically in case of temporary network partition.
const MAX_BACKOFF_EXPONENT: u32 = 10;

// ============================================================================
// PeerInfo
// ============================================================================

/// Source of peer discovery.
pub const PeerSource = enum {
    /// Hardcoded bootstrap peer
    bootstrap,
    /// Discovered via peer exchange (GetPeers/Peers)
    peer_exchange,
    /// Provided by user (command line)
    user_provided,
    /// DNS seed (if available)
    dns_seed,
};

/// Connection state of a peer.
///
/// Transitions:
/// - unknown -> connecting: Connection attempt started.
/// - unknown -> failed: Connection attempt failed immediately.
/// - connecting -> connected: Handshake succeeded.
/// - connecting -> failed: Handshake failed or timed out.
/// - connected -> seen: Connection closed gracefully.
/// - seen -> connecting: Retry after backoff period.
/// - failed -> connecting: Retry after exponential backoff.
/// - * -> banned: Peer exhibited malicious behavior (protocol violation).
///
/// State diagram:
///   unknown --> connecting --> connected --> seen
///       |           |              |          |
///       v           v              |          v
///     failed <------+--------------+    (retry after backoff)
///       |
///       v
///     banned (terminal)
pub const PeerState = enum {
    /// Never attempted connection
    unknown,
    /// Currently connected
    connected,
    /// Connection attempt in progress
    connecting,
    /// Successfully connected in the past
    seen,
    /// Connection failed
    failed,
    /// Peer banned (misbehavior)
    banned,
};

/// Information about a discovered peer.
pub const PeerInfo = struct {
    /// Network address (IP + port)
    host: []const u8,
    port: u16,

    /// Discovery metadata
    source: PeerSource,
    first_seen: i64,
    last_seen: ?i64,
    last_attempt: ?i64,

    /// Connection tracking
    state: PeerState,
    connection_count: u32,
    failure_count: u32,

    /// Peer identity (populated after successful connection)
    agent_name: ?[]const u8,
    peer_name: ?[]const u8,
    version: ?root.Version,

    /// Allocator for owned strings
    allocator: ?std.mem.Allocator,

    /// Creates a new PeerInfo.
    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, source: PeerSource) !PeerInfo {
        // Precondition: Host must be non-empty.
        std.debug.assert(host.len > 0);
        const host_copy = try allocator.dupe(u8, host);
        const info = PeerInfo{
            .host = host_copy,
            .port = port,
            .source = source,
            .first_seen = platform.timestampMs(),
            .last_seen = null,
            .last_attempt = null,
            .state = .unknown,
            .connection_count = 0,
            .failure_count = 0,
            .agent_name = null,
            .peer_name = null,
            .version = null,
            .allocator = allocator,
        };
        // Postcondition: Fresh peer starts in unknown state with no history.
        std.debug.assert(info.state == .unknown);
        std.debug.assert(info.connection_count == 0);
        std.debug.assert(info.failure_count == 0);
        return info;
    }

    /// Creates PeerInfo from a Peer received via peer exchange.
    pub fn fromPeer(allocator: std.mem.Allocator, peer: Peer) !?PeerInfo {
        const addr = peer.public_address orelse return null;
        if (addr.ip.len != 4) return null; // Only support IPv4 for now

        var host_buf: [16]u8 = undefined;
        const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
            addr.ip[0],
            addr.ip[1],
            addr.ip[2],
            addr.ip[3],
        }) catch return null;

        var info = try init(allocator, host, addr.port, .peer_exchange);

        // Copy peer identity
        info.agent_name = try allocator.dupe(u8, peer.agent_name);
        info.peer_name = try allocator.dupe(u8, peer.peer_name);
        info.version = peer.version;
        info.last_seen = platform.timestampMs();

        return info;
    }

    /// Records a successful connection.
    pub fn recordSuccess(self: *PeerInfo) void {
        const prev_count = self.connection_count;
        self.state = .connected;
        self.last_seen = platform.timestampMs();
        self.connection_count += 1;
        // Postcondition: State updated, count incremented.
        std.debug.assert(self.state == .connected);
        std.debug.assert(self.connection_count == prev_count + 1);
        std.debug.assert(self.last_seen != null);
    }

    /// Records a connection failure.
    pub fn recordFailure(self: *PeerInfo) void {
        const prev_count = self.failure_count;
        self.state = .failed;
        self.last_attempt = platform.timestampMs();
        self.failure_count += 1;
        // Postcondition: State updated, failure count incremented.
        std.debug.assert(self.state == .failed);
        std.debug.assert(self.failure_count == prev_count + 1);
        std.debug.assert(self.last_attempt != null);
    }

    /// Records disconnection.
    pub fn recordDisconnect(self: *PeerInfo) void {
        if (self.state == .connected) {
            self.state = .seen;
            self.last_seen = platform.timestampMs();
        }
    }

    /// Updates peer identity after successful handshake.
    pub fn updateIdentity(self: *PeerInfo, peer: Peer) !void {
        const allocator = self.allocator orelse return;

        if (self.agent_name) |old| allocator.free(old);
        if (self.peer_name) |old| allocator.free(old);

        self.agent_name = try allocator.dupe(u8, peer.agent_name);
        self.peer_name = try allocator.dupe(u8, peer.peer_name);
        self.version = peer.version;
    }

    /// Computes a score for peer selection (higher is better).
    ///
    /// Scoring algorithm (components are additive):
    /// 1. Connection history: +100 base if ever connected, +1 per connection (max +50)
    /// 2. Failure penalty: -20 per failure (no cap, but backoff prevents rapid retry)
    /// 3. Recency bonus: +50 if seen <1hr, +25 if <24hr, +10 if <1wk
    /// 4. Source weight: user=+200, peer_exchange=+50, dns=+40, bootstrap=+25
    /// 5. State modifier: connected=+100, seen=+50, failed=-50, banned=-1000
    ///
    /// Rationale: User-provided peers are trusted explicitly. Peers we've successfully
    /// connected to recently are likely still online. Banned peers should never be
    /// selected (score will be deeply negative).
    pub fn score(self: *const PeerInfo) i32 {
        var s: i32 = 0;

        // Prefer peers we've successfully connected to.
        if (self.connection_count > 0) {
            s += 100;
            s += @min(@as(i32, @intCast(self.connection_count)), 50);
        }

        // Penalize failures.
        s -= @as(i32, @intCast(self.failure_count)) * 20;

        // Prefer recently seen peers.
        if (self.last_seen) |seen| {
            const age_ms = platform.timestampMs() - seen;
            const age_hours = @divTrunc(age_ms, 3600000);
            if (age_hours < PEER_FRESH_HOURS) {
                s += 50;
            } else if (age_hours < PEER_RECENT_HOURS) {
                s += 25;
            } else if (age_hours < PEER_STALE_HOURS) {
                s += 10;
            }
        }

        // Source preference.
        s += switch (self.source) {
            .user_provided => 200, // Highest priority
            .peer_exchange => 50,
            .bootstrap => 25,
            .dns_seed => 40,
        };

        // Penalize banned/failed state.
        s += switch (self.state) {
            .connected => 100,
            .seen => 50,
            .unknown => 0,
            .connecting => 0,
            .failed => -50,
            .banned => -1000,
        };

        return s;
    }

    /// Returns true if this peer should be retried.
    pub fn shouldRetry(self: *const PeerInfo) bool {
        if (self.state == .banned) return false;
        if (self.state == .connected) return false;
        if (self.state == .connecting) return false;

        // Exponential backoff based on failure count.
        // Capped at 2^10 seconds (~17 minutes) to prevent unbounded growth.
        // After 10 failures, peer is likely permanently unreachable but we still
        // retry periodically in case of temporary network partition.
        if (self.last_attempt) |attempt| {
            const backoff_ms = @as(i64, 1000) * std.math.pow(i64, 2, @min(self.failure_count, MAX_BACKOFF_EXPONENT));
            const elapsed = platform.timestampMs() - attempt;
            if (elapsed < backoff_ms) return false;
        }

        return true;
    }

    /// Formats the peer for display.
    pub fn format(self: PeerInfo, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}:{d}", .{ self.host, self.port });
        if (self.agent_name) |name| {
            try writer.print(" ({s}", .{name});
            if (self.version) |v| {
                try writer.print(" v{}", .{v});
            }
            try writer.print(")", .{});
        }
    }

    pub fn deinit(self: *PeerInfo) void {
        if (self.allocator) |allocator| {
            allocator.free(self.host);
            if (self.agent_name) |name| allocator.free(name);
            if (self.peer_name) |name| allocator.free(name);
        }
    }
};

// ============================================================================
// Discovery
// ============================================================================

/// Discovery manages peer discovery and selection.
pub const Discovery = struct {
    allocator: std.mem.Allocator,
    network_magic: [4]u8,

    /// Known peers indexed by "host:port" key
    peers: std.StringHashMap(PeerInfo),

    /// Creates a new Discovery instance.
    pub fn init(allocator: std.mem.Allocator, network_magic: [4]u8) Discovery {
        const discovery = Discovery{
            .allocator = allocator,
            .network_magic = network_magic,
            .peers = std.StringHashMap(PeerInfo).init(allocator),
        };
        // Postcondition: Fresh discovery starts with no peers.
        std.debug.assert(discovery.peers.count() == 0);
        return discovery;
    }

    /// Creates a Discovery with default mainnet settings.
    pub fn initMainnet(allocator: std.mem.Allocator) Discovery {
        var scout = init(allocator, NetworkMagic.mainnet);
        scout.loadBootstrapPeers();
        return scout;
    }

    /// Creates a Discovery with default testnet settings.
    pub fn initTestnet(allocator: std.mem.Allocator) Discovery {
        var scout = init(allocator, NetworkMagic.testnet);
        scout.loadBootstrapPeers();
        return scout;
    }

    pub fn deinit(self: *Discovery) void {
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.peers.deinit();
    }

    /// Loads hardcoded bootstrap peers for the current network.
    pub fn loadBootstrapPeers(self: *Discovery) void {
        const peers = if (std.mem.eql(u8, &self.network_magic, &NetworkMagic.mainnet))
            &mainnet_bootstrap_peers
        else if (std.mem.eql(u8, &self.network_magic, &NetworkMagic.testnet))
            &testnet_bootstrap_peers
        else
            return;

        for (peers) |peer| {
            self.addPeer(peer.host, peer.port, .bootstrap) catch continue;
        }
    }

    /// Adds a peer to the known peers list.
    pub fn addPeer(self: *Discovery, host: []const u8, port: u16, source: PeerSource) !void {
        // Precondition: Host must be non-empty.
        std.debug.assert(host.len > 0);
        const prev_count = self.peers.count();

        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
        errdefer self.allocator.free(key);

        const result = try self.peers.getOrPut(key);
        if (result.found_existing) {
            // Update existing peer
            self.allocator.free(key);
            const peer = result.value_ptr;
            peer.last_seen = platform.timestampMs();
            // Upgrade source if better
            if (@intFromEnum(source) < @intFromEnum(peer.source)) {
                peer.source = source;
            }
            // Postcondition: Count unchanged for existing peer.
            std.debug.assert(self.peers.count() == prev_count);
        } else {
            // Add new peer
            result.value_ptr.* = try PeerInfo.init(self.allocator, host, port, source);
            // Postcondition: Count increased for new peer.
            std.debug.assert(self.peers.count() == prev_count + 1);
        }
    }

    /// Adds a peer from a Peer message (peer exchange).
    pub fn addFromPeer(self: *Discovery, peer: Peer) !void {
        if (try PeerInfo.fromPeer(self.allocator, peer)) |info| {
            var peer_info = info;
            errdefer peer_info.deinit();

            const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ peer_info.host, peer_info.port });
            errdefer self.allocator.free(key);

            const result = try self.peers.getOrPut(key);
            if (result.found_existing) {
                self.allocator.free(key);
                peer_info.deinit();
                // Update existing
                result.value_ptr.last_seen = platform.timestampMs();
                // N.B.: Identity update is best-effort; OOM here is non-fatal since
                // we already have basic peer info. Stale identity is acceptable.
                result.value_ptr.updateIdentity(peer) catch {};
            } else {
                result.value_ptr.* = peer_info;
            }
        }
    }

    /// Processes a Peers message and adds all discovered peers.
    pub fn processPeersMessage(self: *Discovery, peers: root.Peers) !usize {
        var added: usize = 0;
        for (peers.peer_list) |peer| {
            self.addFromPeer(peer) catch continue;
            added += 1;
        }
        return added;
    }

    /// Discovers peers from a connected courier.
    pub fn discoverFromConnection(self: *Discovery, courier: *Connection) !usize {
        // Send GetPeers request
        try courier.sendGetPeers();

        // Wait for Peers response (with timeout)
        var attempts: u32 = 0;
        while (attempts < MAX_DISCOVERY_ATTEMPTS) : (attempts += 1) {
            const msg = try courier.receiveMessageTimeout(3000);
            if (msg) |message| {
                var m = message;
                defer m.deinit();

                switch (m) {
                    .Peers => |peers| {
                        return try self.processPeersMessage(peers);
                    },
                    else => {
                        // Not the message we're looking for, continue
                    },
                }
            }
        }

        return 0; // No peers received
    }

    /// Gets a peer by address.
    pub fn getPeer(self: *Discovery, host: []const u8, port: u16) ?*PeerInfo {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ host, port }) catch return null;
        return self.peers.getPtr(key);
    }

    /// Updates peer state after connection success.
    pub fn recordConnectionSuccess(self: *Discovery, host: []const u8, port: u16, peer: ?Peer) void {
        if (self.getPeer(host, port)) |info| {
            info.recordSuccess();
            if (peer) |p| {
                // N.B.: Identity update is best-effort; OOM here is non-fatal.
                // Successful connection is already recorded; stale identity is acceptable.
                info.updateIdentity(p) catch {};
            }
        }
    }

    /// Updates peer state after connection failure.
    pub fn recordConnectionFailure(self: *Discovery, host: []const u8, port: u16) void {
        if (self.getPeer(host, port)) |info| {
            info.recordFailure();
        }
    }

    /// Updates peer state after disconnection.
    pub fn recordDisconnect(self: *Discovery, host: []const u8, port: u16) void {
        if (self.getPeer(host, port)) |info| {
            info.recordDisconnect();
        }
    }

    /// Returns the total number of known peers.
    pub fn peerCount(self: *const Discovery) usize {
        return self.peers.count();
    }

    /// Returns count of peers in a specific state.
    pub fn peerCountByState(self: *const Discovery, state: PeerState) usize {
        var count: usize = 0;
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == state) {
                count += 1;
            }
        }
        return count;
    }

    /// Selects the best peers for connection attempts.
    /// Returns up to `count` peers sorted by score.
    pub fn selectBestPeers(self: *Discovery, count: usize) ![]PeerInfo {
        // Precondition: Requesting at least one peer.
        std.debug.assert(count > 0);

        // Collect retryable peers
        var candidates = std.ArrayList(PeerInfo).init(self.allocator);
        defer candidates.deinit();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.shouldRetry()) {
                try candidates.append(entry.value_ptr.*);
            }
        }

        // Sort by score (descending)
        std.mem.sort(PeerInfo, candidates.items, {}, struct {
            fn lessThan(_: void, a: PeerInfo, b: PeerInfo) bool {
                return a.score() > b.score();
            }
        }.lessThan);

        // Return top N
        const result_count = @min(count, candidates.items.len);
        const result = try self.allocator.alloc(PeerInfo, result_count);
        @memcpy(result, candidates.items[0..result_count]);

        // Postcondition: Result is sorted by score (descending).
        if (result.len > 1) {
            for (0..result.len - 1) |i| {
                std.debug.assert(result[i].score() >= result[i + 1].score());
            }
        }
        return result;
    }

    /// Selects random peers for connection attempts.
    pub fn selectRandomPeers(self: *Discovery, count: usize, rng: std.Random) ![]PeerInfo {
        // Collect retryable peers
        var candidates = std.ArrayList(PeerInfo).init(self.allocator);
        defer candidates.deinit();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.shouldRetry()) {
                try candidates.append(entry.value_ptr.*);
            }
        }

        if (candidates.items.len == 0) {
            return &.{};
        }

        // Shuffle
        rng.shuffle(PeerInfo, candidates.items);

        // Return top N
        const result_count = @min(count, candidates.items.len);
        const result = try self.allocator.alloc(PeerInfo, result_count);
        @memcpy(result, candidates.items[0..result_count]);
        return result;
    }

    /// Gets all peers as a slice (caller must free).
    pub fn getAllPeers(self: *Discovery) ![]PeerInfo {
        const result = try self.allocator.alloc(PeerInfo, self.peers.count());
        var i: usize = 0;
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            result[i] = entry.value_ptr.*;
            i += 1;
        }
        return result;
    }
};

// ============================================================================
// Bootstrap Peers
// ============================================================================

const BootstrapPeer = struct {
    host: []const u8,
    port: u16,
};

/// Mainnet bootstrap peers (well-known Ergo nodes).
const mainnet_bootstrap_peers = [_]BootstrapPeer{
    // ergo-mainnet.de nodes
    .{ .host = "213.239.193.208", .port = 9030 },
    .{ .host = "159.65.11.55", .port = 9030 },
    .{ .host = "165.227.26.175", .port = 9030 },
    .{ .host = "159.89.116.15", .port = 9030 },
    // Community nodes
    .{ .host = "213.152.106.56", .port = 9030 },
    .{ .host = "157.245.21.216", .port = 9030 },
    .{ .host = "68.183.25.21", .port = 9030 },
    .{ .host = "176.9.65.58", .port = 9030 },
};

/// Testnet bootstrap peers.
const testnet_bootstrap_peers = [_]BootstrapPeer{
    .{ .host = "213.239.193.208", .port = 9020 },
    .{ .host = "176.9.65.58", .port = 9020 },
};

// ============================================================================
// Tests
// ============================================================================

test "peer info scoring" {
    const allocator = std.testing.allocator;

    var peer1 = try PeerInfo.init(allocator, "127.0.0.1", 9030, .bootstrap);
    defer peer1.deinit();

    var peer2 = try PeerInfo.init(allocator, "127.0.0.2", 9030, .user_provided);
    defer peer2.deinit();

    // User-provided should score higher
    try std.testing.expect(peer2.score() > peer1.score());

    // Record some successes
    peer1.recordSuccess();
    peer1.recordSuccess();
    peer1.recordDisconnect();

    // Now peer1 should score higher due to connection history
    try std.testing.expect(peer1.score() > peer2.score());
}

test "peer retry backoff" {
    const allocator = std.testing.allocator;

    var peer = try PeerInfo.init(allocator, "127.0.0.1", 9030, .bootstrap);
    defer peer.deinit();

    // Should retry initially
    try std.testing.expect(peer.shouldRetry());

    // Record a failure
    peer.recordFailure();

    // Immediately after failure, should not retry (backoff)
    try std.testing.expect(!peer.shouldRetry());
}

test "scout initialization" {
    const allocator = std.testing.allocator;

    var scout = Discovery.initMainnet(allocator);
    defer scout.deinit();

    // Should have bootstrap peers
    try std.testing.expect(scout.peerCount() > 0);
}

test "scout add peer" {
    const allocator = std.testing.allocator;

    var scout = Discovery.init(allocator, NetworkMagic.mainnet);
    defer scout.deinit();

    try scout.addPeer("192.168.1.1", 9030, .user_provided);
    try scout.addPeer("192.168.1.2", 9030, .peer_exchange);

    try std.testing.expectEqual(@as(usize, 2), scout.peerCount());

    // Adding same peer again shouldn't increase count
    try scout.addPeer("192.168.1.1", 9030, .bootstrap);
    try std.testing.expectEqual(@as(usize, 2), scout.peerCount());
}

test "scout peer selection" {
    const allocator = std.testing.allocator;

    var scout = Discovery.init(allocator, NetworkMagic.mainnet);
    defer scout.deinit();

    try scout.addPeer("192.168.1.1", 9030, .bootstrap);
    try scout.addPeer("192.168.1.2", 9030, .user_provided);
    try scout.addPeer("192.168.1.3", 9030, .peer_exchange);

    const best = try scout.selectBestPeers(2);
    defer allocator.free(best);

    try std.testing.expectEqual(@as(usize, 2), best.len);
    // User-provided should be first (highest priority)
    try std.testing.expectEqual(PeerSource.user_provided, best[0].source);
}

test "peer state transitions" {
    const allocator = std.testing.allocator;

    var peer = try PeerInfo.init(allocator, "127.0.0.1", 9030, .bootstrap);
    defer peer.deinit();

    // Initial state
    try std.testing.expectEqual(PeerState.unknown, peer.state);
    try std.testing.expectEqual(@as(u32, 0), peer.connection_count);
    try std.testing.expectEqual(@as(u32, 0), peer.failure_count);

    // Record success: unknown -> connected
    peer.recordSuccess();
    try std.testing.expectEqual(PeerState.connected, peer.state);
    try std.testing.expectEqual(@as(u32, 1), peer.connection_count);

    // Record disconnect: connected -> seen
    peer.recordDisconnect();
    try std.testing.expectEqual(PeerState.seen, peer.state);

    // Record failure: seen -> failed
    peer.recordFailure();
    try std.testing.expectEqual(PeerState.failed, peer.state);
    try std.testing.expectEqual(@as(u32, 1), peer.failure_count);
}

test "peer score edge cases" {
    const allocator = std.testing.allocator;

    // Test banned peer has very negative score
    var banned_peer = try PeerInfo.init(allocator, "127.0.0.1", 9030, .bootstrap);
    defer banned_peer.deinit();
    banned_peer.state = .banned;
    try std.testing.expect(banned_peer.score() < -500);

    // Test connected peer has positive score
    var connected_peer = try PeerInfo.init(allocator, "127.0.0.2", 9030, .bootstrap);
    defer connected_peer.deinit();
    connected_peer.state = .connected;
    try std.testing.expect(connected_peer.score() > 0);

    // Test failure penalty accumulates
    var failed_peer = try PeerInfo.init(allocator, "127.0.0.3", 9030, .bootstrap);
    defer failed_peer.deinit();
    const initial_score = failed_peer.score();
    failed_peer.failure_count = 5;
    try std.testing.expect(failed_peer.score() < initial_score);
    try std.testing.expect(failed_peer.score() == initial_score - 100); // -20 per failure * 5
}

test "peer shouldRetry states" {
    const allocator = std.testing.allocator;

    // Banned peers should never retry
    var banned = try PeerInfo.init(allocator, "127.0.0.1", 9030, .bootstrap);
    defer banned.deinit();
    banned.state = .banned;
    try std.testing.expect(!banned.shouldRetry());

    // Connected peers should not retry
    var connected = try PeerInfo.init(allocator, "127.0.0.2", 9030, .bootstrap);
    defer connected.deinit();
    connected.state = .connected;
    try std.testing.expect(!connected.shouldRetry());

    // Connecting peers should not retry
    var connecting = try PeerInfo.init(allocator, "127.0.0.3", 9030, .bootstrap);
    defer connecting.deinit();
    connecting.state = .connecting;
    try std.testing.expect(!connecting.shouldRetry());

    // Unknown/seen/failed should retry (with backoff)
    var unknown = try PeerInfo.init(allocator, "127.0.0.4", 9030, .bootstrap);
    defer unknown.deinit();
    try std.testing.expect(unknown.shouldRetry());
}

test "scout connection tracking" {
    const allocator = std.testing.allocator;

    var scout = Discovery.init(allocator, NetworkMagic.mainnet);
    defer scout.deinit();

    try scout.addPeer("192.168.1.1", 9030, .bootstrap);

    // Record success
    scout.recordConnectionSuccess("192.168.1.1", 9030, null);
    const peer1 = scout.getPeer("192.168.1.1", 9030);
    try std.testing.expect(peer1 != null);
    try std.testing.expectEqual(PeerState.connected, peer1.?.state);
    try std.testing.expectEqual(@as(u32, 1), peer1.?.connection_count);

    // Record disconnect
    scout.recordDisconnect("192.168.1.1", 9030);
    try std.testing.expectEqual(PeerState.seen, peer1.?.state);

    // Record failure
    scout.recordConnectionFailure("192.168.1.1", 9030);
    try std.testing.expectEqual(PeerState.failed, peer1.?.state);
    try std.testing.expectEqual(@as(u32, 1), peer1.?.failure_count);
}

test "scout peerCountByState" {
    const allocator = std.testing.allocator;

    var scout = Discovery.init(allocator, NetworkMagic.mainnet);
    defer scout.deinit();

    try scout.addPeer("192.168.1.1", 9030, .bootstrap);
    try scout.addPeer("192.168.1.2", 9030, .bootstrap);
    try scout.addPeer("192.168.1.3", 9030, .bootstrap);

    // All start as unknown
    try std.testing.expectEqual(@as(usize, 3), scout.peerCountByState(.unknown));
    try std.testing.expectEqual(@as(usize, 0), scout.peerCountByState(.connected));

    // Connect one peer
    scout.recordConnectionSuccess("192.168.1.1", 9030, null);
    try std.testing.expectEqual(@as(usize, 2), scout.peerCountByState(.unknown));
    try std.testing.expectEqual(@as(usize, 1), scout.peerCountByState(.connected));

    // Fail another
    scout.recordConnectionFailure("192.168.1.2", 9030);
    try std.testing.expectEqual(@as(usize, 1), scout.peerCountByState(.unknown));
    try std.testing.expectEqual(@as(usize, 1), scout.peerCountByState(.failed));
}

test "scout testnet initialization" {
    const allocator = std.testing.allocator;

    var scout = Discovery.initTestnet(allocator);
    defer scout.deinit();

    // Should have testnet bootstrap peers
    try std.testing.expect(scout.peerCount() > 0);
    try std.testing.expect(std.mem.eql(u8, &scout.network_magic, &NetworkMagic.testnet));
}

test "scout getAllPeers" {
    const allocator = std.testing.allocator;

    var scout = Discovery.init(allocator, NetworkMagic.mainnet);
    defer scout.deinit();

    try scout.addPeer("192.168.1.1", 9030, .bootstrap);
    try scout.addPeer("192.168.1.2", 9030, .user_provided);

    const all_peers = try scout.getAllPeers();
    defer allocator.free(all_peers);

    try std.testing.expectEqual(@as(usize, 2), all_peers.len);
}
