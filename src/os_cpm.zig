pub const log = std.log.scoped(.altair_disk_lib);
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

/// MITS 8" floppy disk format
///
/// Strange things to note:
/// 1) The skew algorithm for the first 6 tracks is different to the rest of the disk.
/// 2) The phsyical sector size is 137 bytes, with 128 bytes of that being data
/// 3) The rest of the sector contains control information such as track numbers, checksums and stop bits.
/// 4) The layout of this control data is different for the first 6 tracks vs the rest of the disk.
pub const DiskImageType_MITS_8IN = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [32]u16{
        0, 8,  16, 24, 2, 10, 18, 26,
        4, 12, 20, 28, 6, 14, 22, 30,
        1, 9,  17, 25, 3, 11, 19, 27,
        5, 13, 21, 29, 7, 15, 23, 31,
    };
    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .FDD_8IN,
            .type_name = "FDD_8IN",
            .description = "MITS 8\" Floppy Disk (CPM)",
            .OS = .cpm,
            .tracks = 77,
            .reserved_tracks = 2,
            .sectors_per_track = 32,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 2048,
            .directories = 64,
            .reserved_allocs = 2,
            .image_size = 337568,
            .varying_sector_format = true,
            .skew_fn = skew,
            .skew_table = &skew_table,
        };
        result.init();
        return result;
    }

    /// For historical reasons, the skew changes based on the track number.
    fn skew(table: []const u16, track: u16, logical_sector: u16) u16 {
        if (track < 6)
            return table[logical_sector];

        return (((table[logical_sector]) * 17) % 32);
    }
};

/// The FDC+ controller supports an 8MB "floppy" disk
/// Has the same skew and 137 byte physical sectors as the
/// standard 8" drive.
pub const DiskImageType_MITS_8IN_8MB = struct {
    const skew_table = [32]u16{
        0, 8,  16, 24, 2, 10, 18, 26,
        4, 12, 20, 28, 6, 14, 22, 30,
        1, 9,  17, 25, 3, 11, 19, 27,
        5, 13, 21, 29, 7, 15, 23, 31,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .FDD_8IN_8MB,
            .type_name = "FDD_8IN_8MB",
            .description = "FDC+ 8MB \"Floppy\" Disk (CPM)",
            .OS = .cpm,
            .tracks = 2048,
            .reserved_tracks = 2,
            .sectors_per_track = 32,
            .sector_size_raw = 137,
            .sector_size_data = 128,
            .block_size = 4096,
            .directories = 512,
            .reserved_allocs = 4,
            .two_byte_allocs = true,
            .image_size = 8978432,
            .varying_sector_format = true,
            .skew_fn = DiskImageType_MITS_8IN.skew,
            .skew_table = &skew_table,
        };
        result.init();
        // FUTURE TODO: These should be calculated, correctly in init, instead of being set here.
        result.allocs_per_extent = 16;
        result.recs_per_extent = 256;
        return result;
    }
};

/// MITS 5MB HDD Format
pub const DiskImageType_MITS_5MB_HDD = struct {
    const skew_table = [_]u16{
        0,  1,  14, 15, 28, 29, 42, 43, 8,  9,  22, 23,
        36, 37, 2,  3,  16, 17, 30, 31, 44, 45, 10, 11,
        24, 25, 38, 39, 4,  5,  18, 19, 32, 33, 46, 47,
        12, 13, 26, 27, 40, 41, 6,  7,  20, 21, 34, 35,
        48, 49, 62, 63, 76, 77, 90, 91, 56, 57, 70, 71,
        84, 85, 50, 51, 64, 65, 78, 79, 92, 93, 58, 59,
        72, 73, 86, 87, 52, 53, 66, 67, 80, 81, 94, 95,
        60, 61, 74, 75, 88, 89, 54, 55, 68, 69, 82, 83,
    };

    pub fn init() DiskImageType {
        return initCommon(true);
    }

    // Split so that the 1024 directory entry version can share this init.
    pub fn initCommon(init_before_return: bool) DiskImageType {
        var result = DiskImageType{
            .type_id = .HDD_5MB,
            .type_name = "HDD_5MB",
            .description = "MITS 5MB Hard Disk (CPM)",
            .OS = .cpm,
            .tracks = 406,
            .reserved_tracks = 1,
            .sectors_per_track = 96,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 4096,
            .directories = 256,
            .reserved_allocs = 2,
            .two_byte_allocs = true,
            .image_size = 4988928,
            .varying_sector_format = false,
            .skew_table = &skew_table,
        };
        if (init_before_return)
            result.init();
        result.recs_per_extent = 256;
        result.allocs_per_extent = 8;
        return result;
    }
};

/// MITS 5MB HDD Format with 1024 directory entries
/// Note that a freshly formatted version of this and the
/// normal disk are indistinguishable!
pub const DiskImageType_MITS_5MB_HDD_1024 = struct {
    pub fn init() DiskImageType {
        var result = DiskImageType_MITS_5MB_HDD.initCommon(false);
        result.type_id = .HDD_5MB_1024;
        result.type_name = "HDD_5MB_1024";
        result.description = "MITS 5MB, with 1024 directories (CPM)";
        result.directories = 1024;
        result.init();

        result.recs_per_extent = 256;
        result.allocs_per_extent = 8;
        result.reserved_allocs = 8;

        return result;
    }
};

// Tarbell floppy disk format
pub const DiskImageType_TARBELL_FDD = struct {
    const skew_table = [_]u16{
        0,  6,  12, 18, 24, 4,  10, 16,
        22, 2,  8,  14, 20, 1,  7,  13,
        19, 25, 5,  11, 17, 23, 3,  9,
        15, 21,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .FDD_TAR,
            .type_name = "FDD_TAR",
            .description = "Tarbell Floppy Disk (CPM)",
            .OS = .cpm,
            .tracks = 77,
            .reserved_tracks = 2,
            .sectors_per_track = 26,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 1024,
            .directories = 64,
            .reserved_allocs = 2,
            .image_size = 256256,
            .varying_sector_format = false,
            .skew_table = &skew_table,
        };
        result.init();
        return result;
    }
};

// FDC+ controller supports 1.5MB floppy disks
pub const @"DiskImageType_FDD_1.5MB" = struct {
    const skew_table = [_]u16{
        0,  1,  2,  3,  4,  5,  6,  7,
        8,  9,  10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31,
        32, 33, 34, 35, 36, 37, 38, 39,
        40, 41, 42, 43, 44, 45, 46, 47,
        48, 49, 50, 51, 52, 53, 54, 55,
        56, 57, 58, 59, 60, 61, 62, 63,
        64, 65, 66, 67, 68, 69, 70, 71,
        72, 73, 74, 75, 76, 77, 78, 79,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .@"FDD_1.5MB",
            .type_name = "FDD_1.5MB",
            .description = "FDC+ 1.5MB Floppy Disk (CPM)",
            .OS = .cpm,
            .tracks = 149,
            .reserved_tracks = 1,
            .sectors_per_track = 80,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 4096,
            .directories = 256,
            .reserved_allocs = 2,
            .two_byte_allocs = true,
            .image_size = 1525760,
            .varying_sector_format = false,
            .skew_table = &skew_table,
        };
        result.init();
        // This should be calculated correctly in init, instead of being set here.
        result.allocs_per_extent = 16;
        return result;
    }
};

pub const DiskImageType_CPM_MINI = struct {
    const skew_table = [16]u16{
        0, 2, 4, 6, 8, 10, 12, 14,
        1, 3, 5, 7, 9, 11, 13, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;
    const reserved_tracks = 4;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CPM_MINI,
            .type_name = "CPM_MINI",
            .description = "MITS 5.25\" Floppy Disk (CPM)",
            .OS = .cpm,
            .tracks = 35,
            .reserved_tracks = reserved_tracks,
            .sectors_per_track = 16,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 32,
            .reserved_allocs = 1,
            .image_size = 76720,
            .varying_sector_format = true,
            .skew_table = &skew_table,
        };
        result.init();
        return result;
    }
};

/// Raw on-disk version of the CPM directory entry
pub const DirEntry = extern struct {
    user: u8,
    filename: [8]u8,
    filetype: [3]u8,
    extent_low: u8,
    reserved: u8,
    extent_hi: u8,
    num_records: u8,
    /// Prefer to access via allocationGet and allocationSet.
    /// Can be 8 or 16 bit depending on the image type.
    allocations: [16]u8,

    pub const empty: DirEntry = std.mem.zeroes(DirEntry);
    pub const filename_len = 8;
    pub const filetype_len = 3;

    pub fn cook(raw_dir: *const DirEntry, arena: std.mem.Allocator, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!CookedDirEntry {
        var filename: [CookedDirEntry.filename_max]u8 = @splat(' '); // space terminated string

        var len = CookedDirEntry.rawStrlen(&raw_dir.filename);
        @memcpy(filename[0..len], raw_dir.filename[0..len]);

        // Remove status bits, encoded in bit 8 of first 2 chars
        for (filename[0..2], 0..) |c, i| {
            filename[i] = c & 0x7f;
        }

        if (raw_dir.filetype[0] != ' ') {
            filename[len] = '.';
            len += 1;
            @memcpy(filename[len .. len + 3], &raw_dir.filetype);

            if (len + 3 < 12)
                filename[len + 3] = ' ';
        }

        var result = CookedDirEntry{
            .user = raw_dir.user,
            .attribs = [_]u8{
                if (raw_dir.attribReadOnly()) 'R' else 'W',
                if (raw_dir.attribSystem()) 'S' else ' ',
            },
            .os = .{ .cpm = .{
                .num_records = raw_dir.num_records,
                .num_allocs = 0,
            } },
            .filename = filename,
            .allocations = .empty,
            .size_in_bytes = undefined,
            .used_in_kbytes = undefined,
            .has_extension = true,
        };
        result.os.cpm.num_allocs = try copyAllocations(&result, arena, raw_dir, image_type);
        if (image_type.OS == .cpm and image_type.recs_per_extent > 128 and result.os.cpm.num_allocs > 4) {
            // CPM records only go up to 128, but can represent up to 256 records.
            result.os.cpm.num_records += 128;
        }
        result.size_in_bytes = result.os.cpm.num_records * 128;
        result.used_in_kbytes = result.os.cpm.num_allocs * image_type.block_size / 1024;
        return result;
    }

    pub fn validate(self: *const DirEntry, image_type: *const DiskImageType, extent_nr: u16) RawDirError!void {
        if (self.user > DiskImageType.max_user and self.user != 0xe5 and self.user != 0x81) {
            logerr(
                "Invalid directory entry: {} [Invalid user: {}. Must be 0-{} or {}]",
                .{ extent_nr, self.user, DiskImageType.max_user, 0xe5 },
            );
            return RawDirError.InvalidUser;
        }

        const max_entents = image_type.dirs_per_alloc * image_type.total_allocs;
        if (self.extentGet(image_type) >= max_entents) {
            logerr(
                "Invalid directory entry: {} [Invalid extent: {}. Must be 0-{}]",
                .{ extent_nr, self.extentGet(image_type), max_entents },
            );
            return RawDirError.InvalidExtent;
        }

        if (self.num_records > 128) {
            logerr(
                "Invalid directory entry: {} [Invalid num_records: {}. Must be 0-{}]",
                .{ extent_nr, self.num_records, 128 },
            );
            return RawDirError.InvalidRecordNumber;
        }
        for (0..self.allocationsCount(image_type)) |i| {
            const alloc = try self.allocationGet(@intCast(i), image_type);
            if (alloc > image_type.total_allocs) {
                logerr(
                    "Invalid directory entry: {} [Invalid allocation: {}. Must be 0-{}]",
                    .{ extent_nr, alloc, image_type.total_allocs },
                );
                return RawDirError.InvalidAllocation;
            }
        }
    }

    pub fn isDeleted(self: *const DirEntry) bool {
        return self.user > DiskImageType.max_user;
    }

    /// is this a disk label, instead of a normal dir entry?
    pub fn isLabel(self: *const DirEntry) bool {
        return self.user == 0x81;
    }

    pub fn setDeleted(self: *DirEntry) void {
        self.user = 0xe5;
    }

    /// Set num_records field.
    pub fn numRecordsSet(self: *DirEntry, record_nr: u16) void {
        self.num_records = @intCast((record_nr % 128) + 1);
    }

    /// Get extent as 16 bit value
    pub fn extentGet(self: *const DirEntry, image_type: *const DiskImageType) u16 {
        if (image_type.OS == .cpm) {
            return @as(u16, self.extent_hi) * 32 + self.extent_low;
        } else {
            return @as(u16, self.extent_hi) * 255 + self.extent_low;
        }
    }

    /// Set extent from 16 bit value
    pub fn extentCountSet(self: *DirEntry, extent_count: u16, image_type: *const DiskImageType) void {
        if (image_type.OS == .cpm) {
            self.extent_low = @intCast(extent_count % 32);
            self.extent_hi = @intCast(extent_count / 32);
        } else {
            self.extent_low = @intCast(extent_count % 256);
            self.extent_hi = @intCast(extent_count / 256);
        }
    }

    pub fn attribReadOnly(self: *const DirEntry) bool {
        return self.filename[0] & 0x80 != 0;
    }

    pub fn attribSystem(self: *const DirEntry) bool {
        return self.filename[1] & 0x80 != 0;
    }

    /// Set allocation as controlled by this extent
    pub fn allocationSet(self: *DirEntry, entry_nr: usize, alloc_nr: u16, image_type: *const DiskImageType) RawDirError!void {
        if (entry_nr >= self.allocationsCount(image_type)) {
            return RawDirError.InvalidEntryNumber;
        }
        if (!image_type.two_byte_allocs) {
            // 8 bit allocations
            self.allocations[entry_nr] = @intCast(alloc_nr & 0xff);
        } else {
            // 16 bit allocations.
            var alloc: [2]u8 = undefined;
            std.mem.writeInt(u16, &alloc, alloc_nr, .little);
            self.allocations[entry_nr * 2] = alloc[0];
            self.allocations[entry_nr * 2 + 1] = alloc[1];
        }
    }

    /// Get the number of an allocation controlled by this extent
    pub fn allocationGet(self: *const DirEntry, entry_nr: usize, image_type: *const DiskImageType) RawDirError!u16 {
        if (entry_nr >= self.allocationsCount(image_type)) {
            return RawDirError.InvalidEntryNumber;
        }

        if (!image_type.two_byte_allocs) {
            return self.allocations[entry_nr];
        } else {
            const alloc: [2]u8 = .{ self.allocations[entry_nr * 2], self.allocations[entry_nr * 2 + 1] };
            return std.mem.readInt(u16, &alloc, .little);
        }
    }

    /// How many allocations are controlled by this extent?
    pub fn allocationsCount(_: *const DirEntry, image_type: *const DiskImageType) u16 {
        return if (image_type.two_byte_allocs)
            @min(8, image_type.allocs_per_extent)
        else
            @min(16, image_type.allocs_per_extent);
    }

    pub fn filenameAndExtensionSet(self: *DirEntry, filename: []const u8) void {
        const dot_pos = std.mem.indexOfScalar(u8, filename, '.') orelse filename.len;
        self.filename = @splat(' ');
        self.filetype = @splat(' ');
        @memcpy(self.filename[0..dot_pos], filename[0..dot_pos]);
        if (dot_pos != filename.len) {
            const type_len = @min(self.filetype.len + 1, filename.len - dot_pos - 1);
            @memcpy(self.filetype[0..type_len], filename[dot_pos + 1 .. dot_pos + type_len + 1]);
        }
    }

    pub fn isFirstEntryForFile(self: *const DirEntry, image_type: *const DiskImageType) bool {
        if (image_type.OS == .cpm and image_type.recs_per_extent > 128 and self.allocations[4] != 0 and self.extentGet(image_type) == 1) {
            return true;
        }
        return self.extentGet(image_type) == 0;
    }

    pub fn eql(self: *const DirEntry, cooked_dir: *const CookedDirEntry) bool {
        return (self.user == cooked_dir.user and
            std.mem.eql(u8, CookedDirEntry.rawSlice(&self.filename), cooked_dir.filenameOnly()) and
            std.mem.eql(u8, CookedDirEntry.rawSlice(&self.filetype), cooked_dir.extensionOnly()));
    }

    pub fn lessThan(img_type: *const DiskImageType, lhs: *DirEntry, rhs: *DirEntry) bool {
        if (std.mem.eql(u8, &lhs.filename, &rhs.filename)) {
            if (std.mem.eql(u8, &lhs.filetype, &rhs.filetype)) {
                if (lhs.user == rhs.user) {
                    return lhs.extentGet(img_type) < rhs.extentGet(img_type);
                } else {
                    return lhs.user < rhs.user;
                }
            } else {
                return std.mem.lessThan(u8, &lhs.filetype, &rhs.filetype);
            }
        } else {
            return std.mem.lessThan(u8, &lhs.filename, &rhs.filename);
        }
    }
};

/// Directory entries keep track of a logical address consisting of:
/// 1) An allocation representing 1 block. Allocations start at 0.
/// 2) A record representing a 128k segment within the block, starting at 1
pub const LogicalAddress = struct {
    allocation: u16,
    record: u8,
};

/// Add any new allocations to the list of used allocations.
fn copyAllocations(cooked: *CookedDirEntry, arena: std.mem.Allocator, raw: *const DirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!u8 {
    var alloc_count: u8 = 0;

    try cooked.allocations.ensureUnusedCapacity(arena, raw.allocations.len);
    for (0..raw.allocationsCount(image_type)) |alloc_nr| {
        const allocation = try raw.allocationGet(alloc_nr, image_type);
        // zero means no more allocations.
        if (allocation == 0) {
            break;
        }
        cooked.allocations.appendAssumeCapacity(allocation);
        alloc_count += 1;
    }
    return alloc_count;
}

pub fn loadDirectory(image: *DiskImage, option: DirectoryTable.LoadOption) DirectoryTable.DirectoryLoadError!void {
    const dir = &image.directory;
    const image_type = image.image_type;
    var sector: DiskSector = undefined;
    const directory_sector_count = image_type.directories / image_type.dirs_per_sector;
    var sector_nr: u16 = 0;

    // Reserve allocations used for directories
    for (0..image_type.reserved_allocs) |i| {
        dir.free_allocations.unset(i);
    }

    while (sector_nr < directory_sector_count) : ({
        sector_nr += 1;
    }) {
        const logical_address = LogicalAddress{
            .allocation = sector_nr / (image_type.block_size / image_type.sector_size_data),
            .record = @intCast(sector_nr % image_type.recs_per_alloc),
        };
        // Read the raw CPM directory entries and add them to the raw_directories array.
        try readSectorLogical(image, logical_address, &sector);
        const entries: []DirEntry = std.mem.bytesAsSlice(DirEntry, sector.dataBytes());

        dir.raw_directories.cpm.appendSliceAssumeCapacity(entries);
    }

    // For CDOS, Check that the number of directories etc is the "default" value for that disk
    // Support for other directories counts is a FUTURE TODO
    if (dir.image_type.OS == .cdos and dir.raw_directories.cpm.items.len > 0 and dir.raw_directories.cpm.items[0].isLabel()) {
        const raw_item = dir.raw_directories.cpm.items[0];
        const expected_num_records: u8 = switch (image_type.type_id.toCDOS()) {
            .CDOS_SMSSSD, .CDOS_SMDSSD, .CDOS_SMSSDD, .CDOS_LGSSSD => 0x10,
            .CDOS_LGSSDD, .CDOS_LGDSSD, .CDOS_SMDSDD => 0x20,
            .CDOS_LGDSDD => 0x40,
        };
        if (expected_num_records != raw_item.num_records) {
            if (!@import("builtin").is_test) logerr(
                "CDOS disks with a non-default number of directories are not currently supported. Expected {}, actual {}",
                .{ @as(u16, expected_num_records) * 4, @as(u16, raw_item.num_records) * 4 },
            );
            return error.InvalidImageFile;
        }
    }

    // building the cooked dirs needs sorted raw_dirs.
    var raw_dirs_sorted: std.ArrayList(*DirEntry) = try .initCapacity(dir.allocator(), dir.raw_directories.cpm.items.len);
    defer raw_dirs_sorted.deinit(dir.allocator());
    for (dir.raw_directories.cpm.items) |*raw_dir| {
        raw_dirs_sorted.appendAssumeCapacity(raw_dir);
    }
    std.mem.sort(*DirEntry, raw_dirs_sorted.items, image.image_type, DirEntry.lessThan);

    // Create the CookedDirEntries and remove any used allocations from the free alocations set.
    for (raw_dirs_sorted.items, 0..) |entry, i| {
        if (!entry.isDeleted()) {
            const entry_nr = (@intFromPtr(entry) - @intFromPtr(&dir.raw_directories.cpm.items[0])) / @sizeOf(DirEntry);
            if (option == .full) {
                buildCookedEntry(dir, @intCast(entry_nr)) catch |err|
                    switch (err) {
                        error.InvalidUser,
                        error.InvalidExtent,
                        error.InvalidRecordNumber,
                        error.InvalidAllocation,
                        error.InvalidEntryNumber,
                        error.InvalidDirectoryEntry,
                        => {
                            logerr(
                                "Directory entry {} for \"{s}\" has invalid directory entries and has been hidden. Use --recover to try and recover the image: {t}",
                                .{ i, std.mem.trimEnd(u8, &entry.filename, " "), err },
                            );
                            continue;
                        },
                        error.OutOfMemory,
                        error.InvalidImageFile,
                        => return err,
                    };
            }
            // Mark off the used allocations
            for (0..entry.allocationsCount(image_type)) |alloc_nr| {
                const alloc = try entry.allocationGet(alloc_nr, image_type);
                // 0 marks the end of the used allocations in this extent.
                if (alloc == 0)
                    break;
                if (alloc >= image_type.total_allocs) {
                    logerr(
                        "Invalid directory entry: {} [Invalid allocation: {}. Must be 0-{}]",
                        .{ i, alloc, image_type.total_allocs },
                    );
                } else {
                    dir.free_allocations.unset(alloc);
                }
            }
        }
    }

    // Note you cannot rely on this list remaining sorted during any operation that manipulates the
    // raw directory entries. Filename searches will need to traverse the whole list.
    // If this starts getting used alot, it would be worth making it a HashArray to give easy lookups, while still
    // keeping the contents stored in a sortable array.
    std.mem.sort(CookedDirEntry, dir.cooked_directories.items, {}, struct {
        fn lessThan(_: void, lhs: CookedDirEntry, rhs: CookedDirEntry) bool {
            if (!std.mem.eql(u8, lhs.filenameAndExtension(), rhs.filenameAndExtension())) {
                return std.mem.lessThan(u8, lhs.filenameAndExtension(), rhs.filenameAndExtension());
            }
            return lhs.user < rhs.user;
        }
    }.lessThan);
}

/// Whenever a new extent is created, register it with the directory
/// Builds up the associated CookedDirEntry as new RawDirEntries are registered.
pub fn buildCookedEntry(dir: *DirectoryTable, raw_entry_idx: u16) (error{ OutOfMemory, InvalidImageFile } || RawDirError)!void {
    const entry = &dir.raw_directories.cpm.items[raw_entry_idx];
    try entry.validate(dir.image_type, raw_entry_idx);
    if (entry.isFirstEntryForFile(dir.image_type)) {
        try dir.cooked_directories.append(dir.allocator(), try entry.cook(dir.allocator(), dir.image_type));
    } else {
        if (dir.cooked_directories.items.len == 0) {
            logerr("Cannot detect first entry for file {s}.{s}: ", .{ entry.filename, entry.filetype });
            return error.InvalidImageFile;
        }
        const prev = &dir.cooked_directories.items[dir.cooked_directories.items.len - 1];
        try extendCookedEntry(prev, dir.allocator(), entry, dir.image_type);
    }
}

pub fn extendCookedEntry(dir: *CookedDirEntry, arena: std.mem.Allocator, raw_dir: *const DirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!void {
    dir.os.cpm.num_records += raw_dir.num_records;
    const num_allocs = try copyAllocations(dir, arena, raw_dir, image_type);
    dir.os.cpm.num_allocs += num_allocs;
    if (image_type.recs_per_extent > 128 and num_allocs > 4) {
        dir.os.cpm.num_records += 128;
    }
}

/// Turn any "host" filename into a valid CPM filename.
///
/// Check that the passed in filename can be represented as "8.3"
/// CPM Manual says that filenames cannot include:
/// < > . , ; : = ? * [ ] % | ( ) / \
/// while all alphanumerics and remaining special characters are allowed.
/// We'll also enforce that it is at least a "printable" character
/// as the 8th bit of the first 2 filename chars are used for attributes
/// Note that CPM filenames permit a subset of filenames on modern OS's, except for ", which
/// is not allowed on Windows. So no need to have a "reverse" translation of CPM to local filenames.
pub fn translateFilename(filename: []const u8, buffer: []u8) error{InvalidFilename}![]u8 {
    var found_dot: bool = false;
    var char_count: usize = 0;
    var ext_count: usize = 0;
    const end_in = filename.ptr + filename.len;
    var in_char: [*]const u8 = filename.ptr; // Caution! Not bounds checked
    var out_char: [*]u8 = buffer.ptr; // Caution! Not bounds checked
    const filename_len = DirEntry.filename_len;
    const ext_len = DirEntry.filetype_len;
    const full_len = filename_len + ext_len + 1; // + 1 for dot
    while (in_char != end_in) {
        const valid_char = switch (in_char[0]) {
            // zig fmt: off
                '<', '>', ',', ';', ':', 
                '?', '*', '[', ']', '%', 
                '|', '(', ')', '/', '\\', => false,
                // zig fmt: on
            else => true,
        };

        if (std.ascii.isPrint(in_char[0]) and valid_char) {
            if (in_char[0] == '.') {
                if (found_dot) {
                    in_char += 1;
                    continue;
                }
                found_dot = true;
            }
            out_char[0] = std.ascii.toUpper(in_char[0]);
            out_char += 1;
            char_count += 1;

            if (char_count == filename_len and !found_dot and in_char + 1 != end_in) {
                out_char[0] = '.';
                out_char += 1;
                char_count += 1;
                found_dot = true;

                while (in_char[0] == '.' and in_char != end_in) {
                    in_char += 1;
                }
                while (in_char[0] != '.' and in_char != end_in) {
                    in_char += 1;
                }
            }
            if (char_count == full_len) {
                break;
            }

            if (found_dot) {
                if (ext_count == ext_len)
                    break;
                ext_count += 1;
            }
        }
        in_char += 1;
    }
    log.info("Translated filename {s} to {s}", .{ filename, buffer[0..char_count] });

    if (char_count <= 1) {
        return error.InvalidFilename;
    } else {
        return buffer[0..char_count];
    }
}

pub fn copyFromImage(image: *DiskImage, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) !void {
    const num_records = entry.os.cpm.num_records;
    // Check for empty file.
    if (entry.allocations.items.len == 0) {
        return;
    }
    const recs_per_sector = (image.image_type.sector_size_data / 128); // Recs always represent 128 bytes
    const num_sectors = (num_records + recs_per_sector - 1) / recs_per_sector;
    var total_rec_nr: u16 = 0;
    for (0..num_sectors) |sec_nr| {
        // We should not longer be able to trigger this. Left for safety.
        const alloc_idx = total_rec_nr / image.image_type.recs_per_alloc;
        if (alloc_idx >= entry.allocations.items.len) {
            logerr("FATAL ERROR: num_records = {}, num_sectors = {}, total_rec_nr = {}, alloc_idx = {}, recs_per_alloc = {}, allocs.len = {}, total_allocs = {} num records = {}\n", .{
                num_records,
                num_sectors,
                total_rec_nr,
                alloc_idx,
                image.image_type.recs_per_alloc,
                entry.allocations.items.len,
                image.image_type.total_allocs,
                entry.os.cpm.num_records,
            });
            return error.InvalidRecordNumber;
        }
        const alloc = entry.allocations.items[alloc_idx];
        if (alloc == 0)
            break;
        var sector: DiskSector = undefined;
        try readSectorLogical(image, .{ .record = @intCast(sec_nr % image.image_type.recs_per_alloc), .allocation = alloc }, &sector);
        // If it is the last sector. then adjust the data length to the 128B record count, rather than just assuming a full sector
        var data_len: usize = if (sec_nr == num_sectors - 1)
            (((num_records - 1) % recs_per_sector) + 1) * 128
        else
            sector.dataLen();
        const check_for_text = text_mode != .Binary;

        // CPM doesn't actually know how long a file is, except in multiples of 128 byte records.
        // So if it is a text file looks for ^Z anywhere in the last sector and use that
        // to mark the EOF. For binary files it doesn't matter if they are too long.
        // Really we only need to check the last record (128 bytes), but we check the whole last sector.
        if (check_for_text and sec_nr == num_sectors - 1) {
            for (sector.dataBytes(), 0..) |b, i| {
                if (text_mode == .Auto) {
                    if (b & 0x80 != 0) {
                        break;
                    }
                }

                if (b == 0x1a) {
                    data_len = i;
                    break;
                }
            }
        }
        try out_writer.writeAll(sector.dataBytes()[0..data_len]);
        total_rec_nr += recs_per_sector;
    }
}

pub fn copyToImage(image: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, user: ?u8, force: bool) !void {
    const cpm_user = user orelse 0;
    const basename = std.fs.path.basename(to_filename);
    var conversion_buf: [CookedDirEntry.filename_max]u8 = undefined;
    const cpm_filename = try translateFilename(basename, &conversion_buf);
    if (image.directory.findByFilename(cpm_filename, user)) |existing_entry| {
        if (force) {
            try image.erase(existing_entry);
        } else {
            return std.Io.File.OpenError.PathAlreadyExists;
        }
    }

    var file_buffer: [DiskSector.sector_size_max]u8 = @splat(0xe5);
    const file_data = file_buffer[0..image.image_type.sector_size_data];

    var extent_nr: u16 = undefined;
    var alloc_nr: u16 = undefined;
    // The number of records at the start of the sector.
    // Used to determine when to create a new extent or request a new allocation.
    // always increment in sector_size_data / 128 increments.
    var record_nr: u16 = 0;
    var extent_count: u16 = 0;
    var alloc_count: u16 = 0;
    // Will be record_nr + the number of records required to process the bytes just
    // read from the file. Used to store the record count in the directory entry.
    var num_records: u16 = 0;
    var sector_count: u16 = 0;

    var nbytes = try file_reader.readSliceShort(file_data);
    // Set any unused portion of the current record to ^Z
    // The rest of the unused portion of the sector is filled with 0xe5
    @memset(file_data[nbytes .. (nbytes + 127) / 128 * 128], 0x1a);

    // short circuit handling on zero-length files.
    if (nbytes == 0) {
        var raw_entry = try rawEntryGetFreeInitialized(&image.directory, &extent_nr);
        raw_entry.filenameAndExtensionSet(cpm_filename);
        raw_entry.user = cpm_user;
        try rawEntryWrite(image, extent_nr);
        try buildCookedEntry(&image.directory, extent_nr);
        return;
    }

    var dir_entry: *DirEntry = undefined;
    while (nbytes != 0) {
        num_records += @intCast((nbytes + 127) / 128);
        // Is this a new extent?
        if (record_nr % image.image_type.recs_per_extent == 0) {
            if (record_nr > 0) {
                try buildCookedEntry(&image.directory, extent_nr);
                extent_count += 1;
            }
            dir_entry = try rawEntryGetFreeInitialized(&image.directory, &extent_nr);
            dir_entry.filenameAndExtensionSet(cpm_filename);
            dir_entry.user = cpm_user;
            alloc_count = 0;
        }
        // Is this a new allocation?
        if (record_nr % image.image_type.recs_per_alloc == 0) {
            alloc_nr = try allocationGetFree(&image.directory);
            const raw_entry = &image.directory.raw_directories.cpm.items[extent_nr];
            try raw_entry.allocationSet(alloc_count, alloc_nr, image.image_type);
            alloc_count += 1;
        }

        // For formats that support 256 records per extent (actually 255. 0 means no records)
        // The 128th record is represented as extent number + 1 with record_count reset to 0
        // This means odd extent numbers have > 127 records and even ones have <= 127 records.
        if (image.image_type.recs_per_extent == 256 and
            record_nr % 128 == 0 and
            record_nr % 256 != 0)
        {
            extent_count += 1;
        }

        // Note technically this should take the record number within the allocation.
        // But instead it is being passed the sector number. It's easier to work this method
        // rather than the correct CPM way and gives the same results.
        const location = toPhysicalAddress(image, .{ .allocation = alloc_nr, .record = @intCast(sector_count % image.image_type.recs_per_extent) });
        var sector: DiskSector = .initFormatted(image.image_type, location);
        @memcpy(sector.dataBytes(), file_data);
        try image.writeSector(location, &sector);

        dir_entry.num_records = @intCast((num_records - 1) % 128 + 1);
        dir_entry.extentCountSet(extent_count, image.image_type);
        try rawEntryWrite(image, extent_nr);
        @memset(file_data, 0xe5);
        nbytes = try file_reader.readSliceShort(file_data);
        @memset(file_data[nbytes .. (nbytes + 127) / 128 * 128], 0x1a);

        // record_nr always advances by full records to ensure that
        // new directory entries are created and new allocs assigned for short-reads
        // on the last read of the file.
        record_nr += image.image_type.sector_size_data / 128;
        sector_count += 1;
    }

    try buildCookedEntry(&image.directory, extent_nr);

    // How copying works:
    //
    // Each directory entry controls one "extent", which will control a maximum of 8 allocations.
    // Each allocation represents one block. So if block size is 2048, each extent will be a maximum of 16KB.
    // Each extent can control up to 128 records, where each record controls a single sector of 128 bytes.
    // For sectors > 128 bytes, each record controls 128 bytes within that sector.
    // To store a file, need to do the following:
    //
    // For each sector. Increment the record number.
    // If reach # recs / extent, create a new directory entry
    // If reach # recs / alloc, then find a new free allocation and add it to the entry.
    //
    // For some formats, two extents are packed into 1 directory entry. In this case, the
    // first extent will be numbered 0, but on the 129th record, the same dir entry is used
    // and the extent number be changed from 1 to 0. The "hidden" extent controls the first 4 allocations
    // in the directory entry.
    // Odd-numbered extents indicate that there is a missing even-numbered extent.
    // The code treats this as a single extent of 256 records for simplicity.
}

/// Return a free CPM directory entry
pub fn rawEntryGetFreeInitialized(dir: *const DirectoryTable, extent_nr: *u16) error{OutOfExtents}!*DirEntry {
    for (dir.raw_directories.cpm.items, 0..) |*entry, i| {
        if (entry.isDeleted() and !entry.isLabel()) {
            extent_nr.* = @intCast(i);
            entry.* = .empty;
            return entry;
        }
    }
    return error.OutOfExtents;
}

pub fn allocationGetFree(dir: *DirectoryTable) error{OutOfAllocs}!u16 {
    if (dir.free_allocations.findFirstSet()) |free_alloc| {
        dir.free_allocations.unset(free_alloc);
        return @intCast(free_alloc);
    } else {
        return error.OutOfAllocs;
    }
}

/// write a CPM diretory entry (RawDirEntry)
pub fn rawEntryWrite(image: *DiskImage, extent_nr: u16) (WriteSectorError || RawDirError)!void {
    // Make sure entry is valid before written.
    const this_entry = &image.directory.raw_directories.cpm.items[extent_nr];
    if (!this_entry.isDeleted()) {
        try this_entry.validate(image.image_type, extent_nr);
    }

    const location = toPhysicalAddress(image, .{ .allocation = extent_nr / image.image_type.dirs_per_alloc, .record = @intCast(extent_nr / image.image_type.dirs_per_sector) });
    var sector: DiskSector = .initFormatted(image.image_type, location);

    // start_index is the index of the directory entry that is at
    // the beginning of this sector
    const start_index = extent_nr / image.image_type.dirs_per_sector * image.image_type.dirs_per_sector;
    // Copy 1 full sector worth of extents/raw entries
    @memcpy(sector.dataBytes(), std.mem.sliceAsBytes(image.directory.raw_directories.cpm.items[start_index .. start_index + image.image_type.dirs_per_sector]));
    try image.writeSector(location, &sector);
}

fn toPhysicalAddress(image: *const DiskImage, address: LogicalAddress) PhysicalAddress {
    const sectors_per_alloc = image.image_type.sectors_per_alloc;

    const absolute_sector = address.allocation * sectors_per_alloc + (address.record % sectors_per_alloc);
    const track: u16 = image.image_type.reserved_tracks + (absolute_sector / image.image_type.sectors_per_track);
    const logical_sector = absolute_sector % image.image_type.sectors_per_track;

    log.debug("ALLOCATION[{}], RECORD[{}], ", .{ address.allocation, address.record });
    return PhysicalAddress{ .track = track, .sector = logical_sector };
}

/// Read a single sector using record, allocation format
pub fn readSectorLogical(image: *DiskImage, location: LogicalAddress, sector: *DiskSector) ReadSectorError!void {
    const physical_location = toPhysicalAddress(image, location);

    try image.readSector(physical_location, sector);
}

const std = @import("std");
const Io = std.Io;

const disk_types = @import("disk_types.zig");
const disk_image = @import("disk_image.zig");
const directory_table = @import("directory_table.zig");

const DiskImageType = disk_types.DiskImageType;
const DiskImage = disk_image.DiskImage;
const RawDirError = DirectoryTable.RawDirError;
const WriteSectorError = DiskImage.WriteSectorError;
const DiskSector = disk_types.DiskSector;
const CookedDirEntry = directory_table.CookedDirEntry;
const TextMode = DiskImage.TextMode;
const DirectoryTable = directory_table.DirectoryTable;
const PhysicalAddress = disk_types.PhysicalAddress;
const ReadSectorError = DiskImage.ReadSectorError;
