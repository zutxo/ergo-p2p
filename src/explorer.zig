//! Explorer - Interactive network explorer for Ergo P2P.
//!
//! Provides an interactive REPL for:
//! - Managing multiple peer connections
//! - Monitoring mempool transactions
//! - Tracking block headers
//! - Exporting network topology graphs
//!
//! Example - Start the explorer:
//!
//!     var explorer = Explorer.init(allocator, NetworkMagic.mainnet, local_peer, config);
//!     defer explorer.deinit();
//!
//!     explorer.linkDiscovery();
//!     try explorer.run();
//!
//! The explorer runs an interactive command loop. Type 'help' for available
//! commands including 'connect', 'peers', 'mempool', 'headers', and 'broadcast'.

const std = @import("std");
const root = @import("ergo_p2p.zig");
const platform = root.platform;
const Color = platform.Color;
const Connection = root.connection.Connection;
const Discovery = root.Discovery;
const Pool = root.Pool;
const Peer = root.Peer;
const NetworkMagic = root.NetworkMagic;
const MessageCode = root.MessageCode;
const ModifierType = root.ModifierType;
const Header = root.Header;

// ============================================================================
// Mempool Entry
// ============================================================================

/// Entry in the mempool tracker.
pub const MempoolEntry = struct {
    tx_id: [32]u8,
    first_seen: i64,
    announcing_peers: std.ArrayList(u64),
    size: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, tx_id: [32]u8, first_seen: i64) MempoolEntry {
        return .{
            .tx_id = tx_id,
            .first_seen = first_seen,
            .announcing_peers = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *MempoolEntry) void {
        self.announcing_peers.deinit();
    }

    pub fn addAnnouncingPeer(self: *MempoolEntry, conn_id: u64) !void {
        // Check if already in list
        for (self.announcing_peers.items) |id| {
            if (id == conn_id) return;
        }
        try self.announcing_peers.append(conn_id);
    }
};

// ============================================================================
// Header Entry
// ============================================================================

/// Entry in the header tracker.
pub const HeaderEntry = struct {
    header_id: [32]u8,
    height: ?u32 = null,
    timestamp: ?u64 = null,
    first_seen: i64,
    announcing_peers: std.ArrayList(u64),
    parent_id: ?[32]u8 = null,

    pub fn init(allocator: std.mem.Allocator, header_id: [32]u8, first_seen: i64) HeaderEntry {
        return .{
            .header_id = header_id,
            .first_seen = first_seen,
            .announcing_peers = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *HeaderEntry) void {
        self.announcing_peers.deinit();
    }

    pub fn addAnnouncingPeer(self: *HeaderEntry, conn_id: u64) !void {
        for (self.announcing_peers.items) |id| {
            if (id == conn_id) return;
        }
        try self.announcing_peers.append(conn_id);
    }
};

// ============================================================================
// Node Metadata
// ============================================================================

/// Metadata about a connected node.
pub const NodeMetadata = struct {
    conn_id: u64,
    host: []const u8,
    port: u16,
    agent_name: ?[]const u8 = null,
    version: ?root.Version = null,
    connection_time: i64,
    messages_received: u64 = 0,
    last_message_time: ?i64 = null,
    headers_announced: u32 = 0,
    txs_announced: u32 = 0,
};

// ============================================================================
// Explorer State
// ============================================================================

/// Explorer configuration.
pub const Config = struct {
    /// Maximum transactions to track in mempool
    max_mempool_entries: u32 = 10000,
    /// Maximum headers to track
    max_header_entries: u32 = 1000,
    /// Auto-request headers when announced
    auto_request_headers: bool = true,
    /// Show verbose message output
    verbose: bool = false,
    /// Poll timeout in milliseconds
    poll_timeout_ms: u32 = 100,
};

/// Interactive network explorer.
pub const Explorer = struct {
    allocator: std.mem.Allocator,
    network_magic: [4]u8,
    local_peer: Peer,
    config: Config,

    /// Pool for connection management
    pool: Pool,

    /// Discovery for peer discovery
    discovery: Discovery,

    /// Mempool tracker
    mempool: std.AutoHashMap([32]u8, MempoolEntry),

    /// Header tracker
    headers: std.AutoHashMap([32]u8, HeaderEntry),

    /// Node metadata
    nodes: std.AutoHashMap(u64, NodeMetadata),

    /// Message streaming enabled for connections
    streaming: std.AutoHashMap(u64, bool),

    /// Running state
    running: bool,

    /// Statistics
    total_messages: u64,
    total_txs_seen: u64,
    total_headers_seen: u64,
    start_time: i64,

    /// Output writer
    stdout: std.fs.File.Writer,

    /// Creates a new Explorer instance.
    pub fn init(
        allocator: std.mem.Allocator,
        network_magic: [4]u8,
        local_peer: Peer,
        config: Config,
    ) Explorer {
        const scout_init = if (std.mem.eql(u8, &network_magic, &NetworkMagic.mainnet))
            Discovery.initMainnet(allocator)
        else
            Discovery.initTestnet(allocator);

        return Explorer{
            .allocator = allocator,
            .network_magic = network_magic,
            .local_peer = local_peer,
            .config = config,
            .pool = Pool.init(allocator, network_magic, local_peer),
            .discovery = scout_init,
            .mempool = std.AutoHashMap([32]u8, MempoolEntry).init(allocator),
            .headers = std.AutoHashMap([32]u8, HeaderEntry).init(allocator),
            .nodes = std.AutoHashMap(u64, NodeMetadata).init(allocator),
            .streaming = std.AutoHashMap(u64, bool).init(allocator),
            .running = false,
            .total_messages = 0,
            .total_txs_seen = 0,
            .total_headers_seen = 0,
            .start_time = platform.timestampMs(),
            .stdout = std.io.getStdOut().writer(),
        };
    }

    /// Links the pool to the discovery. Call this after the Explorer is at its final memory location.
    pub fn linkDiscovery(self: *Explorer) void {
        self.pool.discovery = &self.discovery;
    }

    pub fn deinit(self: *Explorer) void {
        // Clean up mempool entries
        var mempool_iter = self.mempool.valueIterator();
        while (mempool_iter.next()) |entry| {
            @constCast(entry).deinit();
        }
        self.mempool.deinit();

        // Clean up header entries
        var header_iter = self.headers.valueIterator();
        while (header_iter.next()) |entry| {
            @constCast(entry).deinit();
        }
        self.headers.deinit();

        self.nodes.deinit();
        self.streaming.deinit();
        self.pool.deinit();
        self.discovery.deinit();
    }

    /// Main explorer event loop.
    pub fn run(self: *Explorer) !void {
        self.running = true;
        self.start_time = platform.timestampMs();

        try self.printBanner();
        try self.printHelp();
        try self.stdout.print("\n", .{});

        // Main loop
        while (self.running) {
            // Print prompt
            try self.stdout.print("{s}ergo>{s} ", .{ Color.green, Color.reset });

            // Read command (non-blocking would be better, but for simplicity use blocking)
            var line_buf: [1024]u8 = undefined;
            const stdin = std.io.getStdIn();

            // Set up polling for stdin and sockets
            // For now, use simple blocking read with timeout simulation
            if (stdin.reader().readUntilDelimiterOrEof(&line_buf, '\n')) |line_opt| {
                if (line_opt) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (trimmed.len > 0) {
                        self.executeCommand(trimmed) catch |err| {
                            try self.stdout.print("{s}Error: {}{s}\n", .{ Color.red, err, Color.reset });
                        };
                    }
                } else {
                    // EOF reached - exit
                    self.running = false;
                }
            } else |_| {
                // Read error - exit
                self.running = false;
            }

            // Poll connections for messages
            try self.pollConnections();
        }

        try self.printSummary();
    }

    /// Polls all connections for incoming messages.
    fn pollConnections(self: *Explorer) !void {
        const conn_ids = try self.pool.getConnectionIds();
        defer self.allocator.free(conn_ids);

        for (conn_ids) |id| {
            const conn_info = self.pool.getConnection(id) orelse continue;
            if (conn_info.state != .connected) continue;
            const connection = conn_info.connection orelse continue;

            // Try to receive with short timeout
            const msg = connection.receiveMessageTimeout(self.config.poll_timeout_ms) catch |err| {
                if (err == root.connection.Error.ConnectionReset) {
                    conn_info.state = .disconnected;
                    try self.stdout.print("{s}[Connection {d} closed]{s}\n", .{ Color.yellow, id, Color.reset });
                }
                continue;
            };

            if (msg) |message_val| {
                var message = message_val;
                defer message.deinit();

                self.total_messages += 1;

                // Update node metadata
                if (self.nodes.getPtr(id)) |node| {
                    node.messages_received += 1;
                    node.last_message_time = platform.timestampMs();
                }

                // Process message
                try self.processMessage(id, &message);
            }
        }
    }

    /// Processes an incoming message.
    fn processMessage(self: *Explorer, conn_id: u64, message: *root.Message) !void {
        const streaming = self.streaming.get(conn_id) orelse false;

        switch (message.*) {
            .Inv => |inv| {
                switch (inv.type_id) {
                    .Transaction => {
                        for (inv.elements) |tx_id| {
                            try self.trackTransaction(tx_id, conn_id);
                        }
                        if (self.nodes.getPtr(conn_id)) |node| {
                            node.txs_announced += @intCast(inv.elements.len);
                        }
                    },
                    .Header => {
                        for (inv.elements) |header_id| {
                            try self.trackHeader(header_id, conn_id);
                        }
                        if (self.nodes.getPtr(conn_id)) |node| {
                            node.headers_announced += @intCast(inv.elements.len);
                        }

                        // Auto-request headers if enabled
                        if (self.config.auto_request_headers and inv.elements.len > 0) {
                            if (self.pool.getConnection(conn_id)) |conn| {
                                if (conn.connection) |connection| {
                                    connection.requestModifiers(.Header, inv.elements) catch {};
                                }
                            }
                        }
                    },
                    else => {},
                }

                if (streaming or self.config.verbose) {
                    try self.printInv(conn_id, inv);
                }
            },
            .ModifierResponse => |resp| {
                if (resp.type_id == .Header) {
                    for (resp.modifiers) |mod| {
                        // Try to parse and update header info
                        if (Header.fromBytes(mod.data, self.allocator)) |header| {
                            var hdr = header;
                            defer hdr.deinit();

                            if (self.headers.getPtr(mod.id)) |entry| {
                                entry.height = hdr.height;
                                entry.timestamp = hdr.timestamp;
                                entry.parent_id = hdr.parent_id;
                            }
                        } else |_| {}
                    }
                }

                if (streaming or self.config.verbose) {
                    try self.printModifierResponse(conn_id, resp);
                }
            },
            .Peers => |peers| {
                // Add discovered peers to scout
                for (peers.peer_list) |peer| {
                    if (peer.public_address) |addr| {
                        if (addr.isIPv4()) {
                            var host_buf: [16]u8 = undefined;
                            const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
                                addr.ip[0],
                                addr.ip[1],
                                addr.ip[2],
                                addr.ip[3],
                            }) catch continue;
                            self.discovery.addPeer(host, addr.port, .peer_exchange) catch {};
                        }
                    }
                }

                if (streaming or self.config.verbose) {
                    try self.stdout.print("{s}[{d}]{s} Peers: {d} peer(s)\n", .{
                        Color.green,
                        conn_id,
                        Color.reset,
                        peers.peer_list.len,
                    });
                }
            },
            .SyncInfo => |sync| {
                if (streaming or self.config.verbose) {
                    try self.stdout.print("{s}[{d}]{s} SyncInfo: {d} header(s)\n", .{
                        Color.blue,
                        conn_id,
                        Color.reset,
                        sync.last_header_ids.len,
                    });
                }
            },
            else => {},
        }
    }

    /// Tracks a transaction in the mempool.
    fn trackTransaction(self: *Explorer, tx_id: [32]u8, conn_id: u64) !void {
        const now = platform.timestampMs();

        if (self.mempool.getPtr(tx_id)) |entry| {
            try entry.addAnnouncingPeer(conn_id);
        } else {
            // Check limit
            if (self.mempool.count() >= self.config.max_mempool_entries) {
                // Remove oldest entry
                var oldest_id: ?[32]u8 = null;
                var oldest_time: i64 = std.math.maxInt(i64);

                var iter = self.mempool.iterator();
                while (iter.next()) |kv| {
                    if (kv.value_ptr.first_seen < oldest_time) {
                        oldest_time = kv.value_ptr.first_seen;
                        oldest_id = kv.key_ptr.*;
                    }
                }

                if (oldest_id) |oid| {
                    if (self.mempool.fetchRemove(oid)) |removed| {
                        @constCast(&removed.value).deinit();
                    }
                }
            }

            var entry = MempoolEntry.init(self.allocator, tx_id, now);
            try entry.addAnnouncingPeer(conn_id);
            try self.mempool.put(tx_id, entry);
            self.total_txs_seen += 1;
        }
    }

    /// Tracks a header.
    fn trackHeader(self: *Explorer, header_id: [32]u8, conn_id: u64) !void {
        const now = platform.timestampMs();

        if (self.headers.getPtr(header_id)) |entry| {
            try entry.addAnnouncingPeer(conn_id);
        } else {
            // Check limit
            if (self.headers.count() >= self.config.max_header_entries) {
                // Remove oldest entry
                var oldest_id: ?[32]u8 = null;
                var oldest_time: i64 = std.math.maxInt(i64);

                var iter = self.headers.iterator();
                while (iter.next()) |kv| {
                    if (kv.value_ptr.first_seen < oldest_time) {
                        oldest_time = kv.value_ptr.first_seen;
                        oldest_id = kv.key_ptr.*;
                    }
                }

                if (oldest_id) |oid| {
                    if (self.headers.fetchRemove(oid)) |removed| {
                        @constCast(&removed.value).deinit();
                    }
                }
            }

            var entry = HeaderEntry.init(self.allocator, header_id, now);
            try entry.addAnnouncingPeer(conn_id);
            try self.headers.put(header_id, entry);
            self.total_headers_seen += 1;
        }
    }

    // ========================================================================
    // Command Execution
    // ========================================================================

    /// Executes a command string.
    fn executeCommand(self: *Explorer, input: []const u8) !void {
        var iter = std.mem.splitScalar(u8, input, ' ');
        const cmd = iter.next() orelse return;

        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "?")) {
            try self.printHelp();
        } else if (std.mem.eql(u8, cmd, "connect") or std.mem.eql(u8, cmd, "c")) {
            try self.cmdConnect(&iter);
        } else if (std.mem.eql(u8, cmd, "disconnect") or std.mem.eql(u8, cmd, "d")) {
            try self.cmdDisconnect(&iter);
        } else if (std.mem.eql(u8, cmd, "peers") or std.mem.eql(u8, cmd, "p")) {
            try self.cmdPeers();
        } else if (std.mem.eql(u8, cmd, "discover")) {
            try self.cmdDiscover(&iter);
        } else if (std.mem.eql(u8, cmd, "mempool") or std.mem.eql(u8, cmd, "m")) {
            try self.cmdMempool(&iter);
        } else if (std.mem.eql(u8, cmd, "headers") or std.mem.eql(u8, cmd, "h")) {
            try self.cmdHeaders(&iter);
        } else if (std.mem.eql(u8, cmd, "stream") or std.mem.eql(u8, cmd, "s")) {
            try self.cmdStream(&iter);
        } else if (std.mem.eql(u8, cmd, "export") or std.mem.eql(u8, cmd, "e")) {
            try self.cmdExport(&iter);
        } else if (std.mem.eql(u8, cmd, "broadcast") or std.mem.eql(u8, cmd, "b")) {
            try self.cmdBroadcast(&iter);
        } else if (std.mem.eql(u8, cmd, "status")) {
            try self.cmdStatus();
        } else if (std.mem.eql(u8, cmd, "verbose") or std.mem.eql(u8, cmd, "v")) {
            self.config.verbose = !self.config.verbose;
            try self.stdout.print("Verbose mode: {s}{s}{s}\n", .{
                if (self.config.verbose) Color.green else Color.red,
                if (self.config.verbose) "on" else "off",
                Color.reset,
            });
        } else if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "exit")) {
            self.running = false;
        } else if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "cls")) {
            try self.stdout.print("\x1b[2J\x1b[H", .{});
        } else {
            try self.stdout.print("{s}Unknown command: {s}{s}\n", .{ Color.red, cmd, Color.reset });
            try self.stdout.print("Type 'help' for available commands.\n", .{});
        }
    }

    /// Connect command.
    fn cmdConnect(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        const addr = iter.next() orelse {
            try self.stdout.print("Usage: connect <host:port>\n", .{});
            return;
        };

        var host: []const u8 = addr;
        var port: u16 = 9030;

        if (std.mem.indexOf(u8, addr, ":")) |colon| {
            host = addr[0..colon];
            port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch {
                try self.stdout.print("{s}Invalid port{s}\n", .{ Color.red, Color.reset });
                return;
            };
        }

        try self.stdout.print("Connecting to {s}{s}:{d}{s}... ", .{ Color.yellow, host, port, Color.reset });

        if (self.pool.connect(host, port)) |id| {
            try self.stdout.print("{s}connected{s} (ID: {d})\n", .{ Color.green, Color.reset, id });

            // Add node metadata
            const conn = self.pool.getConnection(id) orelse return;
            var meta = NodeMetadata{
                .conn_id = id,
                .host = conn.host,
                .port = conn.port,
                .connection_time = platform.timestampMs(),
            };

            if (conn.remote_peer) |peer| {
                meta.agent_name = peer.agent_name;
                meta.version = peer.version;
                try self.stdout.print("  Peer: {s}{s}{s} v{}\n", .{
                    Color.cyan,
                    peer.agent_name,
                    Color.reset,
                    peer.version,
                });
            }

            try self.nodes.put(id, meta);
            try self.streaming.put(id, false);
        } else |err| {
            try self.stdout.print("{s}failed ({s}){s}\n", .{ Color.red, @errorName(err), Color.reset });
        }
    }

    /// Disconnect command.
    fn cmdDisconnect(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        const id_str = iter.next() orelse {
            try self.stdout.print("Usage: disconnect <id>\n", .{});
            return;
        };

        const id = std.fmt.parseInt(u64, id_str, 10) catch {
            try self.stdout.print("{s}Invalid connection ID{s}\n", .{ Color.red, Color.reset });
            return;
        };

        if (self.pool.getConnection(id)) |_| {
            self.pool.disconnect(id);
            _ = self.nodes.remove(id);
            _ = self.streaming.remove(id);
            try self.stdout.print("Disconnected from connection {d}\n", .{id});
        } else {
            try self.stdout.print("{s}Connection not found{s}\n", .{ Color.red, Color.reset });
        }
    }

    /// Peers command.
    fn cmdPeers(self: *Explorer) !void {
        const status = self.pool.getStatus();

        try self.stdout.print("\n{s}Connected Peers:{s} ({d} total)\n", .{
            Color.bold,
            Color.reset,
            status.connected,
        });

        if (status.connected == 0) {
            try self.stdout.print("  No peers connected. Use 'connect <host:port>' to connect.\n", .{});
            try self.stdout.print("\n", .{});
            return;
        }

        const conn_ids = try self.pool.getConnectionIds();
        defer self.allocator.free(conn_ids);

        for (conn_ids) |id| {
            const conn = self.pool.getConnection(id) orelse continue;
            const state_str = switch (conn.state) {
                .connected => "connected",
                .connecting => "connecting",
                .disconnected => "disconnected",
            };
            const state_color = switch (conn.state) {
                .connected => Color.green,
                .connecting => Color.yellow,
                .disconnected => Color.red,
            };

            try self.stdout.print("  [{d}] {s}{s}:{d}{s} ", .{
                id,
                Color.yellow,
                conn.host,
                conn.port,
                Color.reset,
            });

            if (self.nodes.get(id)) |meta| {
                if (meta.agent_name) |name| {
                    try self.stdout.print("({s}", .{name});
                    if (meta.version) |v| {
                        try self.stdout.print(" v{}", .{v});
                    }
                    try self.stdout.print(") ", .{});
                }
                try self.stdout.print("msgs:{d} ", .{meta.messages_received});
            }

            try self.stdout.print("{s}[{s}]{s}\n", .{ state_color, state_str, Color.reset });
        }

        try self.stdout.print("\n{s}Known Peers:{s} {d}\n\n", .{ Color.dim, Color.reset, self.discovery.peerCount() });
    }

    /// Discover command.
    fn cmdDiscover(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        _ = iter; // depth parameter for future use

        try self.stdout.print("Discovering peers from connected nodes... ", .{});
        const discovered = self.pool.requestPeersFromAll() catch 0;
        try self.stdout.print("{s}discovered {d} peers{s}\n", .{ Color.green, discovered, Color.reset });
        try self.stdout.print("Total known peers: {d}\n", .{self.discovery.peerCount()});
    }

    /// Mempool command.
    fn cmdMempool(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        const count_str = iter.next();
        const show_count: usize = if (count_str) |s|
            std.fmt.parseInt(usize, s, 10) catch 20
        else
            20;

        try self.stdout.print("\n{s}Mempool:{s} {d} transactions tracked\n\n", .{
            Color.bold,
            Color.reset,
            self.mempool.count(),
        });

        if (self.mempool.count() == 0) {
            try self.stdout.print("  No transactions in mempool yet.\n\n", .{});
            return;
        }

        // Collect and sort by first_seen (most recent first)
        var entries = std.ArrayList(MempoolEntry).init(self.allocator);
        defer entries.deinit();

        var iter2 = self.mempool.valueIterator();
        while (iter2.next()) |entry| {
            try entries.append(entry.*);
        }

        std.mem.sort(MempoolEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: MempoolEntry, b: MempoolEntry) bool {
                return a.first_seen > b.first_seen;
            }
        }.lessThan);

        const display_count = @min(show_count, entries.items.len);
        for (entries.items[0..display_count], 0..) |entry, i| {
            const id_hex = root.formatId(entry.tx_id);
            const age_ms = platform.timestampMs() - entry.first_seen;
            const age_sec = @divFloor(age_ms, 1000);

            try self.stdout.print("  [{d:>3}] {s}{s}...{s}{s} ", .{
                i + 1,
                Color.cyan,
                id_hex[0..16],
                id_hex[56..64],
                Color.reset,
            });
            try self.stdout.print("age:{d}s peers:{d}\n", .{ age_sec, entry.announcing_peers.items.len });
        }

        if (entries.items.len > show_count) {
            try self.stdout.print("  ... and {d} more\n", .{entries.items.len - show_count});
        }

        try self.stdout.print("\n", .{});
    }

    /// Headers command.
    fn cmdHeaders(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        const count_str = iter.next();
        const show_count: usize = if (count_str) |s|
            std.fmt.parseInt(usize, s, 10) catch 10
        else
            10;

        try self.stdout.print("\n{s}Headers:{s} {d} tracked\n\n", .{
            Color.bold,
            Color.reset,
            self.headers.count(),
        });

        if (self.headers.count() == 0) {
            try self.stdout.print("  No headers tracked yet.\n\n", .{});
            return;
        }

        // Collect and sort by height (highest first) or first_seen if no height
        var entries = std.ArrayList(HeaderEntry).init(self.allocator);
        defer entries.deinit();

        var iter2 = self.headers.valueIterator();
        while (iter2.next()) |entry| {
            try entries.append(entry.*);
        }

        std.mem.sort(HeaderEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: HeaderEntry, b: HeaderEntry) bool {
                const a_height = a.height orelse 0;
                const b_height = b.height orelse 0;
                if (a_height != b_height) return a_height > b_height;
                return a.first_seen > b.first_seen;
            }
        }.lessThan);

        const display_count = @min(show_count, entries.items.len);
        for (entries.items[0..display_count], 0..) |entry, i| {
            const id_hex = root.formatId(entry.header_id);

            try self.stdout.print("  [{d:>2}] {s}{s}...{s}{s}", .{
                i + 1,
                Color.cyan,
                id_hex[0..16],
                id_hex[56..64],
                Color.reset,
            });

            if (entry.height) |h| {
                try self.stdout.print(" height:{s}{d}{s}", .{ Color.yellow, h, Color.reset });
            }

            try self.stdout.print(" peers:{d}\n", .{entry.announcing_peers.items.len});
        }

        if (entries.items.len > show_count) {
            try self.stdout.print("  ... and {d} more\n", .{entries.items.len - show_count});
        }

        try self.stdout.print("\n", .{});
    }

    /// Stream command.
    fn cmdStream(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        const id_str = iter.next() orelse {
            // List streaming status
            try self.stdout.print("\n{s}Streaming Status:{s}\n", .{ Color.bold, Color.reset });

            const conn_ids = try self.pool.getConnectionIds();
            defer self.allocator.free(conn_ids);

            for (conn_ids) |id| {
                const enabled = self.streaming.get(id) orelse false;
                try self.stdout.print("  [{d}] {s}{s}{s}\n", .{
                    id,
                    if (enabled) Color.green else Color.dim,
                    if (enabled) "streaming" else "quiet",
                    Color.reset,
                });
            }

            try self.stdout.print("\nUsage: stream <id> [on|off]\n\n", .{});
            return;
        };

        const id = std.fmt.parseInt(u64, id_str, 10) catch {
            try self.stdout.print("{s}Invalid connection ID{s}\n", .{ Color.red, Color.reset });
            return;
        };

        if (self.pool.getConnection(id) == null) {
            try self.stdout.print("{s}Connection not found{s}\n", .{ Color.red, Color.reset });
            return;
        }

        const toggle = iter.next();
        const new_state = if (toggle) |t|
            std.mem.eql(u8, t, "on") or std.mem.eql(u8, t, "1")
        else
            !(self.streaming.get(id) orelse false);

        try self.streaming.put(id, new_state);
        try self.stdout.print("Streaming for connection {d}: {s}{s}{s}\n", .{
            id,
            if (new_state) Color.green else Color.red,
            if (new_state) "on" else "off",
            Color.reset,
        });
    }

    /// Export command - exports network graph in DOT format.
    fn cmdExport(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        const filename = iter.next() orelse "network.dot";

        const file = std.fs.cwd().createFile(filename, .{}) catch |err| {
            try self.stdout.print("{s}Failed to create file: {}{s}\n", .{ Color.red, err, Color.reset });
            return;
        };
        defer file.close();

        const writer = file.writer();

        // Write DOT header
        try writer.print("digraph ergo_network {{\n", .{});
        try writer.print("    rankdir=LR;\n", .{});
        try writer.print("    node [shape=box, style=filled];\n", .{});
        try writer.print("\n", .{});

        // Write our node
        try writer.print("    \"ergo-p2p\" [label=\"ergo-p2p\\n(this node)\", fillcolor=\"#90EE90\"];\n", .{});
        try writer.print("\n", .{});

        // Write connected peers
        const conn_ids = try self.pool.getConnectionIds();
        defer self.allocator.free(conn_ids);

        for (conn_ids) |id| {
            const conn = self.pool.getConnection(id) orelse continue;

            var label_buf: [256]u8 = undefined;
            var label: []const u8 = undefined;

            if (self.nodes.get(id)) |meta| {
                if (meta.agent_name) |name| {
                    if (meta.version) |v| {
                        label = std.fmt.bufPrint(&label_buf, "{s}:{d}\\n{s} v{}", .{
                            conn.host,
                            conn.port,
                            name,
                            v,
                        }) catch conn.host;
                    } else {
                        label = std.fmt.bufPrint(&label_buf, "{s}:{d}\\n{s}", .{
                            conn.host,
                            conn.port,
                            name,
                        }) catch conn.host;
                    }
                } else {
                    label = std.fmt.bufPrint(&label_buf, "{s}:{d}", .{ conn.host, conn.port }) catch conn.host;
                }
            } else {
                label = std.fmt.bufPrint(&label_buf, "{s}:{d}", .{ conn.host, conn.port }) catch conn.host;
            }

            const color = switch (conn.state) {
                .connected => "#87CEEB",
                .connecting => "#FFD700",
                .disconnected => "#FFA07A",
            };

            try writer.print("    \"node_{d}\" [label=\"{s}\", fillcolor=\"{s}\"];\n", .{ id, label, color });
            try writer.print("    \"ergo-p2p\" -> \"node_{d}\";\n", .{id});
        }

        // Write known peers (not connected)
        try writer.print("\n    // Known peers (not connected)\n", .{});
        const all_peers = try self.discovery.getAllPeers();
        defer self.allocator.free(all_peers);

        var known_count: u32 = 0;
        for (all_peers) |peer| {
            // Skip if already connected
            var is_connected = false;
            for (conn_ids) |id| {
                if (self.pool.getConnection(id)) |conn| {
                    if (std.mem.eql(u8, conn.host, peer.host) and conn.port == peer.port) {
                        is_connected = true;
                        break;
                    }
                }
            }

            if (!is_connected and known_count < 50) {
                try writer.print("    \"peer_{s}_{d}\" [label=\"{s}:{d}\", fillcolor=\"#D3D3D3\", style=\"filled,dashed\"];\n", .{
                    peer.host,
                    peer.port,
                    peer.host,
                    peer.port,
                });
                known_count += 1;
            }
        }

        try writer.print("}}\n", .{});

        try self.stdout.print("Exported network graph to {s}{s}{s}\n", .{ Color.green, filename, Color.reset });
        try self.stdout.print("View with: dot -Tpng {s} -o network.png\n", .{filename});
    }

    /// Broadcast command - broadcasts a transaction to connected peers.
    fn cmdBroadcast(self: *Explorer, iter: *std.mem.SplitIterator(u8, .scalar)) !void {
        const hex_str = iter.next() orelse {
            try self.stdout.print("Usage: broadcast <transaction_hex>\n", .{});
            try self.stdout.print("       broadcast <tx_id_hex> (to announce only)\n", .{});
            return;
        };

        // Check if we have any connections
        const status = self.pool.getStatus();
        if (status.connected == 0) {
            try self.stdout.print("{s}Error: No peers connected. Use 'connect' first.{s}\n", .{ Color.red, Color.reset });
            return;
        }

        // Parse hex
        if (hex_str.len % 2 != 0) {
            try self.stdout.print("{s}Error: Invalid hex length{s}\n", .{ Color.red, Color.reset });
            return;
        }

        const bytes = self.allocator.alloc(u8, hex_str.len / 2) catch {
            try self.stdout.print("{s}Error: Out of memory{s}\n", .{ Color.red, Color.reset });
            return;
        };
        defer self.allocator.free(bytes);

        for (0..bytes.len) |i| {
            bytes[i] = std.fmt.parseInt(u8, hex_str[i * 2 .. i * 2 + 2], 16) catch {
                try self.stdout.print("{s}Error: Invalid hex character{s}\n", .{ Color.red, Color.reset });
                return;
            };
        }

        var tx_id: [32]u8 = undefined;

        if (bytes.len == 32) {
            // Just a transaction ID - broadcast Inv only
            @memcpy(&tx_id, bytes);
            try self.stdout.print("Broadcasting transaction ID...\n", .{});
        } else {
            // Full transaction - parse and get ID
            var tx = root.Transaction.fromBytes(bytes, self.allocator) catch |err| {
                try self.stdout.print("{s}Error: Failed to parse transaction: {}{s}\n", .{ Color.red, err, Color.reset });
                return;
            };
            defer tx.deinit();

            tx_id = tx.computeId();

            try self.stdout.print("Transaction parsed:\n", .{});
            try self.stdout.print("  Inputs:  {d}\n", .{tx.inputs.len});
            try self.stdout.print("  Outputs: {d}\n", .{tx.outputs.len});

            var total: u64 = 0;
            for (tx.outputs) |out| total += out.value;
            const erg = @as(f64, @floatFromInt(total)) / 1_000_000_000.0;
            try self.stdout.print("  Value:   {d:.4} ERG\n", .{erg});
        }

        const tx_id_hex = root.formatId(tx_id);
        try self.stdout.print("  TX ID:   {s}{s}{s}\n\n", .{ Color.yellow, &tx_id_hex, Color.reset });

        // Broadcast Inv
        var tx_ids: [1][32]u8 = .{tx_id};

        const result = self.pool.broadcastInv(.{
            .type_id = .Transaction,
            .elements = &tx_ids,
        }, .all) catch |err| {
            try self.stdout.print("{s}Error broadcasting: {}{s}\n", .{ Color.red, err, Color.reset });
            return;
        };

        try self.stdout.print("{s}Broadcast result:{s}\n", .{ Color.bold, Color.reset });
        try self.stdout.print("  Successful: {s}{d}{s}\n", .{ Color.green, result.successful, Color.reset });
        try self.stdout.print("  Failed:     {s}{d}{s}\n", .{ Color.red, result.failed, Color.reset });
        try self.stdout.print("  Success rate: {d:.1}%\n\n", .{result.successRate() * 100});
    }

    /// Status command.
    fn cmdStatus(self: *Explorer) !void {
        const uptime_ms = platform.timestampMs() - self.start_time;
        const uptime_sec = @divFloor(uptime_ms, 1000);
        const uptime_min = @divFloor(uptime_sec, 60);

        const status = self.pool.getStatus();

        try self.stdout.print("\n{s}Explorer Status:{s}\n", .{ Color.bold, Color.reset });
        try self.stdout.print("  Network:          {s}{s}{s}\n", .{ Color.cyan, NetworkMagic.name(self.network_magic), Color.reset });
        try self.stdout.print("  Uptime:           {d}m {d}s\n", .{ uptime_min, @mod(uptime_sec, 60) });
        try self.stdout.print("  Connections:      {s}{d}{s} connected, {d} known\n", .{
            Color.green,
            status.connected,
            Color.reset,
            self.discovery.peerCount(),
        });
        try self.stdout.print("  Messages:         {d}\n", .{self.total_messages});
        try self.stdout.print("  Mempool:          {d} txs ({d} total seen)\n", .{ self.mempool.count(), self.total_txs_seen });
        try self.stdout.print("  Headers:          {d} tracked ({d} total seen)\n", .{ self.headers.count(), self.total_headers_seen });
        try self.stdout.print("  Verbose:          {s}\n", .{if (self.config.verbose) "on" else "off"});
        try self.stdout.print("\n", .{});
    }

    // ========================================================================
    // Output Helpers
    // ========================================================================

    fn printBanner(self: *Explorer) !void {
        try self.stdout.print("\n", .{});
        try self.stdout.print("{s}╔═══════════════════════════════════════════════════════════╗{s}\n", .{ Color.cyan, Color.reset });
        try self.stdout.print("{s}║{s}  {s}ergo-p2p{s} Interactive Explorer                            {s}║{s}\n", .{ Color.cyan, Color.reset, Color.bold, Color.reset, Color.cyan, Color.reset });
        try self.stdout.print("{s}║{s}  Network: {s}{s:<20}{s}                        {s}║{s}\n", .{ Color.cyan, Color.reset, Color.yellow, NetworkMagic.name(self.network_magic), Color.reset, Color.cyan, Color.reset });
        try self.stdout.print("{s}╚═══════════════════════════════════════════════════════════╝{s}\n", .{ Color.cyan, Color.reset });
        try self.stdout.print("\n", .{});
    }

    fn printHelp(self: *Explorer) !void {
        try self.stdout.print("{s}Commands:{s}\n", .{ Color.bold, Color.reset });
        try self.stdout.print("  {s}connect{s} <host:port>  Connect to a peer\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}disconnect{s} <id>      Disconnect from peer\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}peers{s}                List connected peers\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}discover{s}             Discover peers via GetPeers\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}mempool{s} [count]      Show mempool transactions\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}headers{s} [count]      Show tracked headers\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}broadcast{s} <hex>      Broadcast transaction\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}stream{s} <id> [on|off] Toggle message streaming\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}status{s}               Show explorer status\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}export{s} [file]        Export network graph (DOT)\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}verbose{s}              Toggle verbose output\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}clear{s}                Clear screen\n", .{ Color.green, Color.reset });
        try self.stdout.print("  {s}quit{s}                 Exit explorer\n", .{ Color.green, Color.reset });
        try self.stdout.print("\n{s}Shortcuts:{s} c=connect, d=disconnect, p=peers, m=mempool, h=headers, b=broadcast, s=stream, e=export, v=verbose, q=quit\n", .{ Color.dim, Color.reset });
    }

    fn printInv(self: *Explorer, conn_id: u64, inv: root.Inv) !void {
        var ts_buf: [32]u8 = undefined;
        const ts = platform.formatTimestamp(platform.timestampMs(), &ts_buf);

        const type_color = switch (inv.type_id) {
            .Transaction => Color.cyan,
            .Header => Color.yellow,
            else => Color.dim,
        };

        try self.stdout.print("[{s}] {s}[{d}]{s} Inv: {d} {s}{s}{s}(s)\n", .{
            ts,
            Color.dim,
            conn_id,
            Color.reset,
            inv.elements.len,
            type_color,
            inv.type_id.name(),
            Color.reset,
        });
    }

    fn printModifierResponse(self: *Explorer, conn_id: u64, resp: root.ModifierResponse) !void {
        var ts_buf: [32]u8 = undefined;
        const ts = platform.formatTimestamp(platform.timestampMs(), &ts_buf);

        try self.stdout.print("[{s}] {s}[{d}]{s} ModifierResponse: {d} {s}(s)\n", .{
            ts,
            Color.dim,
            conn_id,
            Color.reset,
            resp.modifiers.len,
            resp.type_id.name(),
        });
    }

    fn printSummary(self: *Explorer) !void {
        const uptime_ms = platform.timestampMs() - self.start_time;
        const uptime_sec = @divFloor(uptime_ms, 1000);

        try self.stdout.print("\n{s}Session Summary:{s}\n", .{ Color.bold, Color.reset });
        try self.stdout.print("  Duration:     {d} seconds\n", .{uptime_sec});
        try self.stdout.print("  Messages:     {d}\n", .{self.total_messages});
        try self.stdout.print("  Transactions: {d} seen\n", .{self.total_txs_seen});
        try self.stdout.print("  Headers:      {d} seen\n", .{self.total_headers_seen});
        try self.stdout.print("\nGoodbye!\n\n", .{});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "explorer initialization" {
    const allocator = std.testing.allocator;
    const peer = try Peer.init("test", "test", root.DefaultVersion, &root.BasicFeatureSet);

    var explorer = Explorer.init(allocator, NetworkMagic.mainnet, peer, .{});
    defer explorer.deinit();

    try std.testing.expectEqual(@as(usize, 0), explorer.mempool.count());
    try std.testing.expectEqual(@as(usize, 0), explorer.headers.count());
}

test "mempool entry tracking" {
    const allocator = std.testing.allocator;

    var tx_id: [32]u8 = undefined;
    @memset(&tx_id, 0xAB);

    var entry = MempoolEntry.init(allocator, tx_id, 12345);
    defer entry.deinit();

    try entry.addAnnouncingPeer(1);
    try entry.addAnnouncingPeer(2);
    try entry.addAnnouncingPeer(1); // Duplicate, should not add

    try std.testing.expectEqual(@as(usize, 2), entry.announcing_peers.items.len);
}

test "header entry tracking" {
    const allocator = std.testing.allocator;

    var header_id: [32]u8 = undefined;
    @memset(&header_id, 0xCD);

    var entry = HeaderEntry.init(allocator, header_id, 12345);
    defer entry.deinit();

    try entry.addAnnouncingPeer(1);
    try std.testing.expectEqual(@as(usize, 1), entry.announcing_peers.items.len);
}
