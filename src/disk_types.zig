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

/// The physical track and sector number after skew
pub const PhysicalAddress = struct {
    track: u16,
    sector: u16,
    pub const zero: PhysicalAddress = .{ .track = 0, .sector = 0 };
};

// Represents the basic disk parameters for a supported disk type
// Performs format-specfic functions such as converting logical to
// physical disk sectors.
// Should never be instantiated directly, but instead is initalized
// by one of the Concrete formats, e.g. DiskImageType_MITS_8IN
pub const DiskImageType = struct {
    pub const dir_entry_size: u16 = 32;
    //    pub const sector_data_size = 128;
    //  pub const dir_entries_per_sector = sector_data_size / dir_entry_size;
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
    // Number of sectors on the first track
    sectors_per_track0: ?u16 = null,
    // Sector size of the physical media (This will be 128 for everything except the MITS FDDs)
    sector_size_raw: u16,
    // Size of the logical (data containing portion of the sector)
    sector_size_data: u16,
    // Size of the sectors on track0
    sector_size_data0: ?u16 = null,
    // Block size, must be multiple of 1024.
    block_size: u16,
    // Maximum number of directory entries and extents
    directories: u16,
    // How many allocations per directory entry.
    directory_allocs: u16,
    // Size of a disk image?
    image_size: u32,
    // Support detection of padded images etc.
    detect_conditions: AutoDetectConditions,
    // Are all sectors formatted the same or do they vary per track?
    varying_sector_format: bool,
    OS: enum { cpm, cdos },

    // Skew from logical to physical sector
    skew_fn: *const fn (skew_table: []const u16, track: u16, sector: u16) u16 = undefined,
    // Defines logical to physical skews.
    skew_table: []const u16 = undefined,
    // Format disk
    format_fn: *const fn (address: PhysicalAddress, sector_data: []u8, raw_sector: ?[]u8) []u8 = undefined,
    // On MITS formats the control/data layout varies depending on track number.
    offset_fn: ?*const fn (otype: OffsetType, track: u16) u32 = null,
    // Checksum for MITS formats.
    checksum_fn: ?*const fn (track: u16, sector_data: []u8) u8 = null,
    // return a "blank" sector that can be written to.
    writeable_sector_fn: ?*const fn (address: PhysicalAddress, sector_data: []u8, raw_sector: ?[]u8) []u8 = null,
    // Turn a track and sector address into a seek offset for read
    seek_offset_read_fn: ?*const fn (self: *const DiskImageType, address: PhysicalAddress) usize = null,
    seek_offset_write_fn: ?*const fn (self: *const DiskImageType, address: PhysicalAddress) usize = null,

    // Raw sector data for MITS formats.
    raw_sector: ?[]u8 = null,
    // Below are "constants" - These are initialised with "init".
    track_size: u16 = undefined,
    total_allocs: u32 = undefined, // Actually u16, but u32 gets rid of a lot of casting.
    recs_per_alloc: u16 = undefined,
    allocs_per_extent: u8 = undefined,
    recs_per_extent: u16 = undefined,
    extents_per_alloc: u16 = undefined,
    dir_entries_per_sector: u16 = undefined,

    const Self = @This();
    pub fn init(self: *Self) void {
        self.track_size = self.sector_size_raw * self.sectors_per_track;
        self.total_allocs = @as(u32, (self.tracks - self.reserved_tracks)) * (self.sectors_per_track * self.sector_size_data) / self.block_size;
        //        self.recs_per_alloc = self.block_size / self.sector_data_size;
        self.recs_per_extent = 128; //self.recs_per_alloc * if (self.OS == .cpm) 8 else 16; // 8 Allocations per extent.
        self.allocs_per_extent = 128 * 128 / self.block_size; // This is the number of entries in the allocations table. (max 16)
        self.recs_per_alloc = self.recs_per_extent / self.allocs_per_extent;

        self.extents_per_alloc = self.block_size / dir_entry_size;
        self.dir_entries_per_sector = self.sector_size_data / dir_entry_size;
    }

    pub fn dump(self: *const Self) void {
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
    pub fn skew(self: *const Self, track: u16, logical_sector: u16) u16 {
        return self.skew_fn(self.skew_table, track, logical_sector);
    }

    // Calculate and store checksum if required by this format.
    pub fn checksum(self: *const Self, track: u16, sector_data: []u8) void {
        if (self.checksum_fn) |csum| {
            const csum_offset = DiskImageType.sector_data_size + self.offset(.checksum, track);
            sector_data[csum_offset] = csum(track, sector_data);
        }
    }

    const OffsetType = enum { track, sector, data, stop, zero, checksum };

    // For the MITS floppy formats, the location of the data and meta-data portions of the
    // sector differ depending on the track number. For all other formats, returns 0.
    pub fn offset(self: *const Self, otype: OffsetType, track: u16) u32 {
        if (self.offset_fn) |offset_fn| {
            return offset_fn(otype, track);
        } else {
            return 0;
        }
    }

    /// Convert a physical track / sector into a seek offset
    pub fn seekOffsetRead(self: *const DiskImageType, address: PhysicalAddress) usize {
        if (self.seek_offset_read_fn) |seek_fn| {
            return seek_fn(self, address);
        } else {
            return self._defaultSeekOffset(address);
        }
    }

    /// Convert a physical track / sector into a seek offset
    pub fn seekOffsetWrite(self: *const DiskImageType, address: PhysicalAddress) usize {
        if (self.seek_offset_write_fn) |seek_fn| {
            return seek_fn(self, address);
        } else {
            return self._defaultSeekOffset(address);
        }
    }

    /// Get a sector ready for writing data.
    pub fn writeableSectorGet(self: *const DiskImageType, address: PhysicalAddress, sector_data: []u8) []u8 {
        if (self.writeable_sector_fn) |writeable_sector| {
            return writeable_sector(address, sector_data, self.raw_sector);
        } else {
            return sector_data;
        }
    }

    /// Get a freshly formatted sector.
    pub fn formattedSectorGet(self: *const DiskImageType, address: PhysicalAddress, sector_data: []u8) []u8 {
        return self.format_fn(address, sector_data, self.raw_sector);
    }

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

    /// Return total number of sectors used to store data.
    pub fn largestFileBytes(self: *const DiskImageType) u32 {
        return (self.total_allocs - self.directory_allocs) * self.block_size;
    }

    // By default, use the provided skew table, with no other adjustment required.
    fn _defaultSkewFn(skew_table: []const u16, track: u16, logical_sector: u16) u16 {
        _ = track;
        return skew_table[logical_sector] + 1;
    }

    // By default just need to fill each sector with 0xe5
    fn _defaultFormattedSectorGet(address: PhysicalAddress, sector_data: []u8, raw_sector: ?[]u8) []u8 {
        _ = address;
        _ = raw_sector;
        @memset(sector_data, 0xe5);
        return sector_data;
    }

    fn _defaultSeekOffset(self: *const Self, location: PhysicalAddress) usize {
        return @as(usize, location.track) * self.track_size +
            (location.sector - 1) * self.sector_size_raw;
    }
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

    pub fn init(raw_sector: []u8) DiskImageType {
        std.debug.assert(raw_sector.len == sector_size);
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
            .offset_fn = offset,
            .writeable_sector_fn = writeableSectorGet,
            .seek_offset_read_fn = seekOffsetRead,
            .raw_sector = raw_sector,
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
        const data_start = offset(.data, track);
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
        sector_data[offset(.checksum, track)] = csum;
    }

    /// Read vs write for the MITS 8" disks as we have to write out the track
    /// metadata / control data as well when writing.
    fn seekOffsetRead(self: *const DiskImageType, location: PhysicalAddress) usize {
        return self._defaultSeekOffset(location) + self.offset(.data, location.track);
    }

    /// In addition to storing the sector data, need to store control meta data including,
    /// track and sector number, stop byte, zero byte and checksum.
    fn formattedSectorGet(address: PhysicalAddress, sector_data: []u8, _raw_sector: ?[]u8) []u8 {
        _ = sector_data; // Ignored as we use the internal raw_sector instead.
        const raw_sector = _raw_sector orelse unreachable;

        @memset(raw_sector, 0xe5);
        raw_sector[1] = 0x00;
        raw_sector[2] = 0x01;
        raw_sector[offset(.track, address.track)] = @truncate(address.track | 0x80);
        raw_sector[offset(.stop, address.track)] = 0xff;
        raw_sector[offset(.zero, address.track)] = 0x00;

        // For tracks < 6, zero from zero byte to end of sector.
        if (address.track < 6) {
            @memset(raw_sector[offset(.zero, 0)..], 0x00);
        } else {
            // TODO: remove
            // std.debug.print("track = {x}, sector={x} {x}\n", .{ address.track, address.sector, ((address.sector - 1) * 17) % 32 });
            raw_sector[offset(.sector, address.track)] = @intCast(((address.sector - 1) * 17) % 32);
        }
        checksum(address.track, raw_sector);

        return raw_sector;
    }

    /// Return the internal 137 byte raw_sector buffer, freshly formatted,
    /// with the input sector_data copied into it.
    fn writeableSectorGet(address: PhysicalAddress, sector_data: []u8, _raw_sector: ?[]u8) []u8 {
        var raw_sector = formattedSectorGet(address, sector_data, _raw_sector);
        const data_start = offset(.data, address.track);
        const data_end = data_start + sector_data_size;
        @memcpy(raw_sector[data_start..data_end], sector_data);
        checksum(address.track, raw_sector);
        return raw_sector;
    }

    /// Return the byte offset into the sector where data and meta-data is stored.
    /// This position varies for the first 6 tracks compared to the rest of the disk.
    fn offset(otype: DiskImageType.OffsetType, track: u16) u32 {
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

    pub fn init(raw_sector: []u8) DiskImageType {
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
            .offset_fn = DiskImageType_MITS_8IN.offset,
            .writeable_sector_fn = DiskImageType_MITS_8IN.writeableSectorGet,
            .raw_sector = raw_sector,
        };
        result.init();
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
            .image_size = 4988928,
            .detect_conditions = .duplicate_size,
            .varying_sector_format = false,
            .skew_fn = DiskImageType._defaultSkewFn,
            .skew_table = &skew_table,
            .format_fn = DiskImageType._defaultFormattedSectorGet,
            .offset_fn = null,
        };
        if (init_before_return)
            result.init();
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
            .skew_fn = DiskImageType._defaultSkewFn,
            .skew_table = &_skew_table,
            .format_fn = DiskImageType._defaultFormattedSectorGet,
            .offset_fn = null,
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
            .image_size = 1525760,
            .varying_sector_format = false,
            .detect_conditions = .none,
            .skew_fn = DiskImageType._defaultSkewFn,
            .skew_table = &_skew_table,
            .format_fn = DiskImageType._defaultFormattedSectorGet,
            .offset_fn = null,
        };
        result.init();
        return result;
    }
};

// Because the MITS floppy drives are formatted with 137 bytes per sector
// this buffer is used to create a 137 byte physical sector out of the
// 128 byte cpm sector when writing to the image.
var mits_raw_sector: [DiskImageType_MITS_8IN.sector_size]u8 = undefined;

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
            .varying_sector_format = false,
            .skew_fn = DiskImageType._defaultSkewFn,
            .skew_table = &_skew_table,
            .format_fn = DiskImageType._defaultFormattedSectorGet,
            .offset_fn = null,
        };
        result.init();
        return result;
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
            .varying_sector_format = false,
            .skew_fn = DiskImageType._defaultSkewFn,
            .skew_table = &_skew_table,
            .format_fn = DiskImageType._defaultFormattedSectorGet,
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
            .block_size = 2048,
            .directories = 128,
            .directory_allocs = 2, // TODO: WAs 2
            .image_size = 625920,
            .detect_conditions = .none,
            .varying_sector_format = true, // track 0 is SD, rest DD
            .skew_fn = DiskImageType._defaultSkewFn,
            .skew_table = &_skew_table,
            .format_fn = formattedSectorGet,
            .seek_offset_read_fn = seekOffset,
            .seek_offset_write_fn = seekOffset,
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

    /// Handle that the first track is single density for double density disks.
    fn seekOffset(self: *const DiskImageType, location: PhysicalAddress) usize {
        return if (location.track == 0)
            // TODO: This can be simplified to just (location.sector - 1) * 128
            @as(usize, location.track) * self.track_size + (location.sector - 1) * 128
        else
            // There are 26 sectors of 128 bytes on the first SD track.
            return 26 * 128 + @as(usize, location.track - 1) * self.track_size + (location.sector - 1) * self.sector_size_raw;
    }

    // By default just need to fill each sector with 0xe5
    fn formattedSectorGet(address: PhysicalAddress, sector_data: []u8, _: ?[]u8) []u8 {
        const sector_len: u16 = if (address.track == 0) 128 else 512; // TODO: Should come from config.
        @memset(sector_data, 0xe5);
        return sector_data[0..sector_len];
    }
};

/// all available disk image formats.
pub const all_disk_types: std.enums.EnumArray(DiskImageTypes, DiskImageType) = .init(.{
    .FDD_8IN = DiskImageType_MITS_8IN.init(&mits_raw_sector),
    .HDD_5MB = DiskImageType_MITS_5MB_HDD.init(),
    .HDD_5MB_1024 = DiskImageType_MITS_5MB_HDD_1024.init(),
    .FDD_TAR = DiskImageType_TARBELL_FDD.init(),
    .@"FDD_1.5MB" = @"DiskImageType_FDD_1.5MB".init(),
    .FDD_8IN_8MB = DiskImageType_MITS_8IN_8MB.init(&mits_raw_sector),
    .CDOS_SMSSSD = DiskImageType_CDOS_SMSSSD.init(),
    .CDOS_LGSSSD = DiskImageType_CDOS_LGSSSD.init(),
    .CDOS_LGSSDD = DiskImageType_CDOS_LGSSDD.init(),
});

// Zig creates these array at compile time, including setting up the function calls
// for the different image types, performs all of the calculations in the init functions and
// initializes the array with these values.
// Similarly initDiskTypeNames() iterates through each entry in all_disk_types and extracts just the names,
// at vompile time.

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
