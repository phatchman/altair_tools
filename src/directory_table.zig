// TODO: Replace all of the checks on attribs for 'Status'
const log = std.log.scoped(.altair_disk_lib);
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

/// An abstracted view of the on-disk raw directory entry.
pub const CookedDirEntry = struct {
    pub const filename_max = 24;
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
    filename: [filename_max]u8,
    has_extension: bool,

    const FileType = enum { small, large, random_access, sequential, normal };
    pub fn fileType(self: *const CookedDirEntry) FileType {
        return switch (self.os) {
            .cpm => .normal,
            .ados => switch (self.attribs[1]) {
                'S' => .sequential,
                'R' => .random_access,
                else => unreachable,
            },
            .hd_basic => switch (self.attribs[1]) {
                'S' => .small,
                'L' => .large,
                else => unreachable,
            },
        };
    }

    pub fn filenameOnlyMaxLen(os: OperatingSystem) u8 {
        return switch (os) {
            .cdos, .cpm => os_cpm.DirEntry.filename_len,
            .ados => os_ados.DirEntry.filename_len,
            .hd_basic => os_hd_basic.DirEntry.filename_len,
        };
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

    pub fn createdDate(self: *const CookedDirEntry) ?[3]u8 {
        switch (self.os) {
            inline else => |os| {
                if (@hasField(@TypeOf(os), "creation_date")) {
                    return os.creation_date;
                }
            },
        }
        return null;
    }

    pub fn modifiedDate(self: *const CookedDirEntry) ?[3]u8 {
        switch (self.os) {
            inline else => |os| {
                if (@hasField(@TypeOf(os), "modification_date")) {
                    return os.modification_date;
                }
            },
        }
        return null;
    }

    /// Return the length of a space terminated string.
    pub fn rawStrlen(str: []const u8) usize {
        return std.mem.indexOfScalar(u8, str, ' ') orelse str.len;
    }

    /// Return a slice representing the value of a space-termianted string.
    pub fn rawSlice(str: []const u8) []const u8 {
        return str[0..rawStrlen(str)];
    }
};

/// Stores and populates the raw and cooked directory entries
pub const DirectoryTable = struct {
    /// All dynamic allocations should use this allocator.
    arena: std.heap.ArenaAllocator,

    /// The CPM directory entries in on-disk format.
    /// note there may be multiple raw entries per file.
    raw_directories: union(enum) {
        cpm: std.ArrayList(os_cpm.DirEntry),
        ados: std.ArrayList(os_ados.DirEntry),
        hd_basic: std.ArrayList(os_hd_basic.DirEntry),
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

    pub fn deinit(self: *DirectoryTable) void {
        self.arena.deinit();
    }

    /// All allocations need to be done via this allocator so they can be
    /// freed in deinit.
    pub fn allocator(self: *DirectoryTable) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub const LoadOption = enum { full, raw_only };
    pub const DirectoryLoadError = (error{ OutOfMemory, InvalidImageFile } || DiskImage.ReadSectorError || RawDirError);
    /// Load the directory table
    pub fn load(self: *DirectoryTable, image: *DiskImage, option: LoadOption) DirectoryLoadError!void {
        try switch (image.image_type.OS) {
            .cpm, .cdos => os_cpm.loadDirectory(image, option),
            .ados => os_ados.loadDirectory(image, option),
            .hd_basic => os_hd_basic.loadDirectory(self.arena.allocator(), self, image, option),
        };
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
            // TODO: Does anything use allocation zero? This is CPM-specific.
            if (alloc == 0) break;
            self.allocationSetFree(disk_image, cooked_dir, alloc);
        }
        cooked_dir.allocations.clearAndFree(self.allocator());
        // Make sure to always remove the deleted CookedDir.
        defer _ = self.cooked_directories.orderedRemove(cooked_index);

        // Delete all the raw_entries and write to disk.
        switch (self.raw_directories) {
            // FUTURE TODO: It is only CPM that needs to scan through all the entries.
            inline else => |raw_dirs, os| {
                for (raw_dirs.items, 0..) |*raw_item, idx| {
                    if (!raw_item.isDeleted() and raw_item.eql(cooked_dir)) {
                        raw_item.setDeleted();
                        try disk_image.rawEntryWrite(@intCast(idx));
                        // For altair dos, also need to go through and set all of the file numbers in each
                        // sector, the bytes_written, next_track and next_sector to 0
                        switch (os) {
                            .ados => {
                                try os_ados.clearErasedSectors(disk_image, raw_item);
                            },
                            .hd_basic => {
                                try os_hd_basic.writeAllocationBitmap(disk_image);
                            },
                            else => {},
                        }
                        return;
                    }
                }
            },
        }
    }

    fn allocationSetFree(self: *DirectoryTable, image: *DiskImage, to_erase: *const CookedDirEntry, alloc: u16) void {
        switch (self.image_type.OS) {
            .hd_basic => os_hd_basic.allocationSetFree(image, to_erase, alloc),
            else => self.free_allocations.set(alloc),
        }
    }

    /// Translate from host filename to image-compatible filename.
    pub fn translateToFilename(os: OperatingSystem, from_filename: []const u8, to_filename: []u8) error{InvalidFilename}![]u8 {
        return switch (os) {
            .cpm, .cdos => os_cpm.translateFilename(from_filename, to_filename),
            .ados => os_ados.translateFilename(from_filename, to_filename),
            .hd_basic => os_hd_basic.translateFilename(from_filename, to_filename),
        };
    }

    /// Performs a wildcard lookup of the directory. * and ? are supported wildcard characters.
    /// Use the returned FileNameIterator to walk through the directory entries
    pub fn findByFileNameWildcards(self: *const DirectoryTable, pattern: []const u8, user: ?u8) FileNameIterator {
        return FileNameIterator.init(self.cooked_directories.items, pattern, user);
    }

    /// Find by exact match. Case insentitive.
    /// FUTURE TODO: not all formats are case insensitive.
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

    /// Number of free directory entries
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

    /// Validation errors
    pub const RawDirError = error{
        InvalidUser,
        InvalidExtent,
        InvalidRecordNumber,
        InvalidAllocation,
        InvalidEntryNumber,
        InvalidDirectoryEntry,
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
    // FUTURE TODO: not all filesystems have extensions and some are case sensitive
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

const os_hd_basic = @import("os_hd_basic.zig");
const os_cpm = @import("os_cpm.zig");
const os_ados = @import("os_altair_dos.zig");

const DiskImageType = @import("disk_types.zig").DiskImageType;
const DiskImage = @import("disk_image.zig").DiskImage;
const DiskSector = @import("disk_types.zig").DiskSector;
const OperatingSystem = @import("disk_types.zig").OperatingSystem;
const PhysicalAddress = @import("disk_types.zig").PhysicalAddress;
