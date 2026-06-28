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
    const filename_len = 12;

    reader: SeekableReader,
    writer: SeekableWriter,
    image_type: *const DiskImageType,
    directory: DirectoryTable,
    allocator: std.mem.Allocator,
    /// Zero-width field for namespacing.
    cpm: CPM = .{},
    /// Zero-width field for namespacing
    ados: ADOS = .{},

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

    pub const TextMode = enum { Auto, Text, Binary };

    pub fn copyFromImage(self: *DiskImage, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) !void {
        try switch (self.image_type.OS) {
            .cpm, .cdos => CPM.copyFromImage(self, entry, out_writer, text_mode),
            .ados => ADOS.copyFromImage(self, entry, out_writer, text_mode),
        };
    }

    pub fn rawEntryWrite(self: *DiskImage, raw_entry_nr: u16) !void {
        try switch (self.image_type.OS) {
            .cpm, .cdos => self.cpm.rawEntryWrite(raw_entry_nr),
            .ados => self.ados.rawEntryWrite(raw_entry_nr),
        };
    }

    /// Try and auto-detect what type of disk image this is
    pub fn detectImageType(io: std.Io, image_file: File, is_unique: *bool) ?*const DiskImageType {
        is_unique.* = true;
        for (&all_disk_types.values) |*dt| {
            if (dt.isCorrectFormat(io, image_file)) {
                switch (dt.type_id) {
                    .FDD_8IN => {
                        const ados = all_disk_types.getPtrConst(.ADOS_8IN);
                        if (ados.isCorrectFormat(io, image_file)) {
                            return ados;
                        } else {
                            return dt;
                        }
                    },
                    .HDD_5MB, .HDD_5MB_1024 => {
                        is_unique.* = false;
                        return dt;
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

    fn debug(comptime fmt: []const u8, args: anytype) void {
        if (true) return;
        std.debug.print(fmt, args);
    }

    /// Copy a file from file_reader to the disk image.
    pub fn copyToImage(self: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, user: ?u8, force: bool, text_mode: TextMode) !void {
        try switch (self.image_type.OS) {
            .cpm, .cdos => CPM.copyToImage(self, file_reader, to_filename, user, force),
            .ados => ADOS.copyToImage(self, file_reader, to_filename, force, text_mode),
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
        // This is safe as only track 0 can have a different sector count.
        const expected_size = self.sectorsForTrack(0) * self.image_type.sectorSizeRawForTrack(0) +
            (self.image_type.reserved_tracks - 1) * self.sectorsForTrack(1) * self.image_type.sectorSizeRawForTrack(1);
        if (in_size != expected_size) {
            log.err("Expected system image size of {}, actual size is {}", .{ expected_size, in_size });
            return error.InvalidImageFile;
        }

        var buf: [4096]u8 = undefined;
        var file_reader = in_file.reader(io, &buf);
        _ = try file_reader.interface.stream(self.writer.interface(), .unlimited);
        try self.writer.seekTo(0);
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
            .cdos => {},
            else => return error.LabelingNotSupported,
        }
        switch (label) {
            .cdos => |lbl| {
                std.debug.assert(self.image_type.OS == .cdos);

                const raw_entry = &self.directory.raw_directories.cpm.items[0];
                const raw_item = &raw_entry.raw;
                // Either user shuld be 0xe5 from a fresh format / deleted entry or should be 0x81 to indicate a label.
                if (!raw_entry.isLabel() and raw_item.user != 0xe5) return error.LabelNotFound;
                @memset(std.mem.asBytes(raw_item), 0x00);
                raw_item.user = 0x81;
                @memcpy(&raw_item.filename, &lbl.user_label);
                raw_item.filetype[0] = lbl.date_mmddyy[0];
                raw_item.filetype[1] = lbl.date_mmddyy[1];
                raw_item.filetype[2] = lbl.date_mmddyy[2];
                raw_item.extent_low = switch (self.image_type.type_id.toCDOS()) {
                    .CDOS_SMSSSD, .CDOS_SMDSSD, .CDOS_SMSSDD, .CDOS_LGSSSD => 0x08, // TODO: What is this? 8 or 16 bit allocs?
                    .CDOS_LGSSDD, .CDOS_LGDSSD, .CDOS_LGDSDD, .CDOS_SMDSDD => 0x10,
                };
                if (self.image_type.type_id == .CDOS_LGDSDD) {
                    // This is the allocations taken up by the directory table.
                    // In this case 4 allocations (0, 1, 2 and 3).
                    raw_item.reserved = 0x80;
                    raw_item.allocations[2] = 0x01;
                    raw_item.allocations[4] = 0x02;
                    raw_item.allocations[6] = 0x03;
                } else {
                    raw_item.allocations[1] = 1; // The other directories by default take up 2 allocations.
                }
                // This is indirectly the number of directories available.
                // It's actually the number of records used by the directory table (4 32 bytes entires per 128 byte record.)
                // 0x10 * 4 = 64, 0x20 * 4 = 128, 0x40 * 4 = 256
                raw_item.num_records = switch (self.image_type.type_id.toCDOS()) {
                    .CDOS_SMSSSD, .CDOS_SMDSSD, .CDOS_SMSSDD, .CDOS_LGSSSD => 0x10,
                    .CDOS_LGSSDD, .CDOS_LGDSSD, .CDOS_SMDSDD => 0x20,
                    .CDOS_LGDSDD => 0x40,
                };
                try self.cpm.rawEntryWrite(0);
            },
            else => return error.LabelingNotSupported,
        }
    }

    /// Return any disk label in `label`
    pub fn labelGet(self: *const DiskImage, label: *DiskLabel) !void {
        switch (self.image_type.OS) {
            .cdos => {
                label.* = .{ .cdos = undefined };
                const raw_entry = &self.directory.raw_directories.cpm.items[0];
                const raw_item = &raw_entry.raw;
                if (!raw_entry.isLabel()) return error.LabelNotFound;
                @memcpy(&label.cdos.user_label, &raw_item.filename);
                label.cdos.date_mmddyy[0] = raw_item.filetype[0];
                label.cdos.date_mmddyy[1] = raw_item.filetype[1];
                label.cdos.date_mmddyy[2] = raw_item.filetype[2];
            },
            else => return error.LabelingNotSupported,
        }
    }

    /// Try and recover an image with invalid directory entries
    pub fn tryRecovery(self: *DiskImage) !void {
        try self.loadDirectories(.raw_only);
        for (self.directory.raw_directories.cpm.items, 0..) |*raw_dir, i| {
            var saveable = true;
            var valid = false;
            var delete_related = false;
            while (saveable and !valid) {
                raw_dir.validate(self.image_type, @intCast(i)) catch |err| {
                    switch (err) {
                        RawDirError.InvalidUser => {
                            log.info("Error with directory entry {}: User was {}, setting to 0", .{ i, raw_dir.raw.user });
                            raw_dir.raw.user = 0;
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
            try self.cpm.rawEntryWrite(@intCast(i));
        }
    }

    /// Convert between logical (allocation, record) to physical (track, sector) address.
    // This really should take record number but uses sector number instead. i.e for 512k
    // sectors it passes 0, 1, 2. Not 0, 4, 8 when there are 4 records per sector.
    // Everything works 100% fine with sectors, so I'm not inclined to change it.
    // TODO: This now represents either the unskewed track / sector or the physical track / sector.
    fn toPhysicalAddress(self: *const DiskImage, address: LogicalAddress) PhysicalAddress {
        const sectors_per_alloc = self.image_type.block_size / self.image_type.sector_size_data;

        const absolute_sector = address.allocation * sectors_per_alloc + (address.record % sectors_per_alloc);
        const track: u16 = self.image_type.reserved_tracks + (absolute_sector / self.image_type.sectors_per_track);
        const logical_sector = absolute_sector % self.image_type.sectors_per_track;

        log.debug("ALLOCATION[{}], RECORD[{}], LOGICAL[{}], ", .{ address.allocation, address.record, logical_sector });
        return PhysicalAddress{ .track = track, .sector = logical_sector };
    }

    pub const ReadSectorError = Io.Reader.Error || Io.File.Reader.SeekError || PhysicalAddress.ValidateError;
    /// Read a single sector using record, allocation format
    pub fn readSectorLogical(self: *DiskImage, location: LogicalAddress, sector: *DiskSector) ReadSectorError!void {
        const physical_location = self.toPhysicalAddress(location);

        try self.readSectorPhysical(physical_location, sector);
    }

    // Read a single sector using unskewed track and sector
    pub fn readSectorPhysical(self: *DiskImage, location: PhysicalAddress, sector: *DiskSector) ReadSectorError!void {
        try location.validate(self.image_type);
        const physical_location: PhysicalAddress = .{ .track = location.track, .sector = self.image_type.skew(location.track, location.sector) };
        const sector_offset = self.image_type.seekOffset(physical_location);

        log.debug("Reading from TRACK[{}], SECTOR[{}], OFFSET[{}]\n", .{ physical_location.track, physical_location.sector, sector_offset });

        try self.reader.seekTo(@intCast(sector_offset));
        sector.* = .initUnformatted(self.image_type, physical_location.track);
        try self.reader.interface().readSliceAll(sector.rawBytes());
        try sector.dump(physical_location, sector_offset);
    }

    const WriteSectorError = Io.Writer.Error || File.SeekError || PhysicalAddress.ValidateError;
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

    pub const CPM = struct {
        pub fn copyFromImage(self: *DiskImage, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) !void {
            const num_records = entry.os.cpm.num_records;
            // Check for empty file.
            if (entry.allocations.items.len == 0) {
                return;
            }
            const recs_per_sector = (self.image_type.sector_size_data / 128); // Recs always represent 128 bytes
            const num_sectors = (num_records + recs_per_sector - 1) / recs_per_sector;
            var total_rec_nr: u16 = 0;
            for (0..num_sectors) |sec_nr| {
                // This protects against trying to copy files from CDOS.
                const alloc_idx = total_rec_nr / self.image_type.recs_per_alloc;
                if (alloc_idx >= entry.allocations.items.len) {
                    std.debug.print("FATAL ERROR: num_records = {}, num_sectors = {}, total_rec_nr = {}, alloc_idx = {}, recs_per_alloc = {}, allocs.len = {}, total_allocs = {} num records = {}\n", .{
                        num_records,
                        num_sectors,
                        total_rec_nr,
                        alloc_idx,
                        self.image_type.recs_per_alloc,
                        entry.allocations.items.len,
                        self.image_type.total_allocs,
                        entry.os.cpm.num_records,
                    });
                    return error.InvalidRecordNumber;
                }
                const alloc = entry.allocations.items[alloc_idx];
                if (alloc == 0)
                    break;
                var sector: DiskSector = undefined;
                try self.readSectorLogical(.{ .record = @intCast(sec_nr % self.image_type.recs_per_alloc), .allocation = alloc }, &sector);
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

        pub fn copyToImage(self: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, user: ?u8, force: bool) !void {
            const cpm_user = user orelse 0;
            const basename = std.fs.path.basename(to_filename);
            var conversion_buf: [filename_len]u8 = undefined;
            const cpm_filename = try DirectoryTable.translateToCPMFilename(basename, &conversion_buf);
            if (self.directory.findByFilename(cpm_filename, user)) |existing_entry| {
                if (force) {
                    try self.erase(existing_entry);
                } else {
                    return std.Io.File.OpenError.PathAlreadyExists;
                }
            }

            var file_buffer: [DiskSector.sector_size_max]u8 = @splat(0xe5);
            const file_data = file_buffer[0..self.image_type.sector_size_data];

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
            debug("nbytes = {}, sector_data_size = {}\n", .{ nbytes, self.image_type.sector_size_data });

            // short circuit handling on zero-length files.
            if (nbytes == 0) {
                var raw_entry = try self.directory.rawEntryGetFreeInitializedCPM(&extent_nr);
                raw_entry.filenameAndExtensionSet(cpm_filename);
                raw_entry.raw.user = cpm_user;
                try self.cpm.rawEntryWrite(extent_nr);
                try self.directory.buildCookedEntryCPM(extent_nr);
                return;
            }

            var dir_entry: *RawCpmDirEntry = undefined;
            while (nbytes != 0) {
                num_records += @intCast((nbytes + 127) / 128);
                debug(
                    "data_len = {}, nbytes = {}, record_nr = {}, num_records = {}, entry_nr = {}, alloc_nr = {}, alloc_count = {}\n",
                    .{ file_data.len, nbytes, record_nr, num_records, extent_nr, alloc_nr, alloc_count },
                );
                // Is this a new extent?
                if (record_nr % self.image_type.recs_per_extent == 0) {
                    if (record_nr > 0) {
                        try self.directory.buildCookedEntryCPM(extent_nr);
                        extent_count += 1;
                    }
                    dir_entry = try self.directory.rawEntryGetFreeInitializedCPM(&extent_nr);
                    dir_entry.filenameAndExtensionSet(cpm_filename);
                    dir_entry.raw.user = cpm_user;
                    alloc_count = 0;
                }
                // Is this a new allocation?
                if (record_nr % self.image_type.recs_per_alloc == 0) {
                    alloc_nr = try self.directory.allocationGetFreeCPM();
                    const raw_entry = &self.directory.raw_directories.cpm.items[extent_nr];
                    try raw_entry.allocationSet(alloc_count, alloc_nr, self.image_type);
                    alloc_count += 1;
                }

                // For formats that support 256 records per extent (actually 255. 0 means no records)
                // The 128th record is represented as extent number + 1 with record_count reset to 0
                // This means odd extent numbers have > 127 records and even ones have <= 127 records.
                if (self.image_type.recs_per_extent == 256 and
                    record_nr % 128 == 0 and
                    record_nr % 256 != 0)
                {
                    extent_count += 1;
                }

                // Note technically this should take the record number within the allocation.
                // But instead it is being passed the sector number. It's easier to work this method
                // rather than the correct CPM way and gives the same results.
                const location = self.toPhysicalAddress(.{ .allocation = alloc_nr, .record = @intCast(sector_count % self.image_type.recs_per_extent) });
                var sector: DiskSector = .initFormatted(self.image_type, location);
                @memcpy(sector.dataBytes(), file_data);
                try self.writeSector(location, &sector);

                dir_entry.raw.num_records = @intCast((num_records - 1) % 128 + 1);
                dir_entry.extentCountSet(extent_count, self.image_type);
                try self.cpm.rawEntryWrite(extent_nr);
                @memset(file_data, 0xe5);
                nbytes = try file_reader.readSliceShort(file_data);
                @memset(file_data[nbytes .. (nbytes + 127) / 128 * 128], 0x1a);

                // record_nr always advances by full records to ensure that
                // new directory entries are created and new allocs assigned for short-reads
                // on the last read of the file.
                record_nr += self.image_type.sector_size_data / 128;
                sector_count += 1;
            }

            try self.directory.buildCookedEntryCPM(extent_nr);

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

        /// write a CPM diretory entry (RawDirEntry)
        pub fn rawEntryWrite(cpm: *CPM, extent_nr: u16) (WriteSectorError || RawDirError)!void {
            const self: *DiskImage = @alignCast(@fieldParentPtr("cpm", cpm));
            // std.debug.print("write entry: index = {}, extent_count = {}\n", .{ extent_nr, self.directory.raw_directories.cpm.items[extent_nr].extentGet() });
            // Make sure entry is valid before written.
            const this_entry = &self.directory.raw_directories.cpm.items[extent_nr];
            if (!this_entry.isDeleted()) {
                try this_entry.validate(self.image_type, extent_nr);
            }

            const location = self.toPhysicalAddress(.{ .allocation = extent_nr / self.image_type.dirs_per_alloc, .record = @intCast(extent_nr / self.image_type.dirs_per_sector) });
            var sector: DiskSector = .initFormatted(self.image_type, location);

            // start_index is the index of the directory entry that is at
            // the beginning of this sector
            const start_index = extent_nr / self.image_type.dirs_per_sector * self.image_type.dirs_per_sector;
            // Copy 1 full sector worth of extents/raw entries
            @memcpy(sector.dataBytes(), std.mem.sliceAsBytes(self.directory.raw_directories.cpm.items[start_index .. start_index + self.image_type.dirs_per_sector]));
            try self.writeSector(location, &sector);
        }
    };

    pub const ADOS = struct {
        // TODO: Change these so they log error and return copy failed?
        pub fn copyFromImage(self: *DiskImage, entry: *const CookedDirEntry, out_writer: *std.Io.Writer, text_mode: TextMode) (error{ InvalidFormat, WriteFailed, InvalidRecordNumber, InvalidToken } || ReadSectorError)!void {
            if (entry.attribs[0] == 'R') {
                log.err("Copying of Random Access files is not currently supported.", .{});
                return error.InvalidFormat;
            }

            var track_nr: u8 = entry.os.ados.track;
            var sector_nr: u8 = entry.os.ados.sector;
            var file_no: u8 = 255;
            var sector: DiskSector = .initUnformatted(self.image_type, 6); //  // TODO
            var decode_basic_file: bool = false;
            var first_sector: bool = true;
            var temp_file: std.Io.Writer.Allocating = .init(self.allocator);
            defer temp_file.deinit();
            errdefer out_writer.flush() catch {};

            while (track_nr != 0) {
                try self.readSectorPhysical(.{ .track = track_nr, .sector = sector_nr }, &sector);
                if (file_no == 255) file_no = sector.mits_track_6_76.file_nr;

                if (file_no == sector.mits_track_6_76.file_nr) {
                    if (first_sector and text_mode == .Text) {
                        if (sector.mits_track_6_76.data[0] == 0xff) { // Indicates a BASIC file.
                            decode_basic_file = true;
                        } else {
                            log.err("Not an encoded Altair BASIC file. First byte should be 0xff, is 0x{x:02}.", .{sector.mits_track_6_76.data[0]});
                            return error.InvalidFormat;
                        }
                    }
                    if (decode_basic_file) {
                        try temp_file.writer.writeAll(sector.mits_track_6_76.data[0..sector.mits_track_6_76.nbytes]);
                    } else {
                        try out_writer.writeAll(sector.mits_track_6_76.data[0..sector.mits_track_6_76.nbytes]);
                    }
                    first_sector = false;
                } else {
                    log.err("File {s} has corruption in the sector chain on track {}, sector {}. Expected file number {} found {}", .{ entry.filenameAndExtension(), track_nr, sector_nr, file_no, sector.mits_track_6_76.file_nr });
                    return error.InvalidRecordNumber;
                }
                track_nr = sector.mits_track_6_76.next_track;
                sector_nr = sector.mits_track_6_76.next_sector;
            }
            if (decode_basic_file) {
                var reader: std.Io.Reader = .fixed(temp_file.written());
                try basic_file_decoder.decode(&reader, out_writer);
            }
            try out_writer.flush();
        }

        pub fn copyToImage(self: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, force: bool, text_mode: TextMode) !void {
            var filename_buf: [8]u8 = undefined;
            const ados_filename = try DirectoryTable.translateToADOSFilename(to_filename, &filename_buf);
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
                while (reader_in.takeDelimiter('\n')) |slice| {
                    if (slice == null or slice.?.len == 0) break;
                    try conversion_buffer_out.writer.writeAll(slice.?);
                    if (slice.?[slice.?.len - 1] == '\r') {
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
            const new_entry = try self.directory.rawEntryGetFreeInitializedADOS(self, &extent_nr);
            @memcpy(&new_entry.raw.filename, &filename_buf);
            new_entry.raw.mode = 0x2; // Only sequential files are currently supported

            var file_data: [128]u8 = undefined; // TODO: Hard coded
            var nbytes = try reader.readSliceShort(&file_data);
            // Zero length files only get a directory entry and nothing else.
            if (nbytes == 0) {
                try self.ados.rawEntryWrite(extent_nr);
                return;
            }

            var alloc = try self.directory.allocationGetFreeADOS();
            const sectors_per_alloc = self.image_type.block_size / self.image_type.sector_size_data;
            const allocs_per_track = self.image_type.sectors_per_track / sectors_per_alloc;
            var track_nr: u16 = self.image_type.reserved_tracks + alloc / allocs_per_track;
            var sector_nr: u16 = (alloc % allocs_per_track) * sectors_per_alloc; // This is the first sector for this allocation of 8 sectors.

            new_entry.raw.track = @intCast(track_nr);
            new_entry.raw.sector = @intCast(sector_nr);
            try self.ados.rawEntryWrite(extent_nr);
            errdefer self.directory.buildCookedEntryADOS(self, extent_nr) catch {}; // Try and build the cooked dir if we can with what we have.

            var prev_location: ?PhysicalAddress = null;
            var prev_sector: DiskSector = undefined;
            while (nbytes != 0) {
                for (0..sectors_per_alloc) |offset| {
                    track_nr = self.image_type.reserved_tracks + alloc / allocs_per_track;
                    sector_nr = (alloc % allocs_per_track) * sectors_per_alloc + @as(u16, @intCast(offset));

                    // Fill all sectors in the group of 8 for the allocation. (8 * 128) = 1024byte block size.
                    const location: PhysicalAddress = .{ .track = track_nr, .sector = sector_nr };
                    var sector: DiskSector = .initFormatted(self.image_type, location);
                    @memcpy(sector.dataBytes()[0..nbytes], file_data[0..nbytes]);
                    sector.mits_track_6_76.nbytes = @intCast(nbytes);
                    sector.mits_track_6_76.file_nr = @intCast(extent_nr + 1);
                    try self.writeSector(location, &sector);
                    if (prev_location) |prev| {
                        prev_sector.mits_track_6_76.next_track = @intCast(track_nr);
                        prev_sector.mits_track_6_76.next_sector = @intCast(sector_nr);
                        try self.writeSector(prev, &prev_sector);
                    }
                    prev_location = location;
                    prev_sector = sector;

                    nbytes = try reader.readSliceShort(&file_data);
                    if (nbytes == 0) break;
                }
                if (nbytes != 0) {
                    alloc = try self.directory.allocationGetFreeADOS();
                }
            }
            try self.directory.buildCookedEntryADOS(self, extent_nr);

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
        }

        /// write an Altair DOS diretory entry (RawDirEntry)
        pub fn rawEntryWrite(ados: *ADOS, extent_nr: u16) (WriteSectorError || RawDirError)!void {
            const self: *DiskImage = @alignCast(@fieldParentPtr("ados", ados));
            const entries_per_sector = self.image_type.dirs_per_sector;
            const this_entry = &self.directory.raw_directories.ados.items[extent_nr];
            if (!this_entry.isDeleted()) {
                try this_entry.validate(self.image_type, extent_nr);
            }

            // 16 bytes per directory entry. Directory start at Track 70
            const location: PhysicalAddress = .{ .track = 70, .sector = extent_nr / entries_per_sector };
            var sector: DiskSector = .initFormatted(self.image_type, location);

            // start_index is the index of the directory entry that is at
            // the beginning of this sector
            const start_index = extent_nr / entries_per_sector * entries_per_sector;
            // Copy 1 full sector worth of extents/raw entries
            @memcpy(sector.dataBytes(), std.mem.sliceAsBytes(self.directory.raw_directories.ados.items[start_index .. start_index + entries_per_sector]));
            try self.writeSector(location, &sector);
        }
    };
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
const RawCpmDirEntry = @import("directory_table.zig").RawCpmDirEntry;
const RawAdosDirEntry = @import("directory_table.zig").RawAdosDirEntry;
const RawDirError = @import("directory_table.zig").RawDirError;
const File = std.Io.File;
const Io = std.Io;
