//! Main interface for the altair_disk library.
//! The DiskImage class is used to open and manipulate
//! altair disk image formats.

const all_disk_types = @import("disk_types.zig").all_disk_types;
const DUMP = false;

pub const log = std.log.scoped(.altair_disk_lib);

/// Directory entries keep track of a logical address consisting of:
/// 1) An allocation representing 1 block. Allocations start at 0.
/// 2) A record representing a 128k segment within the block, starting at 1
pub const LogicalAddress = struct {
    allocation: u16,
    record: u8,
};

/// Interface for opening and maniplating various Altair CPM disk images.
pub const DiskImage = struct {
    const Self = @This();

    image_file: std.io.StreamSource, // The file backing the disk image
    image_type: *const DiskImageType,
    directory: DirectoryTable,
    _filename_conversion_buf: [12]u8, // Used to convert local to CPM filenames 8.3 = 12 chars.

    /// Initilize a DiskImage from an opened image file.
    /// Image file must at least have read permissions if the loadDirectory() is called.
    /// Note that DiskImage is not fully initialized until loadDirectories is called.
    /// DiskImage takes ownership of the passed in file and will close it on deinit()
    pub fn init(gpa: std.mem.Allocator, file: std.fs.File, image_type: *const DiskImageType) !DiskImage {
        return _init(gpa, .{ .file = file }, image_type);
    }

    /// Init with a StreamSource.
    /// Note that DiskImage does not take ownership of the stream source and will not close it on deinit()
    pub fn _init(gpa: std.mem.Allocator, stream: std.io.StreamSource, image_type: *const DiskImageType) !DiskImage {
        return .{
            .image_file = stream,
            .image_type = image_type,
            .directory = try .init(gpa, image_type),
            ._filename_conversion_buf = @splat(0),
        };
    }

    /// Close the existing image file and open a new one.
    /// closes any files before an error is returned.
    pub fn reinit(self: *Self, gpa: std.mem.Allocator, file: File) !void {
        self.deinit();
        self.image_file = std.io.StreamSource{ .file = file };
        self.directory = try .init(gpa, self.image_type);
    }

    /// Cleanup and close underlying image file.
    pub fn deinit(self: *Self) void {
        self.directory.deinit();
        // Close file if initialized with a file.
        // If initialized with a stream, caller must close.
        if (self.image_file == .file) {
            self.image_file.file.close();
        }
    }

    /// Load the directory table.
    /// If raw_only is false, CookedDirectories are also loaded,
    /// which are an easier to use verion of the raw cpm directories
    pub fn loadDirectories(self: *Self, raw_only: bool) DirectoryLoadError!void {
        try self.directory.load(self, raw_only);
    }

    /// Return disk free capacity.
    pub fn capacityFreeInKB(self: *const Self) usize {
        const free_allocs = self.directory.free_allocations.count();
        return free_allocs * (self.image_type.block_size / 1024);
    }

    /// Return disk total capacity
    pub fn capacityTotalInKB(self: *const Self) usize {
        const image_type = self.image_type;
        return @as(usize, (image_type.total_allocs - image_type.directory_allocs)) * image_type.block_size / 1024;
    }

    /// Return number of available directory entries
    pub fn directoryFreeCount(self: *const Self) usize {
        return self.directory.rawEntryFreeCount();
    }

    pub const TextMode = enum { Auto, Text, Binary };
    pub fn copyFromImage(self: *Self, entry: *const CookedDirEntry, out_file: File, text_mode: TextMode) !void {
        var stream: std.io.StreamSource = .{ .file = out_file };
        return _copyFromImage(self, entry, &stream, text_mode);
    }

    pub fn _copyFromImage(self: *Self, entry: *const CookedDirEntry, out_file: *std.io.StreamSource, text_mode: TextMode) !void {
        var sector: DiskSector = .init();
        const num_records = entry.num_records;
        // Check for empty file.
        if (entry.allocations.items.len == 0) {
            return;
        }
        for (0..num_records) |total_rec_nr| {
            const rec_nr: u8 = @intCast(total_rec_nr % 128);
            const alloc = entry.allocations.items[total_rec_nr / self.image_type.recs_per_alloc];
            if (alloc == 0)
                break;
            try self.readSector(.{ .record = rec_nr, .allocation = alloc }, &sector);
            var data_len = sector.data.len;
            const check_for_text = text_mode != .Binary;

            // CPM doesn't actually know how long a file is, except in multiples of 128 bytes.
            // So if it is a text file looks for ^Z anywhere in the last sector and use that
            // to mark the EOF. For binary files it doesn't matter if they are too long.
            if (check_for_text and total_rec_nr == num_records - 1) {
                for (sector.data, 0..) |b, i| {
                    if (text_mode == .Auto) {
                        if (b & 0x80 != 0) {
                            break;
                        }
                    }

                    if (check_for_text and total_rec_nr == num_records - 1 and b == 0x1a) {
                        data_len = i;
                        break;
                    }
                }
            }

            try out_file.writer().writeAll(sector.data[0..data_len]);
        }
    }

    /// Try and auto-detect what type of disk image this is
    pub fn detectImageType(image_file: File, is_unique: *bool) ?*const DiskImageType {
        for (&all_disk_types.values) |*dt| {
            if (dt.isCorrectFormat(image_file)) {
                is_unique.* = dt.detect_conditions != .duplicate_size;
                return dt;
            }
        }
        return null;
    }

    pub fn copyToImage(self: *Self, in_file: File, to_filename: []const u8, user: ?u8, force: bool) !void {
        var stream: std.io.StreamSource = .{ .file = in_file };
        return _copyToImage(self, &stream, to_filename, user, force);
    }

    pub fn _copyToImage(self: *Self, stream: *std.io.StreamSource, to_filename: []const u8, user: ?u8, force: bool) !void {
        const cpm_user = user orelse 0;

        const basename = std.fs.path.basename(to_filename);
        if (self.directory.findByFilename(basename, user)) |existing_entry| {
            if (force) {
                try self.erase(existing_entry);
            } else {
                return std.fs.Dir.MakeError.PathAlreadyExists;
            }
        }
        const cpm_filename = DirectoryTable.translateToCPMFilename(basename, &self._filename_conversion_buf);

        var sector: DiskSector = .init();
        var alloc_count: u16 = 0;
        var dir_entry: *RawDirEntry = undefined;
        var extent_nr: u16 = 0;
        var first_extent = true;
        var extent_count: usize = 0;
        var alloc_nr: u16 = undefined;
        var record_nr: u16 = 0;

        // load the data to be stored in this record
        var nbytes = try stream.reader().readAll(&sector.data);

        while (nbytes != 0 or first_extent) : ({
            nbytes = try stream.reader().readAll(&sector.data);
        }) {
            // Is this a new extent? (i.e. needs a new directory entry)
            if (record_nr % self.image_type.recs_per_extent == 0) {
                if (!first_extent) {
                    try self.rawEntryWrite(extent_nr);
                    try self.directory.buildCookedEntry(extent_nr, self.image_type);
                } else {
                    first_extent = false;
                }
                // Note: extent is undefined until here on first loop.
                dir_entry = try self.directory.rawEntryGetFree(&extent_nr);
                dir_entry.filenameAndExtensionSet(cpm_filename);
                dir_entry.user = cpm_user;
                alloc_count = 0;
            }

            // Is this a new record / allocation
            if (record_nr % self.image_type.recs_per_alloc == 0) {
                // Note alloc_nr is undefined until here on first loop.
                alloc_nr = if (nbytes > 0) self.directory.allocationGetFree() catch |err| {
                    try self.rawEntryWrite(@intCast(extent_nr));
                    try self.directory.buildCookedEntry(extent_nr, self.image_type);
                    return err;
                } else 0;

                try dir_entry.allocationSet(alloc_count, alloc_nr, self.image_type);
                alloc_count += 1;
            }
            dir_entry.numRecordsSet(record_nr);
            dir_entry.extentSet(@intCast(extent_count));
            if (nbytes > 0) {
                try self.writeSector(.{ .allocation = alloc_nr, .record = @intCast(record_nr % 256) }, &sector);
                sector = .init(); // Re-fill with ^Z
            }

            record_nr += 1;
            if (record_nr % 128 == 0) {
                extent_count += 1;
            }
        }

        try self.rawEntryWrite(@intCast(extent_nr));
        try self.directory.buildCookedEntry(extent_nr, self.image_type);

        // How this works:
        //
        // Each directory entry controls one "extent", which will control a maximum of 8 allocations.
        // Each allocation represents one block. So if block size is 2048, each extent will be a maximum of 16KB.
        // Each extent can control up to 256 records, where each record controls a single sector of 128 bytes.
        // To store a file, need to do the following:
        // Create a new CPM directory entry
        // For each 128 byte sector. Increment the record number.
        // If reach # recs / alloc, then find a new free allocation.
        // If reach # recs / extent, then write out this directory entry and create a new one
        // If reach rec % 128, then increment the extent cound (to cater for > 128 recs / extent)
        // Note that even for > 128 recs per extent, the rec number still has a max of 128.
        // If 16 bit allocations are used in the CPM entry, the the real record number is 128 + the record number.
        // You can tell if 16 bit allocations are being used if the 5th allocation in the CPM entry is not 0.
        // i.e. when 8 bit allocations are used, a max of 4 of the 8 allocation bytes are used.

    }

    /// Erase a file.
    /// Note that this invalidates any pointers to existing CookedDirEntries
    /// Including any iterators.
    pub fn erase(self: *Self, to_erase: *CookedDirEntry) !void {
        return self.directory.eraseEntry(to_erase, self);
    }

    pub fn extractCPM(self: *Self, out_file: File) !void {
        var sector: DiskSector = .init();

        try self.image_file.seekTo(0);

        for (0..self.image_type.reserved_tracks) |_| {
            for (0..self.image_type.sectors_per_track) |_| {
                const nbytes = try self.image_file.reader().readAll(&sector.data);
                if (nbytes != sector.data.len) {
                    return error.InvalidImageFile;
                }
                try out_file.writeAll(&sector.data);
            }
        }
    }

    pub fn installCPM(self: *Self, in_file: File) !void {
        const in_size = try in_file.getEndPos();
        const expected_size = self.image_type.reserved_tracks * self.image_type.track_size;
        if (in_size != expected_size) {
            return error.InvalidImageFile;
        }

        var sector: DiskSector = .init();
        try self.image_file.seekTo(0);

        for (0..self.image_type.reserved_tracks) |_| {
            for (0..self.image_type.sectors_per_track) |_| {
                const nbytes = try in_file.readAll(&sector.data);
                if (nbytes != sector.data.len) {
                    return error.InvalidImageFile;
                }
                try self.image_file.writer().writeAll(&sector.data);
            }
        }
    }

    pub fn formatImage(self: *Self) !void {
        var disk_sector: DiskSector = .init();
        const varying_sector_format = self.image_type.varying_sector_format;

        // Just in case formatting an existing image file from larger to smaller format.
        if (self.image_file == .file) {
            try self.image_file.file.setEndPos(0);
        }
        try self.image_file.seekTo(0);

        var write_sector: []u8 = undefined;
        if (!varying_sector_format) {
            write_sector = self.image_type.formattedSectorGet(.zero, &disk_sector.data);
        }

        for (0..self.image_type.tracks) |track_nr| {
            for (0..self.image_type.sectors_per_track) |sector_nr| {
                if (varying_sector_format) {
                    write_sector = self.image_type.formattedSectorGet(
                        .{ .track = @truncate(track_nr), .sector = @truncate(sector_nr) },
                        &disk_sector.data,
                    );
                }
                try self.image_file.writer().writeAll(write_sector);
            }
        }
    }

    /// Try and recover an image with invalid directory entries
    pub fn tryRecovery(self: *Self) !void {
        try self.loadDirectories(true);
        for (self.directory.raw_directories.items, 0..) |*raw_dir, i| {
            var saveable = true;
            var valid = false;
            var delete_related = false;
            while (saveable and !valid) {
                raw_dir.validate(self.image_type, @intCast(i)) catch |err| {
                    switch (err) {
                        RawDirError.InvalidUser => {
                            log.info("Error with directory entry {}: User was {}, setting to 0", .{ i, raw_dir.user });
                            raw_dir.user = 0;
                            continue;
                        },
                        else => {
                            saveable = false;
                            continue;
                        },
                    }
                };
                valid = true;
            }
            if (valid and delete_related) {
                if (raw_dir.isFirstEntryForFile(self.image_type)) {
                    delete_related = false;
                }
            }
            if (!valid or delete_related) {
                if (!delete_related) {
                    log.info("Error with directory entry {}: Deleting entry", .{i});
                } else {
                    log.info("Error with directory entry {}: Deleting related entry", .{i});
                }

                delete_related = true;
                raw_dir.setDeleted();
            }
            try self.rawEntryWrite(@intCast(i));
        }
    }

    /// Convert between logical (allocation, record) to physical (track, sector) address.
    fn toPhysicalAddress(self: *const Self, address: LogicalAddress) PhysicalAddress {
        var track: u16 = address.allocation * self.image_type.recs_per_alloc + @rem(address.record, self.image_type.recs_per_alloc);
        track = @divTrunc(track, self.image_type.sectors_per_track) + self.image_type.reserved_tracks;
        const logical_sector = @rem((address.allocation * self.image_type.recs_per_alloc + @rem(address.record, self.image_type.recs_per_alloc)), self.image_type.sectors_per_track);

        log.debug("ALLOCATION[{}], RECORD[{}], LOGICAL[{}], ", .{ address.allocation, address.record, logical_sector });
        const physical_sector = self.image_type.skew(track, logical_sector);
        return PhysicalAddress{ .track = track, .sector = physical_sector };
    }

    /// Get the seek location for reading
    fn seekLocationGetRead(self: *const Self, location: PhysicalAddress) usize {
        return _seekLocationGet(self, location, true);
    }

    /// Get the seek location for writing
    fn seekLocationGetWrite(self: *const Self, location: PhysicalAddress) usize {
        // Write location is different for the MITS 8" disks as we have to write out the track
        // metadata / control data as well.
        return _seekLocationGet(self, location, false);
    }

    fn _seekLocationGet(self: *const Self, location: PhysicalAddress, include_data_offset: bool) usize {
        const offset: usize =
            @as(usize, location.track) * self.image_type.track_size +
            (location.sector - 1) * self.image_type.sector_size;
        if (include_data_offset) {
            return offset + self.image_type.offset(.data, location.track);
        } else {
            return offset;
        }
    }

    pub const ReadSectorError = File.ReadError || File.SeekError;
    /// Read a single 128bytes sector
    pub fn readSector(self: *Self, location: LogicalAddress, data: *DiskSector) ReadSectorError!void {
        const physical_location = self.toPhysicalAddress(location);
        // Sometimes the data is not at the start of the sector. So adjust
        const data_offset = self.seekLocationGetRead(physical_location);

        log.debug("Reading from TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, data_offset });

        try self.image_file.seekTo(@as(u64, @intCast(data_offset)));
        _ = try self.image_file.reader().readAll(&data.data);
        try data.dump();
    }

    const WriteSectorError = File.WriteError || File.SeekError;
    /// Write a single 128 byte sector.
    pub fn writeSector(self: *Self, location: LogicalAddress, data: *DiskSector) WriteSectorError!void {
        const physical_location = self.toPhysicalAddress(location);

        const sector_data = self.image_type.writeableSectorGet(physical_location, &data.data);
        const sector_offset = self.seekLocationGetWrite(physical_location);
        try self.image_file.seekTo(sector_offset);
        try self.image_file.writer().writeAll(sector_data);

        log.debug("Writing to TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, sector_offset });
    }

    /// write a CPM ditory entry (RawDirEntry)
    pub fn rawEntryWrite(self: *Self, extent_nr: u16) (WriteSectorError || RawDirError)!void {

        // Make sure entry is valid before written.
        const this_entry = &self.directory.raw_directories.items[extent_nr];
        if (!this_entry.isDeleted()) {
            try this_entry.validate(self.image_type, extent_nr);
        }

        var sector: DiskSector = .init();
        const allocation = extent_nr / self.image_type.extents_per_alloc;
        const record: u8 = @intCast(extent_nr / DiskImageType.dir_entries_per_sector);
        // start_index is the index of the directory entry that is at
        // the beginning of this sector
        const start_index = extent_nr / DiskImageType.dir_entries_per_sector * DiskImageType.dir_entries_per_sector;
        // Copy 1 full sector worth of extents/raw entries
        const dest: *[DiskImageType.dir_entries_per_sector]RawDirEntry = @ptrCast(@alignCast(&sector.data));
        const source = self.directory.raw_directories.items[start_index .. start_index + DiskImageType.dir_entries_per_sector];
        @memcpy(dest, source);
        try self.writeSector(.{ .allocation = allocation, .record = record }, &sector);
    }
};

/// A single 128 byte disk sector.
pub const DiskSector = struct {
    data: [DiskImageType.sector_data_size]u8,

    pub fn init() DiskSector {
        // Initialized to ^Z.
        return .{ .data = @splat(0x1a) };
    }

    pub fn dump(self: DiskSector) !void {
        if (!DUMP)
            return;
        std.debug.print("Disk Sector: \n", .{});
        std.debug.dumpHex(self.data);
    }
};

const std = @import("std");
const Console = @import("console.zig");
const DiskImageType = @import("disk_types.zig").DiskImageType;
const PhysicalAddress = @import("disk_types.zig").PhysicalAddress;
const DirectoryTable = @import("directory_table.zig").DirectoryTable;
const CookedDirEntry = @import("directory_table.zig").CookedDirEntry;
const DirectoryLoadError = DirectoryTable.DirectoryLoadError;
const RawDirEntry = @import("directory_table.zig").RawDirEntry;
const RawDirError = @import("directory_table.zig").RawDirError;
const File = std.fs.File;
