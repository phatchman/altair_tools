//! Perform wildcard filename expansion on windows.

// This is a fairly naive implementation of globbing that gives us 90% of the functionality.
// Examples that will fail are `*ab` vs `aab` and `*.d` for files with multiple '.'s
// Note: Caller must free any strings added to `out_paths`
pub fn glob(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8, out_paths: *std.ArrayList([]const u8)) (std.Io.Dir.OpenError || error{OutOfMemory})!void {
    const basename = std.fs.path.basename(pattern);
    const dirname = std.fs.path.dirname(pattern) orelse "";
    // Check if any globbing is required.
    if (std.mem.findAny(u8, basename, "*?") == null) {
        try out_paths.append(gpa, try gpa.dupe(u8, pattern));
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

const std = @import("std");

test "globbing" {
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
