# Zutxo Style

## The Essence of Style

> "There are three things extremely hard: steel, a diamond, and to know one's self." — Benjamin Franklin

This style guide defines the engineering principles and coding practices for zutxo projects. It is adapted from TigerBeetle's TIGER_STYLE and tailored for blockchain P2P networking libraries in Zig. A collective give-and-take at the intersection of protocol correctness and performance. Numbers and network packets. Safety and speed.

## Why Have Style?

Another word for style is design.

> "The design is not just what it looks like and feels like. The design is how it works." — Steve Jobs

Our design goals are **safety**, **protocol correctness**, **performance**, and **developer experience**. In that order. All four are important. Good style advances these goals.

For a P2P networking library, safety means preventing security vulnerabilities, memory corruption, and protocol violations. Protocol correctness means byte-perfect compatibility with reference implementations. Performance means efficient message handling under network load. Developer experience means clear APIs and excellent documentation.

## On Simplicity And Elegance

Simplicity is not a free pass. It's not in conflict with our design goals.

Rather, simplicity is how we bring our design goals together, how we identify the "super idea" that solves the axes simultaneously, to achieve something elegant.

> "Simplicity and elegance are unpopular because they require hard work and discipline to achieve" — Edsger Dijkstra

Contrary to popular belief, simplicity is also not the first attempt but the hardest revision. The hardest part is how much thought goes into everything.

An hour or day of design is worth weeks or months in production:

> "the simple and elegant systems tend to be easier and faster to design and get right, more efficient in execution, and much more reliable" — Edsger Dijkstra

## Technical Debt

What could go wrong? What's wrong? Which question would we rather ask? The former, because code, like steel, is less expensive to change while it's hot.

Since it's hard enough to discover showstoppers, when we do find them, we solve them. We don't allow protocol violations, memory safety issues, or exponential complexity algorithms to slip through.

> "You shall not pass!" — Gandalf

In other words, zutxo projects have a "zero technical debt" policy. We do it right the first time. We know that what we ship is solid. We may lack crucial features, but what we have meets our design goals.

## Safety

> "The rules act like the seat-belt in your car: initially they are perhaps a little uncomfortable, but after a while their use becomes second-nature and not using them becomes unimaginable." — Gerard J. Holzmann

[NASA's Power of Ten — Rules for Developing Safety Critical Code](https://spinroot.com/gerard/pdf/P10.pdf) will change the way you code forever. To expand:

- Use **only very simple, explicit control flow** for clarity. **Do not use recursion** to ensure that all executions that should be bounded are bounded. Use **only a minimum of excellent abstractions** but only if they make the best sense of the domain. Abstractions are [never zero cost](https://isaacfreund.com/blog/2022-05/). Every abstraction introduces the risk of a leaky abstraction.

- **Put a limit on everything** because, in reality, this is what we expect—everything has a limit. For example, all loops and all queues must have a fixed upper bound to prevent infinite loops or tail latency spikes. This follows the ["fail-fast"](https://en.wikipedia.org/wiki/Fail-fast) principle so that violations are detected sooner rather than later. Where a loop cannot terminate (e.g. an event loop), this must be asserted.

- Use explicitly-sized types like `u32` for everything, avoid architecture-specific `usize` except where required by the standard library.

- **Assertions detect programmer errors. Unlike operating errors, which are expected and which must be handled, assertion failures are unexpected. The only correct way to handle corrupt code is to crash. Assertions downgrade catastrophic correctness bugs into liveness bugs. Assertions are a force multiplier for discovering bugs by fuzzing.**

  - **Assert all function arguments and return values, pre/postconditions and invariants.** A function must not operate blindly on data it has not checked. The purpose of a function is to increase the probability that a program is correct. Assertions within a function are part of how functions serve this purpose. The assertion density of the code must average a minimum of two assertions per function.

  - **[Pair assertions](https://tigerbeetle.com/blog/2023-12-27-it-takes-two-to-contract).** For every property you want to enforce, try to find at least two different code paths where an assertion can be added. For example, assert validity of data right before serializing to wire, and also immediately after deserializing from wire.

  - On occasion, you may use a blatantly true assertion instead of a comment as stronger documentation where the assertion condition is critical and surprising.

  - Split compound assertions: prefer `assert(a); assert(b);` over `assert(a and b);`. The former is simpler to read, and provides more precise information if the condition fails.

  - Use single-line `if` to assert an implication: `if (a) assert(b)`.

  - **Assert the relationships of compile-time constants** as a sanity check, and also to document and enforce subtle invariants or type sizes. Compile-time assertions are extremely powerful because they are able to check a program's design integrity _before_ the program even executes.

  - **The golden rule of assertions is to assert the _positive space_ that you do expect AND to assert the _negative space_ that you do not expect** because where data moves across the valid/invalid boundary between these spaces is where interesting bugs are often found. This is also why **tests must test exhaustively**, not only with valid data but also with invalid data, and as valid data becomes invalid.

- All memory must be statically allocated at startup where possible. **Minimize dynamic allocation after initialization.** This avoids unpredictable behavior that can significantly affect performance, and avoids use-after-free. As a second-order effect, it is our experience that this also makes for more efficient, simpler designs.

- Declare variables at the **smallest possible scope**, and **minimize the number of variables in scope**, to reduce the probability that variables are misused.

- There's a sharp discontinuity between a function fitting on a screen, and having to scroll to see how long it is. For this physical reason we enforce a **soft limit of 70 lines per function**. Art is born of constraints. Some rules of thumb:

  * Good function shape is often the inverse of an hourglass: a few parameters, a simple return type, and a lot of meaty logic between the braces.
  * Centralize control flow. When splitting a large function, try to keep all switch/if statements in the "parent" function, and move non-branchy logic fragments to helper functions. Divide responsibility.
  * Similarly, centralize state manipulation. Let the parent function keep all relevant state in local variables, and use helpers to compute what needs to change, rather than applying the change directly. Keep leaf functions pure.

- Appreciate, from day one, **all compiler warnings at the highest strictness**.

- When handling network messages, **don't do things directly in reaction to external events**. Instead, your program should run at its own pace. This makes your program safer by keeping control flow under your control, and improves performance through batching.

Beyond these rules:

- Compound conditions that evaluate multiple booleans make it difficult for the reader to verify that all cases are handled. Split compound conditions into simple conditions using nested `if/else` branches.

- Negations are not easy! State invariants positively. When working with lengths and indexes, this form is easy to get right:

  ```zig
  if (index < length) {
      // The invariant holds.
  } else {
      // The invariant doesn't hold.
  }
  ```

- All errors must be handled. An [analysis of production failures in distributed data-intensive systems](https://www.usenix.org/system/files/conference/osdi14/osdi14-paper-yuan.pdf) found that the majority of catastrophic failures could have been prevented by simple testing of error handling code.

- **Always motivate, always say why**. Never forget to say why. Because if you explain the rationale for a decision, it not only increases the hearer's understanding, but also shares criteria with them with which to evaluate the decision.

- **Explicitly pass options to library functions at the call site, instead of relying on the defaults**. This improves readability but most of all avoids latent, potentially catastrophic bugs in case the library ever changes its defaults.

## Protocol Correctness

For P2P networking libraries, protocol correctness is paramount. A single byte off can mean incompatibility with the entire network.

- **Byte-perfect compatibility** with the reference implementation is non-negotiable. Every serialization format must match exactly.

- **Use test vectors from the reference implementation** to verify correctness. Never assume your implementation is correct without testing against known-good data.

- **Document protocol deviations** explicitly. If we intentionally differ from the reference (e.g., for performance), document why and ensure interoperability is preserved.

- **Checksum everything**. Network data is untrusted. Verify checksums before processing.

- **Validate message bounds**. Never trust length fields from the network. Always validate against maximum allowed sizes before allocating or reading.

- **Magic bytes first**. Always verify network magic bytes before processing any message. This prevents cross-network contamination.

- **Version gates**. Respect protocol version requirements. Ban peers that don't meet minimum version requirements.

## Performance

> "The lack of back-of-the-envelope performance sketches is the root of all evil." — Rivacindela Hudsoni

- Think about performance from the outset, from the beginning. **The best time to solve performance, to get the huge 1000x wins, is in the design phase.**

- **Perform back-of-the-envelope sketches with respect to the four resources (network, disk, memory, CPU) and their two main characteristics (bandwidth, latency).**

- Optimize for the slowest resources first (network, disk, memory, CPU) in that order, after compensating for the frequency of usage.

- Amortize network, disk, memory and CPU costs by batching accesses.

- Be explicit. Minimize dependence on the compiler to do the right thing for you.

  In particular, extract hot loops into stand-alone functions with primitive arguments without `self`. That way, the compiler doesn't need to prove that it can cache struct's fields in registers, and a human reader can spot redundant computations easier.

- **Pre-allocate message buffers** at startup. Avoid allocation in the message handling hot path.

- **Use fixed-size buffers** for network operations where the maximum message size is known.

## Developer Experience

> "There are only two hard things in Computer Science: cache invalidation, naming things, and off-by-one errors." — Phil Karlton

### Naming Things

- **Get the nouns and verbs just right.** Great names are the essence of great code, they capture what a thing is or does, and provide a crisp, intuitive mental model.

- Use `snake_case` for function, variable, and file names. The underscore is the closest thing we have as programmers to a space.

- Do not abbreviate variable names, unless the variable is a primitive integer type used as an argument to a sort function or matrix calculation.

- Add units or qualifiers to variable names, and put the units or qualifiers last, sorted by descending significance. For example, `timeout_ms` rather than `ms_timeout`.

- Infuse names with meaning. For example, `allocator: Allocator` is a good, if boring name, but `gpa: Allocator` and `arena: Allocator` are excellent.

- When choosing related names, try hard to find names with the same number of characters so that related variables all line up in the source. For example, `source` and `target` are better than `src` and `dest`.

- When a single function calls out to a helper function or callback, prefix the name of the helper function with the name of the calling function. For example, `connect()` and `connectCallback()`.

- Callbacks go last in the list of parameters. This mirrors control flow.

- _Order_ matters for readability. Put important things near the top. The `main` function goes first.

- Don't overload names with multiple meanings that are context-dependent.

### P2P-Specific Naming

For P2P networking code, use consistent naming:

- **Peer**: A remote node we communicate with
- **Connection**: An established TCP session with a peer
- **Message**: A protocol-level unit of communication
- **Frame**: The wire format including header and payload
- **Handshake**: Initial connection establishment protocol
- **Modifier**: Ergo protocol term for blocks, headers, transactions

### Cache Invalidation

- Don't duplicate variables or take aliases to them. This will reduce the probability that state gets out of sync.

- If you don't mean a function argument to be copied when passed by value, and if the argument type is more than 16 bytes, then pass the argument as `*const`.

- Construct larger structs _in-place_ by passing an _out pointer_ during initialization.

- **Shrink the scope** to minimize the number of variables at play.

- Calculate or check variables close to where/when they are used. **Don't introduce variables before they are needed.**

- Use simpler function signatures and return types to reduce dimensionality at the call site.

### Off-By-One Errors

- **The usual suspects for off-by-one errors are casual interactions between an `index`, a `count` or a `size`.** These should be seen as distinct types, with clear rules to cast between them.

- Show your intent with respect to division. Use `@divExact()`, `@divFloor()` or `div_ceil()` to show the reader you've thought through all scenarios.

### Style By The Numbers

- Run `zig fmt`.

- Use 4 spaces of indentation.

- Hard limit all line lengths, without exception, to at most 120 columns. Let your editor help you by setting a column ruler.

- Add braces to the `if` statement unless it fits on a single line for consistency and defense in depth.

## Testing

Testing is not optional. For a P2P library, testing is even more critical because bugs affect network interoperability.

### Testing Pyramid

1. **Unit Tests**: Test individual functions and modules in isolation. Every serialization/deserialization function must have unit tests. Use `zig build test`.

2. **Integration Tests**: Test interactions between modules. Test full message round-trips.

3. **Conformance Tests**: Test against the reference implementation's test vectors. These are non-negotiable for protocol correctness.

4. **Fuzz Tests**: Use Zig's built-in fuzzing to find edge cases in parsers and serializers.

5. **Network Tests**: Test against actual Ergo nodes (mainnet/testnet) to verify real-world compatibility.

### Test Requirements

- **Every public function must have at least one test.**

- **Every serialization format must have conformance tests** using test vectors from the reference implementation.

- **Test both valid and invalid inputs.** Parsers must handle malformed data gracefully.

- **Test boundary conditions.** Maximum message sizes, empty messages, edge cases.

- **Tests must be deterministic.** Use fixed seeds for any randomness.

### Conformance Test Vectors

Maintain a file of test vectors extracted from the Ergo Scala reference implementation:

```zig
// Example: test_vectors.zig
pub const handshake_vector = struct {
    pub const hex = "bcd2919cee2e076572676f726566030306126572676f2d6d61696e6e65742d332e332e36000210040001000102067f000001ae46";
    pub const time: u64 = 1610134874428;
    pub const agent = "ergoref";
    pub const version = .{ .major = 3, .minor = 3, .patch = 6 };
    pub const node_name = "ergo-mainnet-3.3.6";
};

pub const inv_message_vector = struct {
    pub const hex = "0100020437000000226abfdbf565010101010101010101010101010101010102020202020202020202020202020202";
    pub const magic = [4]u8{ 0x01, 0x00, 0x02, 0x04 };
    pub const code: u8 = 55;
    pub const checksum = [4]u8{ 0x6a, 0xbf, 0xdb, 0xf5 };
};
```

## Dependencies

ergo-p2p has a **"zero external dependencies" policy**, apart from the Zig standard library. Dependencies lead to supply chain attacks, safety and performance risk, and slow install times. For foundational infrastructure like a P2P library, the cost of any dependency is amplified throughout the rest of the stack.

## Tooling

Our primary tool is Zig. It may not be the best for everything, but it's good enough for most things. We invest into our Zig tooling to ensure that we can tackle new problems quickly, with a minimum of accidental complexity.

> "The right tool for the job is often the tool you are already using—adding new tools has a higher cost than many people appreciate" — John Carmack

For example, the next time you write a script, instead of `scripts/*.sh`, write `scripts/*.zig`. This not only makes your script cross-platform and portable, but introduces type safety.

## Error Handling

- Use explicit error sets with semantic variants, not generic errors.

- Use `errdefer` for cleanup chains when allocating multiple resources.

- Network errors are expected and must be handled gracefully. Protocol violations should result in peer disconnection or banning.

- Never panic on network input. Malformed messages are expected.

```zig
// Good: Explicit error handling
pub const ParseError = error{
    InvalidMagic,
    InvalidChecksum,
    MessageTooLarge,
    InvalidVersion,
    UnexpectedEndOfData,
};

// Bad: Generic errors
pub fn parse(data: []const u8) !Message {
    // Don't just use `error.InvalidData` for everything
}
```

## Comment Style

> "Comments are sentences, with a space after the slash, with a capital letter and a full stop, or a colon if they relate to something that follows." — TigerBeetle

Comments are well-written prose describing the code, not scribblings in the margin. The most important rule: **always explain why, not just what**. Code shows what; comments explain why.

### Comment Grammar

- Comments are complete sentences with proper capitalization and punctuation.
- End with a period (full stop) for statements.
- End with a colon if the comment introduces something that follows.
- Inline end-of-line comments _can_ be brief phrases without punctuation.

```zig
// This is a complete sentence explaining the rationale.

/// This documents what follows, so it ends with a colon:
///
/// The implementation works as follows:

const value = compute(); // brief inline note
```

### Doc Comments

Use `//!` for file-level module documentation. These go at the very top and provide comprehensive context with examples:

```zig
//! Connection - Single peer connection handler for Ergo P2P protocol.
//!
//! Handles TCP connections, handshake, and message I/O with a single Ergo node.
//!
//! Example:
//!
//!     var conn = Connection.init(allocator, NetworkMagic.mainnet, local_peer);
//!     try conn.connectTo("127.0.0.1", 9030);
//!     try conn.performHandshake();
//!
//! Note: Always call `deinit()` to clean up resources.
```

Use `///` for function and field documentation. Show both correct and incorrect usage when helpful:

```zig
/// Connects to a peer at the given address.
///
/// The connection must not already be established. Call `disconnect()` first
/// if reconnecting to a different peer.
///
/// Example:
///     // good
///     try conn.connect(address);
///
///     // bad - will return AlreadyConnected
///     try conn.connect(address);
///     try conn.connect(other_address);
pub fn connect(self: *Connection, address: std.net.Address) !void {
```

### Invariant Comments

Invariants are critical properties that must always hold true. Document them explicitly and pair with assertions:

```zig
/// Invariant: suspend_size <= process_size <= advance_size <= receive_size
pub const MessageBuffer = struct {

/// Invariants:
/// - value_blocks_received.count < table_blocks_total
/// - value_blocks_received.capacity = constants.lsm_table_value_blocks_max
fn validateBlocks(self: *Self) void {
    assert(self.value_blocks_received.count < self.table_blocks_total);
    assert(self.value_blocks_received.capacity == constants.lsm_table_value_blocks_max);
}
```

On occasion, use a blatantly true assertion instead of a comment as stronger documentation where the condition is critical and surprising:

```zig
// There must be no padding in the Key/Value types to avoid buffer bleeds.
assert(stdx.no_padding(Key));
assert(stdx.no_padding(Value));
```

### Safety Comments

Use `Safety:` to document why unsafe operations are safe in context, or `WARNING:` for dangerous operations:

```zig
// Safety: replicas crash and restart; at any given point in time arbitrarily
// many replicas may be at different checkpoints. The sync mechanism ensures
// consistency is eventually restored.

// WARNING: Disabling direct I/O is unsafe; the page cache cannot be trusted
// after an fsync error.

// Safety: We need to use pointer arithmetic and disable runtime safety to
// avoid bounds checks in this hot path.
```

### State Transition Comments

Document state machines with `Transitions:` and use ASCII diagrams for complex logic:

```zig
/// Transitions:
/// - Initial state is `waiting`.
/// - `waiting -> writing` when the block arrives and begins to repair.
/// - `writing -> aborting` when checkpoint becomes durable and the block is freed.
state: enum { waiting, writing, aborting } = .waiting,

/// Returns whether this range (inclusive) includes the specified slot.
///
/// Cases (`.`=included, ` `=excluded):
///
/// * `head < tail` ->  `  head..tail  `
/// * `head > tail` -> `..tail  head..` (wraps around)
/// * `head = tail` -> panic (caller must handle separately)
pub fn contains(range: *const SlotRange, slot: Slot) bool {
```

### Performance Comments

Justify performance-related limits by explaining their resource implications:

```zig
/// The maximum size of a kernel socket receive buffer in bytes.
/// The receive buffer should ideally exceed the Bandwidth-Delay Product for
/// maximum throughput. However, this can cause bufferbloat and latency spikes
/// for large buffer sizes. See: https://blog.cloudflare.com/the-story-of-one-latency-spike/
pub const socket_recv_buffer_max: u32 = 4 * 1024 * 1024;

/// This impacts sequential disk write throughput (larger is better).
/// However, this also impacts bufferbloat and head-of-line blocking latency
/// for pipelined requests.
pub const write_buffer_size: u32 = 64 * 1024;
```

### Context Markers

Use these prefixes to signal the nature of important comments:

| Marker | Purpose |
|--------|---------|
| `Invariant:` | Properties that must always hold |
| `Invariants:` | Multiple invariant properties (bulleted list) |
| `Safety:` | Explains why an unsafe operation is safe |
| `WARNING:` | Dangerous operation or critical caveat |
| `Transitions:` | State machine transitions |
| `N.B.:` | Important note (nota bene) |

### TODO Comments

Use `TODO` for work items. Add context in parentheses when helpful:

```zig
// TODO: Some errors should probably be fatal.

// TODO: Maybe don't need to close on *every* error.

// TODO(zig): This will be more convenient to express when Zig gets X feature.

// TODO(Linux): Platform-specific note about Linux behavior.

// TODO(Congestion control): This bitset is currently used only for validation.
```

### Complex Logic Explanations

Break complex algorithms into numbered steps or bulleted properties. Use footnote markers for special cases:

```zig
//! Compaction overview:
//!
//! 1. Given:
//!    - levels A and B, where A+1=B
//!    - a single table in level A ("table A")
//!    - all tables from level B which intersect table A's key range ("tables B")
//!
//! 2. If table A's key range is disjoint from level B, move table A into level B.
//!    All done! (But if ranges intersect, jump to step 3).
//!
//! 3. Create an iterator from the sort-merge of table A and tables B.
//!    If the same key exists in both levels, take A's and discard B's. +
//!
//! 4. Write the sort-merge iterator into new tables on disk.
//!
//! + When A's value is a tombstone, there is a special case for garbage collection.
```

### What Makes a Good Comment

Good comments:
- Explain **why** a decision was made, not just what the code does
- Document invariants that must be maintained
- Warn about non-obvious gotchas or edge cases
- Justify performance trade-offs with concrete reasoning
- Reference external documentation or specifications
- Show examples of correct and incorrect usage

Bad comments:
- Restate what the code obviously does
- Are out of date with the code
- Use abbreviations or incomplete sentences
- Lack context about why something is done a certain way

## Documentation

- Use `//!` module-level doc comments at the top of each file explaining its purpose.

- Use `///` doc comments for public functions and types.

- Document the **why**, not just the **what**. Code shows what; comments explain why.

- Keep comments up to date. Stale comments are worse than no comments.

- For protocol-related code, reference the specification or source of truth.

```zig
//! Ergo P2P message framing and serialization.
//!
//! Messages consist of a 13-byte header followed by an optional payload:
//! - Magic bytes (4 bytes): Network identifier
//! - Message code (1 byte): Message type
//! - Length (4 bytes): Payload length (big-endian)
//! - Checksum (4 bytes): Blake2b256 of payload (if length > 0)
//!
//! Reference: org.ergoplatform.network.message.MessageSerializer
```

## The Last Stage

At the end of the day, keep trying things out, have fun, and remember—we're building infrastructure that connects people to the Ergo blockchain. Every byte matters. Every connection counts.

> "Programs must be written for people to read, and only incidentally for machines to execute." — Harold Abelson
