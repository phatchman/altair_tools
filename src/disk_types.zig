//!
//! Contains all parameters required to process the various altair disk formats.
//! Provides generic routines to skew logical to physical disk sectors and
//! other various quirks of the raw disk layouts.
//!
// To add a new image type:
// 1) Create a new DiskImageType_XXX struct
// 2) Add a new entry to the DiskImageTypes enum
// 3) Add (1) and (2) to all_disk_types.
// 4) Add a freshly formatted version of the image to src/test_images
// 5) Add a format test and any other relevant tests to disk_image_tests.zig

// TODO: Sector numbers are currently 1-based. There's no good reason
// they should not be zero based instead.
// Also some skew tables are 1-based and some are 0-based. how tf is that working?

pub const OperatingSystem = enum { cpm, cdos };
pub const DiskLabel = union(OperatingSystem) {
    cpm: void,
    cdos: struct {
        //        disk_format_label: [6]u8, // e.g. LGSSDD for large single-sided double density,
        user_label: [8]u8,
        date_mmddyy: [3]u8,
    },

    pub fn format(self: *const DiskLabel, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.*) {
            .cpm => {},
            .cdos => |lbl| try writer.print("Label: {s}  Date: {c}{c}/{c}{c}/{c}{c}", .{
                lbl.user_label,
                lbl.date_mmddyy[0] / 10 + '0',
                lbl.date_mmddyy[0] % 10 + '0',
                lbl.date_mmddyy[1] / 10 + '0',
                lbl.date_mmddyy[1] % 10 + '0',
                lbl.date_mmddyy[2] / 10 + '0',
                lbl.date_mmddyy[2] % 10 + '0',
            }),
        }
    }
};

/// The physical track and sector number after skew
pub const PhysicalAddress = struct {
    track: u16,
    sector: u16,
    pub const zero: PhysicalAddress = .{ .track = 0, .sector = 0 };
};

/// Represents a single disk sector.
/// For MITS hard-sectored disks, the raw on-disk sector length is different to the data length.
pub const DiskSector = struct {
    // Hexdump raw sectors to debug output
    const DUMP = false;

    backing_buffer: [512]u8,
    sector_len_raw: u16,
    sector_len_data: u16,
    data_start: u8 = 0,

    pub fn init(image_type: *const DiskImageType, track_nr: u16) DiskSector {
        std.debug.assert(image_type.sector_size_data <= 512);
        return .{
            .backing_buffer = undefined,
            .sector_len_data = image_type.sectorSizeDataForTrack(track_nr),
            .sector_len_raw = image_type.sectorSizeRawForTrack(track_nr),
            .data_start = image_type.offsetOf(.data, track_nr),
        };
    }
    /// Return the data portion of the sector
    pub fn dataBytes(self: *DiskSector) []u8 {
        return self.backing_buffer[self.data_start .. self.sector_len_data + self.data_start];
    }

    /// Return the whoel sector, including the data portion.
    pub fn rawBytes(self: *DiskSector) []u8 {
        return self.backing_buffer[0..self.sector_len_raw];
    }

    /// Hexdump raw sector information.
    pub fn dump(self: DiskSector, location: PhysicalAddress, offset: usize) !void {
        if (!DUMP)
            return;
        std.debug.print("Disk Sector: TRACK: {} - SECTOR {} - OFFSET: {}\n", .{ location.track, location.sector, offset });
        std.debug.dumpHex(self.rawBytes());
    }
};

// Represents the basic disk parameters for a supported disk type
// Performs format-specfic functions such as converting logical to
// physical disk sectors.
// Should never be instantiated directly, but instead is initalized
// by one of the Concrete formats, e.g. DiskImageType_MITS_8IN
pub const DiskImageType = struct {
    pub const dir_entry_size: u16 = 32;
    pub const max_user = 15;

    pub const AutoDetectConditions = enum {
        // No special conditions
        none,
        // Also accepts images padded to 128 byte boundary
        padded,
        // Warn that this format has the same size as another format.
        duplicate_size,
    };

    // Internal name
    type_id: DiskImageTypes,
    // Friendly name, used in -T
    type_name: []const u8,
    // Friendly description
    description: []const u8,
    // Number of tracks
    tracks: u16,
    // Number of tracks reserved by OS
    reserved_tracks: u16,
    // How many sectors per track
    sectors_per_track: u16,
    // Number of sectors on track 0, if different
    sectors_per_track0: ?u16 = null,
    // Sector size of the physical media (This will be 128 for everything except the MITS hard-sectored FDDs)
    sector_size_raw: u16,
    // Size of the physical media for track 0, if different.
    sector_size_raw0: ?u16 = null,
    // Size of the logical (data containing portion of the sector)
    sector_size_data: u16,
    // Size of the sectors on track 0, if different
    sector_size_data0: ?u16 = null,
    // Block size, must be multiple of 1024.
    block_size: u16,
    // Maximum number of directory entries
    directories: u16,
    // How many allocations are reserved for the directory table.
    directory_allocs: u16,
    // Are allocation numbers stored as 1 or two bytes in the directory table?
    two_byte_allocs: bool = false,
    // Size of a disk image
    image_size: u32,
    // Support detection of padded images etc.
    detect_conditions: AutoDetectConditions,
    // Are all sectors formatted the same or do they vary per track?
    varying_sector_format: bool,
    // Which operating system is this?
    OS: OperatingSystem,

    // Skew from logical to physical sector
    skew_fn: *const fn (skew_table: []const u16, track: u16, sector: u16) u16 = defaultSkewFn,
    // Defines logical to physical skews.
    skew_table: []const u16 = undefined,
    // Format disk
    format_fn: *const fn (self: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void = defaultFormattedSectorGet,
    // Create the hard-sector meta data for mits formats.
    prepare_write_fn: *const fn (self: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void = defaultPrepareSectorForWrite,
    // For hard-sectored formats, return the offset from start of sector for various disk control bytes.
    offset_fn: *const fn (otype: DiskImageType.OffsetType, track: u16) u8 = defaultOffsetOf,

    // Below are "constants" - These are initialised with "init".
    track_size: u16 = undefined,
    total_allocs: u32 = undefined, // Actually u16, but u32 gets rid of a lot of casting.
    recs_per_alloc: u16 = undefined,
    allocs_per_extent: u8 = undefined,
    recs_per_extent: u16 = undefined,
    extents_per_alloc: u16 = undefined,
    dir_entries_per_sector: u16 = undefined,

    pub fn init(self: *DiskImageType) void {
        self.track_size = self.sector_size_raw * self.sectors_per_track;
        self.total_allocs = @as(u32, (self.tracks - self.reserved_tracks)) * self.sectors_per_track * self.sector_size_data / self.block_size;
        self.recs_per_extent = 128;
        self.allocs_per_extent = 128 * 128 / self.block_size; // This is the number of entries in the allocations table. (max 16)
        //        self.allocs_per_extent = 128 * 128 / self.block_size; // This is the number of entries in the allocations table. (max 16)
        self.recs_per_alloc = self.recs_per_extent / self.allocs_per_extent;

        self.extents_per_alloc = self.block_size / dir_entry_size;
        self.dir_entries_per_sector = self.sector_size_data / dir_entry_size;
    }

    pub fn dump(self: *const DiskImageType) void {
        std.debug.print("Type:         {s}\n", .{self.type_name});
        std.debug.print("Sector Len:   {}\n", .{self.sector_size_raw});
        std.debug.print("Data Len:     {}\n", .{self.sector_size_data});
        std.debug.print("Num Tracks:   {}\n", .{self.tracks});
        std.debug.print("Res Tracks:   {}\n", .{self.reserved_tracks});
        std.debug.print("Secs / Track: {}\n", .{self.sectors_per_track});
        std.debug.print("Block Size:   {}\n", .{self.block_size});
        std.debug.print("Track Len:    {}\n", .{self.track_size});
        std.debug.print("Recs / Ext:   {}\n", .{self.recs_per_extent});
        std.debug.print("Recs / Alloc: {}\n", .{self.recs_per_alloc});
        std.debug.print("Dirs / Sect   {}\n", .{self.dir_entries_per_sector});
        std.debug.print("Allocs / Dir: {}\n", .{self.allocs_per_extent});
        std.debug.print("Dir Allocs:   {}\n", .{self.directory_allocs});
        std.debug.print("Num Dirs:     {}\n", .{self.directories});
        std.debug.print("Num Allocs:   {}\n", .{self.total_allocs});
    }

    /// Convert logical track/sector into physical sector.
    /// The aim is that the next logical sector will by physically undereed the read/write head when
    /// the next sector is ready to be read/written.
    pub fn skew(self: *const DiskImageType, track: u16, logical_sector: u16) u16 {
        return self.skew_fn(self.skew_table, track, logical_sector);
    }

    const OffsetType = enum { track, sector, data, stop, zero, checksum };
    /// Return the offset of sector meta-data fields for hard-sectored formats.
    pub fn offsetOf(self: *const DiskImageType, otype: OffsetType, track_nr: u16) u8 {
        return self.offset_fn(otype, track_nr);
    }

    /// Convert a physical track / sector into a seek offset
    pub fn seekOffset(self: *const DiskImageType, location: PhysicalAddress) usize {
        if (self.sector_size_data0) |sector_size0| {
            return if (location.track == 0)
                sector_size0 * (location.sector - 1)
            else
                self.sectors_per_track0.? * sector_size0 + @as(usize, location.track - 1) * self.track_size + (location.sector - 1) * self.sector_size_raw;
        } else {
            return @as(usize, location.track) * self.track_size + (location.sector - 1) * self.sector_size_raw;
        }
    }

    pub fn prepareSectorForWrite(self: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void {
        self.prepare_write_fn(self, address, sector);
    }

    /// Get a freshly formatted sector.
    pub fn formattedSectorGet(self: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void {
        self.format_fn(self, address, sector);
    }

    /// TODO: PRob just create a stand-alone detection routine, rather than this cimplex nonsense.
    /// Retruns true if supplied image_file is supported by this image type.
    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        const image_size = image_file.length(io) catch {
            return false;
        };
        const alt_size = if (self.detect_conditions == .padded) ((self.image_size + 127) / 128) * 128 else self.image_size;

        if (image_size == self.image_size or image_size == alt_size) {
            return true;
        }
        return false;
    }

    /// Return total number of sectors on disk.
    pub fn sectorCount(self: *const DiskImageType) u16 {
        if (self.sectors_per_track0) |track0| {
            return track0 + (self.tracks - 1) * self.sectors_per_track;
        } else {
            return self.tracks * self.sectors_per_track;
        }
    }

    /// How large is the data portion of the sector for this track?
    pub fn sectorSizeDataForTrack(self: *const DiskImageType, track_nr: u16) u16 {
        return if (track_nr > 0) self.sector_size_data else self.sector_size_data0 orelse self.sector_size_data;
    }

    /// How large is the on-disk sector for this track?
    pub fn sectorSizeRawForTrack(self: *const DiskImageType, track_nr: u16) u16 {
        return if (track_nr > 0) self.sector_size_raw else self.sector_size_raw0 orelse self.sector_size_raw;
    }

    /// Return total number of sectors used to store data.
    pub fn largestFileBytes(self: *const DiskImageType) u32 {
        return (self.total_allocs - self.directory_allocs) * self.block_size;
    }

    // By default, use the provided skew table, with no other adjustment required.
    fn defaultSkewFn(skew_table: []const u16, track: u16, logical_sector: u16) u16 {
        _ = track;
        return skew_table[logical_sector] + 1;
    }

    // By default just need to fill each sector with 0xe5
    fn defaultFormattedSectorGet(self: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void {
        sector.* = .init(self, address.track);
        @memset(sector.dataBytes(), 0xe5);
    }

    fn defaultOffsetOf(_: DiskImageType.OffsetType, _: u16) u8 {
        return 0;
    }

    fn defaultPrepareSectorForWrite(_: *const DiskImageType, _: PhysicalAddress, _: *DiskSector) void {}
};

/// MITS 8" floppy disk format
///
/// Strange things to note:
/// 1) The skew algorithm for the first 6 tracks is different to the rest of the disk.
/// 2) The phsyical sector size is 137 bytes, with 128 bytes of that being data
/// 3) The rest of the sector contains control information such as track numbers, checksums and stop bits.
/// 4) The layout of this control data is different for the first 6 tracks vs the rest of the disk.
pub const DiskImageType_MITS_8IN = struct {
    const _skew_table = [32]u16{
        1, 9,  17, 25, 3, 11, 19, 27,
        5, 13, 21, 29, 7, 15, 23, 31,
        2, 10, 18, 26, 4, 12, 20, 28,
        6, 14, 22, 30, 8, 16, 24, 32,
    };
    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .FDD_8IN,
            .type_name = "FDD_8IN",
            .description = "MITS 8\" Floppy Disk ",
            .OS = .cpm,
            .tracks = 77,
            .reserved_tracks = 2,
            .sectors_per_track = 32,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 2048,
            .directories = 64,
            .directory_allocs = 2,
            .image_size = 337568,
            .detect_conditions = .padded,
            .varying_sector_format = true,
            .skew_fn = skew,
            .skew_table = &_skew_table,
            .format_fn = formattedSectorGet,
            .prepare_write_fn = prepareSectorForWrite,
            .offset_fn = offsetOf,
            //.writeable_sector_fn = writeableSectorGet,
        };
        result.init();
        return result;
    }

    /// For historical reasons, the skew changes based on the track number.
    fn skew(skew_table: []const u16, track: u16, logical_sector: u16) u16 {
        if (track < 6)
            return skew_table[logical_sector];

        return (((skew_table[logical_sector] - 1) * 17) % 32) + 1;
    }

    pub fn checksum(track: u16, sector_data: []u8) void {
        var csum: u8 = 0;
        const data_start = offsetOf(.data, track);
        const data_end = data_start + sector_data_size;
        for (sector_data[data_start..data_end]) |b| {
            csum +%= b;
        }
        if (track >= 6) {
            csum +%= sector_data[2];
            csum +%= sector_data[3];
            csum +%= sector_data[5];
            csum +%= sector_data[6];
        }
        sector_data[offsetOf(.checksum, track)] = csum;
    }

    /// In addition to storing the sector data, need to store control meta data including,
    /// track and sector number, stop byte, zero byte and checksum.
    fn formattedSectorGet(self: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void {
        sector.* = .init(self, address.track);
        @memset(sector.rawBytes(), 0xe5);
        const raw_sector = sector.rawBytes();
        raw_sector[1] = 0x00;
        raw_sector[2] = 0x01;
        raw_sector[offsetOf(.track, address.track)] = @truncate(address.track | 0x80);
        raw_sector[offsetOf(.stop, address.track)] = 0xff;
        raw_sector[offsetOf(.zero, address.track)] = 0x00;

        // For tracks < 6, zero from zero byte to end of sector.
        if (address.track < 6) {
            @memset(raw_sector[offsetOf(.zero, 0)..], 0x00);
        } else {
            raw_sector[offsetOf(.sector, address.track)] = @intCast(((address.sector - 1) * 17) % 32);
        }
        checksum(address.track, raw_sector);
    }

    /// Set all of the control meta data for the sector.
    fn prepareSectorForWrite(_: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void {
        // Fill the non-data parts of the sector with 0xe5.
        @memset(sector.backing_buffer[0..sector.data_start], 0xe5);
        @memset(sector.backing_buffer[sector.data_start + sector_data_size ..], 0xe5);

        // Then set the required control bytes and checksum
        const raw_sector = sector.rawBytes();
        raw_sector[1] = 0x00;
        raw_sector[2] = 0x01;
        raw_sector[offsetOf(.track, address.track)] = @truncate(address.track | 0x80);
        raw_sector[offsetOf(.stop, address.track)] = 0xff;
        raw_sector[offsetOf(.zero, address.track)] = 0x00;
        if (address.track < 6) {
            @memset(raw_sector[offsetOf(.zero, 0)..], 0x00);
        } else {
            raw_sector[offsetOf(.sector, address.track)] = @intCast(((address.sector - 1) * 17) % 32);
        }
        checksum(address.track, raw_sector);
    }

    /// Return the byte offset into the sector where data and meta-data is stored.
    /// This position varies for the first 6 tracks compared to the rest of the disk.
    fn offsetOf(otype: DiskImageType.OffsetType, track: u16) u8 {
        const first_six = track < 6;
        return switch (otype) {
            .data => return if (first_six) 3 else 7,
            .track => 0,
            .sector => return if (first_six) 0 else 1,
            .stop => return if (first_six) 131 else 135,
            .zero => return if (first_six) 133 else 136,
            .checksum => return if (first_six) 132 else 4,
        };
    }
};

/// The FDC+ controller supports an 8MB "floppy" disk
/// Has the same skew and 137 byte physical sectors as the
/// standard 8" drive.
pub const DiskImageType_MITS_8IN_8MB = struct {
    const _skew_table = [32]u16{
        1, 9,  17, 25, 3, 11, 19, 27,
        5, 13, 21, 29, 7, 15, 23, 31,
        2, 10, 18, 26, 4, 12, 20, 28,
        6, 14, 22, 30, 8, 16, 24, 32,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .FDD_8IN_8MB,
            .type_name = "FDD_8IN_8MB",
            .description = "FDC+ 8MB \"Floppy\" Disk",
            .OS = .cpm,
            .tracks = 2048,
            .reserved_tracks = 2,
            .sectors_per_track = 32,
            .sector_size_raw = 137,
            .sector_size_data = 128,
            .block_size = 4096,
            .directories = 512,
            .directory_allocs = 4,
            .image_size = 8978432,
            .detect_conditions = .none,
            .varying_sector_format = true,
            .skew_fn = DiskImageType_MITS_8IN.skew,
            .skew_table = &_skew_table,
            .format_fn = DiskImageType_MITS_8IN.formattedSectorGet,
            .prepare_write_fn = DiskImageType_MITS_8IN.prepareSectorForWrite,
            .offset_fn = DiskImageType_MITS_8IN.offsetOf,
        };
        result.init();
        // TODO: hackiness. Calculate these properly
        result.allocs_per_extent = 16;
        result.recs_per_extent = 256;
        result.two_byte_allocs = true; // TODO: Check this
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
        return _init(true);
    }

    // Split so that the 1024 directory entry version can share this init.
    pub fn _init(init_before_return: bool) DiskImageType {
        var result = DiskImageType{
            .type_id = .HDD_5MB,
            .type_name = "HDD_5MB",
            .description = "MITS 5MB Hard Disk",
            .OS = .cpm,
            .tracks = 406,
            .reserved_tracks = 1,
            .sectors_per_track = 96,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 4096,
            .directories = 256,
            .directory_allocs = 2,
            .two_byte_allocs = true,
            .image_size = 4988928,
            .detect_conditions = .duplicate_size,
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
        var result = DiskImageType_MITS_5MB_HDD._init(false);
        result.type_id = .HDD_5MB_1024;
        result.type_name = "HDD_5MB_1024";
        result.description = "MITS 5MB, with 1024 directories";
        result.directories = 1024;
        result.init();

        result.recs_per_extent = 256;
        result.allocs_per_extent = 8;
        result.directory_allocs = 8;

        return result;
    }
};

// Tarbell floppy disk format
pub const DiskImageType_TARBELL_FDD = struct {
    const _skew_table = [_]u16{
        0,  6,  12, 18, 24, 4,  10, 16,
        22, 2,  8,  14, 20, 1,  7,  13,
        19, 25, 5,  11, 17, 23, 3,  9,
        15, 21,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .FDD_TAR,
            .type_name = "FDD_TAR",
            .description = "Tarbell Floppy Disk",
            .OS = .cpm,
            .tracks = 77,
            .reserved_tracks = 2,
            .sectors_per_track = 26,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 1024,
            .directories = 64,
            .directory_allocs = 2,
            .image_size = 256256,
            .detect_conditions = .none,
            .varying_sector_format = false,
            .skew_table = &_skew_table,
        };
        result.init();
        return result;
    }
};

// FDC+ controller supports 1.5MB floppy disks
pub const @"DiskImageType_FDD_1.5MB" = struct {
    const _skew_table = [_]u16{
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
            .description = "FDC+ 1.5MB Floppy Disk",
            .OS = .cpm,
            .tracks = 149,
            .reserved_tracks = 1,
            .sectors_per_track = 80,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 4096,
            .directories = 256,
            .directory_allocs = 2,
            .two_byte_allocs = true,
            .image_size = 1525760,
            .varying_sector_format = false,
            .detect_conditions = .none,
            .skew_table = &_skew_table,
        };
        result.init();
        // TODO: Hacky
        result.allocs_per_extent = 16;
        return result;
    }
};

pub const DiskImageTypes = enum(usize) {
    FDD_8IN = 0,
    HDD_5MB,
    HDD_5MB_1024,
    FDD_TAR,
    @"FDD_1.5MB",
    FDD_8IN_8MB,
    CDOS_SMSSSD,
    CDOS_LGSSSD,
    CDOS_LGSSDD,
};

// CDOS "Small"
pub const DiskImageType_CDOS_SMSSSD = struct {
    const _skew_table = [_]u16{
        0, 5,  10, 15, 2, 7,  12, 17,
        4, 9,  14, 1,  6, 11, 16, 3,
        8, 13,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_SMSSSD,
            .type_name = "CDOS_SMSSSD",
            .description = "CDOS 5.25\" SS SD Disk",
            .OS = .cdos,
            .tracks = 40,
            .reserved_tracks = 3,
            .sectors_per_track = 18,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 1024,
            .directories = 64,
            .directory_allocs = 2,
            .image_size = 92160,
            .detect_conditions = .none,
            .varying_sector_format = true, // First sector contains label
            .skew_table = &_skew_table,
            .format_fn = CDOS.formattedSectorGet,
        };
        result.init();
        return result;
    }
};

const CDOS = struct {

    // For the first sector on the first track, put the disk format label
    fn formattedSectorGet(self: *const DiskImageType, address: PhysicalAddress, sector: *DiskSector) void {
        self.defaultFormattedSectorGet(address, sector);
        if (address.track == 0 and address.sector == 1) {
            @memcpy(sector.dataBytes()[120..126], @tagName(self.type_id)[5..]); // Remove the CDOS_
        }
    }
};

// CDOS "Large"
pub const DiskImageType_CDOS_LGSSSD = struct {
    const _skew_table = [_]u16{
        0,  6,  12, 18, 24, 4,  10, 16,
        22, 2,  8,  14, 20, 1,  7,  13,
        19, 25, 5,  11, 17, 23, 3,  9,
        15, 21,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_LGSSSD,
            .type_name = "CDOS_LGSSSD",
            .description = "CDOS 8IN 'Large' Disk",
            .OS = .cdos,
            .tracks = 77,
            .reserved_tracks = 2,
            .sectors_per_track = 26,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 1024,
            .directories = 64,
            .directory_allocs = 2,
            .image_size = 256256,
            .detect_conditions = .none,
            .varying_sector_format = true, // First sector contains a label
            .skew_table = &_skew_table,
            .format_fn = CDOS.formattedSectorGet,
        };
        result.init();
        return result;
    }
};

// For all Cromemco DD disks have the, the first track is SD
pub const DiskImageType_CDOS_LGSSDD = struct {
    const _skew_table = [_]u16{
        0, 11, 6,  1, 12, 7,  2,  13,
        8, 3,  14, 9, 4,  15, 10, 5,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_LGSSDD,
            .type_name = "CDOS_LGSSDD",
            .description = "CDOS 8IN SSDD Disk",
            .OS = .cdos,
            .tracks = 77,
            .reserved_tracks = 2,
            .sectors_per_track = 16,
            .sectors_per_track0 = 26,
            .sector_size_raw = 512,
            .sector_size_data = 512,
            .sector_size_data0 = 128,
            .sector_size_raw0 = 128,
            .block_size = 2048,
            .directories = 128,
            .directory_allocs = 2, // TODO: This can be calculated directories * 32 / block_size.
            .image_size = 625920,
            .detect_conditions = .none,
            .varying_sector_format = true, // track 0 is SD, rest DD
            .skew_table = &_skew_table,
            .format_fn = CDOS.formattedSectorGet,
        };
        result.init();
        // Sigh, this format is used by Michah CPM, which works on Cromemco machines,
        // but only uses single byte allocs. I've yet to find and actual CDOS image using
        // the Single Sided Double Density Format.

        // So since we're using single byte allocs on this format we have to restrict to using
        // 254 of the 300 available allocations.
        result.total_allocs = 254;
        return result;
    }
};

/// all available disk image formats.
pub const all_disk_types: std.enums.EnumArray(DiskImageTypes, DiskImageType) = .init(.{
    .FDD_8IN = DiskImageType_MITS_8IN.init(),
    .HDD_5MB = DiskImageType_MITS_5MB_HDD.init(),
    .HDD_5MB_1024 = DiskImageType_MITS_5MB_HDD_1024.init(),
    .FDD_TAR = DiskImageType_TARBELL_FDD.init(),
    .@"FDD_1.5MB" = @"DiskImageType_FDD_1.5MB".init(),
    .FDD_8IN_8MB = DiskImageType_MITS_8IN_8MB.init(),
    .CDOS_SMSSSD = DiskImageType_CDOS_SMSSSD.init(),
    .CDOS_LGSSSD = DiskImageType_CDOS_LGSSSD.init(),
    .CDOS_LGSSDD = DiskImageType_CDOS_LGSSDD.init(),
});

// Zig creates these array at compile time, including setting up the function calls
// for the different image types, performs all of the calculations in the init functions and
// initializes the array with these values.
// Similarly initDiskTypeNames() iterates through each entry in all_disk_types and extracts just the names,
// at compile time.

/// The display names for each image type.
pub const all_disk_type_names = initDiskTypeNames();

/// Return an array of just the image type names
fn initDiskTypeNames() [all_disk_types.values.len][]const u8 {
    var result: [all_disk_types.values.len][]const u8 = undefined;
    for (0..all_disk_types.values.len) |i| {
        result[i] = all_disk_types.values[i].type_name;
    }
    return result;
}

const std = @import("std");
