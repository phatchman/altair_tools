pub const log = std.log.scoped(.altair_disk_lib);
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

// Atair DOS
pub const DiskImageType_ADOS_8IN = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [32]u16{
        0,  17, 2,  19, 4,  21, 6,  23,
        8,  25, 10, 27, 12, 29, 14, 31,
        16, 1,  18, 3,  20, 5,  22, 7,
        24, 9,  26, 11, 28, 13, 30, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .ADOS_8IN,
            .type_name = "ADOS_8IN",
            .description = "MITS 8\" Floppy Disk (Altair DOS & BASIC)",
            .OS = .{
                .ados = .{ .directory_track = 70 },
            },
            .tracks = 77,
            .reserved_tracks = 6,
            .sectors_per_track = 32,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 255, // last entry is always "end of directory"
            .directory_allocs = 4,
            .image_size = 337568,
            .varying_sector_format = true,
            .skew_table = &skew_table,
            .detect_fn = isCorrectFormat,
        };
        result.init();
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (!DiskImageType.defaultDetectFn(self, io, image_file)) return false;
        var reader = image_file.reader(io, &.{});
        // Go to the directory table location on track 70
        reader.seekTo(self.OS.ados.directory_track * @as(u32, self.track_size)) catch return false;
        var sector: DiskSector = .initUnformatted(self, self.OS.ados.directory_track);

        reader.interface.readSliceAll(sector.rawBytes()) catch return false;
        var entries: []DirEntry = std.mem.bytesAsSlice(DirEntry, sector.dataBytes());

        // It might be a new directory with no entries.
        // std.debug.print("checking empty\n", .{});
        if (entries[0].filename[0] == 0xff) {
            // All the other entry filenames need ot start with 0 as they either never existed, or were deleted.
            for (entries[1..]) |e| {
                if (e.filename[0] != 0x00) return false;
            }
            return true;
        }
        // std.debug.print("checking dir\n", .{});

        // So there must be at least 1 entry
        var start: usize = 1;
        for (0..self.sectors_per_track) |_| {
            for (entries, start..) |e, entry_nr| {
                if (e.filename[0] == 255) return false;
                if (e.filename[0] == 0x00) continue; // deleted
                if (e.track >= self.tracks or e.sector >= self.sectors_per_track) return false;
                //                std.debug.print("not EOD or deleted\n", .{});

                for (e.filename) |ch| {
                    // invalid filename chars
                    if (!std.ascii.isPrint(ch)) return false;
                }
                //              std.debug.print("valid filename {s}\n", .{e.filename});

                // must be valid filename. so check that this entry had correct fileno.
                reader.seekTo(@as(u32, e.track) * self.track_size + 137 * @as(u32, e.sector)) catch return false;
                //             std.debug.print("Seeked to : {x}, \n", .{reader.logicalPos()});
                reader.interface.readSliceAll(sector.rawBytes()) catch return false;
                //           std.debug.print("checking file_nr {} vs {}\n", .{ sector.mits_track_6_76.file_nr, entry_nr });

                return sector.data.file_nr == entry_nr;
            }
            start = 0;
            reader.interface.readSliceAll(sector.rawBytes()) catch return false;
            entries = std.mem.bytesAsSlice(DirEntry, sector.rawBytes());
        }

        return false;
    }
};

pub const DiskImageType_ADOS_MINI = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [16]u16{
        0, 1, 2,  3,  4,  5,  6,  7,
        8, 9, 10, 11, 12, 13, 14, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .ADOS_MINI,
            .type_name = "ADOS_MINI",
            .description = "MITS 5.25\" Data Floppy Disk (Altair DOS & BASIC)",
            .OS = .{
                .ados = .{ .directory_track = 34 },
            },
            .tracks = 35,
            .reserved_tracks = 0, // was 11
            .sectors_per_track = 16,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 127,
            .directory_allocs = 2,
            .image_size = 76720,
            .varying_sector_format = true,
            .skew_table = &skew_table,
            .detect_fn = isCorrectFormat,
        };
        result.init();
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (DiskImageType_ADOS_8IN.isCorrectFormat(self, io, image_file)) {
            var sector: [sector_size]u8 = undefined;
            var reader = image_file.reader(io, &.{});
            reader.interface.readSliceAll(&sector) catch return false;
            return sector[135] == 0xff; // Look for stop byte vs zero bytes
        }
        return false;
    }
};

pub const DiskImageType_ADOS_MINI_BOOT = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [16]u16{
        0, 2, 4, 6, 8, 10, 12, 14,
        1, 3, 5, 7, 9, 11, 13, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;
    const reserved_tracks = 12;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .ADOS_MINI_BOOT,
            .type_name = "ADOS_MINI_BOOT",
            .description = "MITS 5.25\" Bootable Floppy Disk (Altair DOS & BASIC)",
            .OS = .{
                .ados = .{ .directory_track = 34 },
            },
            .tracks = 35,
            .reserved_tracks = reserved_tracks,
            .sectors_per_track = 16,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 127,
            .directory_allocs = 2,
            .image_size = 76720,
            .varying_sector_format = true,
            .skew_table = &skew_table,
            .skew_fn = skew,
            .detect_fn = isCorrectFormat,
        };
        result.init();
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (DiskImageType_ADOS_8IN.isCorrectFormat(self, io, image_file)) {
            var sector: [sector_size]u8 = undefined;
            var reader = image_file.reader(io, &.{});
            reader.interface.readSliceAll(&sector) catch return false;
            return sector[135] == 0x00; // Look for stop byte vs zero bytes
        }
        return false;
    }

    // This is never currently called for reserved tracks as they are written as raw 1367 byte sectors.
    pub fn skew(table: []const u16, track: u16, sector: u16) u16 {
        if (track < reserved_tracks) {
            return table[sector];
        } else {
            return sector;
        }
    }
};

pub const DirEntry = extern struct {
    pub const filename_len = 8;
    filename: [filename_len]u8,
    track: u8,
    sector: u8,
    mode: u8,
    unused: [5]u8,

    const empty: DirEntry = .{
        .filename = @splat(' '),
        .track = 0,
        .sector = 0,
        .mode = 0x2, // Default to Seq
        .unused = @splat(0),
    };

    const last: DirEntry = .{
        .filename = .{ 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        .track = 0,
        .sector = 0,
        .mode = 0, // Default to Seq
        .unused = @splat(0),
    };

    // TODO: FIx this.
    // TODO: We don;t need the directory param if we have the image.
    pub fn cook(self: *DirEntry, dir: *DirectoryTable, image: *DiskImage, raw_entry_idx: u16) (error{ OutOfMemory, InvalidImageFile } || RawDirError || PhysicalAddress.ValidateError)!CookedDirEntry {
        const entry = &dir.raw_directories.ados.items[raw_entry_idx];
        try entry.validate(image.image_type, raw_entry_idx);
        var allocations: std.ArrayList(u16) = .empty;
        var result: CookedDirEntry = .{
            .user = 0,
            .filename = @splat(' '),
            .attribs = if (self.mode == 2) .{ 'S', ' ' } else .{ 'R', ' ' },
            .allocations = allocations,
            .size_in_bytes = undefined,
            .used_in_kbytes = undefined,
            .has_extension = false,
            .os = .{
                .ados = blk: {
                    // Calculate File size and Allocations
                    // Walk the linked list of sectors and add up the bytes.
                    // At the same time, build the list of allocations used by the file.
                    var track_nr = entry.track;
                    var sector_nr = entry.sector;
                    var nbytes: u32 = 0;
                    var used: u32 = 0;
                    var nr_sectors: u32 = 0;
                    const sectors_per_alloc = image.image_type.sectors_per_alloc;

                    if (entry.mode == 0x02) { // Sequential
                        while (track_nr != 0) {
                            const allocation = try toAllocation(image.image_type, .{ .track = track_nr, .sector = sector_nr });
                            dir.free_allocations.unset(allocation);
                            if (sector_nr % sectors_per_alloc == 0) {
                                try allocations.append(dir.allocator(), allocation);
                            }

                            var sector: DiskSector = .initUnformatted(image.image_type, image.image_type.OS.ados.directory_track);
                            image.readSector(.{ .track = track_nr, .sector = sector_nr }, &sector) catch |err| switch (err) {
                                error.InvalidTrack, error.InvalidSector => {
                                    log.warn("{s} has invalid track or sector links. File will not be copied correctly: {t}", .{ entry.filename, err });
                                    break :blk .{
                                        .track = entry.track,
                                        .sector = entry.sector,
                                        .size = nbytes,
                                        .used = used,
                                    };
                                },
                                else => {
                                    logerr("Error reading from disk image: {t}\n", .{err});
                                    return error.InvalidImageFile;
                                },
                            };
                            nbytes += sector.data.nbytes;
                            nr_sectors += 1;
                            track_nr = sector.data.next_track;
                            sector_nr = sector.data.next_sector;
                        }
                        used = (nr_sectors + (sectors_per_alloc - 1)) / sectors_per_alloc;
                    } else if (entry.mode == 0x04) { // Random access
                        var group_map: [256]u8 = undefined;
                        var sector: DiskSector = .initUnformatted(image.image_type, track_nr);
                        image.readSector(.{ .track = track_nr, .sector = sector_nr }, &sector) catch |err| {
                            logerr("Error reading from disk image: {t}\n", .{err});
                            return error.InvalidImageFile;
                        };
                        const nr_groups: u32 = sector.data.nbytes;
                        nbytes = nr_groups * image.image_type.block_size;
                        used = nr_groups;
                        @memcpy(group_map[0..128], sector.dataBytes());

                        image.readSector(.{ .track = sector.data.next_track, .sector = sector.data.next_sector }, &sector) catch |err| {
                            logerr("Error reading from disk image: {t}\n", .{err});
                            return error.InvalidImageFile;
                        };
                        @memcpy(group_map[128..], sector.dataBytes());
                        // Can't use track-size here as we only care about the size of the data portions of the track
                        //const allocs_per_track = (self.image_type.sector_size_data * self.image_type.sectors_per_track) / self.image_type.block_size;
                        for (0..nr_groups) |idx| {
                            const encoded_group: u8 = group_map[idx];
                            const alloc = toAllocation(image.image_type, .{
                                .track = (encoded_group & 0x3f) + if (image.image_type.type_id == .ADOS_8IN) @as(u8, 6) else @as(u8, 0),
                                .sector = (encoded_group >> 6) * sectors_per_alloc,
                            }) catch |err| switch (err) {
                                error.InvalidTrack, error.InvalidSector => {
                                    logerr("Directory entry for {s} has invalid track of sector information and will not be copied correctly: {t}. Use --raw for more details.", .{ std.mem.trimEnd(u8, &entry.filename, " "), err });
                                    break :blk .{
                                        .track = entry.track,
                                        .sector = entry.sector,
                                        .size = nbytes,
                                        .used = used,
                                    };
                                },
                            };
                            dir.free_allocations.unset(alloc); // TODO: We need checks around all of these. it is coming from untrusted data.
                        }
                    } else unreachable; // Should have already been validated before we get here.
                    break :blk .{
                        .track = entry.track,
                        .sector = entry.sector,
                        .size = nbytes,
                        .used = used,
                    };
                },
            },
        };
        @memcpy(result.filename[0..self.filename.len], &self.filename);
        result.size_in_bytes = result.os.ados.size;
        result.used_in_kbytes = result.os.ados.used;

        return result;
    }

    pub fn init(raw_dir: *const DirEntry, ados: @FieldType(CookedDirEntry, "os").ADOS, allocations: std.ArrayList(u16), image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!CookedDirEntry {
        var result: CookedDirEntry = .{
            .user = 0,
            .filename = @splat(' '),
            .attribs = if (raw_dir.mode == 2) .{ 'S', ' ' } else .{ 'R', ' ' },
            .block_size = image_type.block_size,
            .allocations = allocations,
            .os = .{ .ados = ados },
            .size_in_bytes = ados.size,
            .used_in_kbytes = ados.used,
            .has_extension = false,
        };
        @memcpy(result.filename[0..raw_dir.filename.len], &raw_dir.filename);
        return result;
    }

    pub fn isDeleted(self: *const DirEntry) bool {
        return self.filename[0] == 0x00 or self.filename[0] == 0xff;
    }

    pub fn setDeleted(self: *DirEntry) void {
        self.filename[0] = 0x00;
    }

    pub fn isLastEntry(self: *const DirEntry) bool {
        return self.filename[0] == 0xff;
    }

    pub fn eql(self: *const DirEntry, cooked: *const CookedDirEntry) bool {
        return std.mem.eql(u8, std.mem.trimEnd(u8, &self.filename, " "), cooked.filenameOnly());
    }

    pub fn lessThan(_: *const DiskImageType, lhs: *const DirEntry, rhs: *const DirEntry) bool {
        return std.mem.lessThan(u8, &lhs.filename, &rhs.filename);
    }

    pub fn validate(self: *const DirEntry, image_type: *const DiskImageType, entry_nr: u16) error{InvalidDirectoryEntry}!void {
        if (self.track >= image_type.tracks) {
            logerr(
                "Invalid directory entry: {} [Invalid track: {}. Must be 0 - {}]",
                .{ entry_nr, self.track, image_type.tracks - 1 },
            );
            return error.InvalidDirectoryEntry;
        }
        if (self.sector >= image_type.sectors_per_track) {
            logerr(
                "Invalid directory entry: {} [Invalid sector: {}. Must be 0 - {}]",
                .{ entry_nr, self.sector, image_type.sectors_per_track - 1 },
            );
            return error.InvalidDirectoryEntry;
        }
        if (!self.isDeleted()) switch (self.mode) {
            0x02, 0x04 => {}, // TODO: enumify this?
            else => {
                logerr(
                    "Invalid directory entry: {} [Invalid mode: {}. Must be 0x02 (sequential) or 0x04 (random access)]",
                    .{ entry_nr, self.mode },
                );
                return error.InvalidDirectoryEntry;
            },
        };
    }
};

pub fn loadDirectory(self: *DirectoryTable, image: *DiskImage, option: DirectoryTable.LoadOption) DirectoryTable.DirectoryLoadError!void {
    // Directory is held on track 70 for 8IN and 34 for 5.25IN
    const directory_track = self.image_type.OS.ados.directory_track;
    for (0..self.image_type.directory_allocs) |i| {
        // 8 sectors per block (block_size / sector_size_data)
        self.free_allocations.unset(try toAllocation(self.image_type, .{ .track = directory_track, .sector = @intCast(i * 8) }));
    }
    if (self.image_type.type_id == .ADOS_MINI) {
        // Can't use track 0 to store data.
        self.free_allocations.unset(0);
        self.free_allocations.unset(1);
    }
    var sector: DiskSector = .initUnformatted(self.image_type, directory_track);
    try self.raw_directories.ados.ensureTotalCapacity(self.allocator(), self.image_type.directories);
    for (0..self.image_type.sectors_per_track) |sector_nr| {
        try image.readSector(.{ .track = directory_track, .sector = @intCast(sector_nr) }, &sector);
        const entries: []DirEntry = std.mem.bytesAsSlice(DirEntry, sector.dataBytes());
        try self.raw_directories.ados.ensureUnusedCapacity(self.allocator(), entries.len);
        self.raw_directories.ados.appendSliceAssumeCapacity(entries);
    }

    var raw_dir_sorted: std.ArrayList(*DirEntry) = try .initCapacity(self.allocator(), self.raw_directories.ados.items.len);
    defer raw_dir_sorted.deinit(self.allocator());
    self.rawDirsSorted(DirEntry, self.raw_directories.ados.items[0..], &raw_dir_sorted);

    try self.cooked_directories.ensureTotalCapacity(self.allocator(), self.raw_directories.ados.items.len);
    loop: for (raw_dir_sorted.items) |dir| {
        switch (dir.filename[0]) {
            0 => continue, // Deleted
            // TODO: Can we use isLast and isDelted here instead?
            255 => break :loop, // End of Directory
            else => {
                // TODO: Put the catch back in .. work out the compile error.
                const raw_entry_idx = (@intFromPtr(dir) - @intFromPtr(&self.raw_directories.ados.items[0])) / @sizeOf(DirEntry);
                self.cooked_directories.appendAssumeCapacity(dir.cook(self, image, @intCast(raw_entry_idx)) catch |err| {
                    if (option != .raw_only) {
                        return err;
                    } else {
                        continue;
                    }
                });
            },
        }
    }

    std.mem.sort(CookedDirEntry, self.cooked_directories.items, {}, struct {
        fn lessThan(_: void, lhs: CookedDirEntry, rhs: CookedDirEntry) bool {
            return std.mem.lessThan(u8, lhs.filenameAndExtension(), rhs.filenameAndExtension());
        }
    }.lessThan);
}

/// Convert to valid Altair DOS / Basic filename
/// There are almost no restrictions on valid filename chars in Altair DOS
/// This program enforces printable and upper case.
pub fn translateFilename(from_filename: []const u8, to_filename: []u8) error{InvalidFilename}![]u8 {
    @memset(to_filename, ' ');
    var index: usize = 0;
    for (from_filename) |c| {
        if (std.ascii.isPrint(c)) {
            to_filename[index] = std.ascii.toUpper(c);
            index += 1;
        }
        if (index == to_filename.len) break;
    }
    if (index == 0) return error.InvalidFilename;
    log.info("Translated filename {s} to {s}", .{ from_filename, to_filename[0..index] });
    return to_filename[0..index];
}

// convert track and sector to allocation
fn toAllocation(image_type: *const DiskImageType, location: PhysicalAddress) PhysicalAddress.ValidateError!u16 {
    try location.validate(image_type);
    if (location.track < image_type.reserved_tracks) {
        return error.InvalidTrack;
    }
    return @as(u16, location.track - image_type.reserved_tracks) * (image_type.sectors_per_track / image_type.sectors_per_alloc) + @as(u16, location.sector / image_type.sectors_per_alloc);
}

// TODO: Change these so they log error and return copy failed?
pub fn copyFromImage(self: *DiskImage, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) (error{ InvalidFormat, WriteFailed, InvalidRecordNumber, InvalidToken } || ReadSectorError)!void {
    var track_nr: u8 = entry.os.ados.track;
    var sector_nr: u8 = entry.os.ados.sector;
    var sector: DiskSector = .initUnformatted(self.image_type, 6); //  // TODO
    errdefer out_writer.flush() catch {};

    switch (entry.attribs[0]) {
        'S' => { // sequential
            var file_no: u8 = 255;
            var decode_basic_file: bool = false;
            var first_sector: bool = true;
            var temp_file: std.Io.Writer.Allocating = .init(self.allocator);
            defer temp_file.deinit();

            while (track_nr != 0) {
                try self.readSector(.{ .track = track_nr, .sector = sector_nr }, &sector);
                if (file_no == 255) file_no = sector.data.file_nr;

                if (file_no == sector.data.file_nr) {
                    if (first_sector and text_mode == .Text) {
                        if (sector.data.data[0] == 0xff) { // Indicates a BASIC file.
                            decode_basic_file = true;
                        } else {
                            log.err("Not an encoded Altair BASIC file. First byte should be 0xff, is 0x{x:02}.", .{sector.data.data[0]});
                            return error.InvalidFormat;
                        }
                    }
                    if (decode_basic_file) {
                        try temp_file.writer.writeAll(sector.data.data[0..sector.data.nbytes]);
                    } else {
                        try out_writer.writeAll(sector.data.data[0..sector.data.nbytes]);
                    }
                    first_sector = false;
                } else {
                    log.err("File {s} has corruption in the sector chain on track {}, sector {}. Expected file number {} found {}", .{ entry.filenameAndExtension(), track_nr, sector_nr, file_no, sector.data.file_nr });
                    return error.InvalidRecordNumber;
                }
                track_nr = sector.data.next_track;
                sector_nr = sector.data.next_sector;
            }
            if (decode_basic_file) {
                var reader: std.Io.Reader = .fixed(temp_file.written());
                try basic_file_decoder.decode(&reader, out_writer);
            }
            try out_writer.flush();
        },
        'R' => { // Random access file
            // The first 256 bytes are the group and track number encoded as
            // 2 bits group and 6 bits track nr - 6. i.e. 0 = track 6.
            // The first sector's `nbytes` holds the number of groups.
            var group_map: [256]u8 = undefined;
            try self.readSector(.{ .track = track_nr, .sector = sector_nr }, &sector);
            const group_count = sector.data.nbytes;
            @memcpy(group_map[0..128], sector.dataBytes());
            track_nr = sector.data.next_track;
            sector_nr = sector.data.next_sector;
            try self.readSector(.{ .track = track_nr, .sector = sector_nr }, &sector);
            @memcpy(group_map[128..], sector.dataBytes());

            const sectors_per_group = self.image_type.block_size / self.image_type.sector_size_data;
            var idx: usize = 0;
            while (idx != group_count) : (idx += 1) { // TODO:
                const group_encoded = group_map[idx];
                track_nr = (group_encoded & 0x3f) + 6;
                const group_nr = group_encoded >> 6;
                sector_nr = @intCast(group_nr * sectors_per_group);
                // The first 2 sectors of the first group are the group_index and group_map. So skip during file writing
                for (if (idx == 0) 2 else 0..sectors_per_group) |offset| {
                    try self.readSector(.{ .track = track_nr, .sector = @intCast(sector_nr + offset) }, &sector);
                    try out_writer.writeAll(sector.dataBytes());
                }
            }
        },
        else => unreachable,
    }
}

pub fn copyToImage(self: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, force: bool, text_mode: TextMode) !void {
    var filename_buf: [8]u8 = undefined;
    const ados_filename = try translateFilename(to_filename, &filename_buf);
    if (self.directory.findByFilename(ados_filename, null)) |existing_entry| {
        if (force) {
            try self.erase(existing_entry);
        } else {
            return std.Io.File.OpenError.PathAlreadyExists;
        }
    }

    // These are used as temporary buffers for converting BASIC files.
    var conversion_buffer_in: std.Io.Writer.Allocating = .init(self.allocator);
    defer conversion_buffer_in.deinit();
    var conversion_buffer_out: std.Io.Writer.Allocating = .init(self.allocator);
    defer conversion_buffer_out.deinit();

    if (text_mode == .Text) {
        // Basic steals the first char from the file, if it is an unencoded ascii file!
        // It also requires CR/NL line endings.
        _ = try file_reader.streamRemaining(&conversion_buffer_in.writer);
        var reader_in: std.Io.Reader = .fixed(conversion_buffer_in.written());

        try conversion_buffer_out.writer.writeByte(' ');
        while (reader_in.takeDelimiter('\n')) |maybe_slice| {
            const slice = maybe_slice orelse break;
            if (slice.len == 0) break;
            try conversion_buffer_out.writer.writeAll(slice);
            if (slice[slice.len - 1] == '\r') {
                try conversion_buffer_out.writer.writeByte('\n');
            } else {
                try conversion_buffer_out.writer.writeAll("\r\n");
            }
        } else |err| {
            return err;
        }
    }
    var conversion_reader: std.Io.Reader = .fixed(conversion_buffer_out.written());
    const reader: *std.Io.Reader = if (text_mode == .Text) &conversion_reader else file_reader;
    var extent_nr: u16 = undefined;
    const new_entry = try rawEntryGetFreeInitialized(&self.directory, self, &extent_nr);
    @memcpy(&new_entry.filename, &filename_buf);
    new_entry.mode = if (text_mode == .Rand) 0x04 else 0x2; // tODO: enumify?

    var file_data: [128]u8 = undefined; // TODO: Hard coded
    var nbytes = try reader.readSliceShort(&file_data);
    // Zero length files only get a directory entry and nothing else.
    if (nbytes == 0) {
        try rawEntryWrite(self, extent_nr);
        return;
    }

    var alloc = try allocationGetFree(&self.directory, text_mode == .Rand);
    const sectors_per_alloc = self.image_type.sectors_per_alloc;
    const allocs_per_track = self.image_type.sectors_per_track / sectors_per_alloc;
    var track_nr: u16 = self.image_type.reserved_tracks + alloc / allocs_per_track;
    var sector_nr: u16 = (alloc % allocs_per_track) * sectors_per_alloc; // This is the first sector for this allocation of 8 sectors.
    var group_map: [256]u8 = @splat(0); // Store track / sector allocations for random access files.
    var group_map_location: PhysicalAddress = .{
        .track = self.image_type.reserved_tracks + alloc / allocs_per_track,
        .sector = (alloc % allocs_per_track) * sectors_per_alloc,
    };

    new_entry.track = @intCast(track_nr);
    new_entry.sector = @intCast(sector_nr);
    try rawEntryWrite(self, extent_nr);
    // TODO: Change this to use buildcookedentry
    //    errdefer buildCookedEntryADOS(self, extent_nr) catch {}; // Try and build the cooked dir if we can with what we have.

    errdefer blk: {
        self.directory.cooked_directories.appendAssumeCapacity(new_entry.cook(&self.directory, self, extent_nr) catch break :blk);
    }

    var prev_location: ?PhysicalAddress = null;
    var prev_sector: DiskSector = undefined;
    var start_sector: usize = if (text_mode == .Rand) 2 else 0; // For random access files, first 2 sectors are index bytes
    var group_idx: usize = 0;
    while (nbytes != 0) {
        if (text_mode == .Rand) {
            if (nbytes != 128) { // TODO: Really they need to be a multiple of 1K.
                logerr("Random access files must be a multiple of 128 bytes in length.", .{});
                return error.InvalidFormat;
            } else if (group_idx == 256) {
                // TODO: Test this
                log.warn("Random access files are limited to {d} bytes. File truncated.", .{255 * sectors_per_alloc * self.image_type.sector_size_data});
                break;
            }
        }
        track_nr = self.image_type.reserved_tracks + alloc / allocs_per_track;
        if (text_mode == .Rand) {
            const track_offset: u8 = if (self.image_type.type_id == .ADOS_8IN) 6 else 0;
            group_map[group_idx] = @as(u8, @intCast(alloc % allocs_per_track)) << 6 | (@as(u8, @intCast(track_nr)) - track_offset);
            group_idx += 1;
        }

        for (start_sector..sectors_per_alloc) |offset| {
            sector_nr = (alloc % allocs_per_track) * sectors_per_alloc + @as(u16, @intCast(offset));
            // Fill all sectors in the group of 8 for the allocation. (8 * 128) = 1024byte block size.
            const location: PhysicalAddress = .{ .track = track_nr, .sector = sector_nr };
            var sector: DiskSector = .initFormatted(self.image_type, location);
            @memcpy(sector.dataBytes()[0..nbytes], file_data[0..nbytes]);
            sector.data.nbytes = @intCast(nbytes);
            sector.data.file_nr = @intCast(extent_nr + 1);
            try self.writeSector(location, &sector);
            if (prev_location) |prev| {
                prev_sector.data.next_track = @intCast(track_nr);
                prev_sector.data.next_sector = @intCast(sector_nr);
                try self.writeSector(prev, &prev_sector);
            }
            prev_location = location;
            prev_sector = sector;

            nbytes = try reader.readSliceShort(&file_data);
            if (nbytes == 0) break;
        }
        if (nbytes != 0) {
            alloc = try allocationGetFree(&self.directory, text_mode == .Rand);
        }
        start_sector = 0;
    }
    if (text_mode == .Rand) {
        // Write the group index block.
        var sector: DiskSector = .initFormatted(self.image_type, group_map_location);
        sector.data.nbytes = @intCast(group_idx);
        sector.data.file_nr = @intCast(extent_nr + 1);
        sector.data.next_track = @intCast(group_map_location.track);
        sector.data.next_sector = @intCast(group_map_location.sector + 1);
        @memcpy(sector.dataBytes(), group_map[0..128]);
        std.debug.print("writing to {} with nbytes = {}\n", .{ group_map_location, sector.data.nbytes });
        try self.writeSector(group_map_location, &sector);
        group_map_location.sector += 1;
        sector = .initFormatted(self.image_type, group_map_location);
        sector.data.nbytes = @intCast(group_idx);
        sector.data.file_nr = @intCast(extent_nr + 1);
        sector.data.next_track = @intCast(group_map_location.track);
        sector.data.next_sector = @intCast(group_map_location.sector + 1);
        @memcpy(sector.dataBytes(), group_map[128..]);
        try self.writeSector(group_map_location, &sector);
    }
    // TODO: Change this into a Build cooked entry.. with all the validation etc..
    // But mostly because we need to do this on the error case as well.
    self.directory.cooked_directories.appendAssumeCapacity(try new_entry.cook(&self.directory, self, extent_nr));

    // The ADOS file allocation is fairly simple for sequential files.
    // 1) The directory entry holds a pointer to the first track and sector for the file.
    // 2) All sectors containing file data, have the directory entry number (starting at 1) set as the file number
    // 3) The sector also contains a ponter to the next track and sector for the file
    // 4) If the next track and sector are 0, then this indicates the end of file.
    // 5) For the last sector, nbytes is set to the amount of data in the last sector.
    //
    // The next track and sector come from the list of free allocations. An allocation represents a block of 8 sectors
    // The file data is written to the first sector in the block and then sequentially through the remaining (logical) sectors
    // Once all 8 sectors have been written, a new allocation is taken.
    // This means we need to keep going back to the previous sector to write the track and sector pointers after we have
    // written data to the next sector.

    // Random access files are laid down the same way as sequential files, except that the first
    // 256 bytes of the file contain encoded pointers to the track and group holding the random access file.
    // The nbytes field for the index sectors tells us how many index entries to scan.
}

/// write an Altair DOS diretory entry (RawDirEntry)
pub fn rawEntryWrite(self: *DiskImage, extent_nr: u16) (WriteSectorError || RawDirError)!void {
    const entries_per_sector = self.image_type.dirs_per_sector;
    const this_entry = &self.directory.raw_directories.ados.items[extent_nr];
    if (!this_entry.isDeleted()) {
        try this_entry.validate(self.image_type, extent_nr);
    }

    // 16 bytes per directory entry. Directory start at Track 70
    const location: PhysicalAddress = .{ .track = self.image_type.OS.ados.directory_track, .sector = extent_nr / entries_per_sector };
    var sector: DiskSector = .initFormatted(self.image_type, location);

    // start_index is the index of the directory entry that is at
    // the beginning of this sector
    const start_index = extent_nr / entries_per_sector * entries_per_sector;
    // Copy 1 full sector worth of extents/raw entries
    @memcpy(sector.dataBytes(), std.mem.sliceAsBytes(self.directory.raw_directories.ados.items[start_index .. start_index + entries_per_sector]));
    try self.writeSector(location, &sector);
}

pub fn clearErasedSectors(image: *DiskImage, raw_item: *DirEntry) !void {
    var track_nr: u16 = raw_item.track;
    var sector_nr: u16 = raw_item.sector;

    while (track_nr != 0) {
        var sector: DiskSector = .initUnformatted(image.image_type, track_nr);
        const location: PhysicalAddress = .{ .track = track_nr, .sector = sector_nr };
        image.readSector(location, &sector) catch |err| switch (err) {
            error.InvalidTrack, error.InvalidSector => {
                log.warn("{s} has invalid track or sector links. Erase still suceeded: {t}", .{ raw_item.filename, err });
                break;
            },
            else => return err,
        };
        track_nr = sector.data.next_track;
        sector_nr = sector.data.next_sector;
        sector.data.file_nr = 0;
        sector.data.nbytes = 0;
        sector.data.next_sector = 0;
        sector.data.next_track = 0;
        try image.writeSector(location, &sector);
    }
}

/// Return a free allocation
pub fn allocationGetFree(self: *DirectoryTable, for_random_access: bool) error{OutOfAllocs}!u16 {
    // Allocations are performed in the order track 71 to track 76
    // Then from track 69 down to 6
    const allocs_per_track = self.image_type.sectors_per_track / self.image_type.sectors_per_alloc;

    if (!for_random_access) {
        for (self.image_type.OS.ados.directory_track + 1..self.image_type.tracks) |track_nr| {
            for (0..allocs_per_track) |alloc_in_track| {
                const alloc_nr = (track_nr - self.image_type.reserved_tracks) * allocs_per_track + alloc_in_track;
                if (self.free_allocations.isSet(alloc_nr)) {
                    self.free_allocations.unset(alloc_nr);
                    return @intCast(alloc_nr);
                }
            }
        }

        // Then look for free allocs from track 69 downwards
        if (self.free_allocations.findLastSet()) |free| {
            // This will return the last alloc on the track. But we need to
            // allocate from the first alloc for the track, upwards.
            const first_alloc = free / allocs_per_track * allocs_per_track;
            for (first_alloc..first_alloc + allocs_per_track) |alloc| {
                if (self.free_allocations.isSet(alloc)) {
                    self.free_allocations.unset(alloc);
                    return @intCast(alloc);
                }
            }
            unreachable;
        }
        return error.OutOfAllocs;
    } else { // Randomn access
        var track: u8 = self.image_type.OS.ados.directory_track - 1;
        while (track >= self.image_type.reserved_tracks) : (track -= 1) {
            for (0..allocs_per_track) |offset| {
                const alloc = (track - self.image_type.reserved_tracks) * allocs_per_track + offset;
                if (self.free_allocations.isSet(alloc)) {
                    self.free_allocations.unset(alloc);
                    return @intCast(alloc);
                }
            }
        }
        return error.OutOfAllocs;
    }
}

pub fn rawEntryGetFreeInitialized(self: *const DirectoryTable, image: *DiskImage, extent_nr: *u16) error{OutOfExtents}!*DirEntry {
    for (self.raw_directories.ados.items[0..self.raw_directories.ados.items.len -| 1], 0..) |*dir, i| {
        if (dir.isLastEntry()) {
            extent_nr.* = @intCast(i);
            dir.* = .last;
            // Set the next entry to be the last entry.
            self.raw_directories.ados.items[i + 1] = .last;
            rawEntryWrite(image, @intCast(i + 1)) catch return error.OutOfExtents;
            return dir;
        } else if (dir.isDeleted()) {
            extent_nr.* = @intCast(i);
            dir.* = .empty;
            return dir;
        }
    }
    return error.OutOfExtents;
}

const disk_types = @import("disk_types.zig");
const DiskImageType = disk_types.DiskImageType;
const DiskSector = disk_types.DiskSector;
const std = @import("std");
const disk_image = @import("disk_image.zig");
const DiskImage = disk_image.DiskImage;
const WriteSectorError = DiskImage.WriteSectorError;
const directory_table = @import("directory_table.zig");
const DirectoryTable = directory_table.DirectoryTable;
const RawDirError = directory_table.RawDirError;
const PhysicalAddress = disk_types.PhysicalAddress;
const CookedDirEntry = directory_table.CookedDirEntry;
const TextMode = DiskImage.TextMode;
const ReadSectorError = DiskImage.ReadSectorError;
const basic_file_decoder = @import("basic_file_decoder.zig");
