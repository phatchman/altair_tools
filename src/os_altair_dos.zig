// Somehow do something to mark random access files, so that they will get loaded back correctly??

// FUTURE TODO: For ados 8 in formats we should detect how many tracks are reserved by looking at the format.

pub const log = std.log.scoped(.altair_disk_lib);
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

pub const max_sector_data_len = 128;
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
            .reserved_allocs = 4,
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
        if (entries[0].filename[0] == 0xff) {
            // All the other entry filenames need ot start with 0 as they either never existed, or were deleted.
            for (entries[1..]) |e| {
                if (e.filename[0] != 0x00) return false;
            }
            return true;
        }

        // So there must be at least 1 entry
        var start: usize = 1;
        for (0..self.sectors_per_track) |_| {
            for (entries, start..) |e, entry_nr| {
                if (e.filename[0] == 255) return false;
                if (e.filename[0] == 0x00) continue; // deleted
                if (e.track >= self.tracks or e.sector >= self.sectors_per_track) return false;

                for (e.filename) |ch| {
                    // invalid filename chars
                    if (!std.ascii.isPrint(ch)) return false;
                }

                // must be valid filename. so check that this entry had correct fileno.
                reader.seekTo(@as(u32, e.track) * self.track_size + 137 * @as(u32, e.sector)) catch return false;
                reader.interface.readSliceAll(sector.rawBytes()) catch return false;

                return sector.data.file_nr == entry_nr;
            }
            start = 0;
            reader.interface.readSliceAll(sector.rawBytes()) catch return false;
            entries = std.mem.bytesAsSlice(DirEntry, sector.dataBytes());
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
            .reserved_allocs = 2,
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
            .reserved_allocs = 2,
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

pub const DiskImageType_TIMESHARE_BASIC = struct {
    pub fn init() DiskImageType {
        var result = DiskImageType_ADOS_8IN.init();
        result.type_name = "TIMESHARE_BASIC";
        result.description = "MITS 8\" Floppy Disk (Timeshare BASIC) [READ ONLY]";
        result.type_id = .TIMESHARE_BASIC;
        result.detect_fn = isCorrectFormat;
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (self.defaultDetectFn(io, image_file)) {
            // Timeshare basic puts 0x41 in a stop byte, which normally should be 0xff in track 65, sector 25.
            var buf: [1]u8 = undefined;
            var reader = image_file.reader(io, &buf);
            reader.seekTo(0x46708) catch return false;
            const byte = reader.interface.takeByte() catch return false;
            return byte == 0x41;
        } else {
            return false;
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

    pub fn cook(self: *DirEntry, image: *DiskImage, raw_entry_idx: u16) (error{ OutOfMemory, InvalidImageFile } || RawDirError || PhysicalAddress.ValidateError)!CookedDirEntry {
        const dir = &image.directory;
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
                            try unsetAllocation(dir, allocation);
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
                                .track = (encoded_group & 0x3f) + if (image.image_type.type_id == .ADOS_8IN or image.image_type.type_id == .TIMESHARE_BASIC) @as(u8, 6) else @as(u8, 0),
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
                            try unsetAllocation(dir, alloc);
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

pub fn loadDirectory(image: *DiskImage, option: DirectoryTable.LoadOption) DirectoryTable.DirectoryLoadError!void {
    // Directory is held on track 70 for 8IN and 34 for 5.25IN
    const dir = &image.directory;
    const directory_track = dir.image_type.OS.ados.directory_track;
    for (0..dir.image_type.reserved_allocs) |i| {
        // 8 sectors per block (block_size / sector_size_data)
        try unsetAllocation(dir, try toAllocation(dir.image_type, .{ .track = directory_track, .sector = @intCast(i * 8) }));
    }
    if (dir.image_type.type_id == .ADOS_MINI) {
        // Can't use track 0 to store data.
        try unsetAllocation(dir, 0);
        try unsetAllocation(dir, 1);
    }
    var sector: DiskSector = .initUnformatted(dir.image_type, directory_track);
    try dir.raw_directories.ados.ensureTotalCapacity(dir.allocator(), dir.image_type.directories);
    for (0..dir.image_type.sectors_per_track) |sector_nr| {
        try image.readSector(.{ .track = directory_track, .sector = @intCast(sector_nr) }, &sector);
        const entries: []DirEntry = std.mem.bytesAsSlice(DirEntry, sector.dataBytes());
        try dir.raw_directories.ados.ensureUnusedCapacity(dir.allocator(), entries.len);
        dir.raw_directories.ados.appendSliceAssumeCapacity(entries);
    }

    // var raw_dir_sorted: std.ArrayList(*DirEntry) = try .initCapacity(dir.allocator(), dir.raw_directories.ados.items.len);
    // defer raw_dir_sorted.deinit(dir.allocator());
    // dir.rawDirsSorted(DirEntry, dir.raw_directories.ados.items[0..], &raw_dir_sorted);

    try dir.cooked_directories.ensureTotalCapacity(dir.allocator(), dir.raw_directories.ados.items.len);
    loop: for (dir.raw_directories.ados.items) |*entry| {
        switch (entry.filename[0]) {
            0 => continue, // Deleted
            255 => break :loop, // End of Directory
            else => {
                const raw_entry_idx = (@intFromPtr(entry) - @intFromPtr(&dir.raw_directories.ados.items[0])) / @sizeOf(DirEntry);
                dir.cooked_directories.appendAssumeCapacity(entry.cook(image, @intCast(raw_entry_idx)) catch |err| {
                    if (option != .raw_only) {
                        return err;
                    } else {
                        continue;
                    }
                });
            },
        }
    }

    std.mem.sort(CookedDirEntry, dir.cooked_directories.items, {}, struct {
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

/// Read sequential files via an IO interface.
/// Used to facilitate the basic_file_decoder taking an input and output stream
/// without needing to first extra the entire file in memory.
const SequentialFileReader = struct {
    pub const ReadError = error{InvalidRecordNumber} || ReadSectorError;

    image: *DiskImage,
    entry: *const CookedDirEntry,
    track: u8,
    sector_nr: u8,
    file_no: u8 = 255,
    sector: DiskSector,
    pending: []const u8 = &.{},
    err: ?ReadError = null,
    interface: std.Io.Reader,

    /// Initialize the sequential file reader.
    /// `buffer` must be at least one raw full sector in length.
    /// Any part of the buffer larger than the sector size is not used.
    pub fn init(image: *DiskImage, entry: *const CookedDirEntry, buffer: []u8) SequentialFileReader {
        var self: SequentialFileReader = .{
            .image = image,
            .entry = entry,
            .track = entry.os.ados.track,
            .sector_nr = entry.os.ados.sector,
            .sector = .initUnformatted(image.image_type, image.image_type.reserved_tracks),
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
        std.debug.assert(buffer.len >= self.sector.dataBytes().len);
        return self;
    }

    fn fillIfEmpty(self: *SequentialFileReader) error{ReadFailed}!void {
        self.err = null;
        if (self.pending.len == 0 and self.track != 0) {
            self.image.readSector(.{ .track = self.track, .sector = self.sector_nr }, &self.sector) catch |e| {
                self.err = e;
                return error.ReadFailed;
            };
            if (self.file_no == 255) self.file_no = self.sector.data.file_nr;
            if (self.file_no != self.sector.data.file_nr) {
                log.err("File {s} has corruption in the sector chain on track {}, sector {}. Expected file number {} found {}", .{
                    self.entry.filenameAndExtension(), self.track, self.sector_nr, self.file_no, self.sector.data.file_nr,
                });
                self.err = error.InvalidRecordNumber;
                return error.ReadFailed;
            }
            self.pending = self.sector.data.data[0..self.sector.data.nbytes];
            self.track = self.sector.data.next_track;
            self.sector_nr = self.sector.data.next_sector;
        }
    }

    /// Loads the first sector if needed; does not consume any bytes.
    pub fn isBasicFile(self: *SequentialFileReader) error{ReadFailed}!bool {
        try self.fillIfEmpty();
        return self.pending.len > 0 and self.pending[0] == 0xff;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SequentialFileReader = @fieldParentPtr("interface", r);
        try self.fillIfEmpty();

        if (self.pending.len == 0) return error.EndOfStream;
        const n = limit.minInt(self.pending.len);
        try w.writeAll(self.pending[0..n]);
        self.pending = self.pending[n..];
        return n;
    }
};

// TODO: Change these so they log error and return copy failed?
pub fn copyFromImage(image: *DiskImage, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) (error{ InvalidFormat, WriteFailed, InvalidRecordNumber, InvalidToken } || ReadSectorError)!void {
    var track_nr: u8 = entry.os.ados.track;
    var sector_nr: u8 = entry.os.ados.sector;
    errdefer out_writer.flush() catch {};
    var buffer: [max_sector_data_len]u8 = undefined;
    switch (entry.attribs[0]) {
        'S' => { // sequential
            var decode_basic_file: bool = false;
            var reader: SequentialFileReader = .init(image, entry, &buffer);
            if (text_mode == .Text) {
                if (try reader.isBasicFile()) {
                    decode_basic_file = true;
                } else {
                    log.err("Not an encoded Altair BASIC file. First byte should be 0xff, is 0x{x:02}.", .{try reader.interface.peekByte()});
                    return error.InvalidFormat;
                }
            }
            if (decode_basic_file) {
                log.info("Converting encoded BASIC file to ASCII", .{});
                basic_file_decoder.decode(&reader.interface, out_writer) catch |err| switch (err) {
                    error.ReadFailed => return reader.err.?,
                    error.WriteFailed => return err,
                    error.EndOfStream => {
                        logerr("Unexpected end of file while decoding basic file. File may be corrupted.", .{});
                        return error.InvalidFormat;
                    },
                    error.InvalidToken => return err,
                    error.InvalidFormat => unreachable, // We already check it was a basic file.
                };
            } else {
                _ = reader.interface.streamRemaining(out_writer) catch |err| switch (err) {
                    error.ReadFailed => return reader.err.?,
                    error.WriteFailed => return err,
                };
            }
        },
        'R' => { // Random access file
            // The first 256 bytes are the group and track number encoded as
            // 2 bits group and 6 bits track nr - 6. i.e. 0 = track 6.
            // The first sector's `nbytes` holds the number of groups.
            var sector: DiskSector = .initUnformatted(image.image_type, track_nr);
            var group_map: [256]u8 = undefined;
            try image.readSector(.{ .track = track_nr, .sector = sector_nr }, &sector);
            const group_count = sector.data.nbytes;
            @memcpy(group_map[0..128], sector.dataBytes());
            track_nr = sector.data.next_track;
            sector_nr = sector.data.next_sector;
            try image.readSector(.{ .track = track_nr, .sector = sector_nr }, &sector);
            @memcpy(group_map[128..], sector.dataBytes());

            const sectors_per_group = image.image_type.block_size / image.image_type.sector_size_data;
            var idx: usize = 0;
            while (idx != group_count) : (idx += 1) {
                const group_encoded = group_map[idx];
                track_nr = (group_encoded & 0x3f) + 6;
                const group_nr = group_encoded >> 6;
                sector_nr = @intCast(group_nr * sectors_per_group);
                // The first 2 sectors of the first group are the group_index and group_map. So skip during file writing
                for (if (idx == 0) 2 else 0..sectors_per_group) |offset| {
                    try image.readSector(.{ .track = track_nr, .sector = @intCast(sector_nr + offset) }, &sector);
                    try out_writer.writeAll(sector.dataBytes());
                }
            }
        },
        else => unreachable,
    }
}

pub const CopyToImageError = (error{ InvalidFilename, InvalidFormat, PathAlreadyExists, OutOfExtents, OutOfAllocs, ReadFailed, StreamTooLong, OutOfMemory, InvalidImageFile } || DiskImage.EraseError);
pub fn copyToImage(image: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, force: bool, text_mode: TextMode) CopyToImageError!void {
    var filename_buf: [8]u8 = undefined;
    const ados_filename = try translateFilename(to_filename, &filename_buf);
    if (image.directory.findByFilename(ados_filename, null)) |existing_entry| {
        if (force) {
            try image.erase(existing_entry);
        } else {
            return error.PathAlreadyExists;
        }
    }

    var basic_read_buf: [4096]u8 = undefined;
    var basic_reader: basic_file_decoder.BasicTextFileReader = .init(file_reader, &basic_read_buf);

    const reader: *std.Io.Reader = if (text_mode == .Text) &basic_reader.interface else file_reader;
    var extent_nr: u16 = undefined;
    const new_entry = try rawEntryGetFreeInitialized(image, &extent_nr);
    @memcpy(&new_entry.filename, &filename_buf);
    new_entry.mode = if (text_mode == .Rand) 0x04 else 0x2; // tODO: enumify?

    var file_data: [128]u8 = undefined;
    var nbytes = reader.readSliceShort(&file_data) catch |err| switch (err) {
        error.ReadFailed => return basic_reader.err orelse err,
    };
    // Zero length files only get a directory entry and nothing else.
    // FUTURE TODO: The handling of cooked dirs here is very fragile. move this into a fucntion and handled cooked dirs outside of it?
    if (nbytes == 0) {
        try rawEntryWrite(image, extent_nr);
        image.directory.cooked_directories.appendAssumeCapacity(try new_entry.cook(image, extent_nr));
        return;
    }

    var alloc = try allocationGetFree(&image.directory, text_mode == .Rand);
    const sectors_per_alloc = image.image_type.sectors_per_alloc;
    const allocs_per_track = image.image_type.sectors_per_track / sectors_per_alloc;
    var track_nr: u16 = image.image_type.reserved_tracks + alloc / allocs_per_track;
    var sector_nr: u16 = (alloc % allocs_per_track) * sectors_per_alloc; // This is the first sector for this allocation of 8 sectors.
    var group_map: [256]u8 = @splat(0); // Store track / sector allocations for random access files.
    var group_map_location: PhysicalAddress = .{
        .track = image.image_type.reserved_tracks + alloc / allocs_per_track,
        .sector = (alloc % allocs_per_track) * sectors_per_alloc,
    };

    new_entry.track = @intCast(track_nr);
    new_entry.sector = @intCast(sector_nr);
    try rawEntryWrite(image, extent_nr);

    // Always try and create the cooked directory with whatever info we have to hand.
    errdefer blk: {
        image.directory.cooked_directories.appendAssumeCapacity(new_entry.cook(image, extent_nr) catch break :blk);
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
                log.warn("Random access files are limited to {d} bytes. File truncated.", .{255 * sectors_per_alloc * image.image_type.sector_size_data});
                break;
            }
        }
        track_nr = image.image_type.reserved_tracks + alloc / allocs_per_track;
        if (text_mode == .Rand) {
            const track_offset: u8 = if (image.image_type.type_id == .ADOS_8IN) 6 else 0;
            group_map[group_idx] = @as(u8, @intCast(alloc % allocs_per_track)) << 6 | (@as(u8, @intCast(track_nr)) - track_offset);
            group_idx += 1;
        }

        for (start_sector..sectors_per_alloc) |offset| {
            sector_nr = (alloc % allocs_per_track) * sectors_per_alloc + @as(u16, @intCast(offset));
            // Fill all sectors in the group of 8 for the allocation. (8 * 128) = 1024byte block size.
            const location: PhysicalAddress = .{ .track = track_nr, .sector = sector_nr };
            var sector: DiskSector = .initFormatted(image.image_type, location);
            @memcpy(sector.dataBytes()[0..nbytes], file_data[0..nbytes]);
            sector.data.nbytes = @intCast(nbytes);
            sector.data.file_nr = @intCast(extent_nr + 1);
            try image.writeSector(location, &sector);
            if (prev_location) |prev| {
                prev_sector.data.next_track = @intCast(track_nr);
                prev_sector.data.next_sector = @intCast(sector_nr);
                try image.writeSector(prev, &prev_sector);
            }
            prev_location = location;
            prev_sector = sector;

            if (nbytes != 0) {
                nbytes = reader.readSliceShort(&file_data) catch |err| switch (err) {
                    error.ReadFailed => return basic_reader.err orelse err,
                };
            } else {
                // Random access files have to fill up the whole group/allocation.
                if (text_mode == .Rand) {
                    @memset(&file_data, 0x00);
                } else {
                    break;
                }
            }
        }
        if (nbytes != 0) {
            alloc = try allocationGetFree(&image.directory, text_mode == .Rand);
        }
        start_sector = 0;
    }
    if (text_mode == .Rand) {
        // Write the group index block.
        var sector: DiskSector = .initFormatted(image.image_type, group_map_location);
        sector.data.nbytes = @intCast(group_idx);
        sector.data.file_nr = @intCast(extent_nr + 1);
        sector.data.next_track = @intCast(group_map_location.track);
        sector.data.next_sector = @intCast(group_map_location.sector + 1);
        @memcpy(sector.dataBytes(), group_map[0..128]);
        try image.writeSector(group_map_location, &sector);
        group_map_location.sector += 1;
        sector = .initFormatted(image.image_type, group_map_location);
        sector.data.nbytes = @intCast(group_idx);
        sector.data.file_nr = @intCast(extent_nr + 1);
        sector.data.next_track = @intCast(group_map_location.track);
        sector.data.next_sector = @intCast(group_map_location.sector + 1);
        @memcpy(sector.dataBytes(), group_map[128..]);
        try image.writeSector(group_map_location, &sector);
    }

    image.directory.cooked_directories.appendAssumeCapacity(try new_entry.cook(image, extent_nr));
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
pub fn rawEntryWrite(image: *DiskImage, extent_nr: u16) (WriteSectorError || RawDirError)!void {
    const entries_per_sector = image.image_type.dirs_per_sector;
    const this_entry = &image.directory.raw_directories.ados.items[extent_nr];
    if (!this_entry.isDeleted()) {
        try this_entry.validate(image.image_type, extent_nr);
    }

    // 16 bytes per directory entry. Directory start at Track 70
    const location: PhysicalAddress = .{ .track = image.image_type.OS.ados.directory_track, .sector = extent_nr / entries_per_sector };
    var sector: DiskSector = .initFormatted(image.image_type, location);

    // start_index is the index of the directory entry that is at
    // the beginning of this sector
    const start_index = extent_nr / entries_per_sector * entries_per_sector;
    // Copy 1 full sector worth of extents/raw entries
    @memcpy(sector.dataBytes(), std.mem.sliceAsBytes(image.directory.raw_directories.ados.items[start_index .. start_index + entries_per_sector]));
    try image.writeSector(location, &sector);
}

pub fn clearErasedSectors(image: *DiskImage, raw_item: *DirEntry) (error{ WriteFailed, InvalidAllocation } || ReadSectorError)!void {
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
        sector.data.file_nr = 0;
        sector.data.nbytes = 0;
        sector.data.next_sector = 0;
        sector.data.next_track = 0;
        try image.writeSector(location, &sector);
        if (sector_nr % image.image_type.sectors_per_alloc == 0) {
            const alloc = try toAllocation(image.image_type, location);
            try setAllocation(&image.directory, alloc);
        }
        track_nr = sector.data.next_track;
        sector_nr = sector.data.next_sector;
    }
}

/// Return a free allocation
pub fn allocationGetFree(dir: *DirectoryTable, for_random_access: bool) error{ OutOfAllocs, InvalidAllocation }!u16 {
    // Allocations are performed in the order track 71 to track 76
    // Then from track 69 down to 6
    const allocs_per_track = dir.image_type.sectors_per_track / dir.image_type.sectors_per_alloc;

    if (!for_random_access) {
        for (dir.image_type.OS.ados.directory_track + 1..dir.image_type.tracks) |track_nr| {
            for (0..allocs_per_track) |alloc_in_track| {
                const alloc_nr = (track_nr - dir.image_type.reserved_tracks) * allocs_per_track + alloc_in_track;
                if (dir.free_allocations.isSet(alloc_nr)) {
                    try unsetAllocation(dir, @intCast(alloc_nr));
                    return @intCast(alloc_nr);
                }
            }
        }

        // Then look for free allocs from track 69 downwards
        if (dir.free_allocations.findLastSet()) |free| {
            // This will return the last alloc on the track. But we need to
            // allocate from the first alloc for the track, upwards.
            const first_alloc = free / allocs_per_track * allocs_per_track;
            for (first_alloc..first_alloc + allocs_per_track) |alloc| {
                if (dir.free_allocations.isSet(alloc)) {
                    try unsetAllocation(dir, @intCast(alloc));
                    return @intCast(alloc);
                }
            }
            unreachable;
        }
        return error.OutOfAllocs;
    } else { // Randomn access
        var track: u8 = dir.image_type.OS.ados.directory_track - 1;
        while (track != 0 and track >= dir.image_type.reserved_tracks) : (track -= 1) {
            for (0..allocs_per_track) |offset| {
                const alloc = (track - dir.image_type.reserved_tracks) * allocs_per_track + offset;
                if (dir.free_allocations.isSet(alloc)) {
                    try unsetAllocation(dir, @intCast(alloc));
                    return @intCast(alloc);
                }
            }
        }
        return error.OutOfAllocs;
    }
}

fn unsetAllocation(dir: *DirectoryTable, alloc: u16) error{InvalidAllocation}!void {
    if (alloc >= dir.free_allocations.capacity()) {
        logerr("Attempt to unset an invalid free allocation. [Allocation = {}. Must be 0 - {}]", .{ alloc, dir.free_allocations.capacity() - 1 });
        return error.InvalidAllocation;
    }
    dir.free_allocations.unset(alloc);
}

fn setAllocation(dir: *DirectoryTable, alloc: u16) error{InvalidAllocation}!void {
    if (alloc >= dir.free_allocations.capacity()) {
        logerr("Attempt to set an invalid free allocation. [Allocation = {}. Must be 0 - {}]", .{ alloc, dir.free_allocations.capacity() - 1 });
        return error.InvalidAllocation;
    }
    std.debug.assert(!dir.free_allocations.isSet(alloc));
    dir.free_allocations.set(alloc);
}

pub fn rawEntryGetFreeInitialized(image: *DiskImage, extent_nr: *u16) error{OutOfExtents}!*DirEntry {
    const dir = &image.directory;
    for (dir.raw_directories.ados.items[0..dir.raw_directories.ados.items.len -| 1], 0..) |*entry, i| {
        if (entry.isLastEntry()) {
            extent_nr.* = @intCast(i);
            entry.* = .last;
            // Set the next entry to be the last entry.
            dir.raw_directories.ados.items[i + 1] = .last;
            rawEntryWrite(image, @intCast(i + 1)) catch return error.OutOfExtents;
            return entry;
        } else if (entry.isDeleted()) {
            extent_nr.* = @intCast(i);
            entry.* = .empty;
            return entry;
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
const RawDirError = DirectoryTable.RawDirError;
const PhysicalAddress = disk_types.PhysicalAddress;
const CookedDirEntry = directory_table.CookedDirEntry;
const TextMode = DiskImage.TextMode;
const ReadSectorError = DiskImage.ReadSectorError;
const basic_file_decoder = @import("basic_file_decoder.zig");
