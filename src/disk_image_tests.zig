//! Tests most disk operations on each image format

// FUTURE TODO: Invalid images and recovery of images.
// FUTURE TODO: Filled random access.

const io = std.testing.io;
const allocator = std.testing.allocator;

test "disk formatted" {
    //std.testing.log_level = .info;
    inline for (all_formats) |fmt| {
        std.log.info("Testing image format {s}", .{fmt.type_name});
        const compare_image: []u8 = switch (fmt.type_id) {
            .FDD_8IN => try allocator.dupe(u8, @embedFile("test_disks/8in_fmt.dsk")),
            .FDD_8IN_8MB => try allocator.dupe(u8, @embedFile("test_disks/8mb_fmt.dsk")),
            .HDD_5MB => try allocator.dupe(u8, @embedFile("test_disks/5mb_fmt.dsk")),
            .HDD_5MB_1024 => try allocator.dupe(u8, @embedFile("test_disks/5mb_1024_fmt.dsk")),
            .FDD_TAR => try allocator.dupe(u8, @embedFile("test_disks/tar_fmt.dsk")),
            .@"FDD_1.5MB" => try allocator.dupe(u8, @embedFile("test_disks/1.5mb_fmt.dsk")),
            .CDOS_SMSSSD => try allocator.dupe(u8, @embedFile("test_disks/smsssd_fmt.dsk")),
            .CDOS_SMSSDD => try allocator.dupe(u8, @embedFile("test_disks/smssdd_fmt.dsk")),
            .CDOS_SMDSSD => try allocator.dupe(u8, @embedFile("test_disks/smdssd_fmt.dsk")),
            .CDOS_SMDSDD => try allocator.dupe(u8, @embedFile("test_disks/smdsdd_fmt.dsk")),
            .CDOS_LGSSSD => try allocator.dupe(u8, @embedFile("test_disks/lgsssd_fmt.dsk")),
            .CDOS_LGSSDD => try allocator.dupe(u8, @embedFile("test_disks/lgssdd_fmt.dsk")),
            .CDOS_LGDSSD => try allocator.dupe(u8, @embedFile("test_disks/lgdssd_fmt.dsk")),
            .CDOS_LGDSDD => try allocator.dupe(u8, @embedFile("test_disks/lgdsdd_fmt.dsk")),
            .ADOS_8IN => try allocator.dupe(u8, @embedFile("test_disks/ados_basic_fmt.dsk")),
            .ADOS_MINI => try allocator.dupe(u8, @embedFile("test_disks/ados_mini_fmt.dsk")),
            .ADOS_MINI_BOOT => try allocator.dupe(u8, @embedFile("test_disks/ados_miniboot_fmt.dsk")),
            .CPM_MINI => try allocator.dupe(u8, @embedFile("test_disks/cpm_mini_fmt.dsk")),
            .HD_BASIC => try allocator.dupe(u8, @embedFile("test_disks/hdbasic_fmt.dsk")),
            .TIMESHARE_BASIC => continue,
        };
        defer allocator.free(compare_image);

        const test_buffer: []u8 = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(test_buffer);
        var test_image: InMemoryImage = undefined;
        test_image.init(test_buffer);

        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        switch (fmt.type_id) {
            .CPM_MINI => try std.testing.expectEqualSlices(u8, clearVariableBytes(compare_image, fmt), clearVariableBytes(test_image.buffer, fmt)),
            else => try std.testing.expectEqualSlices(u8, compare_image, test_image.buffer),
        }
    }
}

test "8in alt size" {
    var is_unique: bool = undefined;
    var image_file = try std.Io.Dir.cwd().openFile(io, "src/test_disks/8in_fmt_alt.dsk", .{ .mode = .read_only });
    defer image_file.close(io);

    const image_type = DiskImage.detectImageType(io, image_file, &is_unique);
    try std.testing.expect(image_type != null); // Image type should be detected as 8IN
    try std.testing.expectEqual(FDD_8IN.type_id, image_type.?.type_id);
    try std.testing.expectEqual(true, is_unique);

    var image_reader = image_file.reader(io, &.{});
    var image_writer = image_file.writer(io, &.{});

    var disk_image = try DiskImage.init(
        allocator,
        .{ .on_disk = &image_reader },
        .{ .on_disk = &image_writer },
        FDD_8IN,
    );
    defer disk_image.deinit();
    try disk_image.loadDirectories(.full);
}

/// There are some part of the disk which are essentially random as they are
/// not explicitely set by the CPM BIOS and are just whatever happens to be in that part of memory
/// These bytes are leftovers from Altair DOS, so are essentially ignored.
/// These "random" bytes are also included in the checksum!!
/// Which means that we can't even compare the checksums between two images.
fn clearVariableBytes(in: []u8, image_type: *const DiskImageType) []u8 {
    if (image_type.type_id == .CPM_MINI) {
        // For some reason CPM mini formats with a 0xFF in the first data byte of the last track
        // probably a bug and we're not going to replicate that
        in[0x12324] = 0xbb;
        in[0x12327] = 0xbb;
    } else if (image_type.OS == .ados) {
        // Clear nbytes and checksum on directory track 70 as nbytes has no meaning there and
        // seems "random"
        for (0..image_type.sectors_per_track) |sect_nr| {
            const start_idx: usize = (image_type.OS.ados.directory_track * @as(usize, image_type.track_size)) + sect_nr * image_type.sector_size_raw;
            in[start_idx + 3] = 0xbb; // data bytes count (unused)
            in[start_idx + 4] = 0xbb; // checksum
        }
    } else if (image_type.OS == .cpm) {
        const start = if (image_type.type_id == .FDD_8IN) 6 else image_type.reserved_tracks;
        for (start..image_type.tracks) |track_nr| {
            for (0..image_type.sectors_per_track) |sect_nr| {
                const start_idx: usize = (track_nr * image_type.track_size) + sect_nr * image_type.sector_size_raw;
                in[start_idx + 2] = 0xbb; // directory index (unused)
                in[start_idx + 3] = 0xbb; // data bytes count (unused)
                in[start_idx + 4] = 0xbb; // checksum
                in[start_idx + 5] = 0xbb; // data pointer (unused)
                in[start_idx + 6] = 0xbb; // data pointer (unused)
            }
        }
    }
    return in;
}
test "disk filled" {
    // std.testing.log_level = .info;
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
            .ADOS_8IN => try allocator.dupe(u8, @embedFile("test_disks/ados_basic_full.dsk")),
            .ADOS_MINI => try allocator.dupe(u8, @embedFile("test_disks/ados_mini_full.dsk")),
            .ADOS_MINI_BOOT => try allocator.dupe(u8, @embedFile("test_disks/ados_miniboot_full.dsk")),
            .CPM_MINI => try allocator.dupe(u8, @embedFile("test_disks/cpm_mini_full.dsk")),
            .HD_BASIC => try allocator.dupe(u8, @embedFile("test_disks/hdbasic_full.dsk")),
            .TIMESHARE_BASIC => continue,
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
        try disk_image.copyToImage(&big_stream, filename, 0, false, .Auto);
        try std.testing.expectEqual(0, disk_image.directory.free_allocations.count());
        try std.testing.expectEqual(0, disk_image.capacityFreeInKB());
        try std.testing.expectEqual(1, disk_image.directory.cooked_directories.items.len);
        try std.testing.expectEqual(0, disk_image.directory.free_allocations.count());
        try std.testing.expectEqualStrings(filename, disk_image.directory.cooked_directories.items[0].filenameAndExtension());
        // Get it back and compare it to the original
        const in_file = try allocator.alloc(u8, big_file.len);
        defer allocator.free(in_file);
        var in_stream: std.Io.Writer = .fixed(in_file);

        // TODO: We should od the same tests before and after the reinit. to make sure both in memory and on-disk are in sync
        // Important to re-init to rebuild the in-memory directory entries from the image.
        try reinitDiskImage(&disk_image);
        try std.testing.expectEqual(fmt, disk_image.image_type);

        try std.testing.expectEqual(0, disk_image.directory.free_allocations.count());
        try std.testing.expectEqual(0, disk_image.capacityFreeInKB());
        try std.testing.expectEqual(1, disk_image.directory.cooked_directories.items.len);
        try std.testing.expectEqual(0, disk_image.directory.free_allocations.count());

        const cooked_dir = disk_image.directory.findByFilename(filename, null);
        try std.testing.expect(cooked_dir != null);
        try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Auto);
        try std.testing.expectEqualSlices(u8, big_file, in_file);

        if (compare_image) |ci| {
            switch (fmt.type_id) {
                .FDD_8IN,
                .ADOS_8IN,
                .ADOS_MINI,
                .ADOS_MINI_BOOT,
                => try std.testing.expectEqualSlices(u8, clearVariableBytes(ci, fmt), clearVariableBytes(test_buffer, fmt)),
                else => try std.testing.expectEqualSlices(u8, ci, test_buffer),
            }
        }
    }
}

test "disk overfilled" {
    //std.testing.log_level = .info;
    // Make file 1 byte too big. Should result in out of allocs.

    inline for (all_formats) |fmt| {
        if (fmt.type_id == .TIMESHARE_BASIC) continue;
        std.log.info("Testing: {t} overfilled", .{fmt.type_id});
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
            disk_image.copyToImage(&big_stream, "BIG.TXT", 0, false, .Auto),
        );
        try std.testing.expectEqual(1, disk_image.directory.cooked_directories.items.len);

        try reinitDiskImage(&disk_image);
        try std.testing.expectError(error.OutOfAllocs, allocationGetFree(&disk_image.directory));
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
            .CDOS_SMSSSD => try allocator.dupe(u8, @embedFile("test_disks/smsssd_dirs.dsk")),
            .CDOS_LGDSDD => try allocator.dupe(u8, @embedFile("test_disks/lgdsdd_dirs.dsk")),
            // TODO: Basic allocates sectors and tracks for files differently to how it does it within files.
            // Need to sus out what exactly is being done differently.
            //.ADOS_8IN => try allocator.dupe(u8, @embedFile("test_disks/ados_basic_dirs.dsk")),
            .TIMESHARE_BASIC => continue,
            else => null,
        };
        defer if (compare_image) |ci| allocator.free(ci);

        // Need to create 0 length files for ados mini, otherwise run out of space before running out of dirs.
        const test_file = switch (fmt.type_id) {
            .ADOS_MINI, .ADOS_MINI_BOOT => "",
            else => "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall",
        };
        var test_stream: std.Io.Reader = .fixed(test_file);

        const image_file = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(image_file);

        var test_image: InMemoryImage = undefined;
        test_image.init(image_file);
        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        var name_buf: [256]u8 = undefined;
        const max_dirs = switch (fmt.OS) {
            .cdos => fmt.directories - 1,
            .hd_basic => fmt.directories - 2,
            .cpm, .ados => fmt.directories,
        };
        for (0..max_dirs) |num| {
            test_stream.seek = 0;
            try disk_image.copyToImage(&test_stream, try std.fmt.bufPrint(&name_buf, "T{d}.TST", .{num}), 0, false, .Auto);
        }
        test_stream.seek = 0;
        try std.testing.expectError(
            error.OutOfExtents,
            disk_image.copyToImage(&test_stream, try std.fmt.bufPrint(&name_buf, "T{d}.TST", .{fmt.directories}), 0, false, .Auto),
        );

        if (compare_image) |ci| {
            switch (fmt.type_id) {
                .FDD_8IN, .ADOS_8IN => try std.testing.expectEqualSlices(u8, clearVariableBytes(ci, fmt), clearVariableBytes(image_file, fmt)),
                else => try std.testing.expectEqualSlices(u8, ci, image_file),
            }
        }
        // test the before and after reinit free count.
        try std.testing.expectEqual(0, disk_image.directory.rawEntryFreeCount());
        try reinitDiskImage(&disk_image);

        const out_buf = try allocator.alloc(u8, test_file.len);
        defer allocator.free(out_buf);
        var out_file: std.Io.Writer = .fixed(out_buf);
        const cooked_dir = disk_image.directory.findByFilename(try std.fmt.bufPrint(&name_buf, "T{d}.TST", .{max_dirs - 1}), null);
        try std.testing.expect(cooked_dir != null);
        try std.testing.expectEqual(0, disk_image.directory.rawEntryFreeCount());
        try disk_image.copyFromImage(cooked_dir.?, &out_file, .Auto);
        try std.testing.expectEqualSlices(u8, test_file, out_buf);
    }
}

test "duplicate filenames" {
    for (all_formats) |fmt| {
        if (fmt.type_id == .TIMESHARE_BASIC) continue;
        var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
        var test_stream: std.Io.Reader = .fixed(&test_file);

        const image_file = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(image_file);
        var test_image: InMemoryImage = undefined;
        test_image.init(image_file);
        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false, .Auto);
        try std.testing.expectError(
            std.Io.File.OpenError.PathAlreadyExists,
            disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false, .Auto),
        );
        // 2nd time force the overwrite.
        try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, true, .Auto);
    }
}

test "8in duplicate CPM filenames" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();

    try disk_image.copyToImage(&test_stream, "PINBALL2.TXT2", 0, false, .Auto);
    try std.testing.expectError(
        std.Io.File.OpenError.PathAlreadyExists,
        disk_image.copyToImage(&test_stream, "PINBALL22.TXT", 0, false, .Auto),
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

    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false, .Auto);

    // 2nd time force the overwrite.
    test_file[0] = 'X';
    test_stream.seek = 0;
    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, true, .Auto);
    var in_file: [test_file.len]u8 = undefined;
    var in_stream: std.Io.Writer = .fixed(&in_file);
    const cooked_dir = disk_image.directory.findByFilename("PINBALL.TXT", null);
    try std.testing.expect(cooked_dir != null);
    try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Text);
    try std.testing.expectEqualSlices(u8, &test_file, &in_file);
}

test "zero-length file" {
    //std.testing.log_level = .info;
    inline for (all_formats) |fmt| {
        if (fmt.type_id == .TIMESHARE_BASIC) continue;
        std.log.info("Testing format: {t}", .{fmt.type_id});
        var test_file = "".*;
        var test_stream: std.Io.Reader = .fixed(&test_file);

        const image_file = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(image_file);
        var test_image: InMemoryImage = undefined;
        test_image.init(image_file);

        var disk_image = try newFormattedMemoryDiskImage(&test_image, fmt);
        defer disk_image.deinit();

        try disk_image.copyToImage(&test_stream, "PINBALL", 0, false, .Auto);

        // Get it back and compare it to the original
        var in_file: [0]u8 = undefined;
        var in_stream: std.Io.Writer = .fixed(&in_file);

        var cooked_dir = disk_image.directory.findByFilename("PINBALL", null);
        try std.testing.expect(cooked_dir != null);
        try std.testing.expectEqual(0, cooked_dir.?.size_in_bytes);
        try std.testing.expectEqual(0, cooked_dir.?.used_in_kbytes);
        // Will throw if it tries to write any bytes to the empty buffer;
        try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Auto);

        try reinitDiskImage(&disk_image);
        cooked_dir = disk_image.directory.findByFilename("PINBALL", null);
        try std.testing.expect(cooked_dir != null);
        try std.testing.expectEqual(0, cooked_dir.?.size_in_bytes);
        try std.testing.expectEqual(0, cooked_dir.?.used_in_kbytes);
        // Will throw if it tries to write any bytes to the empty buffer;
        try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Auto);
    }
}

test "8in Text file" {
    var test_file = "Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall".*;
    var test_stream: std.Io.Reader = .fixed(&test_file);

    var image_file: [FDD_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);

    var disk_image = try newFormattedMemoryDiskImage(&test_image, FDD_8IN);
    defer disk_image.deinit();
    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false, .Auto);

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

    try disk_image.copyToImage(&test_stream, "PINBALL.TXT", 0, false, .Auto);

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

test "Altair DOS random access file" {
    var test_file: [5 * 1024 - 256]u8 = @splat(0x55);
    var test_stream: std.Io.Reader = .fixed(&test_file);
    var test_stream2: std.Io.Reader = .fixed(test_file[0..128]);

    var image_file: [ADOS_8IN.image_size]u8 = undefined;
    var test_image: InMemoryImage = undefined;
    test_image.init(&image_file);
    var disk_image = try newFormattedMemoryDiskImage(&test_image, ADOS_8IN);
    defer disk_image.deinit();

    try disk_image.copyToImage(&test_stream, "RAND", null, false, .Rand);
    try disk_image.copyToImage(&test_stream2, "RAND2", null, false, .Rand);

    var in_file: [test_file.len]u8 = undefined;
    var in_stream: std.Io.Writer = .fixed(&in_file);
    var cooked_dir = disk_image.directory.findByFilename("RAND", null);
    try std.testing.expect(cooked_dir != null);
    try disk_image.copyFromImage(cooked_dir.?, &in_stream, .Rand);
    try std.testing.expectEqualSlices(u8, &test_file, &in_file);

    var in_file2: [1024 - 256]u8 = undefined;
    var in_stream2: std.Io.Writer = .fixed(&in_file2);

    cooked_dir = disk_image.directory.findByFilename("RAND2", null);
    try std.testing.expect(cooked_dir != null);
    try disk_image.copyFromImage(cooked_dir.?, &in_stream2, .Rand);

    try std.testing.expectEqualSlices(u8, test_file[0..128], in_file2[0..128]);
    try std.testing.expect(std.mem.allEqual(u8, in_file2[128..], 0));

    const free_allocs = disk_image.directory.free_allocations.count();
    const used_dirs = disk_image.directory.cooked_directories.items.len;

    try disk_image.erase(cooked_dir.?);
    try std.testing.expect(free_allocs < disk_image.directory.free_allocations.count());
    try std.testing.expect(used_dirs > disk_image.directory.cooked_directories.items.len);
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
    try image_file.init(allocator, @embedFile("test_disks/filenames.dsk"));
    defer image_file.deinit(allocator);

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
    try image_file.init(allocator, @embedFile("test_disks/filenames.dsk"));
    defer image_file.deinit(allocator);
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

    try disk_image.copyToImage(&test_stream, "FILENAME", null, false, .Auto);
    try disk_image.copyToImage(&test_stream, "X.", null, false, .Auto);
    try disk_image.copyToImage(&test_stream, ".X", null, false, .Auto);

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
    try image_file.init(allocator, @embedFile("test_disks/erase_pre.dsk"));
    defer image_file.deinit(allocator);

    var disk_image = try newMemoryDiskImage(&image_file, FDD_8IN);
    defer disk_image.deinit();

    const initial_free_count = disk_image.directory.rawEntryFreeCount();
    const initial_free_allocs = disk_image.directory.free_allocations.count();

    const to_erase = disk_image.directory.findByFilename("file.txt", null);
    try std.testing.expect(to_erase != null);
    try disk_image.erase(to_erase.?);
    const erased = disk_image.directory.findByFilename("file.txt", null);
    try std.testing.expect(erased == null);

    try std.testing.expectEqual(initial_free_count + 1, disk_image.directory.rawEntryFreeCount());
    try std.testing.expect(initial_free_allocs < disk_image.directory.free_allocations.count());

    // Make sure it is really erased
    try reinitDiskImage(&disk_image);
    try std.testing.expectEqual(initial_free_count + 1, disk_image.directory.rawEntryFreeCount());
    try std.testing.expectEqual(null, disk_image.directory.findByFilename("file.txt", null));

    const compare_file = @embedFile("test_disks/erase_post.dsk");
    try std.testing.expectEqualSlices(u8, compare_file, image_file.buffer);
}

test "disk erase" {
    //std.testing.log_level = .info;
    inline for (all_formats) |fmt| {
        if (fmt.type_id == .TIMESHARE_BASIC) continue;
        std.log.info("disk erase for {t}\n", .{fmt.type_id});
        const image_buf = try allocator.alloc(u8, fmt.image_size);
        defer allocator.free(image_buf);

        var image_file: InMemoryImage = undefined;
        image_file.init(image_buf);

        var disk_image = try newFormattedMemoryDiskImage(&image_file, fmt);
        defer disk_image.deinit();

        const in_file: [129]u8 = @splat('T');
        var in_reader: std.Io.Reader = .fixed(&in_file);

        try disk_image.copyToImage(&in_reader, "fil0.txt", null, false, .Auto);
        in_reader.seek = 0;
        try disk_image.copyToImage(&in_reader, "fil1.txt", null, false, .Auto);
        in_reader.seek = 0;
        try disk_image.copyToImage(&in_reader, "fil2.txt", null, false, .Auto);

        const initial_free_count = disk_image.directory.rawEntryFreeCount();
        const initial_free_allocs = disk_image.directory.free_allocations.count();

        const to_erase = disk_image.directory.findByFilename("fil1.txt", null);
        try std.testing.expect(to_erase != null);
        try disk_image.erase(to_erase.?);
        const erased = disk_image.directory.findByFilename("fil1.txt", null);
        try std.testing.expect(erased == null);

        try std.testing.expect(disk_image.directory.findByFilename("fil0.txt", null) != null);
        try std.testing.expect(disk_image.directory.findByFilename("fil2.txt", null) != null);

        try std.testing.expectEqual(initial_free_count + 1, disk_image.directory.rawEntryFreeCount());
        try std.testing.expect(initial_free_allocs < disk_image.directory.free_allocations.count());

        // Make sure it is really erased
        try reinitDiskImage(&disk_image);
        try std.testing.expectEqual(null, disk_image.directory.findByFilename("fil1.txt", null));

        try std.testing.expect(disk_image.directory.findByFilename("fil0.txt", null) != null);
        try std.testing.expect(disk_image.directory.findByFilename("fil2.txt", null) != null);

        try std.testing.expectEqual(initial_free_count + 1, disk_image.directory.rawEntryFreeCount());
        try std.testing.expect(initial_free_allocs < disk_image.directory.free_allocations.count());
    }
}

test "erase large file" {
    var large_buf: [1024 * 66]u8 = @splat(0x55);
    var large_reader: std.Io.Reader = .fixed(&large_buf);

    var image_buf: [HD_BASIC.image_size]u8 = undefined;
    var image_file: InMemoryImage = undefined;
    image_file.init(&image_buf);

    var disk_image = try newFormattedMemoryDiskImage(&image_file, HD_BASIC);
    defer disk_image.deinit();

    const init_free = disk_image.capacityFreeInKB();
    try disk_image.copyToImage(&large_reader, "TEST", null, false, .Auto);
    try std.testing.expect(disk_image.capacityFreeInKB() < init_free);
    const cooked = disk_image.directory.findByFilename("TEST", null);
    try std.testing.expect(cooked != null);
    try disk_image.erase(cooked.?);
    try std.testing.expectEqual(init_free, disk_image.capacityFreeInKB());
}

// Test no corruption when raw directory entries are not contiguous
test "non-contiguous extent" {
    var compare_image: InMemoryConstImage = undefined;
    try compare_image.init(allocator, @embedFile("test_disks/non_contiguous.dsk"));
    defer compare_image.deinit(allocator);

    const expected = @embedFile("test_disks/32k.txt");

    var file_buffer: [expected.len]u8 = undefined;
    var out_stream: std.Io.Writer = .fixed(&file_buffer);

    var disk_image = try newMemoryDiskImage(&compare_image, FDD_8IN);
    defer disk_image.deinit();

    const entry = disk_image.directory.findByFilename("32k.txt", null) orelse return error.InvalidFilename;

    try disk_image.copyFromImage(entry, &out_stream, .Binary);
    try std.testing.expectEqualSlices(u8, expected, &file_buffer);
}

test "autodetect image" {
    //    std.testing.log_level = .info;
    inline for (all_formats) |fmt| {
        std.log.info("Testing autodect for: {s}", .{fmt.type_name});
        const filename = switch (fmt.type_id) {
            .FDD_8IN => "src/test_disks/8in_fmt.dsk",
            .FDD_8IN_8MB => "src/test_disks/8mb_fmt.dsk",
            .HDD_5MB => "src/test_disks/5mb_fmt.dsk",
            .HDD_5MB_1024 => "src/test_disks/5mb_1024_fmt.dsk",
            .FDD_TAR => "src/test_disks/tar_fmt.dsk",
            .@"FDD_1.5MB" => "src/test_disks/1.5mb_fmt.dsk",
            .CDOS_SMSSSD => "src/test_disks/smsssd_fmt.dsk",
            .CDOS_SMSSDD => "src/test_disks/smssdd_fmt.dsk",
            .CDOS_SMDSSD => "src/test_disks/smdssd_fmt.dsk",
            .CDOS_SMDSDD => "src/test_disks/smdsdd_fmt.dsk",
            .CDOS_LGSSSD => "src/test_disks/lgsssd_fmt.dsk",
            .CDOS_LGSSDD => "src/test_disks/lgssdd_fmt.dsk",
            .CDOS_LGDSSD => "src/test_disks/lgdssd_fmt.dsk",
            .CDOS_LGDSDD => "src/test_disks/lgdsdd_fmt.dsk",
            .ADOS_8IN => "src/test_disks/ados_basic_fmt.dsk",
            .ADOS_MINI => "src/test_disks/ados_mini_fmt.dsk",
            .ADOS_MINI_BOOT => "src/test_disks/ados_miniboot_fmt.dsk",
            .CPM_MINI => "src/test_disks/cpm_mini_fmt.dsk",
            .HD_BASIC => "src/test_disks/hdbasic_fmt.dsk",
            .TIMESHARE_BASIC => continue,
        };
        const image_file = try std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only });
        var is_unique: bool = false;
        const image_type = DiskImage.detectImageType(io, image_file, &is_unique);
        std.log.info("Detected image type {?s}", .{if (image_type) |it| it.type_name else null});
        if (fmt.type_id == .HDD_5MB or fmt.type_id == .HDD_5MB_1024) {
            try std.testing.expectEqual(false, is_unique);
            try std.testing.expectEqual(.HDD_5MB, if (image_type) |it| it.type_id else null);
        } else {
            try std.testing.expectEqual(true, is_unique);
            try std.testing.expectEqual(fmt.type_id, if (image_type) |it| it.type_id else null);
        }
    }
}

test "non-standard CDOS" {
    //    std.testing.log_level = .info;
    var test_image: InMemoryConstImage = undefined;
    try test_image.init(allocator, @embedFile("test_disks/lgdsdd_64dirs.dsk"));
    defer test_image.deinit(allocator);

    const disk_image = newMemoryDiskImage(&test_image, CDOS_LGDSDD);
    try std.testing.expectError(error.InvalidImageFile, disk_image);
}

test "fuzz image FDD_8IN" {
    try std.testing.fuzz(FDD_8IN, randomData, .{});
    // To recreate a crash. Embed the crash file and use:
    //    try std.testing.fuzz({}, randomData, .{ .corpus = &.{crash} });
}

// Only test a few representative images by default
// test "fuzz image HDD_5MB" {
//     try std.testing.fuzz(HDD_5MB, randomData, .{});
// }

test "fuzz image HDD_5MB_1024" {
    try std.testing.fuzz(HDD_5MB_1024, randomData, .{});
}

test "fuzz image TAR" {
    try std.testing.fuzz(TAR, randomData, .{});
}

// test "fuzz image FDC" {
//     try std.testing.fuzz(FDC, randomData, .{});
// }

test "fuzz image FDC_8MB" {
    try std.testing.fuzz(FDC_8MB, randomData, .{});
}

test "fuzz image CDOS" {
    // We purposely only test some representative formats to
    // fuzz more evently over all formats.
    inline for (&.{
        CDOS_SMSSSD,
        CDOS_LGDSDD,
    }) |fmt| {
        try std.testing.fuzz(fmt, randomData, .{});
    }
}

test "fuzz image ADOS_8IN" {
    try std.testing.fuzz(ADOS_8IN, randomData, .{});
}

test "fuzz image ADOS_MINI" {
    try std.testing.fuzz(ADOS_MINI, randomData, .{});
}

test "fuzz image ADOS_MIN_BOOT" {
    try std.testing.fuzz(ADOS_MINI_BOOT, randomData, .{});
}

test "fuzz image CPM_MINI" {
    try std.testing.fuzz(CPM_MINI, randomData, .{});
}

test "fuzz image HD_BASIC" {
    try std.testing.fuzz(HD_BASIC, randomData, .{});
}

//const crash = @embedFile("crash");

fn randomData(fmt: *const DiskImageType, smith: *std.testing.Smith) !void {
    const image_buffer = try allocator.alloc(u8, fmt.image_size);
    defer allocator.free(image_buffer);
    smith.bytes(image_buffer);
    var mem_image: InMemoryImage = undefined;
    mem_image.init(image_buffer);

    var disk_image: DiskImage = DiskImage.init(allocator, .{ .in_memory = &mem_image.reader }, .{ .in_memory = &mem_image.writer }, fmt) catch return;
    defer disk_image.deinit();

    disk_image.loadDirectories(.full) catch return;

    var test_file: []u8 = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(test_file);

    if (disk_image.directory.cooked_directories.items.len > 0) {
        var file_writer: std.Io.Writer = .fixed(test_file);
        disk_image.copyFromImage(&disk_image.directory.cooked_directories.items[smith.index(disk_image.directory.cooked_directories.items.len)], &file_writer, smith.value(DiskImage.TextMode)) catch {};
    }
    var len = smith.slice(test_file);
    var file_reader: std.Io.Reader = .fixed(test_file[0..len]);
    var filename: [32]u8 = undefined;
    len = smith.slice(&filename);
    disk_image.copyToImage(&file_reader, filename[0..len], null, true, smith.value(DiskImage.TextMode)) catch return;

    _ = disk_image.capacityFreeInKB();
    _ = disk_image.capacityTotalInKB();
    if (disk_image.directory.cooked_directories.items.len > 0) {
        disk_image.erase(&disk_image.directory.cooked_directories.items[smith.index(disk_image.directory.cooked_directories.items.len)]) catch {};
    }
}

fn allocationGetFree(self: *DirectoryTable) error{ OutOfAllocs, InvalidAllocation }!u16 {
    return switch (self.raw_directories) {
        .cpm => @import("os_cpm.zig").allocationGetFree(self),
        .ados => @import("os_altair_dos.zig").allocationGetFree(self, false),
        .hd_basic => @import("os_hd_basic.zig").allocationGetFree(self),
    };
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
    var disk_image = try DiskImage.init(allocator, .{ .in_memory = &raw_image.reader }, .{ .in_memory = &raw_image.writer }, image_type);
    errdefer disk_image.deinit();
    try disk_image.loadDirectories(.full);
    return disk_image;
}

fn newFormattedMemoryDiskImage(raw_image: *InMemoryImage, image_type: *const DiskImageType) !DiskImage {
    var disk_image = try DiskImage.init(allocator, .{ .in_memory = &raw_image.reader }, .{ .in_memory = &raw_image.writer }, image_type);
    errdefer disk_image.deinit();
    try disk_image.formatImage();
    try disk_image.loadDirectories(.full);
    switch (image_type.OS) {
        .cpm, .ados => {},
        .cdos => {
            var label: DiskLabel = .{ .cdos = undefined };
            @memcpy(&label.cdos.user_label, "ABCDEFGH");
            label.cdos.date_mmddyy[0] = 12;
            label.cdos.date_mmddyy[1] = 12;
            label.cdos.date_mmddyy[2] = 12;
            try disk_image.labelDisk(label);
        },
        .hd_basic => {
            var label: DiskLabel = .{ .hd_basic = undefined };
            @memset(&label.hd_basic.user_label, ' ');
            @memcpy(label.hd_basic.user_label[0..9], "FORMATTED");
            label.hd_basic.created_yymmdd = .{ 77, 5, 6 };
            label.hd_basic.modified_yymmdd = .{ 77, 5, 6 };
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
    try image.reinit(allocator, reader, writer);
    try image.loadDirectories(.full);
}

/// Caller should pass in pointers to an uninitialized reader and writer.
fn newPhysicalDiskImage(reader: *std.Io.File.Reader, writer: *std.Io.File.Writer, image_type: *const DiskImageType) !DiskImage {
    const image_file = try std.Io.Dir.cwd().createFile(std.testing.io, "TEST.IMG", .{ .read = true });
    reader.* = image_file.reader(std.testing.io, &.{});
    writer.* = image_file.writer(std.testing.io, &.{});
    var disk_image = try DiskImage.init(allocator, .{ .on_disk = reader }, .{ .on_disk = writer }, image_type);
    try disk_image.formatImage();
    try disk_image.loadDirectories(.full);
    return disk_image;
}

// Save a disk image buffer to TEST_OUT.DSK
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

// Save an image with a filename including the image format.
fn saveImageFmt(contents: []const u8, fmt: *const DiskImageType) void {
    var file_name: std.Io.Writer.Allocating = .init(allocator);
    defer file_name.deinit();
    file_name.writer.print("TEST_OUT_{s}.DSK", .{fmt.type_name}) catch unreachable;
    var file = std.Io.Dir.cwd().createFile(std.testing.io, file_name.written(), .{}) catch {
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

// Save a test file buffer to TEST_OUT.BIN
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
const DiskLabel = @import("disk_types.zig").DiskLabel;
const FileNameIterator = @import("directory_table.zig").FileNameIterator;
const OperatingSystem = @import("disk_types.zig").OperatingSystem;
const DirectoryTable = @import("directory_table.zig").DirectoryTable;
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
const ADOS_8IN = all_disk_types.getPtrConst(.ADOS_8IN);
const ADOS_MINI = all_disk_types.getPtrConst(.ADOS_MINI);
const ADOS_MINI_BOOT = all_disk_types.getPtrConst(.ADOS_MINI_BOOT);
const CPM_MINI = all_disk_types.getPtrConst(.CPM_MINI);
const HD_BASIC = all_disk_types.getPtrConst(.HD_BASIC);
// Can be set to a limited set of formats when wanting to test a subset.
//const all_formats = .{ ADOS_MINI, ADOS_MINI_BOOT };
//const all_formats = .{HD_BASIC};
//const all_formats = .{ FDD_8IN, HDD_5MB, HDD_5MB_1024 };
//const all_formats = .{ FDD_8IN, HDD_5MB, HDD_5MB_1024, TAR, FDC_8MB, CDOS_SMSSSD, CDOS_SMSSDD, CDOS_SMDSSD, CDOS_SMDSDD, CDOS_LGSSSD, CDOS_LGSSDD, CDOS_LGDSSD, CDOS_LGDSDD, ADOS_8IN };

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

// Basic program for creating "BIG.TXT" in Altair Disk Basic
// 10 CLEAR 500
// 20 OPEN "O",1,"BIG.TXT"
// 30 FOR N=0 TO 2239
// 40 C=32+(N MOD 95)
// 50 P$="--["+MID$(STR$(N),2)+"]--"
// 60 PRINT #1,CHR$(10)+P$+STRING$(127-LEN(P$),C);
// 70 NEXT N
// 80 CLOSE 1

// Basic program for filling directory. Note that this doesn't use all the available directories for some reason.
// 10 CLEAR 500
// 20 T$="Ain't got no distractions, can't hear no buzzes and bells. Don't see no lights a-flashing, plays by sense of smell. Always gets the replay, never seen him fall"
// 30 FOR N=0 TO 254
// 40 OPEN "O",1,"T"+MID$(STR$(N),2)+".TST"
// 50 PRINT #1,T$;
// 60 CLOSE 1
// 70 NEXT N
