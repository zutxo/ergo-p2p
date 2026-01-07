//! Modifier types for Ergo blockchain.
//!
//! This module provides parsing and serialization for block modifiers:
//! - Header: Block header with PoW solution
//! - Transaction: Spending transactions
//!
//! Example - Parse a header from bytes:
//!
//!     var header = try Header.fromBytes(header_bytes, allocator);
//!     defer header.deinit();
//!
//!     const id = header.computeId();
//!     std.debug.print("Header v{} height={} id={x}\n", .{ header.version, header.height, id });
//!
//! Example - Parse a transaction:
//!
//!     var tx = try Transaction.fromHex(tx_hex_string, allocator);
//!     defer tx.deinit();
//!
//!     const tx_id = tx.computeId();
//!     std.debug.print("TX with {} inputs, {} outputs\n", .{ tx.inputs.len, tx.outputs.len });

const std = @import("std");
const root = @import("ergo_p2p.zig");
const vlq = root.vlq;
const blake2b = root.blake2b;

// ============================================================================
// Header Version Constants
// ============================================================================

/// Header version constants.
pub const HeaderVersion = struct {
    /// Initial version (Autolykos v1 with full solution)
    pub const Initial: u8 = 1;
    /// HF version (soft-fork)
    pub const Hardening: u8 = 2;
    /// Interpreter 5.0/6.0 version (Autolykos v2 with compact solution)
    pub const Interpreter50: u8 = 3;

    /// Returns true if this is a v1 header (with full PoW solution)
    pub fn isV1(version: u8) bool {
        return version == Initial;
    }

    /// Returns true if this is a v2+ header (with compact PoW solution)
    pub fn isV2Plus(version: u8) bool {
        return version >= Hardening;
    }
};

// ============================================================================
// AutolykosSolution
// ============================================================================

/// Autolykos PoW solution.
///
/// Version 1 solutions include:
/// - miner_pk: Miner public key (33 bytes group element)
/// - one_time_pk: One-time public key (33 bytes, v1 only)
/// - nonce: 8-byte nonce
/// - distance: Variable-length big integer (v1 only)
///
/// Version 2+ solutions only include:
/// - miner_pk: Miner public key (33 bytes)
/// - nonce: 8-byte nonce
pub const AutolykosSolution = struct {
    /// Miner's public key (compressed group element)
    miner_pk: [33]u8,
    /// One-time public key (v1 only, null for v2+)
    one_time_pk: ?[33]u8,
    /// 8-byte nonce
    nonce: [8]u8,
    /// Distance value as big integer bytes (v1 only, null for v2+)
    distance: ?[]const u8,

    allocator: ?std.mem.Allocator = null,

    /// Deserializes an AutolykosSolution from a reader.
    /// For v1 headers: full solution with one_time_pk and distance
    /// For v2+ headers: compact solution with just miner_pk and nonce
    pub fn deserialize(r: anytype, header_version: u8, allocator: std.mem.Allocator) !AutolykosSolution {
        // Precondition: Version must be a valid protocol version.
        std.debug.assert(header_version >= 1);
        std.debug.assert(header_version <= 3);

        var miner_pk: [33]u8 = undefined;
        try r.readFully(&miner_pk);

        var one_time_pk: ?[33]u8 = null;
        var distance: ?[]const u8 = null;

        if (HeaderVersion.isV1(header_version)) {
            // V1: Read one-time public key
            var otpk: [33]u8 = undefined;
            try r.readFully(&otpk);
            one_time_pk = otpk;
        }

        // Read nonce (always 8 bytes)
        var nonce: [8]u8 = undefined;
        try r.readFully(&nonce);

        if (HeaderVersion.isV1(header_version)) {
            // V1: Read distance as variable-length big integer
            const distance_len = try r.readByte();
            distance = try r.readNBytes(allocator, distance_len);
        }

        const solution = AutolykosSolution{
            .miner_pk = miner_pk,
            .one_time_pk = one_time_pk,
            .nonce = nonce,
            .distance = distance,
            .allocator = if (distance != null) allocator else null,
        };

        // Postcondition: V1 has full solution, V2+ has compact.
        if (HeaderVersion.isV1(header_version)) {
            std.debug.assert(solution.one_time_pk != null);
        } else {
            std.debug.assert(solution.one_time_pk == null);
            std.debug.assert(solution.distance == null);
        }
        return solution;
    }

    /// Serializes the solution to a writer.
    pub fn serialize(self: AutolykosSolution, w: anytype, header_version: u8) !void {
        try w.write(&self.miner_pk);

        if (HeaderVersion.isV1(header_version)) {
            if (self.one_time_pk) |otpk| {
                try w.write(&otpk);
            } else {
                // WARNING: Writing zeros for missing one_time_pk. This indicates
                // a malformed v1 solution - valid v1 headers always have this field.
                // We write zeros to maintain wire format compatibility.
                try w.write(&[_]u8{0} ** 33);
            }
        }

        try w.write(&self.nonce);

        if (HeaderVersion.isV1(header_version)) {
            if (self.distance) |dist| {
                try w.writeByte(@truncate(dist.len));
                try w.write(dist);
            } else {
                try w.writeByte(0);
            }
        }
    }

    pub fn deinit(self: *AutolykosSolution) void {
        if (self.allocator) |allocator| {
            if (self.distance) |dist| {
                allocator.free(dist);
            }
        }
    }
};

// ============================================================================
// Header
// ============================================================================

/// Ergo block header.
///
/// Contains all the metadata for a block including:
/// - Merkle roots for transactions, state, proofs
/// - Mining difficulty and height
/// - PoW solution
/// - Voting data
///
/// Invariants:
/// - version is 1, 2, or 3 (protocol versions)
/// - All hash fields (parent_id, *_root, extension_hash) are exactly 32 bytes
/// - state_root is 33 bytes (includes tree height prefix)
/// - timestamp > 0 (milliseconds since Unix epoch)
/// - For v1: pow_solution includes one_time_pk and distance
/// - For v2+: pow_solution has compact format (miner_pk + nonce only)
///
/// Reference: org.ergoplatform.modifiers.history.Header
pub const Header = struct {
    /// Header version (determines PoW solution format)
    version: u8,
    /// Parent block header ID
    parent_id: [32]u8,
    /// Merkle root of AD proofs
    ad_proofs_root: [32]u8,
    /// Root of the state tree (33 bytes including tree height)
    state_root: [33]u8,
    /// Merkle root of transactions
    transactions_root: [32]u8,
    /// Block timestamp in milliseconds since epoch
    timestamp: u64,
    /// Encoded difficulty target (4 bytes big-endian)
    n_bits: u32,
    /// Block height
    height: u32,
    /// Extension section hash
    extension_hash: [32]u8,
    /// Miner votes (3 bytes)
    votes: [3]u8,
    /// Unparsed bytes for forward compatibility (v2+ only)
    unparsed_bytes: ?[]const u8,
    /// Proof-of-work solution
    pow_solution: AutolykosSolution,

    allocator: ?std.mem.Allocator = null,

    /// Computes the header ID (Blake2b-256 hash of serialized header).
    pub fn computeId(self: *const Header) [32]u8 {
        // We need to serialize to compute the ID
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var w = vlq.writer(fbs.writer());
        self.serializeForId(&w) catch return [_]u8{0} ** 32;
        return blake2b.hash(fbs.getWritten());
    }

    /// Serializes header for ID computation (specific byte order).
    fn serializeForId(self: *const Header, w: anytype) !void {
        // Version
        try w.writeByte(self.version);
        // Parent ID
        try w.write(&self.parent_id);
        // AD proofs root
        try w.write(&self.ad_proofs_root);
        // Transactions root
        try w.write(&self.transactions_root);
        // State root (33 bytes)
        try w.write(&self.state_root);
        // Timestamp (VLQ unsigned long)
        try w.writeUnsignedLong(self.timestamp);
        // Extension hash
        try w.write(&self.extension_hash);

        // nBits (4 bytes big-endian, stored in buffer directly)
        var n_bits_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &n_bits_buf, self.n_bits, .big);
        try w.write(&n_bits_buf);

        // Height (VLQ unsigned int)
        try w.writeUnsignedInt(self.height);
        // Votes
        try w.write(&self.votes);

        // Unparsed bytes (v2+)
        if (self.unparsed_bytes) |unparsed| {
            try w.write(unparsed);
        }

        // PoW solution
        try self.pow_solution.serialize(w, self.version);
    }

    /// Deserializes a Header from a reader.
    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Header {
        // Version
        const version = try r.readByte();
        // Precondition: Version must be a valid protocol version (1-3).
        std.debug.assert(version >= 1);
        std.debug.assert(version <= 3);

        // Parent ID
        var parent_id: [32]u8 = undefined;
        try r.readFully(&parent_id);

        // AD proofs root
        var ad_proofs_root: [32]u8 = undefined;
        try r.readFully(&ad_proofs_root);

        // Transactions root
        var transactions_root: [32]u8 = undefined;
        try r.readFully(&transactions_root);

        // State root (33 bytes - includes tree height byte)
        var state_root: [33]u8 = undefined;
        try r.readFully(&state_root);

        // Timestamp (VLQ unsigned long)
        const timestamp = try r.readUnsignedLong();

        // Extension hash
        var extension_hash: [32]u8 = undefined;
        try r.readFully(&extension_hash);

        // nBits (4 bytes, stored as VLQ in wire format, read as big-endian bytes)
        // Actually in ergonnection-go it reads 4 bytes directly as big-endian
        var n_bits_buf: [4]u8 = undefined;
        try r.readFully(&n_bits_buf);
        const n_bits = std.mem.readInt(u32, &n_bits_buf, .big);

        // Height (VLQ unsigned int)
        const height = try r.readUnsignedInt();

        // Votes (3 bytes)
        var votes: [3]u8 = undefined;
        try r.readFully(&votes);

        // Unparsed bytes (v2+ only)
        var unparsed_bytes: ?[]const u8 = null;
        if (HeaderVersion.isV2Plus(version)) {
            const unparsed_len = try r.readByte();
            if (unparsed_len > 0) {
                unparsed_bytes = try r.readNBytes(allocator, unparsed_len);
            }
        }
        errdefer if (unparsed_bytes) |ub| allocator.free(ub);

        // PoW solution
        const pow_solution = try AutolykosSolution.deserialize(r, version, allocator);
        errdefer {
            var sol = pow_solution;
            sol.deinit();
        }

        const header = Header{
            .version = version,
            .parent_id = parent_id,
            .ad_proofs_root = ad_proofs_root,
            .state_root = state_root,
            .transactions_root = transactions_root,
            .timestamp = timestamp,
            .n_bits = n_bits,
            .height = height,
            .extension_hash = extension_hash,
            .votes = votes,
            .unparsed_bytes = unparsed_bytes,
            .pow_solution = pow_solution,
            .allocator = allocator,
        };

        // Postcondition: Timestamp must be positive (valid Unix time).
        std.debug.assert(header.timestamp > 0);
        return header;
    }

    /// Deserializes a Header from raw bytes.
    pub fn fromBytes(data: []const u8, allocator: std.mem.Allocator) !Header {
        var fbs = std.io.fixedBufferStream(data);
        var r = vlq.reader(fbs.reader());
        return try deserialize(&r, allocator);
    }

    pub fn deinit(self: *Header) void {
        if (self.allocator) |allocator| {
            if (self.unparsed_bytes) |ub| {
                allocator.free(ub);
            }
        }
        self.pow_solution.deinit();
    }

    /// Formats the header for display.
    pub fn format(self: Header, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const id = self.computeId();
        const id_hex = root.formatId(id);
        const parent_hex = root.formatId(self.parent_id);

        try writer.print("Header(v{d} h={d} id={s}...{s} parent={s}...{s})", .{
            self.version,
            self.height,
            id_hex[0..8],
            id_hex[56..64],
            parent_hex[0..8],
            parent_hex[56..64],
        });
    }
};

// ============================================================================
// Transaction Types
// ============================================================================

/// Token (asset) in an Ergo box.
pub const Token = struct {
    /// Token ID (32 bytes)
    id: [32]u8,
    /// Token amount
    amount: u64,

    pub fn serialize(self: Token, w: anytype) !void {
        try w.write(&self.id);
        try w.writeUnsignedLong(self.amount);
    }

    pub fn deserialize(r: anytype) !Token {
        var id: [32]u8 = undefined;
        try r.readFully(&id);
        const amount = try r.readUnsignedLong();
        return .{ .id = id, .amount = amount };
    }
};

/// Spending proof for an input.
pub const SpendingProof = struct {
    /// Proof bytes (serialized sigma proof)
    proof_bytes: []const u8,
    /// Extension data (context variables)
    extension: []const u8,

    allocator: ?std.mem.Allocator = null,

    pub fn serialize(self: SpendingProof, w: anytype) !void {
        try w.writeUnsignedShort(@truncate(self.proof_bytes.len));
        try w.write(self.proof_bytes);
        // Extension is encoded with length
        try w.writeUnsignedShort(@truncate(self.extension.len));
        if (self.extension.len > 0) {
            try w.write(self.extension);
        }
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !SpendingProof {
        const proof_len = try r.readUnsignedShort();
        const proof_bytes = try r.readNBytes(allocator, proof_len);
        errdefer allocator.free(proof_bytes);

        const ext_len = try r.readUnsignedShort();
        const extension = if (ext_len > 0)
            try r.readNBytes(allocator, ext_len)
        else
            &[_]u8{};

        return .{
            .proof_bytes = proof_bytes,
            .extension = extension,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpendingProof) void {
        if (self.allocator) |allocator| {
            allocator.free(self.proof_bytes);
            if (self.extension.len > 0) {
                allocator.free(self.extension);
            }
        }
    }
};

/// Transaction input (spending a box).
pub const Input = struct {
    /// Box ID being spent (32 bytes)
    box_id: [32]u8,
    /// Spending proof
    spending_proof: SpendingProof,

    pub fn serialize(self: Input, w: anytype) !void {
        try w.write(&self.box_id);
        try self.spending_proof.serialize(w);
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Input {
        var box_id: [32]u8 = undefined;
        try r.readFully(&box_id);
        const spending_proof = try SpendingProof.deserialize(r, allocator);
        return .{ .box_id = box_id, .spending_proof = spending_proof };
    }

    pub fn deinit(self: *Input) void {
        self.spending_proof.deinit();
    }
};

/// Output box candidate.
pub const BoxCandidate = struct {
    /// Value in nanoERG
    value: u64,
    /// ErgoTree script bytes
    ergo_tree: []const u8,
    /// Creation height
    creation_height: u32,
    /// Tokens in this box
    tokens: []Token,
    /// Additional registers R4-R9 (6 optional registers)
    registers: [6]?[]const u8,

    allocator: ?std.mem.Allocator = null,

    pub fn serialize(self: BoxCandidate, w: anytype) !void {
        try w.writeUnsignedLong(self.value);
        try w.writeUnsignedInt(@truncate(self.ergo_tree.len));
        try w.write(self.ergo_tree);
        try w.writeUnsignedInt(self.creation_height);
        try w.writeUnsignedInt(@truncate(self.tokens.len));
        for (self.tokens) |token| {
            try token.serialize(w);
        }

        // Serialize registers - count non-null registers first
        var reg_count: u8 = 0;
        for (self.registers) |reg| {
            if (reg != null) reg_count += 1;
        }
        try w.writeByte(reg_count);

        for (self.registers, 0..) |reg, i| {
            if (reg) |r| {
                try w.writeByte(@truncate(i + 4)); // R4 = index 0, etc.
                try w.writeUnsignedInt(@truncate(r.len));
                try w.write(r);
            }
        }
    }

    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !BoxCandidate {
        const value = try r.readUnsignedLong();

        const tree_len = try r.readUnsignedInt();
        const ergo_tree = try r.readNBytes(allocator, tree_len);
        errdefer allocator.free(ergo_tree);

        const creation_height = try r.readUnsignedInt();

        const token_count = try r.readUnsignedInt();
        const tokens = try allocator.alloc(Token, token_count);
        errdefer allocator.free(tokens);

        for (tokens) |*token| {
            token.* = try Token.deserialize(r);
        }

        // Read registers
        var registers: [6]?[]const u8 = .{ null, null, null, null, null, null };
        const reg_count = try r.readByte();

        for (0..reg_count) |_| {
            const reg_id = try r.readByte();
            const reg_len = try r.readUnsignedInt();
            const reg_data = try r.readNBytes(allocator, reg_len);

            if (reg_id >= 4 and reg_id <= 9) {
                registers[reg_id - 4] = reg_data;
            } else {
                allocator.free(reg_data);
            }
        }

        return .{
            .value = value,
            .ergo_tree = ergo_tree,
            .creation_height = creation_height,
            .tokens = tokens,
            .registers = registers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BoxCandidate) void {
        if (self.allocator) |allocator| {
            allocator.free(self.ergo_tree);
            allocator.free(self.tokens);
            for (&self.registers) |*reg| {
                if (reg.*) |r| {
                    allocator.free(r);
                    reg.* = null;
                }
            }
        }
    }
};

/// Ergo transaction.
pub const Transaction = struct {
    /// Transaction inputs (boxes being spent)
    inputs: []Input,
    /// Data inputs (read-only box references)
    data_inputs: [][32]u8,
    /// Output box candidates
    outputs: []BoxCandidate,

    allocator: ?std.mem.Allocator = null,

    /// Computes the transaction ID (Blake2b-256 of serialized tx without proofs).
    pub fn computeId(self: *const Transaction) [32]u8 {
        var buf: [65536]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var w = vlq.writer(fbs.writer());
        self.serializeForId(&w) catch return [_]u8{0} ** 32;
        return blake2b.hash(fbs.getWritten());
    }

    /// Serializes transaction for ID computation (without spending proofs).
    fn serializeForId(self: *const Transaction, w: anytype) !void {
        // Input count
        try w.writeUnsignedShort(@truncate(self.inputs.len));
        // Input box IDs only (no proofs)
        for (self.inputs) |input| {
            try w.write(&input.box_id);
        }
        // Data input count
        try w.writeUnsignedShort(@truncate(self.data_inputs.len));
        // Data input box IDs
        for (self.data_inputs) |di| {
            try w.write(&di);
        }
        // Distinct output count (for ID, we need to count distinct)
        // Actually for simplicity, just count outputs
        try w.writeUnsignedShort(@truncate(self.outputs.len));
        // Output candidates
        for (self.outputs) |*output| {
            try @constCast(output).serialize(w);
        }
    }

    /// Serializes the full transaction (with proofs).
    pub fn serialize(self: *const Transaction, w: anytype) !void {
        // Input count
        try w.writeUnsignedShort(@truncate(self.inputs.len));
        // Inputs with proofs
        for (self.inputs) |*input| {
            try @constCast(input).serialize(w);
        }
        // Data input count
        try w.writeUnsignedShort(@truncate(self.data_inputs.len));
        // Data input box IDs
        for (self.data_inputs) |di| {
            try w.write(&di);
        }
        // Output count
        try w.writeUnsignedShort(@truncate(self.outputs.len));
        // Output candidates
        for (self.outputs) |*output| {
            try @constCast(output).serialize(w);
        }
    }

    /// Serializes transaction to bytes.
    pub fn toBytes(self: *const Transaction, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        var w = vlq.writer(buf.writer());
        try self.serialize(&w);
        return buf.toOwnedSlice();
    }

    /// Deserializes a transaction from a reader.
    pub fn deserialize(r: anytype, allocator: std.mem.Allocator) !Transaction {
        // Input count
        const input_count = try r.readUnsignedShort();
        // Precondition: Transaction must have at least one input.
        std.debug.assert(input_count >= 1);
        const inputs = try allocator.alloc(Input, input_count);
        errdefer allocator.free(inputs);

        var inputs_parsed: usize = 0;
        errdefer for (inputs[0..inputs_parsed]) |*i| i.deinit();

        for (inputs) |*input| {
            input.* = try Input.deserialize(r, allocator);
            inputs_parsed += 1;
        }

        // Data input count
        const data_input_count = try r.readUnsignedShort();
        const data_inputs = try allocator.alloc([32]u8, data_input_count);
        errdefer allocator.free(data_inputs);

        for (data_inputs) |*di| {
            try r.readFully(di);
        }

        // Output count
        const output_count = try r.readUnsignedShort();
        const outputs = try allocator.alloc(BoxCandidate, output_count);
        errdefer allocator.free(outputs);

        var outputs_parsed: usize = 0;
        errdefer for (outputs[0..outputs_parsed]) |*o| o.deinit();

        for (outputs) |*output| {
            output.* = try BoxCandidate.deserialize(r, allocator);
            outputs_parsed += 1;
        }

        return .{
            .inputs = inputs,
            .data_inputs = data_inputs,
            .outputs = outputs,
            .allocator = allocator,
        };
    }

    /// Deserializes a transaction from raw bytes.
    pub fn fromBytes(data: []const u8, allocator: std.mem.Allocator) !Transaction {
        var fbs = std.io.fixedBufferStream(data);
        var r = vlq.reader(fbs.reader());
        return try deserialize(&r, allocator);
    }

    /// Deserializes a transaction from hex string.
    pub fn fromHex(hex: []const u8, allocator: std.mem.Allocator) !Transaction {
        if (hex.len % 2 != 0) return error.InvalidHexLength;

        const bytes = try allocator.alloc(u8, hex.len / 2);
        defer allocator.free(bytes);

        for (0..bytes.len) |i| {
            bytes[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidHexChar;
        }

        return try fromBytes(bytes, allocator);
    }

    pub fn deinit(self: *Transaction) void {
        if (self.allocator) |allocator| {
            for (self.inputs) |*input| {
                input.deinit();
            }
            allocator.free(self.inputs);

            allocator.free(self.data_inputs);

            for (self.outputs) |*output| {
                output.deinit();
            }
            allocator.free(self.outputs);
        }
    }

    /// Formats the transaction for display.
    pub fn format(self: Transaction, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const id = self.computeId();
        const id_hex = root.formatId(id);

        try writer.print("Transaction(id={s}...{s} inputs={d} outputs={d})", .{
            id_hex[0..8],
            id_hex[56..64],
            self.inputs.len,
            self.outputs.len,
        });
    }
};

// ============================================================================
// ParsedModifier
// ============================================================================

/// A parsed modifier (Header, Transaction, etc.)
pub const ParsedModifier = union(root.ModifierType) {
    Header: Header,
    Transaction: Transaction,
    BlockTransactions: void,
    ADProofs: void,
    Extension: void,

    pub fn deinit(self: *ParsedModifier) void {
        switch (self.*) {
            .Header => |*h| h.deinit(),
            .Transaction => |*t| t.deinit(),
            else => {},
        }
    }
};

/// Parses a raw modifier into a typed modifier.
pub fn parseModifier(raw: root.RawModifier, allocator: std.mem.Allocator) !ParsedModifier {
    switch (raw.type_id) {
        .Header => {
            return .{ .Header = try Header.fromBytes(raw.data, allocator) };
        },
        .Transaction => {
            return .{ .Transaction = try Transaction.fromBytes(raw.data, allocator) };
        },
        else => {
            // Return unparsed for now
            return error.UnsupportedModifierType;
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "header version detection" {
    try std.testing.expect(HeaderVersion.isV1(1));
    try std.testing.expect(!HeaderVersion.isV1(2));
    try std.testing.expect(!HeaderVersion.isV1(3));

    try std.testing.expect(!HeaderVersion.isV2Plus(1));
    try std.testing.expect(HeaderVersion.isV2Plus(2));
    try std.testing.expect(HeaderVersion.isV2Plus(3));
}

test "autolykos solution v2 minimal" {
    const allocator = std.testing.allocator;

    // Create minimal v2 solution data
    var data: [33 + 8]u8 = undefined;
    @memset(&data, 0xAB);

    var fbs = std.io.fixedBufferStream(&data);
    var r = vlq.reader(fbs.reader());

    var solution = try AutolykosSolution.deserialize(&r, HeaderVersion.Interpreter50, allocator);
    defer solution.deinit();

    try std.testing.expectEqual(@as(?[33]u8, null), solution.one_time_pk);
    try std.testing.expectEqual(@as(?[]const u8, null), solution.distance);
    try std.testing.expectEqual([_]u8{0xAB} ** 33, solution.miner_pk);
    try std.testing.expectEqual([_]u8{0xAB} ** 8, solution.nonce);
}

test "header v3 parsing" {
    const allocator = std.testing.allocator;

    // Build a minimal v3 header
    // Format: version(1) + parentId(32) + adProofsRoot(32) + txRoot(32) + stateRoot(33) +
    //         timestamp(VLQ) + extensionHash(32) + nBits(4) + height(VLQ) + votes(3) +
    //         unparsedBytesLen(1) + powSolution(33+8)
    var buf: [256]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    // Version 3
    try w.writeByte(3);
    // Parent ID (32 bytes)
    try w.write(&[_]u8{0x01} ** 32);
    // AD proofs root (32 bytes)
    try w.write(&[_]u8{0x02} ** 32);
    // Transactions root (32 bytes)
    try w.write(&[_]u8{0x03} ** 32);
    // State root (33 bytes)
    try w.write(&[_]u8{0x04} ** 33);
    // Timestamp (VLQ) - use a realistic value
    try w.writeUnsignedLong(1704067200000); // 2024-01-01 00:00:00 UTC in ms
    // Extension hash (32 bytes)
    try w.write(&[_]u8{0x05} ** 32);
    // nBits (4 bytes big-endian)
    try w.write(&[_]u8{ 0x1a, 0x1e, 0x20, 0x30 });
    // Height (VLQ)
    try w.writeUnsignedInt(1234567);
    // Votes (3 bytes)
    try w.write(&[_]u8{ 0x00, 0x00, 0x00 });
    // Unparsed bytes length (v2+)
    try w.writeByte(0);
    // PoW solution (v2+: miner_pk(33) + nonce(8))
    try w.write(&[_]u8{0x06} ** 33); // miner_pk
    try w.write(&[_]u8{0x07} ** 8); // nonce

    const written = fbs_write.getWritten();

    // Parse it back
    var header = try Header.fromBytes(written, allocator);
    defer header.deinit();

    // Verify fields
    try std.testing.expectEqual(@as(u8, 3), header.version);
    try std.testing.expectEqual([_]u8{0x01} ** 32, header.parent_id);
    try std.testing.expectEqual([_]u8{0x02} ** 32, header.ad_proofs_root);
    try std.testing.expectEqual([_]u8{0x03} ** 32, header.transactions_root);
    try std.testing.expectEqual([_]u8{0x04} ** 33, header.state_root);
    try std.testing.expectEqual(@as(u64, 1704067200000), header.timestamp);
    try std.testing.expectEqual([_]u8{0x05} ** 32, header.extension_hash);
    try std.testing.expectEqual(@as(u32, 1234567), header.height);
    try std.testing.expectEqual([_]u8{ 0x00, 0x00, 0x00 }, header.votes);
    try std.testing.expectEqual([_]u8{0x06} ** 33, header.pow_solution.miner_pk);
    try std.testing.expectEqual([_]u8{0x07} ** 8, header.pow_solution.nonce);
    try std.testing.expectEqual(@as(?[33]u8, null), header.pow_solution.one_time_pk);

    // Verify ID computation doesn't crash
    const id = header.computeId();
    try std.testing.expect(id[0] != 0 or id[1] != 0); // ID should not be all zeros
}

test "token serialization round trip" {
    const allocator = std.testing.allocator;

    var token_id: [32]u8 = undefined;
    @memset(&token_id, 0xAA);

    const token = Token{
        .id = token_id,
        .amount = 1000000,
    };

    // Serialize
    var buf: [64]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());
    try token.serialize(&w);

    // Deserialize
    var fbs_read = std.io.fixedBufferStream(fbs_write.getWritten());
    var r = vlq.reader(fbs_read.reader());
    const token2 = try Token.deserialize(&r);

    try std.testing.expectEqual(token.id, token2.id);
    try std.testing.expectEqual(token.amount, token2.amount);
    _ = allocator;
}

test "spending proof serialization round trip" {
    const allocator = std.testing.allocator;

    const proof_bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };

    var proof = SpendingProof{
        .proof_bytes = proof_bytes,
        .extension = &[_]u8{},
        .allocator = null,
    };

    // Serialize
    var buf: [256]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());
    try proof.serialize(&w);

    // Deserialize
    var fbs_read = std.io.fixedBufferStream(fbs_write.getWritten());
    var r = vlq.reader(fbs_read.reader());
    var proof2 = try SpendingProof.deserialize(&r, allocator);
    defer proof2.deinit();

    try std.testing.expectEqualSlices(u8, proof.proof_bytes, proof2.proof_bytes);
}

test "box candidate serialization round trip" {
    const allocator = std.testing.allocator;

    // Create a simple ErgoTree (P2PK address format)
    const ergo_tree = &[_]u8{ 0x00, 0x08, 0xcd };

    var box = BoxCandidate{
        .value = 1_000_000_000, // 1 ERG
        .ergo_tree = ergo_tree,
        .creation_height = 1000000,
        .tokens = &[_]Token{},
        .registers = .{ null, null, null, null, null, null },
        .allocator = null,
    };

    // Serialize
    var buf: [256]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());
    try box.serialize(&w);

    // Deserialize
    var fbs_read = std.io.fixedBufferStream(fbs_write.getWritten());
    var r = vlq.reader(fbs_read.reader());
    var box2 = try BoxCandidate.deserialize(&r, allocator);
    defer box2.deinit();

    try std.testing.expectEqual(box.value, box2.value);
    try std.testing.expectEqualSlices(u8, box.ergo_tree, box2.ergo_tree);
    try std.testing.expectEqual(box.creation_height, box2.creation_height);
    try std.testing.expectEqual(box.tokens.len, box2.tokens.len);
}

test "minimal transaction serialization round trip" {
    const allocator = std.testing.allocator;

    // Build a minimal transaction manually
    var buf: [512]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    // 1 input
    try w.writeUnsignedShort(1);
    // Box ID (32 bytes)
    try w.write(&[_]u8{0x01} ** 32);
    // Empty spending proof
    try w.writeUnsignedShort(0); // proof_bytes len
    try w.writeUnsignedShort(0); // extension len

    // 0 data inputs
    try w.writeUnsignedShort(0);

    // 1 output
    try w.writeUnsignedShort(1);
    // Value (1 ERG)
    try w.writeUnsignedLong(1_000_000_000);
    // ErgoTree
    const tree = [_]u8{ 0x00, 0x08, 0xcd };
    try w.writeUnsignedInt(tree.len);
    try w.write(&tree);
    // Creation height
    try w.writeUnsignedInt(1000000);
    // 0 tokens
    try w.writeUnsignedInt(0);
    // 0 registers
    try w.writeByte(0);

    const written = fbs_write.getWritten();

    // Parse it back
    var tx = try Transaction.fromBytes(written, allocator);
    defer tx.deinit();

    // Verify
    try std.testing.expectEqual(@as(usize, 1), tx.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), tx.data_inputs.len);
    try std.testing.expectEqual(@as(usize, 1), tx.outputs.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), tx.outputs[0].value);
    try std.testing.expectEqual(@as(u32, 1000000), tx.outputs[0].creation_height);

    // Verify ID computation
    const tx_id = tx.computeId();
    try std.testing.expect(tx_id[0] != 0 or tx_id[1] != 0);
}

test "transaction toBytes and fromBytes consistency" {
    const allocator = std.testing.allocator;

    // Build a minimal transaction
    var buf: [512]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    // 1 input
    try w.writeUnsignedShort(1);
    try w.write(&[_]u8{0xAA} ** 32);
    try w.writeUnsignedShort(0);
    try w.writeUnsignedShort(0);

    // 0 data inputs
    try w.writeUnsignedShort(0);

    // 1 output
    try w.writeUnsignedShort(1);
    try w.writeUnsignedLong(500_000_000);
    const tree = [_]u8{0x00};
    try w.writeUnsignedInt(tree.len);
    try w.write(&tree);
    try w.writeUnsignedInt(999999);
    try w.writeUnsignedInt(0);
    try w.writeByte(0);

    const original_bytes = fbs_write.getWritten();

    // Parse
    var tx = try Transaction.fromBytes(original_bytes, allocator);
    defer tx.deinit();

    // Re-serialize
    const reserialized = try tx.toBytes(allocator);
    defer allocator.free(reserialized);

    // Should match
    try std.testing.expectEqualSlices(u8, original_bytes, reserialized);
}

test "autolykos solution v1 with full fields" {
    const allocator = std.testing.allocator;

    // Create v1 solution data: miner_pk(33) + one_time_pk(33) + nonce(8) + distance_len(1) + distance(N)
    var data: [33 + 33 + 8 + 1 + 4]u8 = undefined;
    @memset(data[0..33], 0xAA); // miner_pk
    @memset(data[33..66], 0xBB); // one_time_pk
    @memset(data[66..74], 0xCC); // nonce
    data[74] = 4; // distance_len
    @memset(data[75..79], 0xDD); // distance bytes

    var fbs = std.io.fixedBufferStream(&data);
    var r = vlq.reader(fbs.reader());

    var solution = try AutolykosSolution.deserialize(&r, HeaderVersion.Initial, allocator);
    defer solution.deinit();

    try std.testing.expectEqual([_]u8{0xAA} ** 33, solution.miner_pk);
    try std.testing.expect(solution.one_time_pk != null);
    try std.testing.expectEqual([_]u8{0xBB} ** 33, solution.one_time_pk.?);
    try std.testing.expectEqual([_]u8{0xCC} ** 8, solution.nonce);
    try std.testing.expect(solution.distance != null);
    try std.testing.expectEqual(@as(usize, 4), solution.distance.?.len);
}

test "header v2 with unparsed bytes" {
    const allocator = std.testing.allocator;

    var buf: [256]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    // Version 2
    try w.writeByte(2);
    // Standard header fields
    try w.write(&[_]u8{0x01} ** 32); // parent_id
    try w.write(&[_]u8{0x02} ** 32); // ad_proofs_root
    try w.write(&[_]u8{0x03} ** 32); // transactions_root
    try w.write(&[_]u8{0x04} ** 33); // state_root
    try w.writeUnsignedLong(1704067200000); // timestamp
    try w.write(&[_]u8{0x05} ** 32); // extension_hash
    try w.write(&[_]u8{ 0x1a, 0x1e, 0x20, 0x30 }); // nBits
    try w.writeUnsignedInt(500000); // height
    try w.write(&[_]u8{ 0x00, 0x00, 0x00 }); // votes

    // Unparsed bytes (v2+ feature)
    try w.writeByte(3); // 3 bytes of unparsed data
    try w.write(&[_]u8{ 0xDE, 0xAD, 0xBE }); // unparsed bytes

    // PoW solution (v2+: miner_pk + nonce)
    try w.write(&[_]u8{0x06} ** 33);
    try w.write(&[_]u8{0x07} ** 8);

    const written = fbs_write.getWritten();

    var header = try Header.fromBytes(written, allocator);
    defer header.deinit();

    try std.testing.expectEqual(@as(u8, 2), header.version);
    try std.testing.expect(header.unparsed_bytes != null);
    try std.testing.expectEqual(@as(usize, 3), header.unparsed_bytes.?.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE }, header.unparsed_bytes.?);
}

test "header id computation is deterministic" {
    const allocator = std.testing.allocator;

    // Build a v3 header
    var buf: [256]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    try w.writeByte(3);
    try w.write(&[_]u8{0x01} ** 32);
    try w.write(&[_]u8{0x02} ** 32);
    try w.write(&[_]u8{0x03} ** 32);
    try w.write(&[_]u8{0x04} ** 33);
    try w.writeUnsignedLong(1704067200000);
    try w.write(&[_]u8{0x05} ** 32);
    try w.write(&[_]u8{ 0x1a, 0x1e, 0x20, 0x30 });
    try w.writeUnsignedInt(1234567);
    try w.write(&[_]u8{ 0x00, 0x00, 0x00 });
    try w.writeByte(0);
    try w.write(&[_]u8{0x06} ** 33);
    try w.write(&[_]u8{0x07} ** 8);

    const written = fbs_write.getWritten();

    var header = try Header.fromBytes(written, allocator);
    defer header.deinit();

    // Compute ID multiple times
    const id1 = header.computeId();
    const id2 = header.computeId();
    const id3 = header.computeId();

    // All should be equal
    try std.testing.expectEqual(id1, id2);
    try std.testing.expectEqual(id2, id3);
}

test "transaction id computation is deterministic" {
    const allocator = std.testing.allocator;

    var buf: [512]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    try w.writeUnsignedShort(1);
    try w.write(&[_]u8{0x01} ** 32);
    try w.writeUnsignedShort(0);
    try w.writeUnsignedShort(0);
    try w.writeUnsignedShort(0);
    try w.writeUnsignedShort(1);
    try w.writeUnsignedLong(1_000_000_000);
    const tree = [_]u8{ 0x00, 0x08, 0xcd };
    try w.writeUnsignedInt(tree.len);
    try w.write(&tree);
    try w.writeUnsignedInt(1000000);
    try w.writeUnsignedInt(0);
    try w.writeByte(0);

    const written = fbs_write.getWritten();

    var tx = try Transaction.fromBytes(written, allocator);
    defer tx.deinit();

    const id1 = tx.computeId();
    const id2 = tx.computeId();
    const id3 = tx.computeId();

    try std.testing.expectEqual(id1, id2);
    try std.testing.expectEqual(id2, id3);
}

test "box candidate with tokens" {
    const allocator = std.testing.allocator;

    var buf: [512]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    // Value
    try w.writeUnsignedLong(1_000_000_000);
    // ErgoTree
    const tree = [_]u8{0x00};
    try w.writeUnsignedInt(tree.len);
    try w.write(&tree);
    // Creation height
    try w.writeUnsignedInt(500000);
    // 2 tokens
    try w.writeUnsignedInt(2);
    // Token 1
    try w.write(&[_]u8{0xAA} ** 32);
    try w.writeUnsignedLong(100);
    // Token 2
    try w.write(&[_]u8{0xBB} ** 32);
    try w.writeUnsignedLong(200);
    // 0 registers
    try w.writeByte(0);

    const written = fbs_write.getWritten();

    var fbs_read = std.io.fixedBufferStream(written);
    var r = vlq.reader(fbs_read.reader());
    var box = try BoxCandidate.deserialize(&r, allocator);
    defer box.deinit();

    try std.testing.expectEqual(@as(u64, 1_000_000_000), box.value);
    try std.testing.expectEqual(@as(usize, 2), box.tokens.len);
    try std.testing.expectEqual(@as(u64, 100), box.tokens[0].amount);
    try std.testing.expectEqual(@as(u64, 200), box.tokens[1].amount);
}

test "input serialization round trip" {
    const allocator = std.testing.allocator;

    var buf: [256]u8 = undefined;
    var fbs_write = std.io.fixedBufferStream(&buf);
    var w = vlq.writer(fbs_write.writer());

    // Box ID
    try w.write(&[_]u8{0xDD} ** 32);
    // Spending proof with some bytes
    try w.writeUnsignedShort(5); // proof_bytes len
    try w.write(&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 });
    try w.writeUnsignedShort(0); // no extension

    const written = fbs_write.getWritten();

    var fbs_read = std.io.fixedBufferStream(written);
    var r = vlq.reader(fbs_read.reader());
    var input = try Input.deserialize(&r, allocator);
    defer input.deinit();

    try std.testing.expectEqual([_]u8{0xDD} ** 32, input.box_id);
    try std.testing.expectEqual(@as(usize, 5), input.spending_proof.proof_bytes.len);
}
