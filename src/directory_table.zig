//!
//! List of files / directory entries contained on the disk image.
//! Contains:
//! 1) RawDirEntrys that hold a copy of the directory entry structure on the disk image
//! 2) CookedDirEntrys that provide a simpler interface for interacting with the
//!    cpm directory table.
//! 3) The free allocation table.
//!

const log = @import("disk_image.zig").log;
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

/// Validation errors
pub const RawDirError = error{
    InvalidUser,
    InvalidExtent,
    InvalidRecordNumber,
    InvalidAllocation,
    InvalidEntryNumber,
    InvalidDirectoryEntry,
};

/// Raw on-disk version of the CPM directory entry
pub const RawCpmDirEntry = struct {
    pub const Raw = extern struct {
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
    };
    raw: Raw, // This must be the one and only field.

    pub const empty: RawCpmDirEntry = .{ .raw = std.mem.zeroes(Raw) };
    pub const filename_len = 8;
    pub const filetype_len = 3;

    pub fn validate(self: *const RawCpmDirEntry, image_type: *const DiskImageType, extent_nr: u16) RawDirError!void {
        if (self.raw.user > DiskImageType.max_user and self.raw.user != 0xe5 and self.raw.user != 0x81) {
            logerr(
                "Invalid directory entry: {} [Invalid user: {}. Must be 0-{} or {}]",
                .{ extent_nr, self.raw.user, DiskImageType.max_user, 0xe5 },
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

        if (self.raw.num_records > 128) {
            logerr(
                "Invalid directory entry: {} [Invalid num_records: {}. Must be 0-{}]",
                .{ extent_nr, self.raw.num_records, 128 },
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

    pub fn isDeleted(self: *const RawCpmDirEntry) bool {
        return self.raw.user > DiskImageType.max_user;
    }

    /// is this a disk label, instead of a normal dir entry?
    pub fn isLabel(self: *const RawCpmDirEntry) bool {
        return self.raw.user == 0x81;
    }

    pub fn setDeleted(self: *RawCpmDirEntry) void {
        self.raw.user = 0xe5;
    }

    /// Set num_records field.
    pub fn numRecordsSet(self: *RawCpmDirEntry, record_nr: u16) void {
        self.raw.num_records = @intCast((record_nr % 128) + 1);
    }

    /// Get extent as 16 bit value
    pub fn extentGet(self: *const RawCpmDirEntry, image_type: *const DiskImageType) u16 {
        if (image_type.OS == .cpm) {
            return @as(u16, self.raw.extent_hi) * 32 + self.raw.extent_low;
        } else {
            return @as(u16, self.raw.extent_hi) * 255 + self.raw.extent_low;
        }
    }

    /// Set extent from 16 bit value
    pub fn extentCountSet(self: *RawCpmDirEntry, extent_count: u16, image_type: *const DiskImageType) void {
        if (image_type.OS == .cpm) {
            self.raw.extent_low = @intCast(extent_count % 32);
            self.raw.extent_hi = @intCast(extent_count / 32);
        } else {
            self.raw.extent_low = @intCast(extent_count % 256);
            self.raw.extent_hi = @intCast(extent_count / 256);
        }
    }

    pub fn attribReadOnly(self: *const RawCpmDirEntry) bool {
        return self.raw.filename[0] & 0x80 != 0;
    }

    pub fn attribSystem(self: *const RawCpmDirEntry) bool {
        return self.raw.filename[1] & 0x80 != 0;
    }

    /// Set allocation as controlled by this extent
    pub fn allocationSet(self: *RawCpmDirEntry, entry_nr: usize, alloc_nr: u16, image_type: *const DiskImageType) RawDirError!void {
        if (entry_nr >= self.allocationsCount(image_type)) {
            return RawDirError.InvalidEntryNumber;
        }
        if (!image_type.two_byte_allocs) {
            // 8 bit allocations
            self.raw.allocations[entry_nr] = @intCast(alloc_nr & 0xff);
        } else {
            // 16 bit allocations.
            var alloc: [2]u8 = undefined;
            std.mem.writeInt(u16, &alloc, alloc_nr, .little);
            self.raw.allocations[entry_nr * 2] = alloc[0];
            self.raw.allocations[entry_nr * 2 + 1] = alloc[1];
        }
    }

    /// Get the number of an allocation controlled by this extent
    pub fn allocationGet(self: *const RawCpmDirEntry, entry_nr: usize, image_type: *const DiskImageType) RawDirError!u16 {
        if (entry_nr >= self.allocationsCount(image_type)) {
            return RawDirError.InvalidEntryNumber;
        }

        if (!image_type.two_byte_allocs) {
            return self.raw.allocations[entry_nr];
        } else {
            const alloc: [2]u8 = .{ self.raw.allocations[entry_nr * 2], self.raw.allocations[entry_nr * 2 + 1] };
            return std.mem.readInt(u16, &alloc, .little);
        }
    }

    /// How many allocations are controlled by this extent?
    pub fn allocationsCount(_: *const RawCpmDirEntry, image_type: *const DiskImageType) u16 {
        return if (image_type.two_byte_allocs)
            @min(8, image_type.allocs_per_extent)
        else
            @min(16, image_type.allocs_per_extent);
    }

    pub fn filenameAndExtensionSet(self: *RawCpmDirEntry, filename: []const u8) void {
        const dot_pos = std.mem.indexOfScalar(u8, filename, '.') orelse filename.len;
        self.raw.filename = @splat(' ');
        self.raw.filetype = @splat(' ');
        @memcpy(self.raw.filename[0..dot_pos], filename[0..dot_pos]);
        if (dot_pos != filename.len) {
            const type_len = @min(self.raw.filetype.len + 1, filename.len - dot_pos - 1);
            @memcpy(self.raw.filetype[0..type_len], filename[dot_pos + 1 .. dot_pos + type_len + 1]);
        }
    }

    pub fn isFirstEntryForFile(self: *const RawCpmDirEntry, image_type: *const DiskImageType) bool {
        //std.debug.print("isFirstExtentforFile: recs_per_extent {}, allocations[4] {}. extent {} = ", .{ image_type.recs_per_extent, self.entry.allocations[4], self.extentGet() });
        if (image_type.OS == .cpm and image_type.recs_per_extent > 128 and self.raw.allocations[4] != 0 and self.extentGet(image_type) == 1) {
            return true;
        }
        return self.extentGet(image_type) == 0;
    }

    pub fn eql(self: *const RawCpmDirEntry, cooked_dir: *const CookedDirEntry) bool {
        return (self.raw.user == cooked_dir.user and
            std.mem.eql(u8, CookedDirEntry.rawSlice(&self.raw.filename), cooked_dir.filenameOnly()) and
            std.mem.eql(u8, CookedDirEntry.rawSlice(&self.raw.filetype), cooked_dir.extensionOnly()));
    }
};

pub const RawAdosDirEntry = struct {
    pub const Raw = extern struct {
        filename: [8]u8,
        track: u8,
        sector: u8,
        mode: u8,
        unused: [5]u8,
    };
    raw: Raw,

    const empty: RawAdosDirEntry = .{
        .raw = .{
            .filename = @splat(' '),
            .track = 0,
            .sector = 0,
            .mode = 0x2, // Default to Seq
            .unused = @splat(0),
        },
    };

    const last: RawAdosDirEntry = .{
        .raw = .{
            .filename = .{ 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
            .track = 0,
            .sector = 0,
            .mode = 0, // Default to Seq
            .unused = @splat(0),
        },
    };

    pub fn isDeleted(self: *const RawAdosDirEntry) bool {
        return self.raw.filename[0] == 0x00 or self.raw.filename[0] == 0xff;
    }

    pub fn setDeleted(self: *RawAdosDirEntry) void {
        self.raw.filename[0] = 0x00;
    }

    pub fn isLastEntry(self: *const RawAdosDirEntry) bool {
        return self.raw.filename[0] == 0xff;
    }

    pub fn eql(self: *const RawAdosDirEntry, cooked: *const CookedDirEntry) bool {
        return std.mem.eql(u8, std.mem.trimEnd(u8, &self.raw.filename, " "), cooked.filenameOnly());
    }

    pub fn validate(self: *const RawAdosDirEntry, image_type: *const DiskImageType, entry_nr: u16) error{InvalidDirectoryEntry}!void {
        const raw = self.raw;
        if (raw.track >= image_type.tracks) {
            logerr(
                "Invalid directory entry: {} [Invalid track: {}. Must be 0 - {}]",
                .{ entry_nr, raw.track, image_type.tracks - 1 },
            );
            return error.InvalidDirectoryEntry;
        }
        if (raw.sector >= image_type.sectors_per_track) {
            logerr(
                "Invalid directory entry: {} [Invalid sector: {}. Must be 0 - {}]",
                .{ entry_nr, raw.sector, image_type.sectors_per_track - 1 },
            );
            return error.InvalidDirectoryEntry;
        }
        if (!self.isDeleted()) switch (raw.mode) {
            0x02, 0x04 => {}, // TODO: enumify this?
            else => {
                logerr(
                    "Invalid directory entry: {} [Invalid mode: {}. Must be 0x02 (sequential) or 0x04 (random access)]",
                    .{ entry_nr, raw.mode },
                );
                return error.InvalidDirectoryEntry;
            },
        };
    }
};

/// An easier to use version of the raw entry.
pub const CookedDirEntry = struct {
    user: u8,
    attribs: [2]u8,
    allocations: std.ArrayListUnmanaged(u16),
    os: union(enum) {
        pub const ADOS = struct {
            track: u8,
            sector: u8,
            size: u32,
            used: u32,
        };
        cpm: struct {
            num_records: u32,
            num_allocs: u32,
        },
        ados: ADOS,
        hd_basic: struct {
            creation_date: [3]u8,
            modification_date: [3]u8,
            nbytes_last_page: u16,
            npages: u16,
            ngroups: u16,
            last_group: u16,
        },
    },
    size_in_bytes: u32,
    used_in_kbytes: u32,
    /// space padded filename and extension.
    /// prefer to use filenameOnly() filenameAndExtension(), extensionOnly(),
    filename: [12]u8,
    block_size: u16,
    has_extension: bool,

    pub fn initCPM(arena: std.mem.Allocator, raw_dir: *const RawCpmDirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!CookedDirEntry {
        var filename: [12]u8 = @splat(' '); // space terminated string

        var filename_len = rawStrlen(&raw_dir.raw.filename);
        @memcpy(filename[0..filename_len], raw_dir.raw.filename[0..filename_len]);

        // Remove status bits, encoded in bit 8 of first 2 chars
        for (filename[0..2], 0..) |c, i| {
            filename[i] = c & 0x7f;
        }

        if (raw_dir.raw.filetype[0] != ' ') {
            filename[filename_len] = '.';
            filename_len += 1;
            @memcpy(filename[filename_len .. filename_len + 3], &raw_dir.raw.filetype);

            if (filename_len + 3 < 12)
                filename[filename_len + 3] = ' ';
        }

        var result = CookedDirEntry{
            .user = raw_dir.raw.user,
            .attribs = [_]u8{
                if (raw_dir.attribReadOnly()) 'R' else 'W',
                if (raw_dir.attribSystem()) 'S' else ' ',
            },
            .os = .{ .cpm = .{
                .num_records = raw_dir.raw.num_records,
                .num_allocs = 0,
            } },
            .filename = filename,
            .block_size = image_type.block_size,
            .allocations = .empty,
            .size_in_bytes = undefined,
            .used_in_kbytes = undefined,
            .has_extension = true,
        };
        result.os.cpm.num_allocs = try result.copyAllocations(arena, raw_dir, image_type);
        if (image_type.OS == .cpm and image_type.recs_per_extent > 128 and result.os.cpm.num_allocs > 4) {
            // CPM records only go up to 128, but can represent up to 256 records.
            result.os.cpm.num_records += 128;
        }
        result.size_in_bytes = result.os.cpm.num_records * 128;
        result.used_in_kbytes = result.os.cpm.num_allocs * image_type.block_size / 1024;
        return result;
    }

    // TODO: Do we even need to store the os-specific stuff? We could jsut pass it?
    // Well at least with suize and used? We're storing it twice here.
    // TODO: And do we still need block_size??
    pub fn initADOS(raw_dir: *const RawAdosDirEntry, ados: @FieldType(CookedDirEntry, "os").ADOS, allocations: std.ArrayList(u16), image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!CookedDirEntry {
        var result: CookedDirEntry = .{
            .user = 0,
            .filename = @splat(' '),
            .attribs = if (raw_dir.raw.mode == 2) .{ 'S', ' ' } else .{ 'R', ' ' },
            .block_size = image_type.block_size,
            .allocations = allocations,
            .os = .{ .ados = ados },
            .size_in_bytes = ados.size,
            .used_in_kbytes = ados.used,
            .has_extension = false,
        };
        @memcpy(result.filename[0..raw_dir.raw.filename.len], &raw_dir.raw.filename);
        return result;
    }

    pub fn extend(self: *CookedDirEntry, arena: std.mem.Allocator, raw_dir: *const RawCpmDirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!void {
        self.os.cpm.num_records += raw_dir.raw.num_records;
        const num_allocs = try self.copyAllocations(arena, raw_dir, image_type);
        self.os.cpm.num_allocs += num_allocs;
        if (image_type.recs_per_extent > 128 and num_allocs > 4) {
            self.os.cpm.num_records += 128;
        }
    }

    pub fn filenameAndExtension(self: *const CookedDirEntry) []const u8 {
        return rawSlice(&self.filename);
    }

    pub fn filenameOnly(self: *const CookedDirEntry) []const u8 {
        if (!self.has_extension) return self.filenameAndExtension();
        const pos = std.mem.indexOfScalar(u8, &self.filename, '.') orelse return self.filenameAndExtension();
        return self.filename[0..pos];
    }

    pub fn extensionOnly(self: *const CookedDirEntry) []const u8 {
        if (!self.has_extension) return "";
        const pos = std.mem.indexOfScalar(u8, &self.filename, '.') orelse return "";
        return rawSlice(self.filename[pos + 1 ..]);
    }

    /// Add any new allocations to the list of used allocations.
    fn copyAllocations(cooked: *CookedDirEntry, arena: std.mem.Allocator, raw: *const RawCpmDirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!u8 {
        var alloc_count: u8 = 0;

        try cooked.allocations.ensureUnusedCapacity(arena, raw.raw.allocations.len);
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

    /// Return the length of a space terminated string.
    fn rawStrlen(str: []const u8) usize {
        return std.mem.indexOfScalar(u8, str, ' ') orelse str.len;
    }

    /// Return a slice representing the value of a space-termianted string.
    pub fn rawSlice(str: []const u8) []const u8 {
        return str[0..rawStrlen(str)];
    }
};

/// Stores and populates the raw and cooked directory entries
pub const DirectoryTable = struct {
    const RawDirEntry = union(enum) {
        cpm: RawCpmDirEntry,
        ados: RawAdosDirEntry,

        pub fn isDeleted(self: *const RawDirEntry) bool {
            switch (self.*) {
                inline else => |s| return s.isDeleted(),
            }
        }

        pub fn isLabel(self: *const RawDirEntry) bool {
            switch (self.*) {
                inline .ados => return false,
                inline .cpm => |s| return s.isLabel(),
            }
        }

        pub fn items(self: *const RawDirEntry) void {
            switch (self.*) {
                inline else => |s| return s.items,
            }
        }
    };

    /// All dynamic allocations should use this allocator.
    arena: std.heap.ArenaAllocator,

    /// The CPM directory entries in on-disk format.
    /// note there may be multiple raw entries per file.
    raw_directories: union(enum) {
        cpm: std.ArrayList(RawCpmDirEntry),
        ados: std.ArrayList(RawAdosDirEntry),
        hd_basic: std.ArrayList(hd_basic.DirEntry),
    },

    /// The friendlier versions of the raw directories with
    /// one entry per file containing all records and allocations
    /// Initially sorted in alphabetical order, but new files will
    /// always be added to the end of the list.
    /// Note that erase can invalidate any pointers into this array
    /// and will change the sorting order.
    cooked_directories: std.ArrayListUnmanaged(CookedDirEntry),

    /// A record of the disk allocations _not_ used by any file.
    free_allocations: std.DynamicBitSetUnmanaged,
    image_type: *const DiskImageType,

    pub fn init(gpa: std.mem.Allocator, image_type: *const DiskImageType) std.mem.Allocator.Error!DirectoryTable {
        var arena = std.heap.ArenaAllocator.init(gpa);
        return .{
            .raw_directories = switch (image_type.OS) {
                .cpm, .cdos => .{ .cpm = try .initCapacity(arena.allocator(), image_type.directories) },
                .ados => .{ .ados = try .initCapacity(arena.allocator(), image_type.directories) },
                .hd_basic => .{ .hd_basic = try .initCapacity(arena.allocator(), image_type.directories) },
            },
            .cooked_directories = try .initCapacity(arena.allocator(), image_type.directories),
            .free_allocations = try .initFull(arena.allocator(), image_type.total_allocs),
            .arena = arena,
            .image_type = image_type,
        };
    }

    // TODO: Issue is that track 0 is not usable on mini disk data disks. so total allocs it 2 less,
    // but really we want to pretend those are available because otherwise we'd have to do special
    // indexing into the disk.
    // So we can mark alloc 0 and 1 as used on directory load. but then we need to work out a
    // fix for the max file size calc.

    pub fn deinit(self: *DirectoryTable) void {
        self.arena.deinit();
    }

    /// All allocations need to be done via this allocator so they can be
    /// freed in deinit.
    fn allocator(self: *DirectoryTable) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub const LoadOption = enum { full, raw_only };
    pub const DirectoryLoadError = (error{ OutOfMemory, InvalidImageFile } || DiskImage.ReadSectorError || RawDirError);
    /// Load the directory table
    pub fn load(self: *DirectoryTable, image: *DiskImage, option: LoadOption) DirectoryLoadError!void {
        try switch (image.image_type.OS) {
            .cpm, .cdos => loadCPM(self, image, option),
            .ados => loadAltairDOS(self, image, option),
            .hd_basic => hd_basic.loadDirectory(self.arena.allocator(), self, image, option),
        };
    }

    fn loadCPM(self: *DirectoryTable, image: *DiskImage, option: LoadOption) DirectoryLoadError!void {
        const image_type = self.image_type;
        var sector: DiskSector = undefined;
        const directory_sector_count = image_type.directories / image_type.dirs_per_sector;
        var sector_nr: u16 = 0;

        // Reserve allocations used for directories
        for (0..image_type.directory_allocs) |i| {
            self.free_allocations.unset(i);
        }

        while (sector_nr < directory_sector_count) : ({
            sector_nr += 1;
        }) {
            const logical_address = LogicalAddress{
                .allocation = sector_nr / (image_type.block_size / image_type.sector_size_data),
                .record = @intCast(sector_nr % image_type.recs_per_alloc),
            };
            // Read the raw CPM directory entries and add them to the raw_directories array.
            try image.readSectorLogical(logical_address, &sector);
            const entries: []RawCpmDirEntry = std.mem.bytesAsSlice(RawCpmDirEntry, sector.dataBytes());

            self.raw_directories.cpm.appendSliceAssumeCapacity(entries);
        }

        // For CDOS, Check that the number of directories etc is the "default" value for that disk
        // Support for other directories counts is a TODO
        if (self.image_type.OS == .cdos and self.raw_directories.cpm.items.len > 0 and self.raw_directories.cpm.items[0].isLabel()) {
            const raw_item = self.raw_directories.cpm.items[0];
            const expected_num_records: u8 = switch (image_type.type_id.toCDOS()) {
                .CDOS_SMSSSD, .CDOS_SMDSSD, .CDOS_SMSSDD, .CDOS_LGSSSD => 0x10,
                .CDOS_LGSSDD, .CDOS_LGDSSD, .CDOS_SMDSDD => 0x20,
                .CDOS_LGDSDD => 0x40,
            };
            if (expected_num_records != raw_item.raw.num_records) {
                if (!@import("builtin").is_test) logerr(
                    "CDOS disks with a non-default number of directories are not currently supported. Expected {}, actual {}",
                    .{ @as(u16, expected_num_records) * 4, @as(u16, raw_item.raw.num_records) * 4 },
                );
                return error.InvalidImageFile;
            }
        }

        // building the cooked dirs needs sorted raw_dirs.
        var raw_dirs_sorted: std.ArrayList(*RawCpmDirEntry) = try .initCapacity(self.allocator(), self.raw_directories.cpm.items.len);
        defer raw_dirs_sorted.deinit(self.allocator());
        for (self.raw_directories.cpm.items) |*raw_dir| {
            raw_dirs_sorted.appendAssumeCapacity(raw_dir);
        }

        std.mem.sort(*RawCpmDirEntry, raw_dirs_sorted.items, image_type, struct {
            fn lessThan(img_type: *const DiskImageType, lhs: *RawCpmDirEntry, rhs: *RawCpmDirEntry) bool {
                if (std.mem.eql(u8, &lhs.raw.filename, &rhs.raw.filename)) {
                    if (std.mem.eql(u8, &lhs.raw.filetype, &rhs.raw.filetype)) {
                        if (lhs.raw.user == rhs.raw.user) {
                            return lhs.extentGet(img_type) < rhs.extentGet(img_type);
                        } else {
                            return lhs.raw.user < rhs.raw.user;
                        }
                    } else {
                        return std.mem.lessThan(u8, &lhs.raw.filetype, &rhs.raw.filetype);
                    }
                } else {
                    return std.mem.lessThan(u8, &lhs.raw.filename, &rhs.raw.filename);
                }
            }
        }.lessThan);

        // Create the CookedDirEntries and remove any used allocations from the free alocations set.
        for (raw_dirs_sorted.items, 0..) |dir, i| {
            if (!dir.isDeleted()) {
                const entry_nr = (@intFromPtr(dir) - @intFromPtr(&self.raw_directories.cpm.items[0])) / @sizeOf(RawCpmDirEntry);
                if (option == .full) {
                    self.buildCookedEntryCPM(@intCast(entry_nr)) catch |err| switch (err) {
                        error.InvalidUser,
                        error.InvalidExtent,
                        error.InvalidRecordNumber,
                        error.InvalidAllocation,
                        error.InvalidEntryNumber,
                        error.InvalidDirectoryEntry,
                        => {
                            logerr(
                                "Directory entry {} for \"{s}\" has invalid directory entries and has been hidden. Use --recover to try and recover the image: {t}",
                                .{ i, std.mem.trimEnd(u8, &dir.raw.filename, " "), err },
                            );
                        },
                        error.OutOfMemory,
                        error.InvalidImageFile,
                        => return err,
                    };
                }
                // Mark off the used allocations
                for (0..dir.allocationsCount(image_type)) |alloc_nr| {
                    const alloc = try dir.allocationGet(alloc_nr, image_type);
                    // 0 marks the end of the used allocations in this extent.
                    if (alloc == 0)
                        break;
                    if (alloc >= image_type.total_allocs) {
                        logerr(
                            "Invalid directory entry: {} [Invalid allocation: {}. Must be 0-{}]",
                            .{ i, alloc, image_type.total_allocs },
                        );
                    } else {
                        self.free_allocations.unset(alloc);
                    }
                }
            }
        }

        // Note you cannot rely on this list remaining sorted during any operation that manipulates the
        // raw directory entries. Filename searches will need to traverse the whole list.
        // If this starts getting used alot, it would be worth making it a HashArray to give easy lookups, while still
        // keeping the contents stored in a sortable array.
        std.mem.sort(CookedDirEntry, self.cooked_directories.items, {}, struct {
            fn lessThan(_: void, lhs: CookedDirEntry, rhs: CookedDirEntry) bool {
                if (!std.mem.eql(u8, lhs.filenameAndExtension(), rhs.filenameAndExtension())) {
                    return std.mem.lessThan(u8, lhs.filenameAndExtension(), rhs.filenameAndExtension());
                }
                return lhs.user < rhs.user;
            }
        }.lessThan);
    }

    fn loadAltairDOS(self: *DirectoryTable, image: *DiskImage, option: LoadOption) DirectoryLoadError!void {
        // Directory is held on track 70 for 8IN and 34 for 5.25IN
        const directory_track = self.image_type.OS.ados.directory_track;
        for (0..self.image_type.directory_allocs) |i| {
            // 8 sectors per block (block_size / sector_size_data)
            self.free_allocations.unset(try toAllocationADOS(self.image_type, .{ .track = directory_track, .sector = @intCast(i * 8) }));
        }
        if (self.image_type.type_id == .ADOS_MINI) {
            // Can't use track 0 to store data.
            self.free_allocations.unset(0);
            self.free_allocations.unset(1);
        }
        var sector: DiskSector = .initUnformatted(self.image_type, directory_track);
        try self.raw_directories.ados.ensureTotalCapacity(self.allocator(), self.image_type.directories);
        for (0..self.image_type.sectors_per_track) |sector_nr| {
            try image.readSectorPhysical(.{ .track = directory_track, .sector = @intCast(sector_nr) }, &sector);
            const entries: []RawAdosDirEntry = std.mem.bytesAsSlice(RawAdosDirEntry, sector.dataBytes());
            try self.raw_directories.ados.ensureUnusedCapacity(self.allocator(), entries.len);
            self.raw_directories.ados.appendSliceAssumeCapacity(entries);
        }

        try self.cooked_directories.ensureTotalCapacity(self.allocator(), self.raw_directories.ados.items.len);
        loop: for (0..self.raw_directories.ados.items.len) |raw_entry_idx| {
            switch (self.raw_directories.ados.items[raw_entry_idx].raw.filename[0]) {
                0 => continue, // Deleted
                // TODO: Can we use isLast and isDelted here instead?
                255 => break :loop, // End of Directory
                else => self.buildCookedEntryADOS(image, @intCast(raw_entry_idx)) catch |err| {
                    if (option != .raw_only) return err;
                },
            }
        }

        std.mem.sort(CookedDirEntry, self.cooked_directories.items, {}, struct {
            fn lessThan(_: void, lhs: CookedDirEntry, rhs: CookedDirEntry) bool {
                return std.mem.lessThan(u8, lhs.filenameAndExtension(), rhs.filenameAndExtension());
            }
        }.lessThan);
    }

    // convert track and sector to allocation
    fn toAllocationADOS(image_type: *const DiskImageType, location: PhysicalAddress) PhysicalAddress.ValidateError!u16 {
        try location.validate(image_type);
        if (location.track < image_type.reserved_tracks) {
            return error.InvalidTrack;
        }
        return @as(u16, location.track - image_type.reserved_tracks) * (image_type.sectors_per_track / image_type.sectors_per_alloc) + @as(u16, location.sector / image_type.sectors_per_alloc);
    }

    /// Whenever a new extent is created, register it with the directory
    /// Builds up the associated CookedDirEntry as new RawDirEntries are registered.
    pub fn buildCookedEntryCPM(self: *DirectoryTable, raw_entry_idx: u16) (error{ OutOfMemory, InvalidImageFile } || RawDirError)!void {
        const entry = &self.raw_directories.cpm.items[raw_entry_idx];
        try entry.validate(self.image_type, raw_entry_idx);
        if (entry.isFirstEntryForFile(self.image_type)) {
            try self.cooked_directories.append(self.allocator(), try CookedDirEntry.initCPM(self.allocator(), entry, self.image_type));
        } else {
            if (self.cooked_directories.items.len == 0) {
                logerr("Cannot detect first entry for file {s}.{s}: ", .{ entry.raw.filename, entry.raw.filetype });
                return error.InvalidImageFile;
            }
            var prev = &self.cooked_directories.items[self.cooked_directories.items.len - 1];
            try prev.extend(self.allocator(), entry, self.image_type);
        }
    }

    pub fn buildCookedEntryADOS(self: *DirectoryTable, image: *DiskImage, raw_entry_idx: u16) (error{ OutOfMemory, InvalidImageFile } || RawDirError || PhysicalAddress.ValidateError)!void {
        const entry = &self.raw_directories.ados.items[raw_entry_idx];
        try entry.validate(self.image_type, raw_entry_idx);
        var allocations: std.ArrayList(u16) = .empty;
        const os_ados: ?@FieldType(CookedDirEntry, "os").ADOS = blk: {
            // Calculate File size and Allocations
            // Walk the linked list of sectors and add up the bytes.
            // At the same time, build the list of allocations used by the file.
            var track_nr = entry.raw.track;
            var sector_nr = entry.raw.sector;
            var nbytes: u32 = 0;
            var used: u32 = 0;
            var nr_sectors: u32 = 0;
            const sectors_per_alloc = self.image_type.sectors_per_alloc;

            if (entry.raw.mode == 0x02) { // Sequential
                while (track_nr != 0) {
                    const allocation = try toAllocationADOS(self.image_type, .{ .track = track_nr, .sector = sector_nr });
                    self.free_allocations.unset(allocation);
                    if (sector_nr % sectors_per_alloc == 0) {
                        try allocations.append(self.allocator(), allocation);
                    }

                    var sector: DiskSector = .initUnformatted(self.image_type, self.image_type.OS.ados.directory_track);
                    image.readSectorPhysical(.{ .track = track_nr, .sector = sector_nr }, &sector) catch |err| switch (err) {
                        error.InvalidTrack, error.InvalidSector => {
                            log.warn("{s} has invalid track or sector links. File will not be copied correctly: {t}", .{ entry.raw.filename, err });
                            break :blk null;
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
            } else if (entry.raw.mode == 0x04) { // Random access
                var group_map: [256]u8 = undefined;
                var sector: DiskSector = .initUnformatted(self.image_type, track_nr);
                image.readSectorPhysical(.{ .track = track_nr, .sector = sector_nr }, &sector) catch |err| {
                    logerr("Error reading from disk image: {t}\n", .{err});
                    return error.InvalidImageFile;
                };
                const nr_groups: u32 = sector.data.nbytes;
                nbytes = nr_groups * self.image_type.block_size;
                used = nr_groups;
                @memcpy(group_map[0..128], sector.dataBytes());

                image.readSectorPhysical(.{ .track = sector.data.next_track, .sector = sector.data.next_sector }, &sector) catch |err| {
                    logerr("Error reading from disk image: {t}\n", .{err});
                    return error.InvalidImageFile;
                };
                @memcpy(group_map[128..], sector.dataBytes());
                // Can't use track-size here as we only care about the size of the data portions of the track
                //const allocs_per_track = (self.image_type.sector_size_data * self.image_type.sectors_per_track) / self.image_type.block_size;
                for (0..nr_groups) |idx| {
                    const encoded_group: u8 = group_map[idx];
                    const alloc = toAllocationADOS(self.image_type, .{
                        .track = (encoded_group & 0x3f) + if (self.image_type.type_id == .ADOS_8IN) @as(u8, 6) else @as(u8, 0),
                        .sector = (encoded_group >> 6) * sectors_per_alloc,
                    }) catch |err| switch (err) {
                        error.InvalidTrack, error.InvalidSector => {
                            logerr("Directory entry for {s} has invalid track of sector information and is not shown: {t}. Use --raw for more details.", .{ std.mem.trimEnd(u8, &entry.raw.filename, " "), err });
                            break :blk null;
                        },
                    };
                    self.free_allocations.unset(alloc); // TODO: We need checks around all of these. it is coming from untrusted data.
                }
            } else unreachable; // Should have already been validated before we get here.
            break :blk .{
                .track = entry.raw.track,
                .sector = entry.raw.sector,
                .size = nbytes,
                .used = used,
            };
        };
        if (os_ados) |ados| {
            self.cooked_directories.appendAssumeCapacity(try CookedDirEntry.initADOS(entry, ados, allocations, self.image_type));
        }
    }

    /// Remove a file from the image.
    pub fn eraseEntry(self: *DirectoryTable, to_erase: *CookedDirEntry, disk_image: *DiskImage) !void {
        const cooked_index: usize = try index: {
            for (self.cooked_directories.items, 0..) |cooked, i| {
                if (std.meta.eql(to_erase.*, cooked)) {
                    break :index i;
                }
            }
            break :index error.CookedDirEntryNotFound;
        };
        const cooked_dir = &self.cooked_directories.items[cooked_index];
        // Set the allocs used by this cooked entry as free.
        for (cooked_dir.allocations.items) |alloc| {
            if (alloc == 0) break;
            self.free_allocations.set(alloc);
        }
        cooked_dir.allocations.clearAndFree(self.allocator());
        // Make sure to always remove the deleted CookedDir.
        defer _ = self.cooked_directories.orderedRemove(cooked_index);

        // Delete all the raw_entries and write to disk.
        switch (self.raw_directories) {
            inline else => |raw_dirs| {
                for (raw_dirs.items, 0..) |*raw_item, idx| {
                    if (!raw_item.isDeleted() and raw_item.eql(cooked_dir)) {
                        raw_item.setDeleted();
                        try disk_image.rawEntryWrite(@intCast(idx));
                        // For altair dos, also need to go through and set all of the file numbers in each
                        // sector, the bytes_written, next_track and next_sector to 0
                        if (@TypeOf(raw_dirs) == @TypeOf(self.raw_directories.ados)) {
                            var track_nr: u16 = raw_item.raw.track;
                            var sector_nr: u16 = raw_item.raw.sector;

                            while (track_nr != 0) {
                                var sector: DiskSector = .initUnformatted(self.image_type, track_nr);
                                const location: PhysicalAddress = .{ .track = track_nr, .sector = sector_nr };
                                disk_image.readSectorPhysical(location, &sector) catch |err| switch (err) {
                                    error.InvalidTrack, error.InvalidSector => {
                                        log.warn("{s} has invalid track or sector links. Erase still suceeded: {t}", .{ raw_item.raw.filename, err });
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
                                try disk_image.writeSector(location, &sector);
                            }
                        } else if (@TypeOf(raw_dirs) == @TypeOf(self.raw_directories.hd_basic)) {
                            // TODO:
                            try hd_basic.writeAllocationBitmap(disk_image);
                        }

                        return;
                    }
                }
            },
        }
    }

    /// Performs a wildcard lookup of the directory. * and ? are supported wildcard characters.
    /// Use the returned FileNameIterator to walk through the directory entries
    pub fn findByFileNameWildcards(self: *const DirectoryTable, pattern: []const u8, user: ?u8) FileNameIterator {
        return FileNameIterator.init(self.cooked_directories.items, pattern, user);
    }

    /// Find by exact match. Case insentitive.
    pub fn findByFilename(self: *const DirectoryTable, filename: []const u8, user: ?u8) ?*CookedDirEntry {
        // Can't use a binary search here as when adding new files, they are added at the end,
        // not in alhpabetical order. So need to walk entire directory. There are 1024 entries
        // at most.
        for (self.cooked_directories.items) |*entry| {
            if (user) |u| {
                if (entry.user != u) continue;
            }
            if (FileNameIterator.filenameEqual(filename, entry.filenameAndExtension(), false)) {
                return entry;
            }
        }
        return null;
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
    pub fn translateToCPMFilename(filename: []const u8, buffer: []u8) error{InvalidFilename}![]u8 {
        var found_dot: bool = false;
        var char_count: usize = 0;
        var ext_count: usize = 0;
        const end_in = filename.ptr + filename.len;
        var in_char: [*]const u8 = filename.ptr; // Caution! Not bounds checked
        var out_char: [*]u8 = buffer.ptr; // Caution! Not bounds checked
        const filename_len = RawCpmDirEntry.filename_len;
        const ext_len = RawCpmDirEntry.filetype_len;
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

    /// Convert to valid Altair DOS / Basic filename
    /// There are almost no restrictions on valid filename chars in Altair DOS
    /// This program enforces printable and upper case.
    pub fn translateToADOSFilename(from_filename: []const u8, to_filename: *[8]u8) error{InvalidFilename}![]u8 {
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

    /// Note this is used by the tests: // TODO: Then move it to the TESTS..
    /// Return a free allocation
    pub fn allocationGetFreeCPM(self: *DirectoryTable) error{OutOfAllocs}!u16 {
        if (self.free_allocations.findFirstSet()) |free_alloc| {
            self.free_allocations.unset(free_alloc);
            return @intCast(free_alloc);
        } else {
            return error.OutOfAllocs;
        }
    }

    /// Return a free allocation
    pub fn allocationGetFreeADOS(self: *DirectoryTable, for_random_access: bool) error{OutOfAllocs}!u16 {
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
    /// Return a free CPM directory entry
    pub fn rawEntryGetFreeInitializedCPM(self: *const DirectoryTable, extent_nr: *u16) error{OutOfExtents}!*RawCpmDirEntry {
        for (self.raw_directories.cpm.items, 0..) |*dir, i| {
            if (dir.isDeleted() and !dir.isLabel()) {
                extent_nr.* = @intCast(i);
                dir.* = .empty;
                return dir;
            }
        }
        return error.OutOfExtents;
    }

    pub fn rawEntryGetFreeInitializedADOS(self: *const DirectoryTable, image: *DiskImage, extent_nr: *u16) error{OutOfExtents}!*RawAdosDirEntry {
        for (self.raw_directories.ados.items[0..self.raw_directories.ados.items.len -| 1], 0..) |*dir, i| {
            if (dir.isLastEntry()) {
                extent_nr.* = @intCast(i);
                dir.* = .last;
                // Set the next entry to be the last entry.
                self.raw_directories.ados.items[i + 1] = .last;
                image.ados.rawEntryWrite(@intCast(i + 1)) catch return error.OutOfExtents;
                return dir;
            } else if (dir.isDeleted()) {
                extent_nr.* = @intCast(i);
                dir.* = .empty;
                return dir;
            }
        }
        return error.OutOfExtents;
    }

    /// Number of free CPM directory entries
    pub fn rawEntryFreeCount(self: *const DirectoryTable) usize {
        var count: usize = 0;
        switch (self.raw_directories) {
            .cpm => |cpm| {
                for (cpm.items) |dir| {
                    if (dir.isDeleted() and !dir.isLabel()) {
                        count += 1;
                    }
                }
            },
            inline .ados, .hd_basic => |ados| {
                for (ados.items) |dir| {
                    if (dir.isLastEntry()) break;
                    if (!dir.isDeleted()) {
                        count += 1;
                    }
                }
                count = self.image_type.directories - count; // There are always 255 directories on ADOS
            },
        }
        return count;
    }

    pub const DirectoryError = error{
        // No more directory entries available.
        OutOfExtents,
        // No more allocations available.
        OutOfAllocs,
    };
};

pub const FileNameIterator = struct {
    directory: []CookedDirEntry,
    pattern: []const u8,
    user: ?u8,
    index: usize,

    pub fn init(directory: []CookedDirEntry, filename_pattern: []const u8, user: ?u8) FileNameIterator {
        return .{
            .directory = directory,
            .pattern = filename_pattern,
            .user = user,
            .index = 0,
        };
    }
    pub fn next(self: *FileNameIterator) ?*CookedDirEntry {
        for (self.directory[self.index..]) |*entry| {
            if (self.user) |u| {
                // Skip files not for this user.
                if (entry.user != u) {
                    self.index += 1;
                    continue;
                }
            }
            if (FileNameIterator.filenameEqual(self.pattern, entry.filenameAndExtension(), true)) {
                self.index += 1;
                return &self.directory[self.index - 1];
            }
            self.index += 1;
        }
        return null;
    }

    /// Tests if two filenames are equal using wildcard pattern matching.
    pub fn filenameEqual(lhs_pattern: []const u8, rhs: []const u8, wildcards: bool) bool {
        var lhs_pos: usize = 0;
        var rhs_pos: usize = 0;
        var found_dot: bool = false;

        while (lhs_pos < lhs_pattern.len and rhs_pos < rhs.len) {
            if (wildcards and lhs_pattern[lhs_pos] == '*') {
                // '*' matches to either next '.' or end of string.
                // If get a '*' and already encountered a '.' return true as must match to rest of string.
                // Otherwise skip to the first '.' character.
                if (found_dot)
                    return true;
                lhs_pos = std.mem.indexOfScalar(u8, lhs_pattern[lhs_pos..], '.') orelse return true;
                rhs_pos = std.mem.indexOfScalar(u8, rhs[rhs_pos..], '.') orelse {
                    return true;
                };
            } else if (wildcards and lhs_pattern[lhs_pos] == '?') {
                lhs_pos += 1;
                rhs_pos += 1;
                continue;
            } else {
                if (rhs[rhs_pos] == '.') {
                    found_dot = true;
                }
                if (!(std.ascii.toUpper(lhs_pattern[lhs_pos]) == std.ascii.toUpper(rhs[rhs_pos]))) {
                    return false;
                }
            }
            lhs_pos += 1;
            rhs_pos += 1;
        }

        // If equal, both will be at end of string
        if (lhs_pos == lhs_pattern.len and rhs_pos == rhs.len) {
            return true;
        }
        // Treat ABC. and ABC as Equal
        if (lhs_pos == lhs_pattern.len and rhs_pos == rhs.len and rhs[rhs_pos] == '.' and rhs_pos == rhs.len - 1) {
            return true;
        }
        if (rhs_pos == rhs.len and lhs_pos == lhs_pattern.len - 1 and lhs_pattern[lhs_pos] == '.') {
            return true;
        }
        return false;
    }
};

const std = @import("std");
const DiskImageType = @import("disk_types.zig").DiskImageType;
const DiskImage = @import("disk_image.zig").DiskImage;
const DiskSector = @import("disk_types.zig").DiskSector;
const OperatingSystem = @import("disk_types.zig").OperatingSystem;
const LogicalAddress = @import("disk_image.zig").LogicalAddress;
const PhysicalAddress = @import("disk_types.zig").PhysicalAddress;
const hd_basic = @import("hd_basic.zig");
