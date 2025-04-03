//! Provide a global, buffered stdin and stdout
//! and non-buffered stderr.
//! Console.stdin - AnyReader for a buffered stdin
//! Console.stdout - AnyWriter for a buffered stdout.
//! Console.stderr - AnyWriter for an _un_buffered stderr.

pub var stdin: *const std.io.AnyReader = undefined;
pub var stdout: *const std.io.AnyWriter = undefined;
pub var stderr: *const std.io.AnyWriter = undefined;

var _internal: Internal = undefined;

pub fn init(
    stdin_buffered: *std.io.BufferedReader(4096, std.fs.File.Reader),
    stdin_reader: *const std.io.AnyReader,
    stdout_buffered: *std.io.BufferedWriter(4096, std.fs.File.Writer),
    stdout_writer: *const std.io.AnyWriter,
    stderr_writer: *const std.io.AnyWriter,
) void {
    stdin = stdin_reader;
    stdout = stdout_writer;
    stderr = stderr_writer;
    _internal = .{
        .stdin_buffered = stdin_buffered,
        .stdout_buffered = stdout_buffered,
    };
}

/// Flushes output
pub fn deinit() void {
    flushOut() catch {};
}

/// Flush stdin
pub fn flushIn() !void {
    try _internal.stdin_buffered.flush();
}

/// Flush stdout
pub fn flushOut() !void {
    try _internal.stdout_buffered.flush();
}

// Store pointers to the buffered writers as "private" variables.
const Internal = struct {
    stdin_buffered: *std.io.BufferedReader(4096, std.fs.File.Reader),
    stdout_buffered: *std.io.BufferedWriter(4096, std.fs.File.Writer),
};

const std = @import("std");
