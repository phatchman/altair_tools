//! Perform wildcard filename expansion on windows.

// This is non-backtracking implementation of globbing.
// Examples that will fail are `*ab` vs `aab` and `*.d` for files with multiple '.'s
// Note: Caller must free any strings added to `out_paths`
pub const windows = struct {
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

    // TODO: Should handle reserved names and non-printables on windows.
    pub fn safeHostFilename(from_filename: []const u8, to_filename: []u8) error{NoSpaceLeft}![]u8 {
        const illegal_chars: []const u8 = "<>:\"/\\|?*+%"; // % is not illegal, but we need to escape it anyway
        return encodeIllegalChars(u8, to_filename, from_filename, illegal_chars);
    }
};

pub fn safeHostFilename(from_filename: []const u8, to_filename: []u8) error{NoSpaceLeft}![]u8 {
    const unixy_illegal_chars: []const u8 = "/%"; // % is not illegal but is used as escape char

    return switch (@import("builtin").os.tag) {
        .windows => windows.safeHostFilename(from_filename, to_filename),
        else => encodeIllegalChars(u8, to_filename, from_filename, unixy_illegal_chars),
    };
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
    }
    return dest[0..to_idx];
}

test "test safe windows filename" {
    var filename_buf: [512]u8 = undefined;

    // unchanged when already safe
    try std.testing.expectEqualSlices(u8, "COP-HF", try windows.safeHostFilename("COP-HF", &filename_buf));

    // illegal char
    try std.testing.expectEqualSlices(u8, "%2ACOPRND%2A", try windows.safeHostFilename("*COPRND*", &filename_buf));

    // literal '%'
    try std.testing.expectEqualSlices(u8, "100%25DONE", try windows.safeHostFilename("100%DONE", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%252ACOPRND%252A", try windows.safeHostFilename("%2ACOPRND%2A", &filename_buf));

    // reserved device names
    try std.testing.expectEqualSlices(u8, "%43ON", try windows.safeHostFilename("CON", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%43ON.TXT", try windows.safeHostFilename("CON.TXT", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%80RN%43ON", try windows.safeHostFilename("PRNCON", &filename_buf));
    try std.testing.expectEqualSlices(u8, "%43ON%80RN", try windows.safeHostFilename("CONPRN", &filename_buf));

    // // trailing dot/space
    // try std.testing.expectEqualSlices(u8, "HELLO%2E", try windows.safeHostFilename("HELLO.", &filename_buf));

    // empty input
    try std.testing.expectEqualSlices(u8, "", try windows.safeHostFilename("", &filename_buf));

    // buffer too small
    var tiny_buf: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, windows.safeHostFilename("*COPRND*", &tiny_buf));
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

    // TODO: For future globbing improvements
    //try std.testing.expectEqual(true, globMatch("*ab", "abb"));
    //try std.testing.expectEqual(true, globMatch("*.*.d", "a.b.c.d"));
    //try std.testing.expectEqual(true, globMatch("*ab", "aabb"));
}

const std = @import("std");
