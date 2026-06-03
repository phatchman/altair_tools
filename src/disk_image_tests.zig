//! Test all disk operations on each image format

// TODO: Add labelling tests
// TODO: Invalid images and recovery of images.

const io = std.testing.io;
const allocator = std.testing.allocator;

test "disk formatted" {
    // std.testing.log_level = .info;
    inline for (all_formats) |fmt| {
        std.log.info("Testing image format {s}", .{fmt.type_name});
        const compare_image = switch (fmt.type_id) {
            .FDD_8IN => @embedFile("test_disks/8in_fmt.dsk"),
            .FDD_8IN_8MB => @embedFile("test_disks/8mb_fmt.dsk"),
            .HDD_5MB => @embedFile("test_disks/5mb_fmt.dsk"),
            .HDD_5MB_1024 => @embedFile("test_disks/5mb_1024_fmt.dsk"),
            .FDD_TAR => @embedFile("test_disks/tar_fmt.dsk"),
            .@"FDD_1.5MB" => @embedFile("test_disks/1.5mb_fmt.dsk"),
            .CDOS_SMSSSD => @embedFile("test_disks/smsssd_fmt.dsk"),
            .CDOS_SMSSDD => @embedFile("test_disks/smssdd_fmt.dsk"),
            .CDOS_SMDSSD => @embedFile("test_disks/smdssd_fmt.dsk"),
            .CDOS_SMDSDD => @embedFile("test_disks/smdsdd_fmt.dsk"),
            .CDOS_LGSSSD => @embedFile("test_disks/lgsssd_fmt.dsk"),
            .CDOS_LGSSDD => @embedFile("test_disks/lgssdd_fmt.dsk"),
            .CDOS_LGDSSD => @embedFile("test_disks/lgdssd_fmt.dsk"),
            .CDOS_LGDSDD => @embedFile("test_disks/lgdsdd_fmt.dsk"),
        };

        const test_buffer: []u8 = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(test_buffer);
        var test_image: InMemoryImage = undefined;
        test_image.init(test_buffer);

        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        try std.testing.expectEqualSlices(u8, compare_image, test_image.buffer);
    }
}

test "8in alt size" {
    var is_unique: bool = undefined;
    var image_file = try std.Io.Dir.cwd().openFile(io, "src/test_disks/8in_fmt_alt.dsk", .{ .mode = .read_only });
    errdefer image_file.close(io);

    const image_type = DiskImage.detectImageType(io, image_file, &is_unique);
    try std.testing.expect(image_type != null); // Image type should be detected as 8IN
    try std.testing.expectEqual(FDD_8IN.type_id, image_type.?.type_id);
    try std.testing.expectEqual(true, is_unique);

    var image_reader = image_file.reader(io, &.{});
    var image_writer = image_file.writer(io, &.{});

    var disk_image = try DiskImage.init(
        std.testing.allocator,
        .{ .on_disk = &image_reader },
        .{ .on_disk = &image_writer },
        FDD_8IN,
    );
    try disk_image.loadDirectories(false);
    disk_image.deinit();
}

test "HDD 5MB formatted" {
    const compare_image = @embedFile("test_disks/5mb_fmt.dsk");
    var test_buffer: [HDD_5MB.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&test_buffer);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, HDD_5MB);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "HDD 5MB 1024 dirs formatted" {
    const compare_image = @embedFile("test_disks/5mb_fmt.dsk");
    var test_buffer: [HDD_5MB_1024.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&test_buffer);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, HDD_5MB_1024);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "Tarbell formatted" {
    const compare_image = @embedFile("test_disks/tar_fmt.dsk");
    var test_buffer: [TAR.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&test_buffer);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, TAR);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "FDC 1.5MB formatted" {
    const compare_image = @embedFile("test_disks/1.5mb_fmt.dsk");
    var test_buffer: [FDC.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&test_buffer);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDC);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

test "FDC 8MB formatted" {
    const compare_image = @embedFile("test_disks/8mb_fmt.dsk");
    var test_buffer: [FDC_8MB.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&test_buffer);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDC_8MB);
    defer disk_image.deinit();
    try std.testing.expectEqualSlices(u8, compare_image, &test_buffer);
}

/// There are some part of the disk are essentially random as they are
/// not explicitely set by the CPM bios and is just whatever happens to be in that part of memory
/// These bytes are leftovers from Altair DOS, so are essentially ignored.
/// These "random" bytes are also included in the checksum!!
/// Which means that we can't even compare the checksums between two images.
fn clearVariableBytes(in: []u8) []u8 {
    for (6..77) |track_nr| {
        for (0..32) |sect_nr| {
            const start_idx: usize = (track_nr * 32 * 137) + sect_nr * 137;
            in[start_idx + 2] = 0xaa; // directory index (unused)
            in[start_idx + 3] = 0xaa; // data bytes count (unused)
            in[start_idx + 4] = 0xaa; // checksum
            in[start_idx + 5] = 0xaa; // data pointer (unused)
            in[start_idx + 6] = 0xaa; // data pointer (unused)
        }
    }
    return in;
}
test "disk filled" {
    //std.testing.log_level = .info;
    // Make a file to fill the disk.
    inline for (all_formats) |fmt| {
        const compare_image: ?[]u8 = switch (fmt.type_id) {
            .FDD_8IN => try allocator.dupe(u8, @embedFile("test_disks/8in_full.dsk")),
            .HDD_5MB => try allocator.dupe(u8, @embedFile("test_disks/5mb_full.dsk")),
            .HDD_5MB_1024 => try allocator.dupe(u8, @embedFile("test_disks/5mb_1024_full.dsk")),
            .CDOS_SMSSSD => try allocator.dupe(u8, @embedFile("test_disks/smsssd_full.dsk")),
            .CDOS_SMSSDD => try allocator.dupe(u8, @embedFile("test_disks/smssdd_full.dsk")),
            .CDOS_SMDSSD => try allocator.dupe(u8, @embedFile("test_disks/smdssd_full.dsk")),
            .CDOS_SMDSDD => try allocator.dupe(u8, @embedFile("test_disks/smdsdd_full.dsk")),
            .CDOS_LGSSSD => try allocator.dupe(u8, @embedFile("test_disks/lgsssd_full.dsk")),
            .CDOS_LGSSDD => try allocator.dupe(u8, @embedFile("test_disks/lgssdd_full.dsk")),
            .CDOS_LGDSSD => try allocator.dupe(u8, @embedFile("test_disks/lgdssd_full.dsk")),
            .CDOS_LGDSDD => try allocator.dupe(u8, @embedFile("test_disks/lgdsdd_full.dsk")),
            else => null,
        };
        defer if (compare_image) |ci| allocator.free(ci);
        std.log.info("Testing: {t} filled {s} compare image", .{ fmt.type_id, if (compare_image == null) "without" else "with" });

        const nr_sectors: usize = fmt.largestFileBytes() / fmt.sector_size_data;
        var big_file = try allocator.alloc(u8, nr_sectors * fmt.sector_size_data);
        defer allocator.free(big_file);

        for (0..nr_sectors) |sector| {
            const fill_char: u8 = ' ' + @as(u8, @intCast(sector % (127 - ' ')));
            const start = sector * fmt.sector_size_data;
            const end = start + fmt.sector_size_data;
            @memset(big_file[start..end], fill_char);
            _ = try std.fmt.bufPrint(big_file[start..end], "\n--[{d}]--", .{sector});
        }
        var big_stream: std.Io.Reader = .fixed(big_file);

        // Create in-memory disk image.
        const test_buffer: []u8 = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(test_buffer);
        var test_image: InMemoryImage = undefined;
        test_image.init(test_buffer);

        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        // Copy to disk to fill it up.
        const filename = "BIG.TXT";
        try disk_image.copyToImage(&big_stream, filename, 0, false);
        try std.testing.expectEqual(0, disk_image.directory.free_allocations.count());
        try std.testing.expectEqual(0, disk_image.capacityFreeInKB());
        try std.testing.expectEqual(1, disk_image.directory.cooked_directories.items.len);
        try std.testing.expectEqualStrings(filename, disk_image.directory.cooked_directories.items[0].filenameAndExtension());
        // Get it back and compare it to the original
        const in_file = try allocator.alloc(u8, big_file.len);
        defer allocator.free(in_file);
        var in_stream: std.Io.Writer = .fixed(in_file);

        // Important to re-init to rebuild the in-memory directory entries from the image.
        try reinitDiskImage(&disk_image);
        const cooked_dir = disk_image.directory.findByFilename(filename, null);
        try std.testing.expect(cooked_dir != null);
        try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Binary);
        try std.testing.expectEqualSlices(u8, big_file, in_file);

        if (compare_image) |ci| {
            switch (fmt.type_id) {
                .FDD_8IN => try std.testing.expectEqualSlices(u8, clearVariableBytes(ci), clearVariableBytes(test_buffer)),
                else => try std.testing.expectEqualSlices(u8, ci, test_buffer),
            }
        }
    }
}

test "disk overfilled" {
    // std.testing.log_level = .info;
    // Make file 1 byte too big. Should result in out of allocs.

    inline for (all_formats) |fmt| {
        std.log.info("Testing: {t} filled", .{fmt.type_id});
        // TODO: FIX
        const big_file = try allocator.alloc(u8, fmt.largestFileBytes() + 1);
        @memset(big_file, 'X');
        defer allocator.free(big_file);
        var big_stream: std.Io.Reader = .fixed(big_file);

        const test_buffer = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(test_buffer);
        var test_image: InMemoryImage = undefined;
        test_image.init(test_buffer);
        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        try std.testing.expectError(
            error.OutOfAllocs,
            disk_image.copyToImage(&big_stream, "BIG.TXT", 0, false),
        );
        try std.testing.expectEqual(1, disk_image.directory.cooked_directories.items.len);

        try reinitDiskImage(&disk_image);
        try std.testing.expectError(error.OutOfAllocs, disk_image.directory.allocationGetFree());
        try std.testing.expect(disk_image.directory.findByFilename("BIG.TXT", null) != null);
    }
}

test "overfill directory" {
    //std.testing.log_level = .info;
    inline for (all_formats) |fmt| {
        std.log.info("Testing format: {t}", .{fmt.type_id});
        const compare_image: ?[]u8 = switch (fmt.type_id) {
            .FDD_8IN => try allocator.dupe(u8, @embedFile("test_disks/8in_dirs.dsk")),
            .HDD_5MB => try allocator.dupe(u8, @embedFile("test_disks/5mb_dirs.dsk")),
            .HDD_5MB_1024 => try allocator.dupe(u8, @embedFile("test_disks/5mb_1024_dirs.dsk")),
            else => null,
        };
        defer if (compare_image) |ci| allocator.free(ci);

        var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
        var test_stream: std.Io.Reader = .fixed(&test_file);

        const image_file = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(image_file);

        var test_image: InMemoryImage = undefined;
        test_image.init(image_file);
        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        var name_buf: [256]u8 = undefined;
        const max_dirs = if (fmt.OS == .cdos) fmt.directories - 1 else fmt.directories;
        for (0..max_dirs) |num| {
            test_stream.seek = 0;
            try disk_image.copyToImage(&test_stream, try std.fmt.bufPrint(&name_buf, "T{d}.TST", .{num}), 0, false);
        }
        test_stream.seek = 0;
        try std.testing.expectError(
            error.OutOfExtents,
            disk_image.copyToImage(&test_stream, try std.fmt.bufPrint(&name_buf, "T{d}.TST", .{fmt.directories}), 0, false),
        );
        if (compare_image) |ci| {
            switch (fmt.type_id) {
                .FDD_8IN => try std.testing.expectEqualSlices(u8, clearVariableBytes(ci), clearVariableBytes(image_file)),
                else => try std.testing.expectEqualSlices(u8, ci, image_file),
            }
        }

        try reinitDiskImage(&disk_image);

        const out_buf = try allocator.alloc(u8, test_file.len);
        defer allocator.free(out_buf);
        var out_file: std.Io.Writer = .fixed(out_buf);
        const cooked_dir = disk_image.directory.findByFilename(try std.fmt.bufPrint(&name_buf, "T{d}.TST", .{max_dirs - 1}), null);
        try std.testing.expect(cooked_dir != null);

        try disk_image.copyFromImage(cooked_dir.?, &out_file, .Auto);
        try std.testing.expectEqualSlices(u8, &test_file, out_buf);
    }
}

test "8in duplicate filenames" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);
    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();

    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false);
    try std.testing.expectError(
        std.Io.File.OpenError.PathAlreadyExists,
        disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false),
    );
    // 2nd time force the overwrite.
    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, true);
}

test "8in duplicate CPM filenames" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();

    try disk_image.copyToImage(&test_stream, "PINBALL2.TXT2", 0, false);
    try std.testing.expectError(
        std.Io.File.OpenError.PathAlreadyExists,
        disk_image.copyToImage(&test_stream, "PINBALL22.TXT", 0, false),
    );
}

test "test force overwrite" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);
    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();

    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false);

    // 2nd time force the overwrite.
    test_file[0] = 'X';
    test_stream.seek = 0;
    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, true);
    var in_file: [test_file.len]u8 = undefined;
    var in_stream: std.Io.Writer = .fixed(&in_file);
    const cooked_dir = disk_image.directory.findByFilename("PINBALL.TXT", null);
    try std.testing.expect(cooked_dir != null);
    try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Text);
    try std.testing.expectEqualSlices(u8, &test_file, &in_file);
}

test "8 in zero-length file" {
    var test_file = "".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();
    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false);

    // Get it back and compare it to the original
    var in_file: [0]u8 = undefined;
    var in_stream: std.Io.Writer = .fixed(&in_file);

    const cooked_dir = disk_image.directory.findByFilename("PINBALL.TXT", null);
    try std.testing.expect(cooked_dir != null);
    // Will throw if it tries to write any bytes to the empty buffer;
    try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Text);
}

test "8in Text file" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();
    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false);

    // Get it back and compare it to the original
    var in_file: [test_file.len]u8 = undefined;
    var in_stream: std.Io.Writer = .fixed(&in_file);

    const cooked_dir = disk_image.directory.findByFilename("PINBALL.TXT", null);
    try std.testing.expect(cooked_dir != null);
    // Will throw if it tries to write any buytes to the empty buffer;
    try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Text);
    try std.testing.expectEqualSlices(u8, &test_file, &in_file);
}

test "8in Binary file" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();

    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false);

    // Get it back and compare it to the original
    var in_file: [((test_file.len + 127) / 128) * 128]u8 = undefined;
    var in_stream: std.Io.Writer = .fixed(&in_file);
    const cooked_dir = disk_image.directory.findByFilename("PINBALL.TXT", null);
    try std.testing.expect(cooked_dir != null);
    try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Binary);
    var compare_buffer: [in_file.len]u8 = undefined;

    // In binary mode the file should be padded with ^Z (0x1A)
    @memcpy(compare_buffer[0..test_file.len], &test_file);
    @memset(compare_buffer[test_file.len..], 0x1A);
    try std.testing.expectEqualSlices(u8, &compare_buffer, &in_file);
}

test "8in Auto detect file type" {
    // TODO: embed a test file with bin and ascii in it and get both.
}

fn countFilenames(itr: FileNameIterator) usize {
    var my_itr = itr;
    var c: usize = 0;
    while (my_itr.next() != null) {
        c += 1;
    }
    return c;
}

test "Multiple filenames across users" {
    var image_file: InMemoryConstImage = undefined;
    try image_file.init(std.testing.allocator, @embedFile("test_disks/filenames.dsk"));
    defer image_file.deinit(std.testing.allocator);

    var disk_image = try newMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    var out_file: [4096]u8 = undefined;
    var out_stream: std.Io.Writer = .fixed(&out_file);

    // Searching with user should return 1 file.
    var itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", 0);
    try std.testing.expectEqual(1, countFilenames(itr));
    itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", 1);
    try std.testing.expectEqual(1, countFilenames(itr));
    itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", 2);
    try std.testing.expectEqual(1, countFilenames(itr));

    // Searching without user should return 3 files.
    itr = disk_image.directory.findByFileNameWildcards("SOMETHIN.EXT", null);
    try std.testing.expectEqual(3, countFilenames(itr));

    // Make sure get works. TODO: Make sure put works.
    var user: u8 = 0;
    while (user < 3) : (user += 1) {
        try disk_image.copyFromImage(itr.next().?, &out_stream, .Auto);
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

    var image_file: InMemoryConstImage = undefined;
    try image_file.init(std.testing.allocator, @embedFile("test_disks/filenames.dsk"));
    defer image_file.deinit(std.testing.allocator);
    var disk_image = try newMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    var itr = disk_image.directory.findByFileNameWildcards("F*", null);
    try std.testing.expectEqual(6, countFilenames(itr));

    itr = disk_image.directory.findByFileNameWildcards("F*.EXT", null);
    try std.testing.expectEqual(1, countFilenames(itr));

    itr = disk_image.directory.findByFileNameWildcards("*.EXT", null);
    try std.testing.expectEqual(4, countFilenames(itr));

    itr = disk_image.directory.findByFileNameWildcards("*.E*", null);
    try std.testing.expectEqual(5, countFilenames(itr));

    itr = disk_image.directory.findByFileNameWildcards("*.EX*", null);
    try std.testing.expectEqual(5, countFilenames(itr));

    itr = disk_image.directory.findByFileNameWildcards("F?LENAME.EX?", null);
    try std.testing.expectEqual(2, countFilenames(itr));

    itr = disk_image.directory.findByFileNameWildcards("F*.EX?", null);
    try std.testing.expectEqual(2, countFilenames(itr));
}

test "Find filenames without extensions" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();

    try disk_image.copyToImage(&test_stream, "FILENAME", null, false);
    try disk_image.copyToImage(&test_stream, "X.", null, false);
    try disk_image.copyToImage(&test_stream, ".X", null, false);

    try std.testing.expect(disk_image.directory.findByFilename("FILENAME", null) != null);
    try std.testing.expect(disk_image.directory.findByFilename("FILENAME.", null) != null);

    try std.testing.expect(disk_image.directory.findByFilename("X", null) != null);
    try std.testing.expect(disk_image.directory.findByFilename("X.", null) != null);

    try std.testing.expect(disk_image.directory.findByFilename(".X", null) != null);

    var itr = disk_image.directory.findByFileNameWildcards("F*", null);
    try std.testing.expectEqual(1, countFilenames(itr));
    itr = disk_image.directory.findByFileNameWildcards("F*.*", null);
    try std.testing.expectEqual(1, countFilenames(itr));
}

test "erase" {
    var image_file: InMemoryConstImage = undefined;
    try image_file.init(std.testing.allocator, @embedFile("test_disks/erase_pre.dsk"));
    defer image_file.deinit(std.testing.allocator);

    var disk_image = try newMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    const to_erase = disk_image.directory.findByFilename("filename.exe", null);
    try std.testing.expect(to_erase != null);
    try disk_image.erase(to_erase.?);

    const erased = disk_image.directory.findByFilename("filename.exe", null);
    try std.testing.expect(erased == null);

    const compare_file = @embedFile("test_disks/erase_post.dsk");
    try std.testing.expectEqualSlices(u8, compare_file, image_file.buffer);
}

// Test no corruption when raw directory entries are not contiguous
test "non-contiguous extent" {
    var compare_image: InMemoryConstImage = undefined;
    try compare_image.init(std.testing.allocator, @embedFile("test_disks/non_contiguous.dsk"));
    defer compare_image.deinit(std.testing.allocator);

    const expected = @embedFile("test_disks/32k.txt");

    var file_buffer: [expected.len]u8 = undefined;
    var out_stream: std.Io.Writer = .fixed(&file_buffer);

    var disk_image = try newMemoryDiskImage(&compare_image, FDD_8IN);
    defer disk_image.deinit();

    const entry = disk_image.directory.findByFilename("32k.txt", null) orelse return error.InvalidFilename;

    try disk_image.copyFromImage(entry, &out_stream, .Binary);
    try std.testing.expectEqualSlices(u8, expected, &file_buffer);
}

/// Create readers and writers against a []const u8
/// deinit() must be called to free allocated buffer
const InMemoryConstImage = struct {
    buffer: []u8,
    reader: std.Io.Reader,
    writer: std.Io.Writer,

    pub fn init(self: *InMemoryConstImage, gpa: std.mem.Allocator, buffer: []const u8) error{OutOfMemory}!void {
        self.buffer = try gpa.alloc(u8, buffer.len);
        @memcpy(self.buffer, buffer);
        self.reader = .fixed(self.buffer);
        self.writer = .fixed(self.buffer);
    }

    pub fn deinit(self: *InMemoryConstImage, gpa: std.mem.Allocator) void {
        gpa.free(self.buffer);
        self.* = undefined;
    }
};

/// Create readers and writers against a var []u8.
const InMemoryImage = struct {
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    buffer: []u8,

    pub fn init(self: *InMemoryImage, buffer: []u8) void {
        self.reader = .fixed(buffer);
        self.writer = .fixed(buffer);
        self.buffer = buffer;
    }
};

fn newMemoryDiskImage(raw_image: *InMemoryConstImage, image_type: *const DiskImageType) !DiskImage {
    var disk_image = try DiskImage.init(std.testing.allocator, .{ .in_memory = &raw_image.reader }, .{ .in_memory = &raw_image.writer }, image_type);
    errdefer disk_image.deinit();
    try disk_image.loadDirectories(false);
    return disk_image;
}

fn newFormattedMemoryDiskImage(raw_image: *InMemoryImage, image_type: *const DiskImageType) !DiskImage {
    // TODO: Always use these init fns or remove them.
    var disk_image = try DiskImage.init(std.testing.allocator, .{ .in_memory = &raw_image.reader }, .{ .in_memory = &raw_image.writer }, image_type);
    errdefer disk_image.deinit();
    try disk_image.formatImage();
    try disk_image.loadDirectories(false);
    switch (image_type.OS) {
        .cpm => {},
        .cdos => {
            var label: DiskLabel = .{ .cdos = undefined };
            @memcpy(&label.cdos.user_label, "ABCDEFGH");
            label.cdos.date_mmddyy[0] = 12;
            label.cdos.date_mmddyy[1] = 12;
            label.cdos.date_mmddyy[2] = 12;
            try disk_image.labelDisk(label);
        },
    }
    return disk_image;
}

pub fn reinitDiskImage(image: *DiskImage) !void {
    const reader = image.reader;
    const writer = image.writer;
    try reader.seekTo(0);
    try writer.seekTo(0);
    try image.reinit(std.testing.allocator, reader, writer);
    try image.loadDirectories(false);
}

/// Caller should pass in pointers to an uninitialized reader and writer.
fn newPhysicalDiskImage(reader: *std.Io.File.Reader, writer: *std.Io.File.Writer, image_type: *const DiskImageType) !DiskImage {
    const image_file = try std.Io.Dir.cwd().createFile(std.testing.io, "TEST.IMG", .{ .read = true });
    reader.* = image_file.reader(std.testing.io, &.{});
    writer.* = image_file.writer(std.testing.io, &.{});
    var disk_image = try DiskImage.init(std.testing.allocator, .{ .on_disk = reader }, .{ .on_disk = writer }, image_type);
    try disk_image.formatImage();
    try disk_image.loadDirectories(false);
    return disk_image;
}

fn saveImage(contents: []const u8) void {
    var file = std.Io.Dir.cwd().createFile(std.testing.io, "TEST_OUT.DSK", .{}) catch {
        return;
    };
    defer file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    defer writer.flush() catch {};
    writer.interface.writeAll(contents) catch {
        return;
    };
}

fn saveFile(contents: []const u8) void {
    var file = std.Io.Dir.cwd().createFile(std.testing.io, "TEST_OUT.BIN", .{}) catch {
        return;
    };
    defer file.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buf);
    writer.interface.writeAll(contents) catch {
        return;
    };
}

const std = @import("std");
const DiskImage = @import("disk_image.zig").DiskImage;
const DiskImageType = @import("disk_types.zig").DiskImageType;
const DiskImageTypes = @import("disk_types.zig").DiskImageTypes;
const DiskLabel = @import("disk_image.zig").DiskLabel;
const FileNameIterator = @import("directory_table.zig").FileNameIterator;
const all_disk_types = @import("disk_types.zig").all_disk_types;
const FDD_8IN = all_disk_types.getPtrConst(.FDD_8IN);
const HDD_5MB = all_disk_types.getPtrConst(.HDD_5MB);
const HDD_5MB_1024 = all_disk_types.getPtrConst(.HDD_5MB_1024);
const TAR = all_disk_types.getPtrConst(.FDD_TAR);
const FDC = all_disk_types.getPtrConst(.@"FDD_1.5MB");
const FDC_8MB = all_disk_types.getPtrConst(.FDD_8IN_8MB);
const CDOS_SMSSSD = all_disk_types.getPtrConst(.CDOS_SMSSSD);
const CDOS_SMSSDD = all_disk_types.getPtrConst(.CDOS_SMSSDD);
const CDOS_SMDSSD = all_disk_types.getPtrConst(.CDOS_SMDSSD);
const CDOS_SMDSDD = all_disk_types.getPtrConst(.CDOS_SMDSDD);
const CDOS_LGSSSD = all_disk_types.getPtrConst(.CDOS_LGSSSD);
const CDOS_LGSSDD = all_disk_types.getPtrConst(.CDOS_LGSSDD);
const CDOS_LGDSSD = all_disk_types.getPtrConst(.CDOS_LGDSSD);
const CDOS_LGDSDD = all_disk_types.getPtrConst(.CDOS_LGDSDD);
// Can be set to a limited set of formats when wanting to test a subset.
//const all_formats = .{ FDD_8IN, HDD_5MB, HDD_5MB_1024, TAR, FDC, FDC_8MB, CDOS_SMSSSD, CDOS_LGSSSD, CDOS_LGSSDD };
//const all_formats = .{ FDD_8IN, HDD_5MB, HDD_5MB_1024, TAR, FDC, FDC_8MB, CDOS_SMSSSD, CDOS_LGSSSD };
//const all_formats = .{ FDD_8IN, HDD_5MB };
//const all_formats = .{FDD_8IN};
//const all_formats = .{CDOS_SMDSDD};
const all_formats = _: {
    const fields = std.meta.fields(DiskImageTypes);
    var result: [fields.len]*const DiskImageType = undefined;
    var idx: usize = 0;
    for (fields) |field| {
        result[idx] = all_disk_types.getPtrConst(@field(DiskImageTypes, field.name));
        idx += 1;
    }
    const result_c = result;
    break :_ &result_c;
};

test {
    std.testing.refAllDecls(@This());
}
