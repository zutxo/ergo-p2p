# ergo-p2p

A high-performance, zero-dependency Ergo blockchain P2P networking library and interactive CLI tool written in Zig.

## Features

- **Zero External Dependencies**: Uses only Zig standard library
- **Cross-Platform**: Windows, macOS, and Linux support
- **High Performance**: Non-blocking I/O, concurrent connections
- **Memory Safe**: Explicit allocator handling, no hidden allocations
- **Protocol Fidelity**: Complete Ergo P2P protocol implementation

### Capabilities

- Direct peer-to-peer connections to Ergo nodes
- Real-time monitoring of transactions and block headers
- Network topology exploration and peer discovery
- Transaction broadcasting with privacy-aware strategies
- Mempool observation and analysis
- Network graph visualization (DOT format export)

## Installation

### Quick Start (Bundled Zig)

The project includes a script to download the correct Zig version:

```bash
git clone <repository-url>
cd ergo-p2p

# Download Zig 0.14.1 (one-time setup)
./zig/download.sh

# Build
./zig/zig build

# Run tests
./zig/zig build test
```

### Using System Zig

If you prefer to use your system's Zig installation:

- Requires [Zig](https://ziglang.org/download/) 0.14.0 or later

```bash
zig build
zig build test
```

The executable will be in `zig-out/bin/ergo-p2p`.

## Quick Start

### Interactive Explorer

```bash
# Start the interactive explorer
./zig-out/bin/ergo-p2p explore

# Explorer commands:
ergo> connect 165.227.26.175:9030    # Connect to a peer
ergo> peers                           # List connected peers
ergo> discover                        # Discover more peers
ergo> mempool                         # Show mempool transactions
ergo> headers                         # Show tracked headers
ergo> status                          # Show explorer status
ergo> quit                            # Exit
```

### Monitor a Single Node

```bash
# Monitor messages from a specific node
./zig-out/bin/ergo-p2p -p 127.0.0.1:9030 monitor
```

### Discover Peers

```bash
# Discover peers from bootstrap nodes
./zig-out/bin/ergo-p2p discover
```

### Multi-Peer Relay

```bash
# Connect to multiple peers and monitor
./zig-out/bin/ergo-p2p relay
```

### Broadcast Transaction

```bash
# Broadcast a transaction (hex-encoded)
./zig-out/bin/ergo-p2p broadcast -t <transaction_hex>

# Broadcast from file
./zig-out/bin/ergo-p2p broadcast -f tx.hex

# With strategy options
./zig-out/bin/ergo-p2p broadcast -t <hex> -s staggered -c 10
```

## CLI Reference

```
ergo-p2p [OPTIONS] [COMMAND]

COMMANDS:
    explore     Interactive network explorer (default)
    monitor     Monitor events from a single node
    discover    Discover peers from bootstrap nodes
    relay       Connect to multiple peers and monitor
    broadcast   Broadcast transaction to network

OPTIONS:
    -n, --network <NETWORK>  Network: mainnet (default), testnet
    -p, --peer <ADDR>        Peer address (host:port)
    -a, --agent <NAME>       Agent name (default: ergo-p2p)
    -t, --tx <HEX>           Transaction hex (for broadcast)
    -f, --file <PATH>        Transaction file (for broadcast)
    -s, --strategy <TYPE>    Broadcast strategy: all, staggered, random
    -c, --count <N>          Number of peers (default: 8)
    -h, --help               Show help
```

## Library Usage

ergo-p2p can be used as a library in other Zig projects.

### Add as Dependency

In your `build.zig.zon`:

```zig
.dependencies = .{
    .ergo_p2p = .{
        .path = "../ergo-p2p",
    },
},
```

In your `build.zig`:

```zig
const ergo_p2p = b.dependency("ergo_p2p", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ergo-p2p", ergo_p2p.module("ergo-p2p"));
```

### Example: Connect to a Peer

```zig
const std = @import("std");
const ergo = @import("ergo-p2p");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create local peer identity
    const local_peer = try ergo.Peer.init(
        "my-app",
        "my-app",
        ergo.DefaultVersion,
        &ergo.BasicFeatureSet,
    );

    // Create connection handler
    var conn = ergo.connection.Connection.init(
        allocator,
        ergo.NetworkMagic.mainnet,
        local_peer,
    );
    defer conn.deinit();

    // Connect and handshake
    try conn.connectTo("165.227.26.175", 9030);
    try conn.performHandshake();

    // Print remote peer info
    if (conn.getRemotePeer()) |peer| {
        std.debug.print("Connected to: {s} v{}\n", .{
            peer.agent_name,
            peer.version,
        });
    }

    // Send GetPeers request
    try conn.sendGetPeers();

    // Receive response
    if (try conn.receiveMessageTimeout(5000)) |msg| {
        var message = msg;
        defer message.deinit();

        switch (message) {
            .Peers => |peers| {
                std.debug.print("Received {} peers\n", .{peers.peer_list.len});
            },
            else => {},
        }
    }
}
```

### Example: Broadcast Transaction

```zig
const std = @import("std");
const ergo = @import("ergo-p2p");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse transaction from hex
    const tx_hex = "..."; // Your signed transaction hex
    var tx = try ergo.Transaction.fromHex(tx_hex, allocator);
    defer tx.deinit();

    const tx_id = tx.computeId();
    std.debug.print("TX ID: {s}\n", .{std.fmt.fmtSliceHexLower(&tx_id)});

    // Create pool for multi-peer broadcast
    const local_peer = try ergo.Peer.init("broadcaster", "broadcaster", ergo.DefaultVersion, &ergo.BasicFeatureSet);

    var discovery = ergo.Discovery.initMainnet(allocator);
    defer discovery.deinit();

    var pool = ergo.Pool.init(allocator, ergo.NetworkMagic.mainnet, local_peer);
    defer pool.deinit();
    pool.discovery = &discovery;

    // Connect to peers
    const peers = try discovery.selectBestPeers(5);
    defer allocator.free(peers);

    for (peers) |peer_info| {
        _ = pool.connect(peer_info.host, peer_info.port) catch continue;
    }

    // Broadcast transaction Inv
    var tx_ids: [1][32]u8 = .{tx_id};
    const result = try pool.broadcastInv(.{
        .type_id = .Transaction,
        .elements = &tx_ids,
    }, .all);

    std.debug.print("Broadcast: {}/{} successful\n", .{
        result.successful,
        result.attempted,
    });
}
```

## Module Structure

```
src/
├── ergo_p2p.zig    # Core types, message serialization, re-exports
├── vlq.zig         # VLQ (Variable-Length Quantity) encoding
├── blake2b.zig     # Blake2b-256 hashing (pure Zig)
├── connection.zig  # Single peer connection handler
├── discovery.zig   # Peer discovery and management
├── pool.zig        # Multi-peer broadcast coordination
├── explorer.zig    # Interactive network explorer
├── modifiers.zig   # Block header and transaction parsing
├── platform.zig    # Cross-platform abstractions
└── main.zig        # CLI entry point
```

## Protocol Details

### Network Magic

| Network | Magic Bytes |
|---------|------------|
| Mainnet | `[1, 0, 2, 4]` |
| Testnet | `[2, 0, 2, 3]` |

### Default Ports

| Network | Port |
|---------|------|
| Mainnet | 9030 |
| Testnet | 9020 |

### Message Types

| Code | Name | Description |
|------|------|-------------|
| 1 | GetPeers | Request peer list |
| 2 | Peers | Peer list response |
| 22 | ModifierRequest | Request block/tx data |
| 33 | ModifierResponse | Block/tx data response |
| 55 | Inv | Inventory announcement |
| 65 | SyncInfo | Sync state announcement |

### Modifier Types

| Code | Name |
|------|------|
| 2 | Transaction |
| 101 | Header |
| 102 | BlockTransactions |
| 104 | ADProofs |
| 108 | Extension |

## Broadcast Strategies

- **all**: Send to all connected peers simultaneously
- **staggered**: Send with delay between peers (privacy-preserving)
- **random**: Send to random subset of peers

## Explorer Commands

| Command | Shortcut | Description |
|---------|----------|-------------|
| `connect <host:port>` | `c` | Connect to a peer |
| `disconnect <id>` | `d` | Disconnect from peer |
| `peers` | `p` | List connected peers |
| `discover` | - | Discover peers via GetPeers |
| `mempool [count]` | `m` | Show mempool transactions |
| `headers [count]` | `h` | Show tracked headers |
| `broadcast <hex>` | `b` | Broadcast transaction |
| `stream <id> [on\|off]` | `s` | Toggle message streaming |
| `status` | - | Show explorer status |
| `export [file]` | `e` | Export network graph (DOT) |
| `verbose` | `v` | Toggle verbose output |
| `clear` | - | Clear screen |
| `quit` | `q` | Exit explorer |

## Network Graph Export

The explorer can export the network topology as a DOT graph:

```bash
ergo> export network.dot
```

Convert to image:

```bash
dot -Tpng network.dot -o network.png
```

## Contributing

Contributions are welcome! Please ensure:

1. Code follows Zig idioms and style
2. All tests pass (`zig build test`)
3. New features include appropriate tests
4. Documentation is updated

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- Inspired by [yam](https://github.com/petertodd/yam) (Bitcoin P2P tool)
- Based on Ergo protocol documentation and [ergonnection-go](https://github.com/ross-weir/ergonnection-go)
