//! Test all disk operations on each image format

test "8in formatted" {
    const compare_image = @embedFile("test_disks/8in_fmt.dsk");
    var test_buffer: [FDD_8IN.image_size]u8 = undefined;

    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, FDD_8IN);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "HDD 5MB formatted" {
    const compare_image = @embedFile("test_disks/5mb_fmt.dsk");
    var test_buffer: [HDD_5MB.image_size]u8 = undefined;

    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, HDD_5MB);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "HDD 5MB 1024 dirs formatted" {
    const compare_image = @embedFile("test_disks/5mb_fmt.dsk");
    var test_buffer: [HDD_5MB_1024.image_size]u8 = undefined;

    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, HDD_5MB_1024);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "HDD 5MB 1024 supports 1024 dirs?" {
    var test_buffer: [HDD_5MB_1024.image_size]u8 = undefined;

    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, HDD_5MB_1024);
    defer disk_image.deinit();

    var test_file = "Mostly harmless.".*;
    var test_stream = makeStream(&test_file);

    var filename_buffer: [20]u8 = undefined;
    // Should handle 1024 entries
    for (0..1024) |i| {
        const filename = try std.fmt.bufPrint(&filename_buffer, "{d}.TXT", .{i});
        try disk_image._copyToImage(&test_stream, filename, 0, false);
    }
    // buit not 1025
    try std.testing.expectError(error.OutOfExtents, disk_image._copyToImage(&test_stream, "STRAW.BAK", 0, false));
}

test "Tarbell formatted" {
    const compare_image = @embedFile("test_disks/tar_fmt.dsk");
    var test_buffer: [TAR.image_size]u8 = undefined;

    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, TAR);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "FDC 1.5MB formatted" {
    const compare_image = @embedFile("test_disks/1.5mb_fmt.dsk");
    var test_buffer: [FDC.image_size]u8 = undefined;

    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, FDC);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "FDC 8MB formatted" {
    const compare_image = @embedFile("test_disks/8mb_fmt.dsk");
    var test_buffer: [FDC_8MB.image_size]u8 = undefined;

    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, FDC_8MB);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "8in filled" {
    // Make a 296K file to fill the disk.
    const nr_sectors = 296 * 1024 / 128;
    var big_file: [nr_sectors * 128]u8 = undefined;
    for (0..nr_sectors) |sector| {
        const fill_char: u8 = ' ' + @as(u8, @intCast(sector % (127 - ' ')));
        const start = sector * 128;
        const end = start + 128;
        @memset(big_file[start..end], fill_char);
        _ = try std.fmt.bufPrint(big_file[start..end], "\n--[{d}]--", .{sector});
    }
    var big_stream = makeStream(&big_file);

    // Create in-memory disk image.
    var test_buffer: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, FDD_8IN);
    defer disk_image.deinit();

    // Copy to disk to fill it up.
    const filename = "BIG.TXT";
    try disk_image._copyToImage(&big_stream, filename, 0, false);
    try std.testing.expectEqual(disk_image.directory.free_allocations.count(), 0);
    try std.testing.expectEqual(disk_image.capacityFreeInKB(), 0);
    try std.testing.expectEqual(disk_image.directory.cooked_directories.items.len, 1);
    try std.testing.expectEqualStrings(disk_image.directory.cooked_directories.items[0].filenameAndExtension(), filename);

    // Get it back and compare it to the original
    var in_file: [big_file.len]u8 = undefined;
    var in_stream = makeStream(&in_file);

    const cooked_dir = disk_image.directory.findByFilename(filename, null);
    try std.testing.expect(cooked_dir != null);
    try disk_image._copyFromImage(cooked_dir.?, &in_stream, .Binary);
    try std.testing.expectEqualSlices(u8, &in_file, &big_file);
}

test "8MB filled" {
    // Make a 8168KB file to fill the disk.
    const nr_sectors = 8168 * 1024 / 128;
    var big_file = try std.testing.allocator.alloc(u8, nr_sectors * 128);
    defer std.testing.allocator.free(big_file);
    for (0..nr_sectors) |sector| {
        const fill_char: u8 = ' ' + @as(u8, @intCast(sector % (127 - ' ')));
        const start = sector * 128;
        const end = start + 128;
        @memset(big_file[start..end], fill_char);
        _ = try std.fmt.bufPrint(big_file[start..end], "\n--[{d}]--", .{sector});
    }
    var big_stream = makeStream(big_file);

    // Create in-memory disk image.
    const test_buffer = try std.testing.allocator.alloc(u8, FDC_8MB.image_size);
    defer std.testing.allocator.free(test_buffer);
    var disk_image = try newFormattedMemoryDiskImage(test_buffer, FDC_8MB);
    defer disk_image.deinit();

    // Copy to disk to fill it up.
    const filename = "BIG.TXT";
    try disk_image._copyToImage(&big_stream, filename, 0, false);
    try std.testing.expectEqual(disk_image.directory.free_allocations.count(), 0);
    try std.testing.expectEqual(disk_image.capacityFreeInKB(), 0);
    try std.testing.expectEqual(disk_image.directory.cooked_directories.items.len, 1);
    try std.testing.expectEqualStrings(disk_image.directory.cooked_directories.items[0].filenameAndExtension(), filename);

    // Get it back and compare it to the original
    const in_file = try std.testing.allocator.alloc(u8, big_file.len);
    defer std.testing.allocator.free(in_file);
    var in_stream = makeStream(in_file);

    const cooked_dir = disk_image.directory.findByFilename(filename, null);
    try std.testing.expect(cooked_dir != null);
    try disk_image._copyFromImage(cooked_dir.?, &in_stream, .Binary);
    try std.testing.expectEqualSlices(u8, in_file, big_file);
}

test "8in overfilled disk" {
    // Make file 1 byte too big. Should result in out of allocs.
    var big_file = std.mem.zeroes([296 * 1024 + 1]u8);
    var big_stream = makeStream(&big_file);

    var test_buffer: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&test_buffer, FDD_8IN);
    defer disk_image.deinit();

    try std.testing.expectError(
        error.OutOfAllocs,
        disk_image._copyToImage(&big_stream, "BIG.TXT", 0, false),
    );
    try std.testing.expectEqual(disk_image.directory.cooked_directories.items.len, 1);
}

test "8in overfill directory" {
    var test_file = "Mary had a little lamb, it's father was the ram.".*;
    var test_stream = makeStream(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    var name_buf: [256]u8 = undefined;
    for (0..FDD_8IN.directories) |num| {
        try disk_image._copyToImage(&test_stream, try std.fmt.bufPrint(&name_buf, "T{d}", .{num}), 0, false);
    }
    try std.testing.expectError(
        error.OutOfExtents,
        disk_image._copyToImage(&test_stream, try std.fmt.bufPrint(&name_buf, "T{d}", .{FDD_8IN.directories}), 0, false),
    );
}

test "8in duplicate filenames" {
    var test_file = "Mary had a little lamb, it's father was the ram.".*;
    var test_stream = makeStream(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    try disk_image._copyToImage(&test_stream, "MARY.TXT", 0, false);
    try std.testing.expectError(
        std.fs.File.OpenError.PathAlreadyExists,
        disk_image._copyToImage(&test_stream, "MARY.TXT", 0, false),
    );
    // 2nd time force the overwrite.
    try disk_image._copyToImage(&test_stream, "MARY.TXT", 0, true);
}

test "8 in zero-length file" {
    var test_file = "".*;
    var test_stream = makeStream(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();
    try disk_image._copyToImage(&test_stream, "MARY.TXT", 0, false);

    // Get it back and compare it to the original
    var in_file: [0]u8 = undefined;
    var in_stream = makeStream(&in_file);

    const cooked_dir = disk_image.directory.findByFilename("MARY.TXT", null);
    try std.testing.expect(cooked_dir != null);
    // Will throw if it tries to write any bytes to the empty buffer;
    try disk_image._copyFromImage(cooked_dir.?, &in_stream, .Text);
}

test "8in Text file" {
    var test_file = "Mary had a little lamb, it's father was the ram.".*;
    var test_stream = makeStream(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();
    try disk_image._copyToImage(&test_stream, "MARY.TXT", 0, false);

    // Get it back and compare it to the original
    var in_file: [test_file.len]u8 = undefined;
    var in_stream = makeStream(&in_file);

    const cooked_dir = disk_image.directory.findByFilename("MARY.TXT", null);
    try std.testing.expect(cooked_dir != null);
    // Will throw if it tries to write any buytes to the empty buffer;
    try disk_image._copyFromImage(cooked_dir.?, &in_stream, .Text);
    try std.testing.expectEqualSlices(u8, &test_file, &in_file);
}

test "8in Binary file" {
    var test_file = "Mary had a little lamb, it's father was the ram.".*;
    var test_stream = makeStream(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    try disk_image._copyToImage(&test_stream, "MARY.TXT", 0, false);

    // Get it back and compare it to the original
    var in_file: [((test_file.len + 127) / 128) * 128]u8 = undefined;
    var in_stream = makeStream(&in_file);
    const cooked_dir = disk_image.directory.findByFilename("MARY.TXT", null);
    try std.testing.expect(cooked_dir != null);
    try disk_image._copyFromImage(cooked_dir.?, &in_stream, .Binary);
    var compare_buffer: [in_file.len]u8 = undefined;

    // In binary mode the file should be padded with ^Z (0x1A)
    @memcpy(compare_buffer[0..test_file.len], &test_file);
    @memset(compare_buffer[test_file.len..], 0x1A);
    try std.testing.expectEqualSlices(u8, &compare_buffer, &in_file);
}

test "8in Auto detect file type" {
    // TODO: embed a test file with bin and ascii in it and get both.
}

const util = struct {
    pub fn count(itr: FileNameIterator) usize {
        var my_itr = itr;
        var c: usize = 0;
        while (my_itr.next() != null) {
            c += 1;
        }
        return c;
    }
};

test "Multiple filenames across users" {
    const image_file = @embedFile("test_disks/filenames.dsk");
    var disk_image = try newReadOnlyMemoryDiskImage(image_file, FDD_8IN);
    defer disk_image.deinit();

    var out_file: [4096]u8 = undefined;
    var out_stream = makeStream(&out_file);

    // Searching with user should return 1 file.
    var itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", 0);
    try std.testing.expectEqual(1, util.count(itr));
    itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", 1);
    try std.testing.expectEqual(1, util.count(itr));
    itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", 2);
    try std.testing.expectEqual(1, util.count(itr));

    // Searching without user should return 3 files.
    itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", null);
    try std.testing.expectEqual(3, util.count(itr));

    // Make sure get works. TODO: Make sure put works.
    var user: u8 = 0;
    while (user < 3) : (user += 1) {
        try disk_image._copyFromImage(itr.next().?, &out_stream, .Auto);
    }

    // Check normal lookups also work
    try std.testing.expect(disk_image.directory.findByFilename("SOMETHIN.EXT", 0) != null);
    try std.testing.expect(disk_image.directory.findByFilename("SOMETHIN.EXT", 1) != null);
    try std.testing.expect(disk_image.directory.findByFilename("SOMETHIN.EXT", 2) != null);
    try std.testing.expect(disk_image.directory.findByFilename("SOMETHIN.EXT", null) != null);
    // Trailing . should also match.
    try std.testing.expect(disk_image.directory.findByFilename("SOMETHIN.EXT.", null) != null);
}

test "Find filename with wildcards" {
    // Name     Ext   Length Used U At
    // FILE     COM     128B   2K 0 W
    // FILE     TXT     128B   2K 1 W
    // FILENAME COM     128B   2K 0 W
    // FILENAME EXE     128B   2K 1 W
    // FILENAME EXT     128B   2K 1 W
    // FILENAME TXT     128B   2K 2 W
    // SOMETHIN EXT     128B   2K 0 W
    // SOMETHIN EXT     128B   2K 1 W
    // SOMETHIN EXT     128B   2K 2 W

    const image_file = @embedFile("test_disks/filenames.dsk");
    var disk_image = try newReadOnlyMemoryDiskImage(image_file, FDD_8IN);
    defer disk_image.deinit();

    var itr = disk_image.directory.findByFileNameWildcards("F*", null);
    try std.testing.expectEqual(6, util.count(itr));

    itr = disk_image.directory.findByFileNameWildcards("F*.EXT", null);
    try std.testing.expectEqual(1, util.count(itr));

    itr = disk_image.directory.findByFileNameWildcards("*.EXT", null);
    try std.testing.expectEqual(4, util.count(itr));

    itr = disk_image.directory.findByFileNameWildcards("*.E*", null);
    try std.testing.expectEqual(5, util.count(itr));

    itr = disk_image.directory.findByFileNameWildcards("*.EX*", null);
    try std.testing.expectEqual(5, util.count(itr));

    itr = disk_image.directory.findByFileNameWildcards("F?LENAME.EX?", null);
    try std.testing.expectEqual(2, util.count(itr));

    itr = disk_image.directory.findByFileNameWildcards("F*.EX?", null);
    try std.testing.expectEqual(2, util.count(itr));
}

test "Find filenames without extensions" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream = makeStream(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var disk_image = try newFormattedMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    try disk_image._copyToImage(&test_stream, "FILENAME", null, false);
    try disk_image._copyToImage(&test_stream, "X.", null, false);
    try disk_image._copyToImage(&test_stream, ".X", null, false);
    saveImage(&image_file);

    try std.testing.expect(disk_image.directory.findByFilename("FILENAME", null) != null);
    try std.testing.expect(disk_image.directory.findByFilename("FILENAME.", null) != null);

    try std.testing.expect(disk_image.directory.findByFilename("X", null) != null);
    try std.testing.expect(disk_image.directory.findByFilename("X.", null) != null);

    try std.testing.expect(disk_image.directory.findByFilename(".X", null) != null);

    var itr = disk_image.directory.findByFileNameWildcards("F*", null);
    try std.testing.expectEqual(1, util.count(itr));
    itr = disk_image.directory.findByFileNameWildcards("F*.*", null);
    try std.testing.expectEqual(1, util.count(itr));
}

test "erase" {
    const image_file = @embedFile("test_disks/erase_pre.dsk");
    var image_buffer: [image_file.len]u8 = undefined;
    @memcpy(&image_buffer, image_file);

    var disk_image = try newMemoryDiskImage(&image_buffer, FDD_8IN);
    defer disk_image.deinit();

    const to_erase = disk_image.directory.findByFilename("filename.exe", null);
    try std.testing.expect(to_erase != null);
    try disk_image.erase(to_erase.?);

    const erased = disk_image.directory.findByFilename("filename.exe", null);
    try std.testing.expect(erased == null);

    const compare_file = @embedFile("test_disks/erase_post.dsk");
    try std.testing.expectEqualSlices(u8, compare_file, &image_buffer);
}

fn newMemoryDiskImage(buf: []u8, image_type: *const DiskImageType) !DiskImage {
    const stream = std.io.fixedBufferStream(buf);
    var disk_image = try DiskImage._init(std.testing.allocator, .{ .buffer = stream }, image_type);
    errdefer disk_image.deinit();
    try disk_image.loadDirectories(false);
    return disk_image;
}

fn newFormattedMemoryDiskImage(buf: []u8, image_type: *const DiskImageType) !DiskImage {
    const stream = std.io.fixedBufferStream(buf);
    var disk_image = try DiskImage._init(std.testing.allocator, .{ .buffer = stream }, image_type);
    errdefer disk_image.deinit();
    try disk_image.formatImage();
    try disk_image.loadDirectories(false);
    return disk_image;
}

fn newReadOnlyMemoryDiskImage(buf: []const u8, image_type: *const DiskImageType) !DiskImage {
    const stream = std.io.fixedBufferStream(buf);
    var disk_image = try DiskImage._init(std.testing.allocator, .{ .const_buffer = stream }, image_type);
    errdefer disk_image.deinit();
    try disk_image.loadDirectories(false);
    return disk_image;
}

fn makeStream(buf: []u8) std.io.StreamSource {
    const test_buffer = std.io.fixedBufferStream(buf);
    return std.io.StreamSource{ .buffer = test_buffer };
}

fn newPhysicalDiskImage(stream: std.io.FixedBufferStream([]u8), image_type: *const DiskImageType) !DiskImage {
    _ = stream;
    const image_file = try std.fs.cwd().createFile("TEST.IMG", .{ .read = true });
    var disk_image = try DiskImage._init(std.testing.allocator, .{ .file = image_file }, image_type);
    try disk_image.formatImage();
    try disk_image.loadDirectories(false);
    return disk_image;
}

fn saveImage(buf: []const u8) void {
    var file = std.fs.cwd().createFile("TEST_OUT.DSK", .{}) catch {
        return;
    };
    defer file.close();
    file.writeAll(buf) catch {
        return;
    };
}

fn saveFile(buf: []const u8) void {
    var file = std.fs.cwd().createFile("TEST_OUT.BIN", .{}) catch {
        return;
    };
    defer file.close();
    file.writeAll(buf) catch {
        return;
    };
}

// TODO: Invalid images and recovery of images.

const std = @import("std");
const DiskImage = @import("disk_image.zig").DiskImage;
const DiskImageType = @import("disk_types.zig").DiskImageType;
const FileNameIterator = @import("directory_table.zig").FileNameIterator;
const FDD_8IN = @import("disk_types.zig").all_disk_types.getPtrConst(.FDD_8IN);
const HDD_5MB = @import("disk_types.zig").all_disk_types.getPtrConst(.HDD_5MB);
const HDD_5MB_1024 = @import("disk_types.zig").all_disk_types.getPtrConst(.HDD_5MB_1024);
const TAR = @import("disk_types.zig").all_disk_types.getPtrConst(.FDD_TAR);
const FDC = @import("disk_types.zig").all_disk_types.getPtrConst(.@"FDD_1.5MB");
const FDC_8MB = @import("disk_types.zig").all_disk_types.getPtrConst(.FDD_8IN_8MB);
