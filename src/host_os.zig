//! The home of various host operating system fuctions
//! By host we mean the operating system running altairdsk vs the image operating system

pub const windows = struct {
    // This is non-backtracking implementation of globbing.
    // Examples that will fail are `*ab` vs `aab` and `*.d` for files with multiple '.'s
    // Note: Caller must free any strings added to `out_paths`
    pub fn glob(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8, out_paths: *std.ArrayList([]const u8)) (std.Io.Dir.OpenError || error{OutOfMemory})!void {
        const basename = std.fs.path.basename(pattern);
        const dirname = std.fs.path.dirname(pattern) orelse "";
        // Check if any globbing is required.
        if (std.mem.findAny(u8, basename, "*?") == null) {
            try out_paths.append(gpa, try gpa.dupe(u8, basename));
            return;
        }

        const cwd = try std.Io.Dir.cwd().openDir(io, dirname, .{ .iterate = true });
        defer cwd.close(io);
        var itr = cwd.iterateAssumeFirstIteration();
        while (try itr.next(io)) |file| {
            if (file.kind == .file) {
                if (globMatch(basename, file.name)) {
                    try out_paths.append(gpa, try std.fs.path.join(gpa, &.{ dirname, file.name }));
                }
            }
        }
    }

    fn globMatch(pattern: []const u8, filename: []const u8) bool {
        var file_idx: usize = 0;
        var pat_idx: usize = 0;

        if (pattern.len == 0 or filename.len == 0) return false;

        for (pattern) |pat_ch| {
            if (file_idx >= filename.len) return false;
            const file_ch = filename[file_idx];
            switch (pat_ch) {
                '?' => {
                    file_idx += 1;
                },
                '*' => {
                    if (pat_idx == pattern.len - 1) {
                        return true;
                    } else {
                        const next_pat = pattern[pat_idx + 1];
                        while (file_idx < filename.len and filename[file_idx] != '.' and filename[file_idx] != next_pat) {
                            file_idx += 1;
                        }
                    }
                },
                else => {
                    if (std.ascii.toUpper(pat_ch) != std.ascii.toUpper(file_ch)) {
                        return false;
                    } else {
                        file_idx += 1;
                    }
                },
            }
            pat_idx += 1;
        }
        return pat_idx == pattern.len and file_idx == filename.len;
    }

    // As of Windows 11, only NUL is reserved. But we encode them anyway.
    pub fn toSafeHostFilename(from_filename: []const u8, to_filename: []u8) error{NoSpaceLeft}![]u8 {
        const illegal_chars: []const u8 = "<>:\"/\\|?*+%"; // % is not illegal, but we need to escape it anyway
        const illegal_names: []const []const u8 = &[_][]const u8{
            "CON",  "PRN",  "AUX",  "NUL",  "COM1",
            "COM2", "COM3", "COM4", "COM5", "COM6",
            "COM7", "COM8", "COM9", "LPT1", "LPT2",
            "LPT3", "LPT4", "LPT5", "LPT6", "LPT7",
            "LPT8", "LPT9",
        };
        const result = try encodeIllegalChars(u8, to_filename, from_filename, illegal_chars);
        var result_len = result.len;
        for (illegal_names) |name| {
            if (std.ascii.startsWithIgnoreCase(result, name)) {
                if (result.len == name.len or
                    (result.len > name.len and result[name.len] == '.'))
                {
                    if (to_filename.len <= result_len + 2) return error.NoSpaceLeft;
                    @memmove(to_filename[2 .. result_len + 2], to_filename[0..result_len]);
                    result_len += (try std.fmt.bufPrint(to_filename, "%{X:02}", .{name[0]})).len - 1;
                }
                break;
            }
        }
        // Preserve trailing periods
        if (result_len > 1 and to_filename[result_len - 1] == '.') {
            result_len += (try std.fmt.bufPrint(to_filename[result_len - 1 ..], "%{X:02}", .{'.'})).len - 1;
        }
        return to_filename[0..result_len];
    }
};

pub fn toSafeHostFilename(from_filename: []const u8, to_filename: []u8) error{NoSpaceLeft}![]u8 {
    const unixy_illegal_chars: []const u8 = "/%"; // % is not illegal but is used as escape char

    return switch (@import("builtin").os.tag) {
        .windows => windows.toSafeHostFilename(from_filename, to_filename),
        else => encodeIllegalChars(u8, to_filename, from_filename, unixy_illegal_chars),
    };
}

pub fn fromSafeHostFilename(host_filename: []const u8, image_filename: []u8) error{NoSpaceLeft}![]u8 {
    return decodeIllegalChars(u8, image_filename, host_filename);
}

fn encodeIllegalChars(comptime T: type, dest: []T, source: []const T, illegal_chars: []const T) error{NoSpaceLeft}![]u8 {
    var to_idx: usize = 0;
    for (source) |ch| {
        if (std.mem.indexOfScalar(T, illegal_chars, ch)) |_| {
            to_idx += (try std.fmt.bufPrint(dest[to_idx..], "%{X:02}", .{ch})).len;
        } else {
            dest[to_idx] = ch;
            to_idx += 1;
        }
        if (to_idx == dest.len) return error.NoSpaceLeft;
    }
    return dest[0..to_idx];
}

fn decodeIllegalChars(comptime T: type, dest: []T, source: []const T) error{NoSpaceLeft}![]u8 {
    var dest_idx: usize = 0;
    var source_idx: usize = 0;
    while (source_idx < source.len) : ({
        source_idx += 1;
        dest_idx += 1;
    }) {
        if (dest.len <= dest_idx + 2) return error.NoSpaceLeft;
        if (source_idx + 2 < source.len and source[source_idx] == '%') {
            const new_ch = std.fmt.parseInt(u8, source[source_idx..][1..3], 16) catch 255;
            if (std.ascii.isPrint(new_ch)) {
                dest[dest_idx] = new_ch;
                source_idx += 2;
                continue;
            }
        }
        dest[dest_idx] = source[source_idx];
    }
    return dest[0..dest_idx];
}

test "test safe windows filename" {
    var filename_buf: [512]u8 = undefined;

    // unchanged when already safe
    try std.testing.expectEqualSlices(u8, "COP-HF", try windows.toSafeHostFilename("COP-HF", &filename_buf));

    // illegal char
    try std.testing.expectEqualSlices(u8, "%2ACOPRND%2A", try windows.toSafeHostFilename("*COPRND*", &filename_buf));

    // literal '%'
    try std.testing.expectEqualSlices(u8, "100%25DONE", try windows.toSafeHostFilename("100%DONE", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%252ACOPRND%252A", try windows.toSafeHostFilename("%2ACOPRND%2A", &filename_buf));

    // These are no longer reserved on win 11, so low priority to implement this.
    // reserved device names
    try std.testing.expectEqualSlices(u8, "%43ON", try windows.toSafeHostFilename("CON", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%43ON.TXT", try windows.toSafeHostFilename("CON.TXT", &filename_buf));
    try std.testing.expectEqualSlices(u8, "PRNCON", try windows.toSafeHostFilename("PRNCON", &filename_buf));
    try std.testing.expectEqualSlices(u8, "CONPRN", try windows.toSafeHostFilename("CONPRN", &filename_buf));

    // trailing dot/space
    try std.testing.expectEqualSlices(u8, "HELLO%2E", try windows.toSafeHostFilename("HELLO.", &filename_buf));

    // empty input
    try std.testing.expectEqualSlices(u8, "", try windows.toSafeHostFilename("", &filename_buf));

    // buffer too small
    var tiny_buf: [3]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, windows.toSafeHostFilename("*COPRND*", &tiny_buf));
    try std.testing.expectError(error.NoSpaceLeft, windows.toSafeHostFilename("CON", &tiny_buf));
}

test "test from safe host filename" {
    var filename_buf: [512]u8 = undefined;

    // unchanged when no escapes present
    try std.testing.expectEqualSlices(u8, "COP-HF", try fromSafeHostFilename("COP-HF", &filename_buf));

    // illegal char
    try std.testing.expectEqualSlices(u8, "*COPRND*", try fromSafeHostFilename("%2ACOPRND%2A", &filename_buf));

    // literal '%'
    try std.testing.expectEqualSlices(u8, "100%DONE", try fromSafeHostFilename("100%25DONE", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%2ACOPRND%2A", try fromSafeHostFilename("%252ACOPRND%252A", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%FILE%", try fromSafeHostFilename("%FILE%", &filename_buf));

    // reserved device names round trip
    try std.testing.expectEqualSlices(u8, "CON", try fromSafeHostFilename("%43ON", &filename_buf));
    try std.testing.expectEqualSlices(u8, "CON.TXT", try fromSafeHostFilename("%43ON.TXT", &filename_buf));
    try std.testing.expectEqualSlices(u8, "PRNCON", try fromSafeHostFilename("PRNCON", &filename_buf));
    try std.testing.expectEqualSlices(u8, "CONPRN", try fromSafeHostFilename("CONPRN", &filename_buf));

    // trailing dot/space round trip
    try std.testing.expectEqualSlices(u8, "HELLO.", try fromSafeHostFilename("HELLO%2E", &filename_buf));

    // empty input
    try std.testing.expectEqualSlices(u8, "", try fromSafeHostFilename("", &filename_buf));

    // lowercase hex digits
    try std.testing.expectEqualSlices(u8, "*COPRND*", try fromSafeHostFilename("%2aCOPRND%2a", &filename_buf));

    // not enough hex digits after '%'
    try std.testing.expectEqualSlices(u8, "100%2", try fromSafeHostFilename("100%2", &filename_buf));
    try std.testing.expectEqualSlices(u8, "100%", try fromSafeHostFilename("100%", &filename_buf));
    // (non-hex digits after '%')
    try std.testing.expectEqualSlices(u8, "100%ZZDONE", try fromSafeHostFilename("100%ZZDONE", &filename_buf));

    // buffer too small
    var tiny_buf: [3]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, fromSafeHostFilename("%2ACOPRND%2A", &tiny_buf));
    try std.testing.expectError(error.NoSpaceLeft, fromSafeHostFilename("%43ON", &tiny_buf));
}

test "globbing" {
    const globMatch = windows.globMatch;
    try std.testing.expectEqual(true, globMatch("abc*", "abcdef"));
    try std.testing.expectEqual(true, globMatch("abc*", "abcdef."));
    try std.testing.expectEqual(true, globMatch("abc*", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch("abc*.st*", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch("abc*.*ar", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch("abcdef.star", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch("*.star", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch("*.*", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch("*", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch(".*", ".star"));
    try std.testing.expectEqual(true, globMatch("ab*f*", "abcdef.star"));
    try std.testing.expectEqual(true, globMatch("*.*", "a.b.c"));
    try std.testing.expectEqual(true, globMatch("a??d?f", "abcdef"));
    try std.testing.expectEqual(true, globMatch("*.t?t", "abcdef.txt"));

    try std.testing.expectEqual(false, globMatch("*.", "abcdef.star"));
    try std.testing.expectEqual(false, globMatch("aa.aa", "aa.a"));
    try std.testing.expectEqual(false, globMatch("", "a"));
    try std.testing.expectEqual(false, globMatch(".*", "b.star"));
    try std.testing.expectEqual(false, globMatch("a??d?f", "abcxef"));
    try std.testing.expectEqual(false, globMatch("*.??", "abcdef.txt"));

    // FUTURE TODO: For future globbing improvements
    //try std.testing.expectEqual(true, globMatch("*ab", "abb"));
    //try std.testing.expectEqual(true, globMatch("*.*.d", "a.b.c.d"));
    //try std.testing.expectEqual(true, globMatch("*ab", "aabb"));
}

const std = @import("std");
