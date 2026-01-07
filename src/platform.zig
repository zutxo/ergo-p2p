//! Platform abstractions for cross-platform compatibility.
//!
//! Provides OS-specific functionality for terminal mode, socket operations,
//! and resource limits.
//!
//! ## Cross-Platform Notes
//!
//! - **Linux/macOS**: Full functionality including raw terminal mode,
//!   non-blocking sockets, and file descriptor limit management.
//!
//! - **Windows**: Network communication works via Zig's cross-platform
//!   socket abstractions. Terminal raw mode and non-blocking socket helpers
//!   are not implemented (functions are no-ops). The interactive explorer
//!   will work but without advanced terminal features.

const std = @import("std");
const builtin = @import("builtin");

/// Platform detection constants.
pub const is_windows = builtin.os.tag == .windows;
pub const is_macos = builtin.os.tag == .macos;
pub const is_linux = builtin.os.tag == .linux;
pub const is_posix = !is_windows;

/// Terminal state for raw mode.
pub const TermState = if (is_posix) std.posix.termios else void;

/// Enables raw terminal mode for character-by-character input.
pub fn enableRawMode() !TermState {
    if (is_posix) {
        const stdin = std.io.getStdIn();
        var termios = try std.posix.tcgetattr(stdin.handle);
        const original = termios;

        // Disable canonical mode, echo, and signals
        termios.lflag.ICANON = false;
        termios.lflag.ECHO = false;
        termios.lflag.ISIG = false;

        // Set minimum bytes and timeout
        termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin.handle, .FLUSH, termios);
        return original;
    }
    return {};
}

/// Restores terminal to previous state.
pub fn disableRawMode(state: TermState) void {
    if (is_posix) {
        const stdin = std.io.getStdIn();
        std.posix.tcsetattr(stdin.handle, .FLUSH, state) catch {};
    }
}

/// Sets a socket to non-blocking mode.
pub fn setNonBlocking(fd: std.posix.socket_t) !void {
    if (is_posix) {
        const flags = try std.posix.fcntl(fd, .F_GETFL, @as(u32, 0));
        _ = try std.posix.fcntl(fd, .F_SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
    }
}

/// Sets a socket to blocking mode.
pub fn setBlocking(fd: std.posix.socket_t) !void {
    if (is_posix) {
        const flags = try std.posix.fcntl(fd, .F_GETFL, @as(u32, 0));
        const nonblock_mask = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
        _ = try std.posix.fcntl(fd, .F_SETFL, flags & ~nonblock_mask);
    }
}

/// Attempts to raise the open file descriptor limit.
pub fn raiseOpenFileLimit() !u64 {
    if (is_posix) {
        var limits = try std.posix.getrlimit(.NOFILE);

        // Try to raise to maximum
        if (limits.max > limits.cur) {
            limits.cur = limits.max;
            std.posix.setrlimit(.NOFILE, limits) catch {
                // If we can't set max, try a reasonable default
                limits.cur = @min(100_000, limits.max);
                std.posix.setrlimit(.NOFILE, limits) catch {};
            };
        }

        const new_limits = try std.posix.getrlimit(.NOFILE);
        return new_limits.cur;
    }
    return 0;
}

/// Gets the current timestamp in milliseconds.
pub fn timestampMs() i64 {
    return std.time.milliTimestamp();
}

/// Gets the current timestamp in seconds.
pub fn timestampSec() i64 {
    return std.time.timestamp();
}

/// Formats a timestamp as ISO 8601 string.
pub fn formatTimestamp(timestamp_ms: i64, buf: []u8) []const u8 {
    const epoch_seconds: u64 = @intCast(@divTrunc(timestamp_ms, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

/// ANSI color codes for terminal output.
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";

    pub const bg_red = "\x1b[41m";
    pub const bg_green = "\x1b[42m";
    pub const bg_yellow = "\x1b[43m";
    pub const bg_blue = "\x1b[44m";
};

// ============================================================================
// Tests
// ============================================================================

test "platform detection" {
    // At least one should be true
    try std.testing.expect(is_windows or is_macos or is_linux or is_posix);
}

test "timestamp" {
    const ts = timestampMs();
    try std.testing.expect(ts > 0);

    var buf: [32]u8 = undefined;
    const formatted = formatTimestamp(ts, &buf);
    try std.testing.expect(formatted.len > 0);
}
