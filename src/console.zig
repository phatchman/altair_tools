//! Provide a global, buffered stdin and stdout
//! and non-buffered stderr.

pub var stdin: *const std.io.AnyReader = undefined;
pub var stdout: *const std.io.AnyWriter = undefined;
pub var stderr: *const std.io.AnyWriter = undefined;

var internal: Internal = undefined;

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
    internal = .{
        .stdin_buffered = stdin_buffered,
        .stdout_buffered = stdout_buffered,
    };
}

pub fn deinit() void {
    flushOut() catch {};
}

pub fn flushIn() !void {
    try internal.stdin_buffered.flush();
}

pub fn flushOut() !void {
    try internal.stdout_buffered.flush();
}

const Internal = struct {
    stdin_buffered: *std.io.BufferedReader(4096, std.fs.File.Reader) = undefined,
    stdout_buffered: *std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined,
};

const std = @import("std");
