//! Main interface for the altair_disk library.
//! The DiskImage class is used to open and manipulate
//! altair disk image formats.

const all_disk_types = @import("disk_types.zig").all_disk_types;
// Display raw disk sectors in hex as they are read.
const DUMP = false;

pub const log = std.log.scoped(.altair_disk_lib);

/// Directory entries keep track of a logical address consisting of:
/// 1) An allocation representing 1 block. Allocations start at 0.
/// 2) A record representing a 128k segment within the block, starting at 1
pub const LogicalAddress = struct {
    allocation: u16,
    record: u8,
};

pub const SeekableReader = union(enum) {
    on_disk: *std.Io.File.Reader,
    in_memory: *std.Io.Reader,

    pub fn seekTo(self: SeekableReader, offset: u64) File.Reader.SeekError!void {
        switch (self) {
            .on_disk => |file| try file.seekTo(offset),
            .in_memory => |mem| {
                std.debug.assert(offset <= mem.buffer.len);
                mem.seek = offset;
            },
        }
    }

    pub fn interface(self: SeekableReader) *std.Io.Reader {
        return switch (self) {
            .on_disk => |file| &file.interface,
            .in_memory => |mem| mem,
        };
    }
};

pub const SeekableWriter = union(enum) {
    on_disk: *std.Io.File.Writer,
    in_memory: *std.Io.Writer,

    pub fn seekTo(self: SeekableWriter, offset: u64) (File.Writer.SeekError || Io.Writer.Error)!void {
        switch (self) {
            .on_disk => |file| try file.seekTo(offset),
            .in_memory => |mem| {
                std.debug.assert(offset <= mem.buffer.len);
                mem.end = offset;
            },
        }
    }

    pub fn interface(self: SeekableWriter) *std.Io.Writer {
        return switch (self) {
            .on_disk => |file| &file.interface,
            .in_memory => |mem| mem,
        };
    }

    pub fn truncate(self: SeekableWriter) (File.Writer.EndError || File.Writer.SeekError || Io.Writer.Error)!void {
        return switch (self) {
            .on_disk => |file| {
                try file.seekTo(0);
                try file.end();
            },
            .in_memory => |mem| {
                mem.end = 0;
            },
        };
    }
};

/// Interface for opening and maniplating various Altair CPM disk images.
pub const DiskImage = struct {
    const Self = @This();

    reader: SeekableReader,
    writer: SeekableWriter,
    image_type: *const DiskImageType,
    directory: DirectoryTable,
    _filename_conversion_buf: [12]u8, // Used to convert local to CPM filenames 8.3 = 12 chars.

    /// Initilize a DiskImage from an opened image file.
    /// Image file must at least have read permissions if the loadDirectories() is called.
    /// Note: 1) DiskImage is not fully initialized until loadDirectories() is called.
    ///       2) Caller is responsible for closing the underlying file after deinit()
    pub fn init(gpa: std.mem.Allocator, reader: SeekableReader, writer: SeekableWriter, image_type: *const DiskImageType) !DiskImage {
        return .{
            .reader = reader,
            .writer = writer,
            .image_type = image_type,
            .directory = try .init(gpa, image_type),
            ._filename_conversion_buf = @splat(0),
        };
    }

    /// Close the existing image file and open a new one.
    /// closes any files before an error is returned.
    pub fn reinit(self: *Self, gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        self.deinit();
        self.reader = reader;
        self.writer = writer;
        self.directory = try .init(gpa, self.image_type);
    }

    /// Cleanup.
    /// Caller should close underlying file after calling deinit()
    pub fn deinit(self: *Self) void {
        self.directory.deinit();
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

    pub fn copyFromImage(self: *Self, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) !void {
        var sector: DiskSector = .init(self.image_type); // TODO: Just make this sector data size, rather than image_type.
        const num_records = entry.num_records;
        // Check for empty file.
        if (entry.allocations.items.len == 0) {
            return;
        }
        const recs_per_sector = (self.image_type.sector_data_size / 128);
        const num_sectors = num_records / recs_per_sector; // TODO: Calc this
        var total_rec_nr: u16 = 0;
        for (0..num_sectors) |sec_nr| {
            //            const rec_nr: u8 = @intCast(total_rec_nr % 128);
            // This protects against trying to copy files from CDOS.
            const alloc_idx = total_rec_nr / self.image_type.recs_per_alloc;
            if (alloc_idx >= entry.allocations.items.len) {
                std.debug.print("num_record = {}, total_rec_nr = {}, rec_nr = {}, alloc_idx = {}, recs_per_alloc = {}, allocs.len = {}, total_allocs = {} num records = {}\n", .{
                    num_records,
                    0, //total_rec_nr,
                    0, // rec_nr,
                    alloc_idx,
                    self.image_type.recs_per_alloc,
                    entry.allocations.items.len,
                    self.image_type.total_allocs,
                    entry.num_records,
                });
                return error.InvalidRecordNumber;
            }
            const alloc = entry.allocations.items[alloc_idx];
            if (alloc == 0)
                break;
            //            try self.readSector(.{ .record = rec_nr, .allocation = alloc }, &sector);
            try self.readSector(.{ .record = @intCast(sec_nr % self.image_type.recs_per_alloc), .allocation = alloc }, &sector);
            var data_len: usize = sector.sector_len;
            const check_for_text = text_mode != .Binary;

            // CPM doesn't actually know how long a file is, except in multiples of 128 bytes.
            // So if it is a text file looks for ^Z anywhere in the last sector and use that
            // to mark the EOF. For binary files it doesn't matter if they are too long.
            if (check_for_text and total_rec_nr == num_records - 1) {
                for (sector.data(), 0..) |b, i| {
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

            try out_writer.writeAll(sector.data()[0..data_len]);
            total_rec_nr += recs_per_sector;
            // TODO:
            //            if (sec_nr == 2) @breakpoint();
        }
    }

    /// Try and auto-detect what type of disk image this is
    pub fn detectImageType(io: std.Io, image_file: File, is_unique: *bool) ?*const DiskImageType {
        for (&all_disk_types.values) |*dt| {
            if (dt.isCorrectFormat(io, image_file)) {
                is_unique.* = dt.detect_conditions != .duplicate_size;
                return dt;
            }
        }
        return null;
    }

    pub fn copyToImage(self: *Self, file_reader: *std.Io.Reader, to_filename: []const u8, user: ?u8, force: bool) !void {
        const cpm_user = user orelse 0;

        const basename = std.fs.path.basename(to_filename);
        const cpm_filename = try DirectoryTable.translateToCPMFilename(basename, &self._filename_conversion_buf);
        if (self.directory.findByFilename(cpm_filename, user)) |existing_entry| {
            if (force) {
                try self.erase(existing_entry);
            } else {
                return std.Io.File.OpenError.PathAlreadyExists;
            }
        }

        var sector: DiskSector = .init(self.image_type);
        var alloc_count: u16 = 0;
        var dir_entry: *RawDirEntry = undefined;
        var extent_nr: u16 = 0;
        var first_extent = true;
        var extent_count: usize = 0;
        var alloc_nr: u16 = undefined;
        var record_nr: u16 = 0;
        var nbytes: usize = 0;

        // TODO: This whole thing needs a big cleanup!!!
        nbytes = try file_reader.readSliceShort(sector.data());

        while (nbytes != 0 or first_extent) : ({
            nbytes = try file_reader.readSliceShort(sector.data());
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
                dir_entry.entry.user = cpm_user;
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
                sector = .init(self.image_type); // Re-fill with ^Z
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

    pub fn extractCPM(self: *Self, io: std.Io, out_file: File) !void {
        var sector: DiskSector = .init(self.image_type);

        try self.reader.seekTo(0);

        for (0..self.image_type.reserved_tracks) |_| {
            for (0..self.image_type.sectors_per_track) |_| {
                // TODO: Log error here?
                self.reader.interface().readSliceAll(sector.data()) catch return error.InvalidImageFile;
                var writer = out_file.writer(io, &.{});
                try writer.interface.writeAll(sector.data());
            }
        }
    }

    pub fn installCPM(self: *Self, io: std.Io, in_file: File) !void {
        const in_size = try in_file.length(io);
        const expected_size = self.image_type.reserved_tracks * self.image_type.track_size;
        if (in_size != expected_size) {
            return error.InvalidImageFile;
        }

        var buf: [4096]u8 = undefined;
        var file_reader = in_file.reader(io, &buf);
        _ = try file_reader.interface.streamRemaining(self.writer.interface());
        try self.writer.seekTo(0);
    }

    pub fn formatImage(self: *Self) !void {
        var disk_sector: DiskSector = .init(self.image_type);
        const varying_sector_format = self.image_type.varying_sector_format;

        // Just in case formatting an existing image file from larger to smaller format.
        try self.writer.truncate();

        // Small optimization. If the format does not vary, just get the formatted sector only once.
        var write_sector: []u8 = undefined;
        if (!varying_sector_format) {
            write_sector = self.image_type.formattedSectorGet(.zero, disk_sector.data());
        }

        for (0..self.image_type.tracks) |track_nr| {
            for (0..self.image_type.sectors_per_track) |sector_nr| {
                if (varying_sector_format) {
                    // Request a new formatted sector for each sector.
                    write_sector = self.image_type.formattedSectorGet(
                        .{ .track = @truncate(track_nr), .sector = @truncate(sector_nr) },
                        disk_sector.data(),
                    );
                }
                try self.writer.interface().writeAll(write_sector);
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
                            log.info("Error with directory entry {}: User was {}, setting to 0", .{ i, raw_dir.entry.user });
                            raw_dir.entry.user = 0;
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
        if (true) {
            //const recs_per_sector = self.image_type.sector_data_size / 128;
            const sectors_per_alloc = self.image_type.block_size / self.image_type.sector_data_size;

            const absolute_sector = address.allocation * sectors_per_alloc + (address.record % sectors_per_alloc);
            //            const absolute_sector = address.allocation * sectors_per_alloc + address.record * recs_per_sector;
            const track: u16 = self.image_type.reserved_tracks + (absolute_sector / self.image_type.sectors_per_track);
            const logical_sector = absolute_sector % self.image_type.sectors_per_track;

            log.debug("ALLOCATION[{}], RECORD[{}], LOGICAL[{}], ", .{ address.allocation, address.record, logical_sector });
            // std.debug.print("ALLOCATION[{}], RECORD[{}], TRACK[{}], ABS [{}], LOGICAL[{}]", .{ address.allocation, address.record, track, absolute_sector, logical_sector });
            const physical_sector = self.image_type.skew(track, logical_sector);
            return PhysicalAddress{ .track = track, .sector = physical_sector };
        } else {
            var track: u16 = address.allocation * self.image_type.recs_per_alloc + @rem(address.record, self.image_type.recs_per_alloc);
            track = @divTrunc(track, self.image_type.sectors_per_track) + self.image_type.reserved_tracks;
            const logical_sector = @rem((address.allocation * self.image_type.recs_per_alloc + @rem(address.record, self.image_type.recs_per_alloc)), self.image_type.sectors_per_track);

            log.debug("ALLOCATION[{}], RECORD[{}], LOGICAL[{}], ", .{ address.allocation, address.record, logical_sector });
            std.debug.print("ALLOCATION[{}], RECORD[{}], TRACK[{}], LOGICAL[{}]\n", .{ address.allocation, address.record, track, logical_sector });
            const physical_sector = self.image_type.skew(track, logical_sector);
            return PhysicalAddress{ .track = track, .sector = physical_sector };
        }
    }

    // TODO: Check all of the errors.
    pub const ReadSectorError = Io.Reader.Error || Io.File.Reader.SeekError;
    /// Read a single 128bytes sector
    pub fn readSector(self: *Self, location: LogicalAddress, data: *DiskSector) ReadSectorError!void {
        const physical_location = self.toPhysicalAddress(location);
        // Sometimes the data is not at the start of the sector. So adjust
        const data_offset = self.image_type.seekOffsetRead(physical_location);

        log.debug("Reading from TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, data_offset });
        //std.debug.print("Reading from TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, data_offset });

        try self.reader.seekTo(@intCast(data_offset));
        _ = try self.reader.interface().readSliceAll(data.data());
        try data.dump(physical_location, data_offset);
    }

    const WriteSectorError = Io.Writer.Error || File.SeekError;
    /// Write a single sector.
    pub fn writeSector(self: *Self, location: LogicalAddress, data: *DiskSector) WriteSectorError!void {
        const physical_location = self.toPhysicalAddress(location);

        const sector_data = self.image_type.writeableSectorGet(physical_location, data.data());
        const sector_offset = self.image_type.seekOffsetWrite(physical_location);
        try self.writer.seekTo(sector_offset);
        try self.writer.interface().writeAll(sector_data);

        log.debug("Writing to TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, sector_offset });
    }

    /// write a CPM diretory entry (RawDirEntry)
    pub fn rawEntryWrite(self: *Self, extent_nr: u16) (WriteSectorError || RawDirError)!void {

        // Make sure entry is valid before written.
        const this_entry = &self.directory.raw_directories.items[extent_nr];
        if (!this_entry.isDeleted()) {
            try this_entry.validate(self.image_type, extent_nr);
        }

        var sector: DiskSector = .init(self.image_type);
        const allocation = extent_nr / self.image_type.extents_per_alloc;
        const record: u8 = @intCast(extent_nr / self.image_type.dir_entries_per_sector);
        // start_index is the index of the directory entry that is at
        // the beginning of this sector
        const start_index = extent_nr / self.image_type.dir_entries_per_sector * self.image_type.dir_entries_per_sector;
        // Copy 1 full sector worth of extents/raw entries
        const dest: []RawDirEntry = std.mem.bytesAsSlice(RawDirEntry, sector.data());
        // TODO:
        //        const dest: *[]RawDirEntry = @ptrCast(@alignCast(sector.data()));
        const source = self.directory.raw_directories.items[start_index .. start_index + self.image_type.dir_entries_per_sector];
        @memcpy(dest, source);
        try self.writeSector(.{ .allocation = allocation, .record = record }, &sector);
    }
};

/// A single 128 byte disk sector.
pub const DiskSector = struct {
    _backing: [512]u8, // TODO: Make this look at DiskImage.max_supported_sector_size or something.
    sector_len: u16, // OR Just return a formatted slice from the DiskImageType.

    pub fn init(image_type: *const DiskImageType) DiskSector {
        // Initialized to ^Z.
        std.debug.assert(image_type.sector_data_size <= 512); // TODO
        return .{ ._backing = @splat(0x1a), .sector_len = image_type.sector_data_size };
    }

    pub fn data(self: *DiskSector) []u8 {
        return self._backing[0..self.sector_len];
    }

    pub fn dump(self: DiskSector, location: PhysicalAddress, offset: usize) !void {
        if (!DUMP)
            return;
        std.debug.print("Disk Sector: TRACK: {} - SECTOR {} - OFFSET: {}\n", .{ location.track, location.sector, offset });
        std.debug.dumpHex(self._backing[0..self.sector_len]);
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
const File = std.Io.File;
const Io = std.Io;
