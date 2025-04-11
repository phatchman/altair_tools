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

const log = @import("disk_image.zig").log;

/// Validation errors
pub const RawDirError = error{
    InvalidUser,
    InvalidExtent,
    InvalidRecordNumber,
    InvalidAllocation,
    InvalidEntryNumber,
};

/// Raw on-disk version of the directory entry
pub const RawDirEntry = extern struct {
    user: u8,
    filename: [8]u8,
    filetype: [3]u8,
    extent_low: u8,
    reserved: u8,
    extent_hi: u8,
    num_records: u8,
    _allocations: [DiskImageType.allocs_per_extent]u8,

    pub const empty: RawDirEntry = std.mem.zeroes(RawDirEntry);
    pub const filename_len = 8;
    pub const filetype_len = 3;

    pub fn validate(self: *const RawDirEntry, image_type: *const DiskImageType, extent_nr: u16) RawDirError!void {
        if (self.user > DiskImageType.max_user and self.user != 0xe5) {
            log.err(
                "Invalid directory entry: {} [Invalid user: {}. Must be 0-{} or {}]",
                .{ extent_nr, self.user, DiskImageType.max_user, 0xe5 },
            );
            return RawDirError.InvalidUser;
        }

        const max_entents = image_type.extents_per_alloc * image_type.total_allocs;
        if (self.extentGet() >= max_entents) {
            log.err(
                "Invalid directory entry: {} [Invalid extent: {}. Must be 0-{}]",
                .{ extent_nr, self.extentGet(), max_entents },
            );
            return RawDirError.InvalidExtent;
        }

        if (self.num_records > image_type.recs_per_extent) {
            log.err(
                "Invalid directory entry: {} [Invalid num_records: {}. Must be 0-{}]",
                .{ extent_nr, self.num_records, image_type.recs_per_extent },
            );
            return RawDirError.InvalidRecordNumber;
        }
        for (0..self.allocationsCount()) |i| {
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

    pub fn isDeleted(self: *const RawDirEntry) bool {
        return self.user > DiskImageType.max_user;
    }

    pub fn setDeleted(self: *RawDirEntry) void {
        self.user = 0xe5;
    }

    /// Set num_records field.
    pub fn numRecordsSet(self: *RawDirEntry, record_nr: u16) void {
        self.num_records = @intCast((record_nr % 128) + 1);
    }

    /// Get extent as 16 bit value
    pub fn extentGet(self: *const RawDirEntry) u16 {
        return @as(u16, self.extent_hi) * 32 + self.extent_low;
    }

    /// Set extent from 16 bit value
    pub fn extentSet(self: *RawDirEntry, extent_count: u16) void {
        self.extent_low = @intCast(extent_count % 32);
        self.extent_hi = @intCast(extent_count / 32);
    }

    pub fn attribReadOnly(self: *const RawDirEntry) bool {
        return self.filename[0] & 0x80 != 0;
    }

    pub fn attribSystem(self: *const RawDirEntry) bool {
        return self.filename[1] & 0x80 != 0;
    }

    /// Set allocation as controlled by this extent
    pub fn allocationSet(self: *RawDirEntry, entry_nr: usize, record_nr: u16, image_type: *const DiskImageType) RawDirError!void {
        if (entry_nr >= self.allocationsCount()) {
            return RawDirError.InvalidEntryNumber;
        }
        if (image_type.total_allocs <= 256) {
            // 8 bit allocations
            self._allocations[entry_nr] = @intCast(record_nr & 0xff);
        } else {
            // 16 bit allocations.
            var alloc: [2]u8 = undefined;
            std.mem.writeInt(u16, &alloc, record_nr, .little);
            self._allocations[entry_nr * 2] = alloc[0];
            self._allocations[entry_nr * 2 + 1] = alloc[1];
        }
    }

    /// Get the number of an allocation controlled by this extent
    pub fn allocationGet(self: *const RawDirEntry, entry_nr: usize, image_type: *const DiskImageType) RawDirError!u16 {
        if (entry_nr >= self.allocationsCount()) {
            return RawDirError.InvalidEntryNumber;
        }
        if (image_type.total_allocs <= 256) {
            return self._allocations[entry_nr];
        } else {
            const alloc: [2]u8 = .{ self._allocations[entry_nr * 2], self._allocations[entry_nr * 2 + 1] };
            return std.mem.readInt(u16, &alloc, .little);
        }
    }

    /// How many allocations are controlled by this extent?
    pub fn allocationsCount(self: *const RawDirEntry) u16 {
        _ = self;
        return DiskImageType.allocs_per_extent / 2;
    }

    pub fn filenameAndExtensionSet(self: *RawDirEntry, filename: []const u8) void {
        const dot_pos = std.mem.indexOfScalar(u8, filename, '.') orelse filename.len;
        self.filename = @splat(' ');
        self.filetype = @splat(' ');
        @memcpy(self.filename[0..dot_pos], filename[0..dot_pos]);
        if (dot_pos != filename.len) {
            const type_len = @min(self.filetype.len + 1, filename.len - dot_pos - 1);
            @memcpy(self.filetype[0..type_len], filename[dot_pos + 1 .. dot_pos + type_len + 1]);
        }
    }

    pub fn isFirstEntryForFile(self: *const RawDirEntry, image_type: *const DiskImageType) bool {
        if (image_type.recs_per_extent > 128 and self._allocations[4] != 0 and self.extentGet() == 1) {
            return true;
        }
        return self.extentGet() == 0;
    }
};

/// An easier to use version of the raw entry.
pub const CookedDirEntry = struct {
    raw_indexes: std.ArrayListUnmanaged(u16),
    user: u8,
    extent_nr: u16,
    attribs: [2]u8,
    num_records: u32,
    num_allocs: u32,
    allocations: std.ArrayListUnmanaged(u16),
    _filename: [12]u8, // Filename is a slice onto this.
    image_type: *const DiskImageType,

    pub fn init(arena: std.mem.Allocator, raw_dir: *const RawDirEntry, raw_index: u16, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!CookedDirEntry {
        var _filename: [12]u8 = @splat(' '); // space terminated strings!

        var filename_len = rawStrlen(&raw_dir.filename);
        @memcpy(_filename[0..filename_len], raw_dir.filename[0..filename_len]);

        // Remove status bits, encoded in bit 8 of first 2 chars
        for (_filename[0..2], 0..) |c, i| {
            _filename[i] = c & 0x7f;
        }

        if (raw_dir.filetype[0] != ' ') {
            _filename[filename_len] = '.';
            filename_len += 1;
            @memcpy(_filename[filename_len .. filename_len + 3], &raw_dir.filetype);

            if (filename_len + 3 < 12)
                _filename[filename_len + 3] = ' ';
        }

        var result = CookedDirEntry{
            .raw_indexes = .empty,
            .user = raw_dir.user,
            .extent_nr = raw_dir.extentGet(),
            .attribs = [_]u8{
                if (raw_dir.attribReadOnly()) 'R' else 'W',
                if (raw_dir.attribSystem()) 'S' else ' ',
            },
            .num_records = raw_dir.num_records,
            .num_allocs = 0,
            .allocations = .empty,
            ._filename = _filename,
            .image_type = image_type,
        };
        try result.raw_indexes.append(arena, raw_index);
        result.num_allocs = try result.copyAllocations(arena, raw_dir, image_type);
        if (image_type.recs_per_extent > 128 and result.num_allocs > 4) {
            result.num_records += 128;
        }
        return result;
    }

    pub fn extend(self: *CookedDirEntry, arena: std.mem.Allocator, raw_dir: *const RawDirEntry, raw_index: u16, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!void {
        try self.raw_indexes.append(arena, raw_index);
        self.num_records += raw_dir.num_records;
        const num_allocs = try self.copyAllocations(arena, raw_dir, image_type);
        self.num_allocs += num_allocs;
        if (image_type.recs_per_extent > 128 and num_allocs > 4) {
            self.num_records += 128;
        }
    }

    pub fn filenameAndExtension(self: *const CookedDirEntry) []const u8 {
        return rawSlice(&self._filename);
    }

    pub fn filenameOnly(self: *const CookedDirEntry) []const u8 {
        const pos = std.mem.indexOfScalar(u8, &self._filename, '.') orelse return self.filenameAndExtension();
        return self._filename[0..pos];
    }

    pub fn extension(self: *const CookedDirEntry) []const u8 {
        const pos = std.mem.indexOfScalar(u8, &self._filename, '.') orelse return "";
        return rawSlice(self._filename[pos + 1 ..]);
    }

    pub fn allocsUsedInKB(self: *const CookedDirEntry) u32 {
        return (self.num_allocs * self.image_type.block_size) / 1024;
    }

    pub fn recordsUsedInB(self: *const CookedDirEntry) u32 {
        return self.num_records * DiskImageType.sector_data_size;
    }

    /// Add any new allocations to teh list of used allocations.
    fn copyAllocations(cooked: *CookedDirEntry, arena: std.mem.Allocator, raw: *const RawDirEntry, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!u8 {
        var alloc_count: u8 = 0;
        try cooked.allocations.ensureUnusedCapacity(arena, DiskImageType.allocs_per_extent / 2);
        for (0..raw.allocationsCount()) |alloc_nr| {
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
    fn rawSlice(str: []const u8) []const u8 {
        return str[0..rawStrlen(str)];
    }
};

/// Stores and populates the raw and cooked directory entries
pub const DirectoryTable = struct {
    const Self = @This();
    /// All dynamic allocations should use this allocator.
    arena: std.heap.ArenaAllocator,

    /// The CPM directory entries in on-disk format.
    /// note there may be multiple raw entries per file.
    raw_directories: std.ArrayListUnmanaged(RawDirEntry),

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
            .raw_directories = try .initCapacity(arena.allocator(), image_type.directories),
            .cooked_directories = try .initCapacity(arena.allocator(), image_type.directories),
            .free_allocations = try .initFull(arena.allocator(), image_type.total_allocs),
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// All allocations need to be done via this allocator so they can be
    /// freed in deinit.
    fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub const DirectoryLoadError = (error{OutOfMemory} || DiskImage.ReadSectorError || RawDirError);
    /// Load the directory table
    /// raw_only: Load only the raw entries. Useful if the image has been corrupted.
    pub fn load(self: *Self, image: *DiskImage, raw_only: bool) DirectoryLoadError!void {
        const image_type = image.image_type;
        var sector: DiskSector = .init();
        const directory_sector_count = image_type.directories / DiskImageType.dir_entries_per_sector;
        var raw_dir_index: usize = 0;
        var sector_nr: u16 = 0;

        // Reserve allocations used for directories
        for (0..image_type.directory_allocs) |i| {
            self.free_allocations.unset(i);
        }

        while (sector_nr < directory_sector_count) : ({
            sector_nr += 1;
            raw_dir_index += DiskImageType.dir_entries_per_sector;
        }) {
            const logical_address = LogicalAddress{
                .allocation = sector_nr / image_type.recs_per_alloc,
                .record = @intCast(sector_nr % image_type.recs_per_alloc),
            };
            // Read the raw CPM directory entries and add them to the raw_directories array.
            try image.readSector(logical_address, &sector);
            const entries = std.mem.bytesAsSlice(RawDirEntry, &sector.data);
            self.raw_directories.appendSliceAssumeCapacity(entries);
        }

        // Create the CookedDirEntries and remove any used allocations from the free alocations set.
        for (self.raw_directories.items, 0..) |dir, i| {
            if (!dir.isDeleted()) {
                self.buildCookedEntry(@intCast(i), image_type) catch |err| {
                    if (!raw_only) return err;
                };
                // Mark off the used allocations
                for (0..dir.allocationsCount()) |alloc_nr| {
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
                if (lhs.user != rhs.user) {
                    return lhs.user < rhs.user;
                }
                return lhs.extent_nr < rhs.extent_nr;
            }
        }.lessThan);
    }

    /// Whenever a new extent is created, register it with the directory
    /// Builds up the associated CookedDirEntry as new RawDirEntries are registered.
    pub fn buildCookedEntry(self: *Self, raw_entry_nr: u16, image_type: *const DiskImageType) (error{OutOfMemory} || RawDirError)!void {
        const entry = &self.raw_directories.items[raw_entry_nr];
        try entry.validate(image_type, raw_entry_nr);
        if (entry.isFirstEntryForFile(image_type)) {
            try self.cooked_directories.append(self.allocator(), try CookedDirEntry.init(self.allocator(), entry, raw_entry_nr, image_type));
        } else {
            // Note: Requires that we always add in order and we can rely on ther prev entry
            // being the last entry
            var prev = &self.cooked_directories.items[self.cooked_directories.items.len - 1];
            try prev.extend(self.allocator(), entry, raw_entry_nr, image_type);
        }
    }

    /// Remove a file from the image.
    pub fn eraseEntry(self: *Self, to_erase: *CookedDirEntry, disk_image: *DiskImage) !void {
        const cooked_index: usize = try index: {
            for (self.cooked_directories.items, 0..) |cooked, i| {
                if (std.meta.eql(to_erase.*, cooked)) {
                    break :index i;
                }
            }
            break :index error.CookedDirEntryNotFound;
        };
        // Set the allocs used by this cooked entry as free.
        for (to_erase.allocations.items) |alloc| {
            if (alloc == 0) break;
            self.free_allocations.set(alloc);
        }
        to_erase.allocations.clearAndFree(self.allocator());
        // Delete all the raw_entries and write to disk.
        for (to_erase.raw_indexes.items) |raw_index| {
            var raw_entry = &self.raw_directories.items[raw_index];
            raw_entry.setDeleted();
            try disk_image.rawEntryWrite(raw_index);
        }

        // Finally removed the deleted CookedDir.
        _ = self.cooked_directories.swapRemove(cooked_index);
    }

    /// Performs a wildcard lookup of the directory. * and ? are supported wildcard characters.
    /// Use the returned FileNameIterator to walk through the directory entries
    pub fn findByFileNameWildcards(self: *const Self, pattern: []const u8, user: ?u8) FileNameIterator {
        return FileNameIterator.init(self.cooked_directories.items, pattern, user);
    }

    /// Find by exact match. Case insentitive.
    pub fn findByFilename(self: *const Self, filename: []const u8, user: ?u8) ?*CookedDirEntry {
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
    pub fn translateToCPMFilename(filename: []const u8, buffer: []u8) error{InvalidFilename}![]u8 {
        var found_dot: bool = false;
        var char_count: usize = 0;
        var ext_count: usize = 0;
        const end_in = filename.ptr + filename.len;
        var in_char: [*]const u8 = filename.ptr; // Caution! Not bounds checked
        var out_char: [*]u8 = buffer.ptr; // Caution! Not bounds checked
        const filename_len = RawDirEntry.filename_len;
        const ext_len = RawDirEntry.filetype_len;
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
    pub fn allocationGetFree(self: *Self) error{OutOfAllocs}!u16 {
        const free = self.free_allocations.findFirstSet();
        if (free) |free_alloc| {
            self.free_allocations.unset(free_alloc);
            return @intCast(free_alloc);
        } else {
            return DirectoryError.OutOfAllocs;
        }
    }

    /// Return a free CPM directory entry
    pub fn rawEntryGetFree(self: *const Self, extent_nr: *u16) error{OutOfExtents}!*RawDirEntry {
        for (self.raw_directories.items, 0..) |*dir, i| {
            if (dir.isDeleted()) {
                extent_nr.* = @intCast(i);
                dir.* = .empty;
                return dir;
            }
        }
        return DirectoryError.OutOfExtents;
    }

    /// Number of free CPM directory entries
    pub fn rawEntryFreeCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.raw_directories.items) |dir| {
            if (!dir.isDeleted()) {
                count += 1;
            }
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
const DiskSector = @import("disk_image.zig").DiskSector;
const LogicalAddress = @import("disk_image.zig").LogicalAddress;
