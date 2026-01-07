//! ergo-p2p - Ergo P2P Network Tool
//!
//! A high-performance, zero-dependency Ergo blockchain P2P networking
//! library and interactive CLI tool.

const std = @import("std");
const ergo = @import("ergo-p2p");

const Connection = ergo.connection.Connection;
const NetworkMagic = ergo.NetworkMagic;
const Version = ergo.Version;
const Peer = ergo.Peer;
const MessageCode = ergo.MessageCode;
const ModifierType = ergo.ModifierType;
const platform = ergo.platform;
const Color = platform.Color;

const version_string = "0.1.0";

/// Command line arguments.
const Args = struct {
    command: Command = .help,
    network: [4]u8 = NetworkMagic.mainnet,
    peer_host: ?[]const u8 = null,
    peer_port: u16 = 9030,
    agent_name: []const u8 = ergo.DefaultAgentName,
    show_help: bool = false,
    /// Transaction hex for broadcast command
    tx_hex: ?[]const u8 = null,
    /// Transaction file for broadcast command
    tx_file: ?[]const u8 = null,
    /// Broadcast strategy
    broadcast_strategy: []const u8 = "all",
    /// Number of peers for broadcast
    peer_count: u32 = 8,
};

const Command = enum {
    help,
    monitor,
    discover,
    relay,
    explore,
    broadcast,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Early argument parsing allows us to show help or errors before any network operations.
    const args = parseArgs() catch |err| {
        try stderr.print("Error parsing arguments: {}\n", .{err});
        try printUsage(stderr);
        return;
    };

    if (args.show_help or args.command == .help) {
        try printUsage(stdout);
        return;
    }

    // Dispatch to the appropriate command handler based on user selection.
    switch (args.command) {
        .monitor => try runMonitor(allocator, args, stdout, stderr),
        .discover => try runDiscover(allocator, args, stdout, stderr),
        .relay => try runRelay(allocator, args, stdout, stderr),
        .explore => try runExplore(allocator, args, stderr),
        .broadcast => try runBroadcast(allocator, args, stdout, stderr),
        .help => try printUsage(stdout),
    }
}

/// Parses command line arguments.
fn parseArgs() !Args {
    var args = Args{};
    var arg_iter = std.process.args();

    // First arg is always the executable name, not user input.
    _ = arg_iter.skip();

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.show_help = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--network")) {
            const network = arg_iter.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, network, "mainnet")) {
                args.network = NetworkMagic.mainnet;
            } else if (std.mem.eql(u8, network, "testnet")) {
                args.network = NetworkMagic.testnet;
            } else {
                return error.InvalidNetwork;
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--peer")) {
            const addr = arg_iter.next() orelse return error.MissingArgument;
            // Support "host:port" syntax for convenience; otherwise use default port.
            if (std.mem.indexOf(u8, addr, ":")) |colon_pos| {
                args.peer_host = addr[0..colon_pos];
                args.peer_port = std.fmt.parseInt(u16, addr[colon_pos + 1 ..], 10) catch return error.InvalidPort;
            } else {
                args.peer_host = addr;
            }
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--agent")) {
            args.agent_name = arg_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "monitor")) {
            args.command = .monitor;
        } else if (std.mem.eql(u8, arg, "discover")) {
            args.command = .discover;
        } else if (std.mem.eql(u8, arg, "relay")) {
            args.command = .relay;
        } else if (std.mem.eql(u8, arg, "explore")) {
            args.command = .explore;
        } else if (std.mem.eql(u8, arg, "broadcast")) {
            args.command = .broadcast;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tx")) {
            args.tx_hex = arg_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            args.tx_file = arg_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--strategy")) {
            args.broadcast_strategy = arg_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            const count_str = arg_iter.next() orelse return error.MissingArgument;
            args.peer_count = std.fmt.parseInt(u32, count_str, 10) catch return error.InvalidNumber;
        } else if (arg[0] == '-') {
            return error.UnknownOption;
        }
    }

    return args;
}

/// Runs the monitor command.
fn runMonitor(allocator: std.mem.Allocator, args: Args, stdout: anytype, stderr: anytype) !void {
    const host = args.peer_host orelse {
        try stderr.print("Error: No peer address specified. Use -p <host:port>\n", .{});
        return;
    };

    try stdout.print("{s}ergo-p2p v{s}{s} - Monitor Mode\n", .{ Color.bold, version_string, Color.reset });
    try stdout.print("Network: {s}{s}{s}\n", .{ Color.cyan, NetworkMagic.name(args.network), Color.reset });
    try stdout.print("Connecting to: {s}{s}:{d}{s}\n\n", .{ Color.yellow, host, args.peer_port, Color.reset });

    // Peer identity is required for the Ergo P2P handshake protocol.
    const local_peer = try Peer.init(
        args.agent_name,
        args.agent_name,
        ergo.DefaultVersion,
        &ergo.BasicFeatureSet,
    );

    // Single connection since monitor mode focuses on one peer's messages.
    var conn = Connection.init(allocator, args.network, local_peer);
    defer conn.deinit();

    // Must establish TCP connection before protocol handshake.
    try stdout.print("Connecting...\n", .{});
    conn.connectTo(host, args.peer_port) catch |err| {
        try stderr.print("{s}Connection failed: {}{s}\n", .{ Color.red, err, Color.reset });
        return;
    };
    try stdout.print("{s}Connected!{s}\n", .{ Color.green, Color.reset });

    // Ergo nodes reject messages until handshake completes.
    try stdout.print("Sending handshake...\n", .{});
    conn.sendHandshake() catch |err| {
        try stderr.print("{s}Handshake send failed: {}{s}\n", .{ Color.red, err, Color.reset });
        return;
    };

    try stdout.print("Waiting for handshake response...\n", .{});
    conn.receiveHandshake() catch |err| {
        try stderr.print("{s}Handshake receive failed: {}{s}\n", .{ Color.red, err, Color.reset });
        return;
    };

    // Display remote peer details to help identify the node software and version.
    if (conn.getRemotePeer()) |peer| {
        try stdout.print("\n{s}Peer Info:{s}\n", .{ Color.bold, Color.reset });
        try stdout.print("  Agent: {s}{s}{s}\n", .{ Color.cyan, peer.agent_name, Color.reset });
        try stdout.print("  Name:  {s}{s}{s}\n", .{ Color.cyan, peer.peer_name, Color.reset });
        try stdout.print("  Version: {s}{}{s}\n", .{ Color.cyan, peer.version, Color.reset });
        try stdout.print("  Features: {d}\n", .{peer.features.len});
        if (peer.public_address) |addr| {
            try stdout.print("  Address: {}\n", .{addr});
        }
    }

    try stdout.print("\n{s}Monitoring messages (Ctrl+C to quit)...{s}\n\n", .{ Color.dim, Color.reset });

    // SyncInfo signals readiness for block announcements; nodes won't push Inv without it.
    try stdout.print("Sending SyncInfo...\n", .{});
    try conn.sendSyncInfo();

    // GetPeers helps us learn about other nodes in the network for future connections.
    try stdout.print("Sending GetPeers request...\n", .{});
    try conn.sendGetPeers();

    // Event loop: continuously receive and display messages until timeout or disconnect.
    var msg_count: u64 = 0;
    var timeout_count: u32 = 0;
    while (conn.isConnected()) {
        const msg = conn.receiveMessageTimeout(5000) catch |err| {
            if (err == ergo.connection.Error.ConnectionReset) {
                try stdout.print("\n{s}Connection closed by peer{s}\n", .{ Color.yellow, Color.reset });
                break;
            }
            try stderr.print("Error receiving message: {}\n", .{err});
            continue;
        };

        // null indicates timeout with no message; track consecutive timeouts for idle detection.
        if (msg) |message_val| {
            timeout_count = 0;
            var message = message_val;
            defer message.deinit();
            msg_count += 1;

            var ts_buf: [32]u8 = undefined;
            const ts = platform.formatTimestamp(platform.timestampMs(), &ts_buf);

            switch (message) {
                .GetPeers => {
                    try stdout.print("[{s}] {s}GetPeers{s} request received\n", .{ ts, Color.green, Color.reset });
                },
                .Peers => |peers| {
                    try stdout.print("[{s}] {s}Peers{s}: {d} peers\n", .{ ts, Color.green, Color.reset, peers.peer_list.len });
                    for (peers.peer_list, 0..) |peer, i| {
                        try stdout.print("    [{d}] {s} v{} ({s})\n", .{ i, peer.agent_name, peer.version, peer.peer_name });
                    }
                },
                .Inv => |inv| {
                    try stdout.print("[{s}] {s}Inv{s}: {d} {s}(s)\n", .{
                        ts,
                        Color.cyan,
                        Color.reset,
                        inv.elements.len,
                        inv.type_id.name(),
                    });
                    // Request only recent headers to avoid overwhelming the connection with old data.
                    if (inv.elements.len > 0 and inv.type_id == .Header) {
                        const start = if (inv.elements.len > 3) inv.elements.len - 3 else 0;
                        const count = inv.elements.len - start;
                        try stdout.print("    Requesting {d} header(s)...\n", .{count});
                        conn.requestModifiers(inv.type_id, inv.elements[start..]) catch |err| {
                            try stderr.print("    {s}Error requesting modifiers: {}{s}\n", .{ Color.red, err, Color.reset });
                        };
                    }
                },
                .ModifierRequest => |req| {
                    try stdout.print("[{s}] {s}ModifierRequest{s}: {d} {s}(s)\n", .{
                        ts,
                        Color.magenta,
                        Color.reset,
                        req.elements.len,
                        req.type_id.name(),
                    });
                },
                .ModifierResponse => |resp| {
                    try stdout.print("[{s}] {s}ModifierResponse{s}: {d} {s}(s)\n", .{
                        ts,
                        Color.yellow,
                        Color.reset,
                        resp.modifiers.len,
                        resp.type_id.name(),
                    });
                    for (resp.modifiers, 0..) |mod, i| {
                        const id_hex = ergo.formatId(mod.id);

                        // Header parsing extracts structured block info for display.
                        if (resp.type_id == .Header) {
                            if (ergo.Header.fromBytes(mod.data, allocator)) |header| {
                                var hdr = header;
                                defer hdr.deinit();
                                const computed_id = hdr.computeId();
                                const computed_hex = ergo.formatId(computed_id);
                                const parent_hex = ergo.formatId(hdr.parent_id);

                                try stdout.print("    [{d}] {s}Header{s} v{d} height={d}\n", .{
                                    i,
                                    Color.cyan,
                                    Color.reset,
                                    hdr.version,
                                    hdr.height,
                                });
                                try stdout.print("         ID:     {s}...{s}\n", .{
                                    computed_hex[0..16],
                                    computed_hex[56..64],
                                });
                                try stdout.print("         Parent: {s}...{s}\n", .{
                                    parent_hex[0..16],
                                    parent_hex[56..64],
                                });
                                try stdout.print("         Time:   {d} ms\n", .{hdr.timestamp});
                            } else |_| {
                                try stdout.print("    [{d}] ID: {s}...{s} ({d} bytes) [parse error]\n", .{
                                    i,
                                    id_hex[0..16],
                                    id_hex[56..64],
                                    mod.data.len,
                                });
                            }
                        } else {
                            try stdout.print("    [{d}] ID: {s}...{s} ({d} bytes)\n", .{
                                i,
                                id_hex[0..16],
                                id_hex[56..64],
                                mod.data.len,
                            });
                        }
                    }
                },
                .SyncInfo => |sync| {
                    try stdout.print("[{s}] {s}SyncInfo{s}: {d} header ID(s)\n", .{ ts, Color.blue, Color.reset, sync.last_header_ids.len });
                },
            }
        } else {
            // Timeout - no message received
            timeout_count += 1;
            if (timeout_count >= 12) { // 60 seconds total
                try stdout.print("\n{s}No messages for 60 seconds, exiting...{s}\n", .{ Color.dim, Color.reset });
                break;
            }
        }
    }

    try stdout.print("\nTotal messages received: {d}\n", .{msg_count});
}

/// Runs the discover command - discovers peers from bootstrap nodes.
fn runDiscover(allocator: std.mem.Allocator, args: Args, stdout: anytype, stderr: anytype) !void {
    try stdout.print("{s}ergo-p2p v{s}{s} - Peer Discovery\n", .{ Color.bold, version_string, Color.reset });
    try stdout.print("Network: {s}{s}{s}\n\n", .{ Color.cyan, NetworkMagic.name(args.network), Color.reset });

    // Bootstrap peers provide initial entry points; we expand from there.
    var discovery = if (std.mem.eql(u8, &args.network, &NetworkMagic.mainnet))
        ergo.Discovery.initMainnet(allocator)
    else
        ergo.Discovery.initTestnet(allocator);
    defer discovery.deinit();

    try stdout.print("Loaded {s}{d}{s} bootstrap peers\n", .{ Color.green, discovery.peerCount(), Color.reset });

    // Peer identity required for protocol handshake.
    const local_peer = try Peer.init(
        args.agent_name,
        args.agent_name,
        ergo.DefaultVersion,
        &ergo.BasicFeatureSet,
    );

    // User-specified peer takes priority for discovery starting point.
    if (args.peer_host) |host| {
        try discovery.addPeer(host, args.peer_port, .user_provided);
    }

    // selectBestPeers() ranks by success rate and recency; try top candidates first.
    const peers_to_try = try discovery.selectBestPeers(5);
    defer allocator.free(peers_to_try);

    if (peers_to_try.len == 0) {
        try stderr.print("{s}No peers available to connect to{s}\n", .{ Color.red, Color.reset });
        return;
    }

    try stdout.print("\nAttempting to discover peers from {d} nodes...\n\n", .{peers_to_try.len});

    var total_discovered: usize = 0;

    for (peers_to_try) |peer_info| {
        try stdout.print("Connecting to {s}{s}:{d}{s}... ", .{ Color.yellow, peer_info.host, peer_info.port, Color.reset });

        // Fresh connection per peer; connection pooling not needed for discovery.
        var conn = Connection.init(allocator, args.network, local_peer);
        defer conn.deinit();

        // Establish TCP before protocol handshake.
        conn.connectTo(peer_info.host, peer_info.port) catch |err| {
            try stdout.print("{s}failed ({s}){s}\n", .{ Color.red, @errorName(err), Color.reset });
            discovery.recordConnectionFailure(peer_info.host, peer_info.port);
            continue;
        };

        try stdout.print("{s}connected{s}\n", .{ Color.green, Color.reset });

        // Protocol handshake required before any other messages.
        conn.performHandshake() catch |err| {
            try stdout.print("  Handshake failed: {s}{s}{s}\n", .{ Color.red, @errorName(err), Color.reset });
            discovery.recordConnectionFailure(peer_info.host, peer_info.port);
            continue;
        };

        // Track success for peer scoring algorithm.
        discovery.recordConnectionSuccess(peer_info.host, peer_info.port, conn.getRemotePeer());

        if (conn.getRemotePeer()) |remote| {
            try stdout.print("  Peer: {s}{s}{s} v{}\n", .{ Color.cyan, remote.agent_name, Color.reset, remote.version });
        }

        // GetPeers returns the peer's known addresses, expanding our network view.
        try stdout.print("  Requesting peers... ", .{});
        const discovered = discovery.discoverFromConnection(&conn) catch |err| {
            try stdout.print("{s}failed ({s}){s}\n", .{ Color.red, @errorName(err), Color.reset });
            continue;
        };

        try stdout.print("{s}discovered {d} new peers{s}\n", .{ Color.green, discovered, Color.reset });
        total_discovered += discovered;

        // Update state for scoring; don't keep idle connections open.
        discovery.recordDisconnect(peer_info.host, peer_info.port);
    }

    // Summary shows overall discovery effectiveness.
    try stdout.print("\n{s}Discovery Summary:{s}\n", .{ Color.bold, Color.reset });
    try stdout.print("  Total known peers: {s}{d}{s}\n", .{ Color.green, discovery.peerCount(), Color.reset });
    try stdout.print("  Newly discovered:  {s}{d}{s}\n", .{ Color.green, total_discovered, Color.reset });

    // Display all known peers for user inspection.
    try stdout.print("\n{s}Known Peers:{s}\n", .{ Color.bold, Color.reset });

    const all_peers = try discovery.getAllPeers();
    defer allocator.free(all_peers);

    // Higher scores indicate more reliable peers; show best first.
    std.mem.sort(ergo.PeerInfo, all_peers, {}, struct {
        fn lessThan(_: void, a: ergo.PeerInfo, b: ergo.PeerInfo) bool {
            return a.score() > b.score();
        }
    }.lessThan);

    for (all_peers, 0..) |peer, i| {
        const state_color = switch (peer.state) {
            .connected, .seen => Color.green,
            .failed => Color.red,
            .banned => Color.red,
            else => Color.dim,
        };
        try stdout.print("  [{d:>2}] {s}{s}:{d}{s}", .{ i + 1, Color.yellow, peer.host, peer.port, Color.reset });
        if (peer.agent_name) |name| {
            try stdout.print(" ({s}", .{name});
            if (peer.version) |v| {
                try stdout.print(" v{}", .{v});
            }
            try stdout.print(")", .{});
        }
        try stdout.print(" {s}[{s}]{s}\n", .{ state_color, @tagName(peer.state), Color.reset });
    }
}

/// Runs the relay command - connects to multiple peers and monitors.
fn runRelay(allocator: std.mem.Allocator, args: Args, stdout: anytype, stderr: anytype) !void {
    try stdout.print("{s}ergo-p2p v{s}{s} - Multi-Peer Relay\n", .{ Color.bold, version_string, Color.reset });
    try stdout.print("Network: {s}{s}{s}\n\n", .{ Color.cyan, NetworkMagic.name(args.network), Color.reset });

    // Bootstrap peers provide initial network entry points.
    var discovery = if (std.mem.eql(u8, &args.network, &NetworkMagic.mainnet))
        ergo.Discovery.initMainnet(allocator)
    else
        ergo.Discovery.initTestnet(allocator);
    defer discovery.deinit();

    // Peer identity required for protocol handshake.
    const local_peer = try Peer.init(
        args.agent_name,
        args.agent_name,
        ergo.DefaultVersion,
        &ergo.BasicFeatureSet,
    );

    // User-specified peer takes priority for connection.
    if (args.peer_host) |host| {
        try discovery.addPeer(host, args.peer_port, .user_provided);
    }

    // Pool manages multiple connections; discovery integration enables peer tracking.
    var pool = ergo.Pool.initWithDiscovery(allocator, args.network, local_peer, &discovery);
    defer pool.deinit();

    pool.setMaxConnections(8);

    try stdout.print("Connecting to peers...\n\n", .{});

    // Connect to highest-scoring peers for reliability.
    const peers = try discovery.selectBestPeers(8);
    defer allocator.free(peers);

    for (peers) |peer_info| {
        try stdout.print("  Connecting to {s}{s}:{d}{s}... ", .{ Color.yellow, peer_info.host, peer_info.port, Color.reset });

        if (pool.connect(peer_info.host, peer_info.port)) |id| {
            if (pool.getConnection(id)) |conn| {
                if (conn.remote_peer) |remote| {
                    try stdout.print("{s}connected{s} ({s} v{})\n", .{
                        Color.green,
                        Color.reset,
                        remote.agent_name,
                        remote.version,
                    });
                } else {
                    try stdout.print("{s}connected{s}\n", .{ Color.green, Color.reset });
                }
            }
        } else |err| {
            try stdout.print("{s}failed ({s}){s}\n", .{ Color.red, @errorName(err), Color.reset });
        }
    }

    // Show user how many peers are available for relay operations.
    const status = pool.getStatus();
    try stdout.print("\n{s}Connection Summary:{s}\n", .{ Color.bold, Color.reset });
    try stdout.print("  Connected:    {s}{d}{s}\n", .{ Color.green, status.connected, Color.reset });
    try stdout.print("  Failed:       {s}{d}{s}\n", .{ Color.red, status.disconnected, Color.reset });

    if (status.connected == 0) {
        try stderr.print("\n{s}No peers connected. Exiting.{s}\n", .{ Color.red, Color.reset });
        return;
    }

    // Expand network knowledge while connections are active.
    try stdout.print("\nDiscovering peers from connected nodes... ", .{});
    const discovered = pool.requestPeersFromAll() catch 0;
    try stdout.print("{s}discovered {d} peers{s}\n", .{ Color.green, discovered, Color.reset });
    try stdout.print("Total known peers: {d}\n", .{discovery.peerCount()});

    // Event loop: aggregate messages from all peers until timeout or all disconnected.
    try stdout.print("\n{s}Monitoring messages (Ctrl+C to quit)...{s}\n\n", .{ Color.dim, Color.reset });

    var msg_count: u64 = 0;
    var timeout_count: u32 = 0;

    // Snapshot connection IDs; pool membership doesn't change during monitoring.
    const conn_ids = try pool.getConnectionIds();
    defer allocator.free(conn_ids);

    while (pool.connectionCount() > 0) {
        var received_any = false;

        // Round-robin polling ensures no single peer monopolizes processing.
        for (conn_ids) |id| {
            const conn_info = pool.getConnection(id) orelse continue;
            if (conn_info.state != .connected) continue;

            const connection = conn_info.connection orelse continue;

            const msg = connection.receiveMessageTimeout(100) catch |err| {
                if (err == ergo.connection.Error.ConnectionReset) {
                    conn_info.state = .disconnected;
                    try stdout.print("{s}[{s}:{d}] Connection closed{s}\n", .{
                        Color.yellow,
                        conn_info.host,
                        conn_info.port,
                        Color.reset,
                    });
                }
                continue;
            };

            if (msg) |message_val| {
                var message = message_val;
                defer message.deinit();
                msg_count += 1;
                received_any = true;
                timeout_count = 0;

                var ts_buf: [32]u8 = undefined;
                const ts = platform.formatTimestamp(platform.timestampMs(), &ts_buf);

                switch (message) {
                    .Inv => |inv| {
                        try stdout.print("[{s}] {s}[{s}:{d}]{s} Inv: {d} {s}(s)\n", .{
                            ts,
                            Color.cyan,
                            conn_info.host,
                            conn_info.port,
                            Color.reset,
                            inv.elements.len,
                            inv.type_id.name(),
                        });
                    },
                    .Peers => |peers_msg| {
                        try stdout.print("[{s}] {s}[{s}:{d}]{s} Peers: {d} peer(s)\n", .{
                            ts,
                            Color.green,
                            conn_info.host,
                            conn_info.port,
                            Color.reset,
                            peers_msg.peer_list.len,
                        });
                    },
                    .SyncInfo => |sync| {
                        try stdout.print("[{s}] {s}[{s}:{d}]{s} SyncInfo: {d} header(s)\n", .{
                            ts,
                            Color.blue,
                            conn_info.host,
                            conn_info.port,
                            Color.reset,
                            sync.last_header_ids.len,
                        });
                    },
                    .ModifierResponse => |resp| {
                        try stdout.print("[{s}] {s}[{s}:{d}]{s} ModifierResponse: {d} {s}(s)\n", .{
                            ts,
                            Color.yellow,
                            conn_info.host,
                            conn_info.port,
                            Color.reset,
                            resp.modifiers.len,
                            resp.type_id.name(),
                        });
                    },
                    else => {},
                }
            }
        }

        if (!received_any) {
            timeout_count += 1;
            if (timeout_count >= 600) { // 60 seconds (600 * 100ms)
                try stdout.print("\n{s}No messages for 60 seconds, exiting...{s}\n", .{ Color.dim, Color.reset });
                break;
            }
        }
    }

    // Show session statistics before exit.
    const final_status = pool.getStatus();
    try stdout.print("\n{s}Final Status:{s}\n", .{ Color.bold, Color.reset });
    try stdout.print("  Messages received: {d}\n", .{msg_count});
    try stdout.print("  Connections:       {d} connected, {d} disconnected\n", .{ final_status.connected, final_status.disconnected });
    try stdout.print("  Known peers:       {d}\n", .{discovery.peerCount()});
}

/// Runs the interactive explorer.
fn runExplore(allocator: std.mem.Allocator, args: Args, stderr: anytype) !void {
    // Peer identity required for protocol handshake.
    const local_peer = try Peer.init(
        args.agent_name,
        args.agent_name,
        ergo.DefaultVersion,
        &ergo.BasicFeatureSet,
    );

    // Default config is sufficient for interactive use.
    const config = ergo.ExplorerConfig{};

    // Explorer provides interactive TUI for network exploration.
    var explorer = ergo.Explorer.init(allocator, args.network, local_peer, config);
    defer explorer.deinit();

    // Pool needs discovery reference for peer scoring; must link after explorer is stable.
    explorer.linkDiscovery();

    // Pre-populate with user's peer for immediate connection in explore mode.
    if (args.peer_host) |host| {
        explorer.discovery.addPeer(host, args.peer_port, .user_provided) catch {};
    }

    explorer.run() catch |err| {
        try stderr.print("{s}Explorer error: {}{s}\n", .{ Color.red, err, Color.reset });
        return;
    };
}

/// Runs the broadcast command - broadcasts a transaction to the network.
fn runBroadcast(allocator: std.mem.Allocator, args: Args, stdout: anytype, stderr: anytype) !void {
    try stdout.print("{s}ergo-p2p v{s}{s} - Transaction Broadcast\n", .{ Color.bold, version_string, Color.reset });
    try stdout.print("Network: {s}{s}{s}\n\n", .{ Color.cyan, NetworkMagic.name(args.network), Color.reset });

    // Transaction bytes can come from hex string or file; normalize to binary.
    var tx_data: []u8 = undefined;
    var tx_data_owned = false;

    if (args.tx_hex) |hex| {
        // Command-line hex: each pair of hex chars becomes one byte.
        if (hex.len % 2 != 0) {
            try stderr.print("{s}Error: Invalid hex length (must be even){s}\n", .{ Color.red, Color.reset });
            return;
        }
        tx_data = try allocator.alloc(u8, hex.len / 2);
        tx_data_owned = true;

        for (0..tx_data.len) |i| {
            tx_data[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch {
                try stderr.print("{s}Error: Invalid hex character at position {d}{s}\n", .{ Color.red, i * 2, Color.reset });
                allocator.free(tx_data);
                return;
            };
        }
    } else if (args.tx_file) |file_path| {
        // File input supports both hex text and raw binary formats.
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            try stderr.print("{s}Error: Cannot open file '{s}': {}{s}\n", .{ Color.red, file_path, err, Color.reset });
            return;
        };
        defer file.close();

        const file_content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            try stderr.print("{s}Error: Cannot read file: {}{s}\n", .{ Color.red, err, Color.reset });
            return;
        };
        defer allocator.free(file_content);

        // Remove whitespace to handle formatted hex dumps.
        const trimmed = std.mem.trim(u8, file_content, " \t\r\n");

        if (trimmed.len % 2 == 0 and isHexString(trimmed)) {
            // Hex-encoded transaction (common export format from wallets).
            tx_data = try allocator.alloc(u8, trimmed.len / 2);
            tx_data_owned = true;

            for (0..tx_data.len) |i| {
                tx_data[i] = std.fmt.parseInt(u8, trimmed[i * 2 .. i * 2 + 2], 16) catch {
                    try stderr.print("{s}Error: Invalid hex in file{s}\n", .{ Color.red, Color.reset });
                    allocator.free(tx_data);
                    return;
                };
            }
        } else {
            // Not valid hex; treat as raw serialized transaction bytes.
            tx_data = try allocator.dupe(u8, trimmed);
            tx_data_owned = true;
        }
    } else {
        try stderr.print("{s}Error: No transaction provided. Use -t <hex> or -f <file>{s}\n", .{ Color.red, Color.reset });
        try stderr.print("\nUsage: ergo-p2p broadcast -t <transaction_hex>\n", .{});
        try stderr.print("       ergo-p2p broadcast -f <transaction_file>\n", .{});
        return;
    }
    defer if (tx_data_owned) allocator.free(tx_data);

    try stdout.print("Transaction size: {s}{d} bytes{s}\n", .{ Color.cyan, tx_data.len, Color.reset });

    // Parsing validates structure and computes transaction ID for Inv message.
    var tx = ergo.Transaction.fromBytes(tx_data, allocator) catch |err| {
        try stderr.print("{s}Error: Failed to parse transaction: {}{s}\n", .{ Color.red, err, Color.reset });
        return;
    };
    defer tx.deinit();

    const tx_id = tx.computeId();
    const tx_id_hex = ergo.formatId(tx_id);

    try stdout.print("Transaction ID: {s}{s}{s}\n", .{ Color.yellow, &tx_id_hex, Color.reset });
    try stdout.print("Inputs:         {d}\n", .{tx.inputs.len});
    try stdout.print("Outputs:        {d}\n", .{tx.outputs.len});

    // Sum outputs for user display; helps verify correct transaction.
    var total_output: u64 = 0;
    for (tx.outputs) |output| {
        total_output += output.value;
    }
    const erg_value = @as(f64, @floatFromInt(total_output)) / 1_000_000_000.0;
    try stdout.print("Total output:   {d:.9} ERG\n\n", .{erg_value});

    // Bootstrap peers provide initial network entry points for broadcast.
    var discovery = if (std.mem.eql(u8, &args.network, &NetworkMagic.mainnet))
        ergo.Discovery.initMainnet(allocator)
    else
        ergo.Discovery.initTestnet(allocator);
    defer discovery.deinit();

    // Peer identity required for protocol handshake.
    const local_peer = try Peer.init(
        args.agent_name,
        args.agent_name,
        ergo.DefaultVersion,
        &ergo.BasicFeatureSet,
    );

    // User-specified peer takes priority for broadcast target.
    if (args.peer_host) |host| {
        try discovery.addPeer(host, args.peer_port, .user_provided);
    }

    // Pool manages multiple connections for redundant broadcast.
    var pool = ergo.Pool.init(allocator, args.network, local_peer);
    defer pool.deinit();
    pool.discovery = &discovery;
    pool.setMaxConnections(args.peer_count);

    // Strategy affects privacy and propagation speed trade-offs.
    const strategy: ergo.BroadcastStrategy = if (std.mem.eql(u8, args.broadcast_strategy, "staggered"))
        .{ .staggered = .{ .delay_ms = 100 } }
    else if (std.mem.eql(u8, args.broadcast_strategy, "random"))
        .{ .random_subset = .{ .count = args.peer_count } }
    else
        .all;

    try stdout.print("Strategy: {s}{s}{s}\n", .{ Color.cyan, args.broadcast_strategy, Color.reset });
    try stdout.print("Connecting to peers...\n\n", .{});

    // Select highest-scoring peers for reliable broadcast.
    const peers = try discovery.selectBestPeers(args.peer_count);
    defer allocator.free(peers);

    var connected_count: u32 = 0;
    for (peers) |peer_info| {
        try stdout.print("  Connecting to {s}{s}:{d}{s}... ", .{ Color.yellow, peer_info.host, peer_info.port, Color.reset });

        if (pool.connect(peer_info.host, peer_info.port)) |id| {
            _ = id;
            try stdout.print("{s}connected{s}\n", .{ Color.green, Color.reset });
            connected_count += 1;
        } else |err| {
            try stdout.print("{s}failed ({s}){s}\n", .{ Color.red, @errorName(err), Color.reset });
        }
    }

    if (connected_count == 0) {
        try stderr.print("\n{s}Error: No peers connected. Cannot broadcast.{s}\n", .{ Color.red, Color.reset });
        return;
    }

    try stdout.print("\nConnected to {s}{d}{s} peer(s)\n\n", .{ Color.green, connected_count, Color.reset });

    // Inv announces transaction availability; peers request full data if interested.
    var tx_ids: [1][32]u8 = .{tx_id};

    try stdout.print("Broadcasting transaction...\n", .{});

    const result = try pool.broadcastInv(.{
        .type_id = .Transaction,
        .elements = &tx_ids,
    }, strategy);

    try stdout.print("\n{s}Broadcast Result:{s}\n", .{ Color.bold, Color.reset });
    try stdout.print("  Successful: {s}{d}{s}\n", .{ Color.green, result.successful, Color.reset });
    try stdout.print("  Failed:     {s}{d}{s}\n", .{ Color.red, result.failed, Color.reset });
    try stdout.print("  Success rate: {d:.1}%\n", .{result.successRate() * 100});

    // Peers that want the transaction will send ModifierRequest; wait to confirm propagation.
    try stdout.print("\nWaiting for modifier requests...\n", .{});

    var requests_received: u32 = 0;
    var tx_bytes: ?[]u8 = null;
    defer if (tx_bytes) |b| allocator.free(b);

    const conn_ids = try pool.getConnectionIds();
    defer allocator.free(conn_ids);

    // 5 second window is typically enough for interested peers to request.
    const start_time = platform.timestampMs();
    while (platform.timestampMs() - start_time < 5000) {
        for (conn_ids) |id| {
            const conn_info = pool.getConnection(id) orelse continue;
            if (conn_info.state != .connected) continue;
            const connection = conn_info.connection orelse continue;

            const msg = connection.receiveMessageTimeout(100) catch continue;

            if (msg) |message_val| {
                var message = message_val;
                defer message.deinit();

                switch (message) {
                    .ModifierRequest => |req| {
                        if (req.type_id == .Transaction) {
                            for (req.elements) |req_id| {
                                if (std.mem.eql(u8, &req_id, &tx_id)) {
                                    requests_received += 1;
                                    try stdout.print("  {s}[{s}:{d}]{s} requested transaction\n", .{
                                        Color.cyan,
                                        conn_info.host,
                                        conn_info.port,
                                        Color.reset,
                                    });

                                    // Serialize on-demand; most nodes may already have the tx.
                                    if (tx_bytes == null) {
                                        tx_bytes = try tx.toBytes(allocator);
                                    }

                                    // TODO: Send ModifierResponse with full tx data.
                                    // Currently we only announce; nodes get tx from mempool gossip.
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    try stdout.print("\n{s}Summary:{s}\n", .{ Color.bold, Color.reset });
    try stdout.print("  Transaction ID: {s}{s}{s}\n", .{ Color.yellow, &tx_id_hex, Color.reset });
    try stdout.print("  Peers reached:  {d}\n", .{result.successful});
    try stdout.print("  Requests:       {d}\n", .{requests_received});

    if (result.successful > 0) {
        try stdout.print("\n{s}Transaction broadcast successfully!{s}\n", .{ Color.green, Color.reset });
    } else {
        try stdout.print("\n{s}Warning: Transaction may not have been broadcast successfully.{s}\n", .{ Color.yellow, Color.reset });
    }
}

fn isHexString(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Prints usage information.
fn printUsage(writer: anytype) !void {
    try writer.print(
        \\{s}ergo-p2p{s} v{s} - Ergo P2P Network Tool
        \\
        \\{s}USAGE:{s}
        \\    ergo-p2p [OPTIONS] [COMMAND]
        \\
        \\{s}COMMANDS:{s}
        \\    explore     Interactive network explorer (default)
        \\    monitor     Monitor events from a single node
        \\    discover    Discover peers from bootstrap nodes
        \\    relay       Connect to multiple peers and monitor
        \\    broadcast   Broadcast transaction to network
        \\
        \\{s}OPTIONS:{s}
        \\    -n, --network <NETWORK>  Network: mainnet (default), testnet
        \\    -p, --peer <ADDR>        Peer address (host:port)
        \\    -a, --agent <NAME>       Agent name (default: ergo-p2p)
        \\    -t, --tx <HEX>           Transaction hex (for broadcast)
        \\    -f, --file <PATH>        Transaction file (for broadcast)
        \\    -s, --strategy <TYPE>    Broadcast strategy: all, staggered, random
        \\    -c, --count <N>          Number of peers (default: 8)
        \\    -h, --help               Show this help
        \\
        \\{s}EXAMPLES:{s}
        \\    ergo-p2p discover
        \\    ergo-p2p -p 127.0.0.1:9030 monitor
        \\    ergo-p2p broadcast -t <transaction_hex>
        \\    ergo-p2p broadcast -f tx.hex -s staggered
        \\
        \\{s}PROTOCOL:{s}
        \\    Mainnet magic: [1, 0, 2, 4]
        \\    Testnet magic: [2, 0, 2, 3]
        \\    Default port:  9030 (mainnet), 9020 (testnet)
        \\
    , .{
        Color.bold,   Color.reset, version_string,
        Color.yellow, Color.reset,
        Color.yellow, Color.reset,
        Color.yellow, Color.reset,
        Color.yellow, Color.reset,
        Color.yellow, Color.reset,
    });
}

test {
    // Ensure library tests are included in `zig build test`.
    std.testing.refAllDecls(@import("ergo-p2p"));
}
