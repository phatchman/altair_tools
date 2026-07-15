//! Main interface for the altair_disk library.
//! The DiskImage class is used to open and manipulate
//! altair disk image formats.

// TODO: Get rid of the logical read and just have a function to do the conversion to track sector like everywher eelse

const all_disk_types = @import("disk_types.zig").all_disk_types;
// Display raw disk sectors in hex as they are read.
const DUMP = false;

pub const log = std.log.scoped(.altair_disk_lib);
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

/// Allows Files and memory images to be used interchangeably for reading
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

    pub fn seekPos(self: SeekableReader) usize {
        return switch (self) {
            .on_disk => |file| {
                file.logicalPos();
            },
            .in_memory => |mem| {
                mem.seek;
            },
        };
    }

    pub fn interface(self: SeekableReader) *std.Io.Reader {
        return switch (self) {
            .on_disk => |file| &file.interface,
            .in_memory => |mem| mem,
        };
    }
};

/// Allows Files and memory images to be used interchangeably for writing
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

    pub fn seekPos(self: SeekableWriter) usize {
        return switch (self) {
            .on_disk => |file| file.logicalPos(),
            .in_memory => |mem| mem.end,
        };
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
    reader: SeekableReader,
    writer: SeekableWriter,
    image_type: *const DiskImageType,
    directory: DirectoryTable,
    allocator: std.mem.Allocator,

    /// Initilize a DiskImage from an opened image file.
    /// Image file must at least have read permissions if the loadDirectories() is called.
    /// Note: 1) DiskImage is not fully initialized until loadDirectories() is called.
    ///       2) Caller is responsible for closing the underlying file after deinit()
    pub fn init(gpa: std.mem.Allocator, reader: SeekableReader, writer: SeekableWriter, image_type: *const DiskImageType) !DiskImage {
        return .{
            .reader = reader,
            .writer = writer,
            .image_type = image_type,
            .allocator = gpa,
            .directory = try .init(gpa, image_type),
        };
    }

    /// Close the existing image file and open a new one.
    /// closes any files before an error is returned.
    pub fn reinit(self: *DiskImage, gpa: std.mem.Allocator, reader: SeekableReader, writer: SeekableWriter) !void {
        self.deinit();
        self.reader = reader;
        self.writer = writer;
        self.directory = try .init(gpa, self.image_type);
    }

    /// Cleanup.
    /// Caller should close underlying file after calling deinit()
    pub fn deinit(self: *DiskImage) void {
        self.directory.deinit();
    }

    /// Load the directory table.
    /// which are an easier to use verion of the raw cpm directories
    pub fn loadDirectories(self: *DiskImage, option: DirectoryTable.LoadOption) DirectoryLoadError!void {
        try self.directory.load(self, option);
    }

    /// Return disk free capacity.
    pub fn capacityFreeInKB(self: *const DiskImage) usize {
        const free_allocs = self.directory.free_allocations.count();
        return free_allocs * (self.image_type.block_size / 1024);
    }

    /// Return disk total capacity
    pub fn capacityTotalInKB(self: *const DiskImage) usize {
        const image_type = self.image_type;
        return @as(usize, (image_type.total_allocs - image_type.directory_allocs)) * image_type.block_size / 1024;
    }

    pub const TextMode = enum {
        Auto,
        Text,
        Binary,
        Rand,

        pub fn forOs(_: TextMode, os: OperatingSystem) type {
            return switch (os) {
                .ados => .{ .Auto, .Text, .Binary, .Rand },
                else => .{ .Auto, .Text, .Binary },
            };
        }
    };

    pub fn copyFromImage(self: *DiskImage, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) !void {
        try switch (self.image_type.OS) {
            .cpm, .cdos => os_cpm.copyFromImage(self, entry, out_writer, text_mode),
            .ados => os_ados.copyFromImage(self, entry, out_writer, text_mode),
            .hd_basic => os_hd_basic.copyFromImage(self, entry, out_writer, text_mode),
        };
    }

    pub fn rawEntryWrite(self: *DiskImage, raw_entry_nr: u16) !void {
        try switch (self.image_type.OS) {
            .cpm, .cdos => os_cpm.rawEntryWrite(self, raw_entry_nr),
            .ados => os_ados.rawEntryWrite(self, raw_entry_nr),
            .hd_basic => os_hd_basic.rawEntryWrite(self, raw_entry_nr),
        };
    }

    /// Try and auto-detect what type of disk image this is
    /// TODO: Maybe we just detect in a specific order than in a loop? And somehow we have to make sure
    /// they are all included.
    pub fn detectImageType(io: std.Io, image_file: File, is_unique: *bool) ?*const DiskImageType {
        is_unique.* = true;
        for (&all_disk_types.values) |*dt| {
            if (dt.isCorrectFormat(io, image_file)) {
                switch (dt.type_id) {
                    .CPM_MINI => {
                        const ados_mini = all_disk_types.getPtrConst(.ADOS_MINI);
                        const ados_miniboot = all_disk_types.getPtrConst(.ADOS_MINI_BOOT);
                        if (ados_mini.isCorrectFormat(io, image_file)) {
                            return ados_mini;
                        } else if (ados_miniboot.isCorrectFormat(io, image_file)) {
                            return ados_miniboot;
                        } else {
                            return dt;
                        }
                    },
                    .FDD_8IN => {
                        const ados = all_disk_types.getPtrConst(.ADOS_8IN);
                        if (ados.isCorrectFormat(io, image_file)) {
                            return ados;
                        } else {
                            return dt;
                        }
                    },
                    .HDD_5MB, .HDD_5MB_1024 => {
                        const hdb = all_disk_types.getPtrConst(.HD_BASIC);
                        if (hdb.isCorrectFormat(io, image_file)) {
                            return hdb;
                        } else {
                            is_unique.* = false;
                            return dt;
                        }
                    },
                    .FDD_TAR => {
                        const lgsssd = all_disk_types.getPtrConst(.CDOS_LGSSSD);
                        // TAR and CDOS_LGSSSD are same size, but can be distinguished
                        // by the CDOS disk label.
                        if (lgsssd.isCorrectFormat(io, image_file)) {
                            return lgsssd;
                        } else {
                            return dt;
                        }
                    },
                    else => return dt,
                }
            }
        }
        return null;
    }

    /// Copy a file from file_reader to the disk image.
    pub fn copyToImage(self: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, user: ?u8, force: bool, text_mode: TextMode) !void {
        try switch (self.image_type.OS) {
            .cpm, .cdos => os_cpm.copyToImage(self, file_reader, to_filename, user, force),
            .ados => os_ados.copyToImage(self, file_reader, to_filename, force, text_mode),
            // TODO: TextMode not actuially required for hd basic? Yes it is for the basic decoder.
            .hd_basic => os_hd_basic.copyToImage(self, file_reader, to_filename, force, text_mode),
        };
    }

    /// Erase a file.
    /// Note that this invalidates any pointers to existing CookedDirEntries
    /// Including any iterators.
    pub fn erase(self: *DiskImage, to_erase: *CookedDirEntry) !void {
        return self.directory.eraseEntry(to_erase, self);
    }

    fn sectorsForTrack(self: *const DiskImage, track_nr: usize) usize {
        if (track_nr == 0)
            return self.image_type.sectors_per_track0 orelse self.image_type.sectors_per_track
        else
            return self.image_type.sectors_per_track;
    }

    pub fn extractOperatingSystem(self: *DiskImage, io: std.Io, out_file: File) !void {
        try self.reader.seekTo(0);
        var writer = out_file.writer(io, &.{});

        for (0..self.image_type.reserved_tracks) |track_nr| {
            var sector: DiskSector = .initUnformatted(self.image_type, @intCast(track_nr));
            for (0..self.sectorsForTrack(track_nr)) |_| {
                self.reader.interface().readSliceAll(sector.rawBytes()) catch return error.InvalidImageFile;
                try writer.interface.writeAll(sector.rawBytes());
            }
        }
    }

    pub fn installOperatingSystem(self: *DiskImage, io: std.Io, in_file: File) !void {
        const in_size = try in_file.length(io);
        if (self.image_type.reserved_tracks == 0) {
            logerr("Not a bootable disk", .{});
            return error.InvalidImagefile;
        }
        // This is safe as only track 0 can have a different sector count.
        const expected_size = self.sectorsForTrack(0) * self.image_type.sectorSizeRawForTrack(0) +
            (self.image_type.reserved_tracks - 1) * self.sectorsForTrack(1) * self.image_type.sectorSizeRawForTrack(1);
        if (in_size != expected_size) {
            log.err("Expected system image size of {}, actual size is {}", .{ expected_size, in_size });
            return error.InvalidImageFile;
        }

        var buf: [4096]u8 = undefined;
        var file_reader = in_file.reader(io, &buf);
        // TODO: Investigate why these don't work. SendFile mneeds a buffer in the writer, not the reader.
        // but streamRemaining should work??
        //_ = try file_reader.interface.streamRemaining(self.writer.interface());
        //_ = try self.writer.interface().sendFileAll(&file_reader, .unlimited);
        while (true) {
            const nbytes = file_reader.interface.readSliceShort(&buf) catch |err| switch (err) {
                error.ReadFailed => return file_reader.err.?,
            };
            if (nbytes == 0) break;
            try self.writer.interface().writeAll(buf[0..nbytes]);
        }

        try self.writer.seekTo(0);

        // TODO: hd_basic needs to copy the volume label from the imported disk to the last sector.
    }

    pub fn formatImage(self: *DiskImage) !void {
        var disk_sector: DiskSector = undefined;
        const varying_sector_format = self.image_type.varying_sector_format;

        if (!varying_sector_format) {
            disk_sector = .initFormatted(self.image_type, .any);
        }

        // Just in case formatting an existing image file from larger to smaller format.
        try self.writer.truncate();

        for (0..self.image_type.tracks) |track_nr| {
            const sectors_per_track = if (track_nr == 0)
                self.image_type.sectors_per_track0 orelse self.image_type.sectors_per_track
            else
                self.image_type.sectors_per_track;

            for (0..sectors_per_track) |sector_nr| {
                // CPM_MINI formats all tracks as if they are data tracks, but expects the first
                // 4 tracks to be formatted as system tracks when read from. So we offsetjust do this override for fomatting.
                const location: PhysicalAddress = .{ .track = @intCast(track_nr), .sector = @intCast(sector_nr) };
                if (varying_sector_format) {
                    // Request a new formatted sector for each sector.
                    disk_sector = .initFormatted(self.image_type, location);
                }
                try self.writeSector(location, &disk_sector);
            }
        }
    }

    pub fn labelDisk(self: *DiskImage, label: DiskLabel) !void {
        switch (self.image_type.OS) {
            .cdos, .hd_basic => {},
            .ados, .cpm => return error.LabelingNotSupported,
        }
        switch (label) {
            .cdos => |lbl| {
                std.debug.assert(self.image_type.OS == .cdos);

                const raw_entry = &self.directory.raw_directories.cpm.items[0];
                // Either user shuld be 0xe5 from a fresh format / deleted entry or should be 0x81 to indicate a label.
                if (!raw_entry.isLabel() and raw_entry.user != 0xe5) return error.LabelNotFound;
                @memset(std.mem.asBytes(raw_entry), 0x00);
                raw_entry.user = 0x81;
                @memcpy(&raw_entry.filename, &lbl.user_label);
                raw_entry.filetype[0] = lbl.date_mmddyy[0];
                raw_entry.filetype[1] = lbl.date_mmddyy[1];
                raw_entry.filetype[2] = lbl.date_mmddyy[2];
                raw_entry.extent_low = switch (self.image_type.type_id.toCDOS()) {
                    .CDOS_SMSSSD, .CDOS_SMDSSD, .CDOS_SMSSDD, .CDOS_LGSSSD => 0x08, // TODO: What is this? 8 or 16 bit allocs?
                    .CDOS_LGSSDD, .CDOS_LGDSSD, .CDOS_LGDSDD, .CDOS_SMDSDD => 0x10,
                };
                if (self.image_type.type_id == .CDOS_LGDSDD) {
                    // This is the allocations taken up by the directory table.
                    // In this case 4 allocations (0, 1, 2 and 3).
                    raw_entry.reserved = 0x80;
                    raw_entry.allocations[2] = 0x01;
                    raw_entry.allocations[4] = 0x02;
                    raw_entry.allocations[6] = 0x03;
                } else {
                    raw_entry.allocations[1] = 1; // The other directories by default take up 2 allocations.
                }
                // This is indirectly the number of directories available.
                // It's actually the number of records used by the directory table (4 32 bytes entires per 128 byte record.)
                // 0x10 * 4 = 64, 0x20 * 4 = 128, 0x40 * 4 = 256
                raw_entry.num_records = switch (self.image_type.type_id.toCDOS()) {
                    .CDOS_SMSSSD, .CDOS_SMDSSD, .CDOS_SMSSDD, .CDOS_LGSSSD => 0x10,
                    .CDOS_LGSSDD, .CDOS_LGDSSD, .CDOS_SMDSDD => 0x20,
                    .CDOS_LGDSDD => 0x40,
                };
                try os_cpm.rawEntryWrite(self, 0);
            },
            .hd_basic => {
                // TODO: Pass it as the hd_basic version instead?
                try os_hd_basic.volumeLabelSet(self, label);
            },
            .cpm, .ados => return error.LabelingNotSupported,
        }
    }

    /// Return any disk label in `label`
    pub fn labelGet(self: *DiskImage, label: *DiskLabel) !void {
        switch (self.image_type.OS) {
            .cdos => {
                label.* = .{ .cdos = undefined };
                const raw_entry = &self.directory.raw_directories.cpm.items[0];
                if (!raw_entry.isLabel()) return error.LabelNotFound;
                @memcpy(&label.cdos.user_label, &raw_entry.filename);
                label.cdos.date_mmddyy[0] = raw_entry.filetype[0];
                label.cdos.date_mmddyy[1] = raw_entry.filetype[1];
                label.cdos.date_mmddyy[2] = raw_entry.filetype[2];
            },
            .hd_basic => try os_hd_basic.volumeLabelGet(self, label),
            .cpm, .ados => return error.LabelingNotSupported,
        }
    }

    /// Try and recover an image with invalid directory entries
    pub fn tryRecovery(self: *DiskImage) !void {
        // TODO: Recovery needs to be OS-specific. At least restricted just to CPM for now.
        // Or some generic method like
        try self.loadDirectories(.raw_only);
        for (self.directory.raw_directories.cpm.items, 0..) |*raw_dir, i| {
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
            try os_cpm.rawEntryWrite(self, @intCast(i));
        }
    }

    // TODO: Comment is out of date. fix fix
    /// Convert between logical (allocation, record) to physical (track, sector) address.
    // This really should take record number but uses sector number instead. i.e for 512k
    // sectors it passes 0, 1, 2. Not 0, 4, 8 when there are 4 records per sector.
    // Everything works 100% fine with sectors, so I'm not inclined to change it.
    // TODO: This now represents either the unskewed track / sector or the physical track / sector.
    // Read a single sector using unskewed track and sector
    pub const ReadSectorError = Io.Reader.Error || Io.File.Reader.SeekError || PhysicalAddress.ValidateError;
    pub fn readSector(self: *DiskImage, location: PhysicalAddress, sector: *DiskSector) ReadSectorError!void {
        try location.validate(self.image_type);
        const physical_location: PhysicalAddress = .{ .track = location.track, .sector = self.image_type.skew(location.track, location.sector) };
        const sector_offset = self.image_type.seekOffset(physical_location);

        log.debug("Reading from TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, sector_offset });

        try self.reader.seekTo(@intCast(sector_offset));
        sector.* = .initUnformatted(self.image_type, physical_location.track);
        try self.reader.interface().readSliceAll(sector.rawBytes());
        try sector.dump(physical_location, sector_offset);
    }

    pub const WriteSectorError = Io.Writer.Error || File.SeekError || PhysicalAddress.ValidateError;
    /// Write a single sector.
    pub fn writeSector(self: *DiskImage, location: PhysicalAddress, sector: *DiskSector) WriteSectorError!void {
        try location.validate(self.image_type);
        const physical_location: PhysicalAddress = .{ .track = location.track, .sector = self.image_type.skew(location.track, location.sector) };
        try physical_location.validate(self.image_type);
        sector.prepareWrite(self.image_type, location);
        const sector_offset = self.image_type.seekOffset(physical_location);
        log.debug("Writing to TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, sector_offset });
        try self.writer.seekTo(sector_offset);
        try self.writer.interface().writeAll(sector.rawBytes());

        try sector.dump(physical_location, sector_offset);
    }
};

const std = @import("std");
const Console = @import("console.zig");
const disk_types = @import("disk_types.zig");
const basic_file_decoder = @import("basic_file_decoder.zig");
const DiskImageType = disk_types.DiskImageType;
const PhysicalAddress = disk_types.PhysicalAddress;
const DiskSector = disk_types.DiskSector;
const DiskLabel = disk_types.DiskLabel;
const DirectoryTable = @import("directory_table.zig").DirectoryTable;
const CookedDirEntry = @import("directory_table.zig").CookedDirEntry;
const DirectoryLoadError = DirectoryTable.DirectoryLoadError;
const RawDirError = @import("directory_table.zig").RawDirError;
const OperatingSystem = disk_types.OperatingSystem;
const File = std.Io.File;
const Io = std.Io;
const os_hd_basic = @import("os_hd_basic.zig");
const os_cpm = @import("os_cpm.zig");
const os_ados = @import("os_altair_dos.zig");
