//!
//! List of files / directory entries contained on the disk image.
//! Contains:
//! 1) RawDirEntrys that hold a copy of the directory entry structure on the disk image
//! 2) CookedDirEntrys that provide a simpler interface for interacting with the
//!    cpm directory table.
//! 3) The free allocation table.
//!
// A lot of the zig code seems to use the function naming convention nounVerb
// It has the advantage of grouping functions for similar things together alphabetically.
// It has the downside that when reading the code it's more natural to read getAbc, rather than abcGet,
// especially if it is aReallyLongIdentifierGet() vs getAreallyLongIdentifier().
// I've tried to use the nounVerb convention in this source code, but it's really hard to break old habits.

// TODO: Put CPM and ADOS functions in their own namespaces or somthing.

const log = @import("disk_image.zig").log;

/// Validation errors
pub const RawDirError = error{
    InvalidUser,
    InvalidExtent,
    InvalidRecordNumber,
    InvalidAllocation,
    InvalidEntryNumber,
};

/// Raw on-disk version of the CPM directory entry
pub const RawCpmDirEntry = struct {
    const Raw = extern struct {
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
    entry: Raw, // This must be the one and only field.

    pub const empty: RawCpmDirEntry = .{ .entry = std.mem.zeroes(Raw) };
    pub const filename_len = 8;
    pub const filetype_len = 3;

    pub fn validate(self: *const RawCpmDirEntry, image_type: *const DiskImageType, extent_nr: u16) RawDirError!void {
        if (self.entry.user > DiskImageType.max_user and self.entry.user != 0xe5 and self.entry.user != 0x81) {
            log.err(
                "Invalid directory entry: {} [Invalid user: {}. Must be 0-{} or {}]",
                .{ extent_nr, self.entry.user, DiskImageType.max_user, 0xe5 },
            );
            return RawDirError.InvalidUser;
        }

        const max_entents = image_type.extents_per_alloc * image_type.total_allocs;
        if (self.extentGet(image_type) >= max_entents) {
            log.err(
                "Invalid directory entry: {} [Invalid extent: {}. Must be 0-{}]",
                .{ extent_nr, self.extentGet(image_type), max_entents },
            );
            return RawDirError.InvalidExtent;
        }

        if (self.entry.num_records > 128) {
            log.err(
                "Invalid directory entry: {} [Invalid num_records: {}. Must be 0-{}]",
                .{ extent_nr, self.entry.num_records, 128 },
            );
            return RawDirError.InvalidRecordNumber;
        }
        for (0..self.allocationsCount(image_type)) |i| {
            const alloc = try self.allocationGet(@intCast(i), image_type);
            if (alloc > image_type.total_allocs) {
                log.err(
                    "Invalid directory entry: {} [Invalid allocation: {}. Must be 0-{}]",
                    .{ extent_nr, alloc, image_type.total_allocs },
                );
                return RawDirError.InvalidAllocation;
            }
        }
    }

    pub fn isDeleted(self: *const RawCpmDirEntry) bool {
        return self.entry.user > DiskImageType.max_user;
    }

    /// is this a disk label, instead of a normal dir entry?
    pub fn isLabel(self: *const RawCpmDirEntry) bool {
        return self.entry.user == 0x81;
    }

    pub fn setDeleted(self: *RawCpmDirEntry) void {
        self.entry.user = 0xe5;
    }

    /// Set num_records field.
    pub fn numRecordsSet(self: *RawCpmDirEntry, record_nr: u16) void {
        self.entry.num_records = @intCast((record_nr % 128) + 1);
    }

    /// Get extent as 16 bit value
    pub fn extentGet(self: *const RawCpmDirEntry, image_type: *const DiskImageType) u16 {
        if (image_type.OS == .cpm) {
            return @as(u16, self.entry.extent_hi) * 32 + self.entry.extent_low;
        } else {
            return @as(u16, self.entry.extent_hi) * 255 + self.entry.extent_low;
        }
    }

    /// Set extent from 16 bit value
    pub fn extentCountSet(self: *RawCpmDirEntry, extent_count: u16, image_type: *const DiskImageType) void {
        if (image_type.OS == .cpm) {
            self.entry.extent_low = @intCast(extent_count % 32);
            self.entry.extent_hi = @intCast(extent_count / 32);
        } else {
            self.entry.extent_low = @intCast(extent_count % 256);
            self.entry.extent_hi = @intCast(extent_count / 256);
        }
    }

    pub fn attribReadOnly(self: *const RawCpmDirEntry) bool {
        return self.entry.filename[0] & 0x80 != 0;
    }

    pub fn attribSystem(self: *const RawCpmDirEntry) bool {
        return self.entry.filename[1] & 0x80 != 0;
    }

    /// Set allocation as controlled by this extent
    pub fn allocationSet(self: *RawCpmDirEntry, entry_nr: usize, alloc_nr: u16, image_type: *const DiskImageType) RawDirError!void {
        if (entry_nr >= self.allocationsCount(image_type)) {
            return RawDirError.InvalidEntryNumber;
        }
        if (!image_type.two_byte_allocs) {
            // 8 bit allocations
            self.entry.allocations[entry_nr] = @intCast(alloc_nr & 0xff);
        } else {
            // 16 bit allocations.
            var alloc: [2]u8 = undefined;
            std.mem.writeInt(u16, &alloc, alloc_nr, .little);
            self.entry.allocations[entry_nr * 2] = alloc[0];
            self.entry.allocations[entry_nr * 2 + 1] = alloc[1];
        }
    }

    /// Get the number of an allocation controlled by this extent
    pub fn allocationGet(self: *const RawCpmDirEntry, entry_nr: usize, image_type: *const DiskImageType) RawDirError!u16 {
        if (entry_nr >= self.allocationsCount(image_type)) {
            std.debug.panic("{}, {}\n", .{ entry_nr, self.allocationsCount(image_type) });
            return RawDirError.InvalidEntryNumber;
        }

        if (!image_type.two_byte_allocs) {
            return self.entry.allocations[entry_nr];
        } else {
            const alloc: [2]u8 = .{ self.entry.allocations[entry_nr * 2], self.entry.allocations[entry_nr * 2 + 1] };
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
        self.entry.filename = @splat(' ');
        self.entry.filetype = @splat(' ');
        @memcpy(self.entry.filename[0..dot_pos], filename[0..dot_pos]);
        if (dot_pos != filename.len) {
            const type_len = @min(self.entry.filetype.len + 1, filename.len - dot_pos - 1);
            @memcpy(self.entry.filetype[0..type_len], filename[dot_pos + 1 .. dot_pos + type_len + 1]);
        }
    }

    pub fn isFirstEntryForFile(self: *const RawCpmDirEntry, image_type: *const DiskImageType) bool {
        //std.debug.print("isFirstExtentforFile: recs_per_extent {}, allocations[4] {}. extent {} = ", .{ image_type.recs_per_extent, self.entry.allocations[4], self.extentGet() });
        if (image_type.OS == .cpm and image_type.recs_per_extent > 128 and self.entry.allocations[4] != 0 and self.extentGet(image_type) == 1) {
            return true;
        }
        return self.extentGet(image_type) == 0;
    }
};

const RawAdosDirEntry = struct {
    pub const Raw = extern struct {
        filename: [8]u8,
        track: u8,
        sector: u8,
        mode: u8,
        unused: [5]u8,
    };
    raw: Raw,

    pub fn isDeleted(self: *const RawAdosDirEntry) bool {
        return self.raw.filename[0] == 0x00;
    }

    pub fn format(self: *const RawAdosDirEntry, writer: *std.Io.Writer) error{WriteFailed}!void {
        var printable: [self.filename.len]u8 = self.filename;
        for (&printable) |*ch| {
            if (!std.ascii.isPrint(ch.*)) ch.* = '?';
        }
        try writer.print(
            "FN: [{s}], TK: [{x:02}], SC: [{x:02}], MD: [{x:02}], UN: [{x}]",
            .{ printable, self.track, self.sector, self.mode, self.unused },
        );
    }
};

/// An easier to use version of the raw entry.
pub const CookedDirEntry = struct {
    user: u8,
    attribs: [2]u8,
    os: union(enum) {
        cpm: struct {
            num_records: u32,
            num_allocs: u32,
            allocations: std.ArrayListUnmanaged(u16),
        },
        ados: struct {
            track: u8,
            sector: u8,
            size: u32,
            used: u32,
        },
    },
    /// space padded filename and extension.
    /// prefer to use filenameOnly() filenameAndExtension(), extensionOnly(),
    filename: [12]u8,
    image_type: *const DiskImageType,

    pub fn init(arena: std.mem.Allocator, raw_dir: *const RawCpmDirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!CookedDirEntry {
        var filename: [12]u8 = @splat(' '); // space terminated strings!

        var filename_len = rawStrlen(&raw_dir.entry.filename);
        @memcpy(filename[0..filename_len], raw_dir.entry.filename[0..filename_len]);

        // Remove status bits, encoded in bit 8 of first 2 chars
        for (filename[0..2], 0..) |c, i| {
            filename[i] = c & 0x7f;
        }

        if (raw_dir.entry.filetype[0] != ' ') {
            filename[filename_len] = '.';
            filename_len += 1;
            @memcpy(filename[filename_len .. filename_len + 3], &raw_dir.entry.filetype);

            if (filename_len + 3 < 12)
                filename[filename_len + 3] = ' ';
        }

        var result = CookedDirEntry{
            .user = raw_dir.entry.user,
            .attribs = [_]u8{
                if (raw_dir.attribReadOnly()) 'R' else 'W',
                if (raw_dir.attribSystem()) 'S' else ' ',
            },
            .os = .{ .cpm = .{
                .num_records = raw_dir.entry.num_records,
                .num_allocs = 0,
                .allocations = .empty,
            } },
            .filename = filename,
            .image_type = image_type,
        };
        result.os.cpm.num_allocs = try result.copyAllocations(arena, raw_dir, image_type);
        if (image_type.OS == .cpm and image_type.recs_per_extent > 128 and result.os.cpm.num_allocs > 4) {
            // CPM records only go up to 128.
            result.os.cpm.num_records += 128;
        }
        return result;
    }

    pub fn extend(self: *CookedDirEntry, arena: std.mem.Allocator, raw_dir: *const RawCpmDirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!void {
        self.os.cpm.num_records += raw_dir.entry.num_records;
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
        const pos = std.mem.indexOfScalar(u8, &self.filename, '.') orelse return self.filenameAndExtension();
        return self.filename[0..pos];
    }

    pub fn extensionOnly(self: *const CookedDirEntry) []const u8 {
        const pos = std.mem.indexOfScalar(u8, &self.filename, '.') orelse return "";
        return rawSlice(self.filename[pos + 1 ..]);
    }

    pub fn allocsUsedInKB(self: *const CookedDirEntry) u32 {
        switch (self.os) {
            .cpm => |cpm| return cpm.num_allocs * self.image_type.block_size / 1024,
            .ados => |ados| return ados.used,
        }
    }

    pub fn recordsUsedInB(self: *const CookedDirEntry) u32 {
        return switch (self.os) {
            .cpm => |cpm| cpm.num_records * 128,
            .ados => |ados| ados.size,
        };
    }

    /// Add any new allocations to the list of used allocations.
    fn copyAllocations(cooked: *CookedDirEntry, arena: std.mem.Allocator, raw: *const RawCpmDirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!u8 {
        var alloc_count: u8 = 0;

        try cooked.os.cpm.allocations.ensureUnusedCapacity(arena, raw.entry.allocations.len);
        for (0..raw.allocationsCount(image_type)) |alloc_nr| {
            const allocation = try raw.allocationGet(alloc_nr, image_type);
            // zero means no more allocations.
            if (allocation == 0) {
                break;
            }
            cooked.os.cpm.allocations.appendAssumeCapacity(allocation);
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
        cpm: std.ArrayListUnmanaged(RawCpmDirEntry),
        ados: std.ArrayListUnmanaged(RawAdosDirEntry),
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

    pub fn init(gpa: std.mem.Allocator, image_type: *const DiskImageType) std.mem.Allocator.Error!DirectoryTable {
        var arena = std.heap.ArenaAllocator.init(gpa);
        return .{
            .raw_directories = switch (image_type.OS) {
                .cpm, .cdos => .{ .cpm = try .initCapacity(arena.allocator(), image_type.directories) },
                .ados => .{ .ados = try .initCapacity(arena.allocator(), image_type.directories) },
            },
            .cooked_directories = try .initCapacity(arena.allocator(), image_type.directories),
            .free_allocations = try .initFull(arena.allocator(), image_type.total_allocs),
            .arena = arena,
        };
    }

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
        };
    }

    fn loadCPM(self: *DirectoryTable, image: *DiskImage, option: LoadOption) DirectoryLoadError!void {
        const image_type = image.image_type;
        var sector: DiskSector = undefined;
        const directory_sector_count = image_type.directories / image_type.dir_entries_per_sector;
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
        if (self.raw_directories.cpm.items.len > 0 and self.raw_directories.cpm.items[0].isLabel()) {
            const raw_item = self.raw_directories.cpm.items[0];
            const expected_num_records: u8 = switch (image.image_type.type_id.toCDOS()) {
                .CDOS_SMSSSD, .CDOS_SMDSSD, .CDOS_SMSSDD, .CDOS_LGSSSD => 0x10,
                .CDOS_LGSSDD, .CDOS_LGDSSD, .CDOS_SMDSDD => 0x20,
                .CDOS_LGDSDD => 0x40,
            };
            if (expected_num_records != raw_item.entry.num_records) {
                if (!@import("builtin").is_test) log.err(
                    "CDOS disks with a non-default number of directories are not currently supported. Expected {}, actual {}",
                    .{ @as(u16, expected_num_records) * 4, @as(u16, raw_item.entry.num_records) * 4 },
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
                if (std.mem.eql(u8, &lhs.entry.filename, &rhs.entry.filename)) {
                    if (std.mem.eql(u8, &lhs.entry.filetype, &rhs.entry.filetype)) {
                        if (lhs.entry.user == rhs.entry.user) {
                            return lhs.extentGet(img_type) < rhs.extentGet(img_type);
                        } else {
                            return lhs.entry.user < rhs.entry.user;
                        }
                    } else {
                        return std.mem.lessThan(u8, &lhs.entry.filetype, &rhs.entry.filetype);
                    }
                } else {
                    return std.mem.lessThan(u8, &lhs.entry.filename, &rhs.entry.filename);
                }
            }
        }.lessThan);

        // Create the CookedDirEntries and remove any used allocations from the free alocations set.
        for (raw_dirs_sorted.items, 0..) |dir, i| {
            if (!dir.isDeleted()) {
                const entry_nr = (@intFromPtr(dir) - @intFromPtr(&self.raw_directories.cpm.items[0])) / @sizeOf(RawCpmDirEntry);
                if (option == .full) {
                    try self.buildCookedEntry(@intCast(entry_nr), image_type);
                }
                // Mark off the used allocations
                for (0..dir.allocationsCount(image_type)) |alloc_nr| {
                    const alloc = try dir.allocationGet(alloc_nr, image_type);
                    // 0 marks the end of the used allocations in this extent.
                    if (alloc == 0)
                        break;
                    if (alloc >= image_type.total_allocs) {
                        log.err(
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

    fn loadAltairDOS(self: *DirectoryTable, image: *DiskImage, _: LoadOption) DirectoryLoadError!void {
        // Directory is held on track 70
        // TODO:
        for (0..image.image_type.directory_allocs) |i| {
            // 8 sectors per block (block_size / sector_size_data)
            self.free_allocations.unset(toAllocationADOS(image.image_type, 70, @intCast(i * 8)));
        }
        std.debug.print("allocations len = {}, count = {}\n", .{ self.free_allocations.capacity(), self.free_allocations.count() });
        var sector: DiskSector = .initUnformatted(image.image_type, 70);
        scan: for (0..image.image_type.sectors_per_track) |sector_nr| {
            try image.readSectorPhysical(.{ .track = 70, .sector = @intCast(sector_nr) }, &sector);
            const entries: []RawAdosDirEntry = std.mem.bytesAsSlice(RawAdosDirEntry, sector.dataBytes());
            try self.raw_directories.ados.ensureUnusedCapacity(self.allocator(), entries.len);
            for (entries) |e| {
                if (e.raw.filename[0] == 255) break :scan; // End of directory
                if (e.raw.filename[0] != 0) { // not deleted
                    self.raw_directories.ados.appendAssumeCapacity(e);
                }
            }
        }

        var raw_dirs_sorted: std.ArrayList(*RawAdosDirEntry) = try .initCapacity(self.allocator(), self.raw_directories.ados.items.len);
        defer raw_dirs_sorted.deinit(self.allocator());
        for (self.raw_directories.ados.items) |*raw_dir| {
            raw_dirs_sorted.appendAssumeCapacity(raw_dir);
        }

        std.mem.sort(*RawAdosDirEntry, raw_dirs_sorted.items, {}, struct {
            fn lessThan(_: void, lhs: *RawAdosDirEntry, rhs: *RawAdosDirEntry) bool {
                return std.mem.lessThan(u8, &lhs.raw.filename, &rhs.raw.filename);
            }
        }.lessThan);

        try self.cooked_directories.ensureTotalCapacity(self.allocator(), raw_dirs_sorted.items.len);
        for (raw_dirs_sorted.items) |dir| {
            var cooked: CookedDirEntry = undefined;
            @memset(&cooked.filename, ' ');
            @memcpy(cooked.filename[0..dir.raw.filename.len], &dir.raw.filename);
            cooked.user = 0;
            cooked.attribs[0] = if (dir.raw.mode == 2) 'S' else 'R';
            cooked.attribs[1] = ' ';
            const size = try self.fileSizeADOS(image, dir);
            cooked.os = .{ .ados = .{
                .track = dir.raw.track,
                .sector = dir.raw.sector,
                .size = size.length,
                .used = size.used,
            } };
            cooked.image_type = image.image_type;
            self.cooked_directories.appendAssumeCapacity(cooked);
        }
    }

    // convert track and sector to allocation
    fn toAllocationADOS(image_type: *const DiskImageType, track: u16, sector: u16) u16 {
        const sectors_per_alloc = image_type.block_size / image_type.sector_size_data;
        return @as(u16, track - image_type.reserved_tracks) * (image_type.sectors_per_track / sectors_per_alloc) + @as(u16, sector / sectors_per_alloc);
    }

    // Walk the chain of sectors and calculate the file size.
    // Also free any allocations used by this file.
    fn fileSizeADOS(self: *DirectoryTable, image: *DiskImage, e: *const RawAdosDirEntry) !struct { length: u32, used: u32 } {
        var track_nr = e.raw.track;
        var sector_nr = e.raw.sector;
        var nbytes: u32 = 0;
        var nr_sectors: u32 = 0;

        while (track_nr != 0) {
            const allocation: u16 = @as(u16, e.raw.track - 6) * (32 / 8) + @as(u16, e.raw.sector / 8);
            std.debug.print("unset tk {}, sk {}, al {} \n", .{ e.raw.track, e.raw.sector, allocation });
            self.free_allocations.unset(toAllocationADOS(image.image_type, e.raw.track, e.raw.sector));
            var sector: DiskSector = .initUnformatted(image.image_type, 70);
            try image.readSectorPhysical(.{ .track = track_nr, .sector = sector_nr }, &sector);
            nbytes += sector.mits_track_6_76.nbytes;
            nr_sectors += 1;
            track_nr = sector.mits_track_6_76.next_track;
            sector_nr = sector.mits_track_6_76.next_sector;
        }
        return .{ .length = nbytes, .used = (nr_sectors + 7) / 8 };
    }

    /// Whenever a new extent is created, register it with the directory
    /// Builds up the associated CookedDirEntry as new RawDirEntries are registered.
    pub fn buildCookedEntry(self: *DirectoryTable, raw_entry_nr: u16, image_type: *const DiskImageType) (error{ OutOfMemory, InvalidImageFile } || RawDirError)!void {
        const entry = &self.raw_directories.cpm.items[raw_entry_nr];
        try entry.validate(image_type, raw_entry_nr);
        if (entry.isFirstEntryForFile(image_type)) {
            // std.debug.print("TRUE\n", .{});
            try self.cooked_directories.append(self.allocator(), try CookedDirEntry.init(self.allocator(), entry, image_type));
        } else {
            if (self.cooked_directories.items.len == 0) {
                log.err("Cannot detect first entry for file {s}.{s}: ", .{ entry.entry.filename, entry.entry.filetype });
                return error.InvalidImageFile;
            }
            var prev = &self.cooked_directories.items[self.cooked_directories.items.len - 1];
            try prev.extend(self.allocator(), entry, image_type);
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
        for (to_erase.os.cpm.allocations.items) |alloc| {
            if (alloc == 0) break;
            self.free_allocations.set(alloc);
        }
        to_erase.os.cpm.allocations.clearAndFree(self.allocator());
        // Delete all the raw_entries and write to disk.
        for (self.raw_directories.cpm.items, 0..) |*raw_item, idx| {
            if (raw_item.entry.user == cooked_dir.user and
                std.mem.eql(u8, CookedDirEntry.rawSlice(&raw_item.entry.filename), cooked_dir.filenameOnly()) and
                std.mem.eql(u8, CookedDirEntry.rawSlice(&raw_item.entry.filetype), cooked_dir.extensionOnly()))
            {
                raw_item.setDeleted();
                try disk_image.rawEntryWrite(@intCast(idx));
            }
        }
        // Finally remove the deleted CookedDir.
        _ = self.cooked_directories.orderedRemove(cooked_index);
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

    /// Return a free allocation
    pub fn allocationGetFree(self: *DirectoryTable) error{OutOfAllocs}!u16 {
        const free: ?usize = self.free_allocations.findFirstSet();
        if (free) |free_alloc| {
            self.free_allocations.unset(free_alloc);
            return @intCast(free_alloc);
        } else {
            return error.OutOfAllocs;
        }
    }

    /// Return a free CPM directory entry
    pub fn rawEntryGetFreeInitialized(self: *const DirectoryTable, extent_nr: *u16) error{OutOfExtents}!*RawCpmDirEntry {
        for (self.raw_directories.cpm.items, 0..) |*dir, i| {
            if (dir.isDeleted() and !dir.isLabel()) {
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
            .ados => |ados| {
                for (ados.items) |dir| {
                    if (!dir.isDeleted()) {
                        count += 1;
                    }
                    count = 255 - count; // There are always 255 directories on ADOS
                }
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
