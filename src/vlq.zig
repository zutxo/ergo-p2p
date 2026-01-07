//! VLQ (Variable-Length Quantity) encoding for Ergo protocol.
//!
//! VLQ uses 7 bits of data per byte with bit 7 as a continuation flag.
//! Signed integers use ZigZag encoding before VLQ encoding.

const std = @import("std");

pub const Error = error{
    OverlongVarint,
    OutOfRange,
    EndOfStream,
    UnexpectedEof,
};

/// Encodes a signed 32-bit integer using ZigZag encoding.
/// Maps negative numbers to positive: 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3, etc.
pub fn zigZagEncodeI32(n: i32) u32 {
    return @bitCast((n << 1) ^ (n >> 31));
}

/// Decodes a ZigZag-encoded 32-bit integer.
pub fn zigZagDecodeI32(n: u32) i32 {
    return @as(i32, @bitCast(n >> 1)) ^ -@as(i32, @intCast(n & 1));
}

/// Encodes a signed 64-bit integer using ZigZag encoding.
pub fn zigZagEncodeI64(n: i64) u64 {
    return @bitCast((n << 1) ^ (n >> 63));
}

/// Decodes a ZigZag-encoded 64-bit integer.
pub fn zigZagDecodeI64(n: u64) i64 {
    return @as(i64, @bitCast(n >> 1)) ^ -@as(i64, @intCast(n & 1));
}

/// VLQ Reader wraps any reader for reading VLQ-encoded values.
pub fn Reader(comptime ReaderType: type) type {
    return struct {
        inner: ReaderType,

        const Self = @This();

        pub fn init(inner_reader: ReaderType) Self {
            return .{ .inner = inner_reader };
        }

        /// Reads a single byte.
        pub fn readByte(self: *Self) !u8 {
            return self.inner.readByte() catch |err| switch (err) {
                error.EndOfStream => return Error.EndOfStream,
                else => return err,
            };
        }

        /// Reads a signed byte.
        pub fn readSignedByte(self: *Self) !i8 {
            return @bitCast(try self.readByte());
        }

        /// Reads a boolean value (0 = false, non-zero = true).
        pub fn readBoolean(self: *Self) !bool {
            return (try self.readByte()) != 0;
        }

        /// Reads exactly n bytes into the provided buffer.
        pub fn readFully(self: *Self, buf: []u8) !void {
            const n = try self.inner.readAll(buf);
            if (n != buf.len) {
                return Error.UnexpectedEof;
            }
        }

        /// Reads exactly n bytes, allocating the buffer.
        pub fn readNBytes(self: *Self, allocator: std.mem.Allocator, n: usize) ![]u8 {
            const buf = try allocator.alloc(u8, n);
            errdefer allocator.free(buf);
            try self.readFully(buf);
            return buf;
        }

        /// Reads an unsigned long (up to 64 bits) using VLQ encoding.
        pub fn readUnsignedLong(self: *Self) !u64 {
            var result: u64 = 0;
            var shift: u6 = 0;

            while (shift < 64) : (shift += 7) {
                const b = try self.readByte();
                result |= @as(u64, b & 0x7F) << shift;
                if ((b & 0x80) == 0) {
                    return result;
                }
            }
            return Error.OverlongVarint;
        }

        /// Reads a signed short using ZigZag + VLQ encoding.
        pub fn readShort(self: *Self) !i16 {
            const val = try self.readUnsignedLong();
            return @truncate(zigZagDecodeI32(@truncate(val)));
        }

        /// Reads an unsigned short using VLQ encoding.
        pub fn readUnsignedShort(self: *Self) !u16 {
            const val = try self.readUnsignedLong();
            if (val > 0xFFFF) {
                return Error.OutOfRange;
            }
            return @truncate(val);
        }

        /// Reads a signed int using ZigZag + VLQ encoding.
        pub fn readInt(self: *Self) !i32 {
            const val = try self.readUnsignedLong();
            return zigZagDecodeI32(@truncate(val));
        }

        /// Reads an unsigned int using VLQ encoding.
        pub fn readUnsignedInt(self: *Self) !u32 {
            const val = try self.readUnsignedLong();
            if (val > 0xFFFFFFFF) {
                return Error.OutOfRange;
            }
            return @truncate(val);
        }

        /// Reads a signed long using ZigZag + VLQ encoding.
        pub fn readLong(self: *Self) !i64 {
            const val = try self.readUnsignedLong();
            return zigZagDecodeI64(val);
        }

        /// Reads a VLQ-prefixed byte array.
        pub fn readBytes(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            const len = try self.readUnsignedInt();
            return self.readNBytes(allocator, len);
        }

        /// Reads a VLQ-prefixed string (UTF-8).
        pub fn readString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            return self.readBytes(allocator);
        }
    };
}

/// VLQ Writer wraps any writer for writing VLQ-encoded values.
pub fn Writer(comptime WriterType: type) type {
    return struct {
        inner: WriterType,

        const Self = @This();

        pub fn init(inner_writer: WriterType) Self {
            return .{ .inner = inner_writer };
        }

        /// Writes raw bytes.
        pub fn write(self: *Self, data: []const u8) !void {
            try self.inner.writeAll(data);
        }

        /// Writes a single byte.
        pub fn writeByte(self: *Self, b: u8) !void {
            try self.inner.writeByte(b);
        }

        /// Writes a boolean value.
        pub fn writeBoolean(self: *Self, b: bool) !void {
            try self.writeByte(if (b) 1 else 0);
        }

        /// Writes an unsigned long using VLQ encoding.
        pub fn writeUnsignedLong(self: *Self, val: u64) !void {
            var value = val;
            var buffer: [10]u8 = undefined;
            var position: usize = 0;

            while (true) {
                if ((value & ~@as(u64, 0x7F)) == 0) {
                    buffer[position] = @truncate(value);
                    position += 1;
                    try self.write(buffer[0..position]);
                    return;
                }
                buffer[position] = @truncate((value & 0x7F) | 0x80);
                position += 1;
                value >>= 7;
            }
        }

        /// Writes a signed short using ZigZag + VLQ encoding.
        pub fn writeShort(self: *Self, val: i16) !void {
            try self.writeUnsignedLong(@as(u64, zigZagEncodeI32(@as(i32, val))));
        }

        /// Writes an unsigned short using VLQ encoding.
        pub fn writeUnsignedShort(self: *Self, val: u16) !void {
            try self.writeUnsignedLong(@as(u64, val));
        }

        /// Writes a signed int using ZigZag + VLQ encoding.
        pub fn writeInt(self: *Self, val: i32) !void {
            try self.writeUnsignedLong(@as(u64, zigZagEncodeI32(val)));
        }

        /// Writes an unsigned int using VLQ encoding.
        pub fn writeUnsignedInt(self: *Self, val: u32) !void {
            try self.writeUnsignedLong(@as(u64, val));
        }

        /// Writes a signed long using ZigZag + VLQ encoding.
        pub fn writeLong(self: *Self, val: i64) !void {
            try self.writeUnsignedLong(zigZagEncodeI64(val));
        }

        /// Writes a VLQ-prefixed byte array.
        pub fn writeBytes(self: *Self, data: []const u8) !void {
            try self.writeUnsignedInt(@truncate(data.len));
            try self.write(data);
        }

        /// Writes a VLQ-prefixed string (UTF-8).
        pub fn writeString(self: *Self, str: []const u8) !void {
            try self.writeBytes(str);
        }
    };
}

/// Creates a VLQ reader from any reader.
pub fn reader(inner: anytype) Reader(@TypeOf(inner)) {
    return Reader(@TypeOf(inner)).init(inner);
}

/// Creates a VLQ writer from any writer.
pub fn writer(inner: anytype) Writer(@TypeOf(inner)) {
    return Writer(@TypeOf(inner)).init(inner);
}

// ============================================================================
// Tests
// ============================================================================

test "zigzag encode/decode i32" {
    const cases = [_]struct { input: i32, encoded: u32 }{
        .{ .input = 0, .encoded = 0 },
        .{ .input = -1, .encoded = 1 },
        .{ .input = 1, .encoded = 2 },
        .{ .input = -2, .encoded = 3 },
        .{ .input = 2, .encoded = 4 },
        .{ .input = 2147483647, .encoded = 4294967294 },
        .{ .input = -2147483648, .encoded = 4294967295 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.encoded, zigZagEncodeI32(case.input));
        try std.testing.expectEqual(case.input, zigZagDecodeI32(case.encoded));
    }
}

test "zigzag encode/decode i64" {
    const cases = [_]struct { input: i64, encoded: u64 }{
        .{ .input = 0, .encoded = 0 },
        .{ .input = -1, .encoded = 1 },
        .{ .input = 1, .encoded = 2 },
        .{ .input = -2, .encoded = 3 },
        .{ .input = 9223372036854775807, .encoded = 18446744073709551614 },
        .{ .input = -9223372036854775808, .encoded = 18446744073709551615 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.encoded, zigZagEncodeI64(case.input));
        try std.testing.expectEqual(case.input, zigZagDecodeI64(case.encoded));
    }
}

test "vlq unsigned long round trip" {
    const cases = [_]u64{
        0,
        1,
        127,
        128,
        255,
        256,
        16383,
        16384,
        2097151,
        2097152,
        268435455,
        268435456,
        0xFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
    };

    for (cases) |val| {
        var buf: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var w = writer(fbs.writer());
        try w.writeUnsignedLong(val);

        fbs.pos = 0;
        var r = reader(fbs.reader());
        const result = try r.readUnsignedLong();
        try std.testing.expectEqual(val, result);
    }
}

test "vlq signed int round trip" {
    const cases = [_]i32{
        0,
        1,
        -1,
        127,
        -127,
        128,
        -128,
        32767,
        -32768,
        2147483647,
        -2147483648,
    };

    for (cases) |val| {
        var buf: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var w = writer(fbs.writer());
        try w.writeInt(val);

        fbs.pos = 0;
        var r = reader(fbs.reader());
        const result = try r.readInt();
        try std.testing.expectEqual(val, result);
    }
}

test "vlq signed long round trip" {
    const cases = [_]i64{
        0,
        1,
        -1,
        9223372036854775807,
        -9223372036854775808,
    };

    for (cases) |val| {
        var buf: [10]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var w = writer(fbs.writer());
        try w.writeLong(val);

        fbs.pos = 0;
        var r = reader(fbs.reader());
        const result = try r.readLong();
        try std.testing.expectEqual(val, result);
    }
}

test "vlq bytes round trip" {
    const data = "Hello, Ergo!";
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var w = writer(fbs.writer());
    try w.writeBytes(data);

    fbs.pos = 0;
    var r = reader(fbs.reader());
    const result = try r.readBytes(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(data, result);
}

test "vlq specific byte sequences" {
    // Test that 300 encodes correctly (0xAC 0x02)
    var buf: [10]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var w = writer(fbs.writer());
    try w.writeUnsignedLong(300);

    try std.testing.expectEqual(@as(u8, 0xAC), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[1]);
}
