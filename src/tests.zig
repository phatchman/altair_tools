const std = @import("std");
const testing = std.testing;
const FileNameIterator = @import("disk_image.zig").FileNameIterator;
const Disk8IN = @import("disk_types.zig").all_disk_types.getPtrConst(.FDD_8IN);
const DiskImageType = @import("disk_types.zig").DiskImageType;
const DirectoryTable = @import("directory_table.zig").DirectoryTable;
const CookedDirEntry = @import("directory_table.zig").CookedDirEntry;
const RawDirEntry = @import("directory_table.zig").RawDirEntry;

comptime {
    _ = @import("disk_image_tests.zig");
}

test "simple filename" {
    const filename = "FILENAME.COM";

    var raw = std.mem.zeroes(RawDirEntry);
    raw.filenameAndExtensionSet(filename);
    try std.testing.expectEqualStrings("FILENAME", &raw.filename);
    try std.testing.expectEqualStrings("COM", &raw.filetype);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cooked = try CookedDirEntry.init(arena.allocator(), &raw, 0, Disk8IN);
    try std.testing.expectEqualStrings("FILENAME.COM", cooked.filenameAndExtension());
    try std.testing.expectEqualStrings("FILENAME", cooked.filenameOnly());
    try std.testing.expectEqualStrings("COM", cooked.extension());
}

test "filename no extension" {
    const filename = "FILENAME";

    var raw: RawDirEntry = std.mem.zeroes(RawDirEntry);
    raw.filenameAndExtensionSet(filename);
    try std.testing.expectEqualStrings("FILENAME", &raw.filename);
    try std.testing.expectEqualStrings("   ", &raw.filetype);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cooked = try CookedDirEntry.init(arena.allocator(), &raw, 0, Disk8IN);
    try std.testing.expectEqualStrings("FILENAME", cooked.filenameAndExtension());
    try std.testing.expectEqualStrings("FILENAME", cooked.filenameOnly());
    try std.testing.expectEqualStrings("", cooked.extension());
}

test "extension no filename" {
    const filename = ".COM";

    var raw: RawDirEntry = std.mem.zeroes(RawDirEntry);
    raw.filenameAndExtensionSet(filename);
    try std.testing.expectEqualStrings("        ", &raw.filename);
    try std.testing.expectEqualStrings("COM", &raw.filetype);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cooked = try CookedDirEntry.init(arena.allocator(), &raw, 0, Disk8IN);
    try std.testing.expectEqualStrings(".COM", cooked.filenameAndExtension());
    try std.testing.expectEqualStrings("", cooked.filenameOnly());
    try std.testing.expectEqualStrings("COM", cooked.extension());
}

test "short filename no extension" {
    const filename = "X.";

    var raw: RawDirEntry = std.mem.zeroes(RawDirEntry);
    raw.filenameAndExtensionSet(filename);
    try std.testing.expectEqualStrings("X       ", &raw.filename);
    try std.testing.expectEqualStrings("   ", &raw.filetype);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cooked = try CookedDirEntry.init(arena.allocator(), &raw, 0, Disk8IN);
    try std.testing.expectEqualStrings("X", cooked.filenameAndExtension());
    try std.testing.expectEqualStrings("X", cooked.filenameOnly());
    try std.testing.expectEqualStrings("", cooked.extension());
}

test "short extension no filename" {
    const filename = ".X";

    var raw: RawDirEntry = std.mem.zeroes(RawDirEntry);
    raw.filenameAndExtensionSet(filename);
    try std.testing.expectEqualStrings("        ", &raw.filename);
    try std.testing.expectEqualStrings("X  ", &raw.filetype);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cooked = try CookedDirEntry.init(arena.allocator(), &raw, 0, Disk8IN);
    try std.testing.expectEqualStrings(".X", cooked.filenameAndExtension());
    try std.testing.expectEqualStrings("", cooked.filenameOnly());
    try std.testing.expectEqualStrings("X", cooked.extension());
}

test "translate valid filename" {
    const filename = "FILENAME.TXT";
    var buffer: [15]u8 = undefined;

    const cpm_name = try DirectoryTable.translateToCPMFilename(filename[0..], &buffer);
    try std.testing.expectEqualStrings(filename, cpm_name);
}

test "translate invalid chars filename" {
    const filename = "FI?LE[AME.T:T";
    var buffer: [15]u8 = undefined;

    const cpm_name = try DirectoryTable.translateToCPMFilename(filename[0..], &buffer);
    try std.testing.expectEqualStrings("FILEAME.TT", cpm_name);
}

test "translate multiple extension filename" {
    const filename = "FILE.....NAME.TXT.ASM";
    var buffer: [15]u8 = undefined;

    const cpm_name = try DirectoryTable.translateToCPMFilename(filename[0..], &buffer);
    try std.testing.expectEqualStrings("FILE.NAM", cpm_name);
}

test "translate all invalid filename" {
    const filename = "[[[.]]]";
    var buffer: [15]u8 = undefined;

    try testing.expectError(error.InvalidFilename, DirectoryTable.translateToCPMFilename(filename[0..], &buffer));
}
