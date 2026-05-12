//! Provide a global, buffered stdin and stdout
//! and non-buffered stderr.

var _internal: struct {
    stdin: std.Io.File.Reader,
    stdout: std.Io.File.Writer,
    stderr: std.Io.File.Writer,

    stdin_buffer: [4096]u8,
    stdout_buffer: [4096]u8,
} = undefined;

pub fn init(io: std.Io) void {
    _internal.stdin = .initStreaming(.stdin(), io, &_internal.stdin_buffer);
    _internal.stdout = .initStreaming(.stdout(), io, &_internal.stdout_buffer);
    _internal.stderr = .initStreaming(.stderr(), io, &.{});
}

pub fn stdin() *std.Io.Reader {
    return &_internal.stdin.interface;
}

pub fn stdout() *std.Io.Writer {
    return &_internal.stdout.interface;
}

pub fn stderr() *std.Io.Writer {
    return &_internal.stderr.interface;
}

/// Flushes output
pub fn deinit() void {
    flushOut() catch {};
}

/// Flush stdin
pub fn flushIn() !void {
    try _internal.stdin.flush();
}

/// Flush stdout
pub fn flushOut() !void {
    try _internal.stdout.flush();
}

// Store pointers to the buffered writers as "private" variables.
const Internal = struct {};

const std = @import("std");
