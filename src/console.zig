//! Provide a global, buffered stdin and stdout
//! and non-buffered stderr.

var internal: struct {
    stdin: std.Io.File.Reader,
    stdout: std.Io.File.Writer,
    stderr: std.Io.File.Writer,

    stdin_buffer: [4096]u8,
    stdout_buffer: [4096]u8,
} = undefined;

pub fn init(io: std.Io) void {
    internal.stdin = .initStreaming(.stdin(), io, &internal.stdin_buffer);
    internal.stdout = .initStreaming(.stdout(), io, &internal.stdout_buffer);
    internal.stderr = .initStreaming(.stderr(), io, &.{});
}

pub fn stdin() *std.Io.Reader {
    return &internal.stdin.interface;
}

pub fn stdout() *std.Io.Writer {
    return &internal.stdout.interface;
}

pub fn stderr() *std.Io.Writer {
    return &internal.stderr.interface;
}

/// Flushes output
pub fn deinit() void {
    flushOut() catch {};
}

/// Flush stdin
pub fn flushIn() !void {
    try internal.stdin.flush();
}

/// Flush stdout
pub fn flushOut() !void {
    try internal.stdout.flush();
}

const std = @import("std");
