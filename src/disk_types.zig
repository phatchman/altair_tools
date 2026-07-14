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

// TODO: Later version of CDOS encode the total number of directories in the 1st directory entry.
//       - Support setting the number of directories at runtime
//       - Support reading the 1st dir entry and decoding the number of directories
//       - Support setting the number of directories at format time
//       - STAT/L on CDOS allows rewriting the entire label, including disk format!
//         ```
//         Single or Double sided diskette (S = Single, D = Double) <D> -
//         Name . . . . . . . . . . . . . . . . . . <ABCDEFGH> -
//         Date . . . . . . . . . . . . . . . . . . <12/12/12> -
//         Number of directory entries (64-512) . . . .  <128> -
//         ```

pub const OperatingSystem = enum { cpm, cdos, ados, hd_basic };
const log = std.log.scoped(.altair_disk_lib);
const logerr = if (@import("builtin").fuzz) log.info else log.err;

pub const DiskLabel = union(OperatingSystem) {
    cpm: void,
    cdos: struct {
        pub const user_label_len: u8 = 8;
        user_label: [user_label_len]u8,
        date_mmddyy: [3]u8,
    },
    ados: void,
    hd_basic: struct {
        pub const user_label_len: u8 = 20;
        user_label: [user_label_len]u8,
        created_yymmdd: [3]u8,
        modified_yymmdd: [3]u8,
    },

    pub fn format(self: *const DiskLabel, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.*) {
            .cpm, .ados => {},
            .cdos => |lbl| try writer.print("Label: {s}  Date: {c}{c}/{c}{c}/{c}{c}", .{
                lbl.user_label,
                lbl.date_mmddyy[0] / 10 + '0',
                lbl.date_mmddyy[0] % 10 + '0',
                lbl.date_mmddyy[1] / 10 + '0',
                lbl.date_mmddyy[1] % 10 + '0',
                lbl.date_mmddyy[2] / 10 + '0',
                lbl.date_mmddyy[2] % 10 + '0',
            }),
            .hd_basic => |lbl| try writer.print("Label: {s}  Created: {f}  Modified: {f}", .{
                lbl.user_label,
                hd_basic.fmtDate(lbl.created_yymmdd),
                hd_basic.fmtDate(lbl.modified_yymmdd),
            }),
        }
    }
};

const AltairDosDirEntry = extern struct {
    filename: [8]u8,
    track: u8,
    sector: u8,
    mode: u8,
    unused: [5]u8,

    pub fn format(self: *const AltairDosDirEntry, writer: *std.Io.Writer) error{WriteFailed}!void {
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

/// The physical track and sector number after skew
pub const PhysicalAddress = struct {
    track: u16,
    sector: u16,

    /// Use when track and sector aren't important
    pub const any: PhysicalAddress = .{ .track = 1, .sector = 1 };

    pub const ValidateError = error{ InvalidTrack, InvalidSector };
    pub fn validate(self: PhysicalAddress, image_type: *const DiskImageType) ValidateError!void {
        if (self.track >= image_type.tracks) {
            logerr(
                "Attempt to read from an invalid track. [Read track {}. Expected 0-{}]",
                .{ self.track, image_type.tracks - 1 },
            );
            return error.InvalidTrack;
        }
        if (self.sector >= image_type.sectorsForTrack(self.track)) {
            logerr(
                "Attempt to read from an invalid sector. [Read sector {}. Expected 0-{}]",
                .{ self.sector, image_type.sectorsForTrack(self.track) - 1 },
            );
            return error.InvalidSector;
        }
    }
};

/// Represents a single disk sector.
/// For MITS hard-sectored disks, the raw on-disk sector length is different to the data length.
pub const DiskSector = union(enum) {
    // Hexdump raw sectors to debug output
    const DUMP = false;
    pub const sector_size_max = 512;

    reserved: extern struct {
        track_nr: u8,
        address: u16 align(1),
        data: [128]u8,
        stop: u8,
        checksum: u8,
        zero: [4]u8,
    },
    data: extern struct {
        track_nr: u8,
        sector_nr: u8,
        file_nr: u8,
        nbytes: u8,
        checksum: u8,
        next_track: u8,
        next_sector: u8,
        data: [128]u8,
        stop: u8,
        zero: u8,
    },
    hd_basic: extern struct { data: [256]u8 },
    cpm_128: extern struct { data: [128]u8 },
    cpm_512: extern struct { data: [512]u8 },

    pub fn initUnformatted(image_type: *const DiskImageType, track_nr: u16) DiskSector {
        return switch (image_type.type_id) {
            // TODO: Need to make this so when add a new 137 byte format we
            // either get a compile error here, or don;t have to update this switch. Either one.
            .FDD_8IN,
            .FDD_8IN_8MB,
            => if (track_nr < 6)
                .{ .reserved = undefined }
            else
                .{ .data = undefined },
            .ADOS_8IN,
            .ADOS_MINI,
            .ADOS_MINI_BOOT,
            => if (track_nr < image_type.reserved_tracks)
                .{ .reserved = undefined }
            else
                .{ .data = undefined },
            // CPM Mini formats all tracks as data tracks, but expects the system tracks to be formatted as
            // system tracks when read. Since we only ever write system tracks raw, we just pretend this
            // format only has data tracks
            .CPM_MINI => .{ .data = undefined },
            .HD_BASIC => .{ .hd_basic = undefined },
            else => switch (image_type.sectorSizeDataForTrack(track_nr)) {
                128 => .{ .cpm_128 = undefined },
                512 => .{ .cpm_512 = undefined },
                else => unreachable,
            },
        };
    }

    pub fn initFormatted(image_type: *const DiskImageType, location: PhysicalAddress) DiskSector {
        var result: DiskSector = .initUnformatted(image_type, location.track);
        @memset(result.rawBytes(), 0xe5);
        switch (result) {
            .reserved => |*sector| {
                // sets `address`. Do it with raw bytes to avoid endian issues.
                result.rawBytes()[1] = 0x00;
                result.rawBytes()[2] = 0x01;
                sector.track_nr = @truncate(location.track | 0x80);
                sector.stop = 0xff;
                @memset(&sector.zero, 0x00);
            },
            .data => |*sector| {
                switch (image_type.OS) {
                    .cpm => {
                        if (image_type.type_id == .CPM_MINI) {
                            @memset(result.rawBytes()[1..7], 0);
                        } else {
                            result.rawBytes()[1] = 0x00;
                            result.rawBytes()[2] = 0x01;
                        }
                        sector.track_nr = @truncate(location.track | 0x80);
                        sector.stop = 0xff;
                        sector.zero = 0x00;
                        sector.sector_nr = @intCast(image_type.skew_table[location.sector]);
                    },
                    .ados => {
                        @memset(result.rawBytes(), 0x00);
                        sector.track_nr = @truncate(location.track | 0x80);
                        sector.stop = 0xff;
                        sector.sector_nr = if (image_type.type_id == .ADOS_8IN)
                            @intCast((image_type.skew_table[location.sector] * 17) % 32)
                        else
                            @intCast(location.sector);
                        sector.nbytes = 0;
                        // For each sector of directory track, set the first byte of the directory
                        // entry to 0xff, indicating "end of directory"
                        if (location.track == image_type.OS.ados.directory_track and location.sector == 0) {
                            if (image_type.type_id == .ADOS_8IN)
                                sector.nbytes = 0x80;
                            sector.data[0] = 0xff;
                        } else if (image_type.type_id == .ADOS_MINI and location.track == 0 and location.sector == 0) {
                            result.data.nbytes = 0x15;
                            result.data.checksum = 0x15;
                        }
                    },
                    else => unreachable,
                }
            },
            .cpm_128, .cpm_512 => {
                @memset(result.rawBytes(), 0xe5);
                switch (image_type.OS) {
                    // Apply the disk label to the first sector for CDOS
                    .cdos => if (location.track == 0 and location.sector == 0)
                        @memcpy(result.dataBytes()[120..126], @tagName(image_type.type_id)[5..]), // Remove the CDOS_
                    else => {},
                }
            },
            .hd_basic => {
                if (location.track < image_type.reserved_tracks) {
                    @memset(result.rawBytes(), 0x00);
                    if (location.track == 0 and location.sector == 0) {
                        hd_basic.initVolumeLabel(image_type, &result);
                    } else if (location.track == 0 and location.sector == 1) {
                        hd_basic.initAllocationMap(&result, .first);
                    } else if (location.track == 0 and location.sector == 2) {
                        hd_basic.initAllocationMap(&result, .second);
                    }
                } else if (location.track == image_type.reserved_tracks and location.sector == 0) {
                    hd_basic.initDirectoryEntries(image_type, &result);
                } else if (location.track == image_type.tracks - 1 and location.sector == image_type.sectors_per_track - 1) {
                    // Last sector contains a copy of the volume descriptor
                    hd_basic.initVolumeLabel(image_type, &result);
                } else {
                    const page = location.track * image_type.sectors_per_track + location.sector;
                    // TODO: fix hard-coded stuff
                    if (page >= 193 and page < 448) {
                        @memset(result.rawBytes(), 0xff);
                    } else {
                        @memset(result.rawBytes(), 0x00);
                    }
                }
            },
        }
        return result;
    }

    /// Calculate the checksum for MITS hard-sectored 8" disks
    fn mitsChecksum(self: *DiskSector, _: PhysicalAddress) u8 {
        var csum: u8 = 0;

        for (self.dataBytes()) |b| {
            csum +%= b;
        }
        if (self.* == .data) {
            csum +%= self.rawBytes()[2];
            csum +%= self.rawBytes()[3];
            csum +%= self.rawBytes()[5];
            csum +%= self.rawBytes()[6];
        }
        return csum;
    }

    fn mitsChecksumMini(self: *DiskSector, _: PhysicalAddress) u8 {
        var csum: u8 = 0;

        for (self.dataBytes()) |b| {
            csum +%= b;
        }
        return csum;
    }

    /// Called just before the sector is written to disk.
    pub fn prepareWrite(self: *DiskSector, image_type: *const DiskImageType, location: PhysicalAddress) void {
        switch (self.*) {
            .reserved => |*sector| {
                switch (image_type.OS) {
                    .cpm => {
                        sector.checksum = self.mitsChecksum(location);
                    },
                    .ados => { // if (location.track > 5) { // TODO: Need to sort out why >5 and do we need to do this for ADOS?
                        sector.checksum = self.mitsChecksum(location);
                    },
                    else => unreachable,
                }
            },
            .data => |*sector| {
                if (image_type.type_id == .ADOS_MINI and location.track == 0 and location.sector == 0) {
                    sector.checksum = 0x15;
                } else if (image_type.type_id == .CPM_MINI) {
                    sector.checksum = self.mitsChecksumMini(location);
                } else {
                    sector.checksum = self.mitsChecksum(location);
                }
            },
            else => {},
        }
    }

    /// Return the data portion of the sector
    pub fn dataBytes(self: *DiskSector) []u8 {
        switch (self.*) {
            inline else => |*sector| return &sector.data,
        }
    }

    pub fn dataLen(self: *const DiskSector) u16 {
        return switch (self.*) {
            inline else => |sector| sector.data.len,
        };
    }

    /// Return the whole sector, including the data portion.
    /// Only different to dataBytes() for hard-sectored disks
    pub fn rawBytes(self: *DiskSector) []u8 {
        return switch (self.*) {
            inline else => |*sector| return std.mem.asBytes(sector),
        };
    }

    /// Offset to the start of teh data
    pub fn dataStart(self: *const DiskSector) u8 {
        return switch (self.*) {
            inline else => |sector| @offsetOf(@TypeOf(sector), "data"),
        };
    }

    /// Hexdump raw sector information.
    pub fn dump(self: DiskSector, location: PhysicalAddress, offset: usize) !void {
        if (!DUMP)
            return;
        std.debug.print("Disk Sector: TRACK: {} - SECTOR {} - OFFSET: {}\n", .{ location.track, location.sector, offset });
        std.debug.dumpHex(std.mem.asBytes(self));
    }
};

// Represents the basic disk parameters for a supported disk type
// Performs format-specfic functions such as converting logical to
// physical disk sectors.
// Should never be instantiated directly, but instead is initalized
// by one of the Concrete formats, e.g. DiskImageType_MITS_8IN
pub const DiskImageType = struct {
    pub const max_user = 15;

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
    // Are all sectors formatted the same or do they vary per track?
    varying_sector_format: bool,
    // Which operating system is this?
    OS: union(OperatingSystem) {
        cpm: void,
        cdos: void,
        ados: struct {
            directory_track: u8,
        },
        hd_basic: void,
    },
    // Skew from logical to physical sector
    skew_fn: *const fn (skew_table: []const u16, track: u16, sector: u16) u16 = defaultSkewFn,
    // Defines logical to physical skews.
    skew_table: []const u16 = undefined,
    // Detect this image type
    detect_fn: *const fn (self: *const DiskImageType, io: std.Io, file: std.Io.File) bool = defaultDetectFn,

    // Below are "constants" - These are initialised with "init".
    track_size: u16 = undefined,
    total_allocs: u32 = undefined, // Actually u16, but u32 gets rid of a lot of casting.
    recs_per_alloc: u16 = undefined,
    allocs_per_extent: u8 = undefined,
    recs_per_extent: u16 = undefined,
    dirs_per_alloc: u16 = undefined,
    dirs_per_sector: u16 = undefined,
    dir_entry_size: u8 = undefined,
    sectors_per_alloc: u16 = undefined,

    pub fn init(self: *DiskImageType) void {
        comptime std.debug.assert(self.skew_table.len == self.sectors_per_track);
        self.track_size = self.sector_size_raw * self.sectors_per_track;
        self.total_allocs = @as(u32, (self.tracks - self.reserved_tracks)) * self.sectors_per_track * self.sector_size_data / self.block_size;
        self.recs_per_extent = 128;
        self.allocs_per_extent = 128 * 128 / self.block_size; // This is the number of entries in the allocations table. (max 16)
        self.recs_per_alloc = self.recs_per_extent / self.allocs_per_extent;
        self.dir_entry_size = switch (self.OS) {
            .cpm, .cdos => 32,
            .ados => 16,
            .hd_basic => 128,
        };
        self.dirs_per_alloc = self.block_size / self.dir_entry_size;
        self.dirs_per_sector = self.sector_size_data / self.dir_entry_size;
        self.sectors_per_alloc = self.block_size / self.sector_size_data;
    }

    pub fn dump(self: *const DiskImageType) void {
        // TODO: Work out what is important to show here.
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
        std.debug.print("Dirs / Sect   {}\n", .{self.dirs_per_sector});
        std.debug.print("Allocs / Dir: {}\n", .{self.allocs_per_extent});
        std.debug.print("Dir Allocs:   {}\n", .{self.directory_allocs});
        std.debug.print("Num Dirs:     {}\n", .{self.directories});
        std.debug.print("Num Allocs:   {}\n", .{self.total_allocs});
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        return self.detect_fn(self, io, image_file);
    }

    /// Convert logical track/sector into physical sector.
    /// The aim is that the next logical sector will by physically undereed the read/write head when
    /// the next sector is ready to be read/written.
    pub fn skew(self: *const DiskImageType, track: u16, logical_sector: u16) u16 {
        if (track == 0 and self.sectors_per_track0 != null) {
            // We don't store a separate skew table for track 0.
            return logical_sector;
        }
        return self.skew_fn(self.skew_table, track, logical_sector);
    }

    /// Convert a physical track / sector into a seek offset
    pub fn seekOffset(self: *const DiskImageType, location: PhysicalAddress) usize {
        if (self.sector_size_data0) |sector_size0| {
            return if (location.track == 0)
                sector_size0 * (location.sector)
            else
                self.sectors_per_track0.? * sector_size0 + @as(usize, location.track - 1) * self.track_size + (location.sector) * self.sector_size_raw;
        } else {
            return @as(usize, location.track) * self.track_size + (location.sector) * self.sector_size_raw;
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

    pub fn sectorsForTrack(self: *const DiskImageType, track_nr: u16) u16 {
        return if (track_nr > 0) self.sectors_per_track else self.sectors_per_track0 orelse self.sectors_per_track;
    }

    /// Return total number of sectors used to store data.
    pub fn largestFileBytes(self: *const DiskImageType) u32 {
        // ADOS Mini can't use track 0, but still counts it as an allocation.
        if (self.type_id == .HD_BASIC) {
            return 4800512; // There is no real way to calc this. it just is.
        }
        const adjustment: u32 = if (self.type_id == .ADOS_MINI) 2 else 0;
        return (self.total_allocs - self.directory_allocs - adjustment) * self.block_size;
    }

    // By default, use the provided skew table, with no other adjustment required.
    fn defaultSkewFn(skew_table: []const u16, _: u16, logical_sector: u16) u16 {
        return skew_table[logical_sector];
    }

    pub fn defaultDetectFn(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        const image_size = image_file.length(io) catch return false;
        return image_size == self.image_size or image_size == (self.image_size + 127) / 128 * 128;
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
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [32]u16{
        0, 8,  16, 24, 2, 10, 18, 26,
        4, 12, 20, 28, 6, 14, 22, 30,
        1, 9,  17, 25, 3, 11, 19, 27,
        5, 13, 21, 29, 7, 15, 23, 31,
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
            .varying_sector_format = true,
            .skew_fn = skew,
            .skew_table = &skew_table,
        };
        result.init();
        return result;
    }

    /// For historical reasons, the skew changes based on the track number.
    fn skew(table: []const u16, track: u16, logical_sector: u16) u16 {
        if (track < 6)
            return table[logical_sector];

        return (((table[logical_sector]) * 17) % 32);
    }
};

/// The FDC+ controller supports an 8MB "floppy" disk
/// Has the same skew and 137 byte physical sectors as the
/// standard 8" drive.
pub const DiskImageType_MITS_8IN_8MB = struct {
    const skew_table = [32]u16{
        0, 8,  16, 24, 2, 10, 18, 26,
        4, 12, 20, 28, 6, 14, 22, 30,
        1, 9,  17, 25, 3, 11, 19, 27,
        5, 13, 21, 29, 7, 15, 23, 31,
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
            .two_byte_allocs = true,
            .image_size = 8978432,
            .varying_sector_format = true,
            .skew_fn = DiskImageType_MITS_8IN.skew,
            .skew_table = &skew_table,
        };
        result.init();
        // TODO: These should be calculated, correctly in init, instead of being set here.
        result.allocs_per_extent = 16;
        result.recs_per_extent = 256;
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
        return initCommon(true);
    }

    // Split so that the 1024 directory entry version can share this init.
    pub fn initCommon(init_before_return: bool) DiskImageType {
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
        var result = DiskImageType_MITS_5MB_HDD.initCommon(false);
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
    const skew_table = [_]u16{
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
            .varying_sector_format = false,
            .skew_table = &skew_table,
        };
        result.init();
        return result;
    }
};

// FDC+ controller supports 1.5MB floppy disks
pub const @"DiskImageType_FDD_1.5MB" = struct {
    const skew_table = [_]u16{
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
            .skew_table = &skew_table,
        };
        result.init();
        // This should be calculated correctly in init, instead of being set here.
        result.allocs_per_extent = 16;
        return result;
    }
};

/// Shared CDOS functions.
pub const CDOS = struct {
    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (!DiskImageType.defaultDetectFn(self, io, image_file)) return false;
        var buf: [128]u8 = undefined;
        var reader = image_file.reader(io, &.{});
        reader.interface.readSliceAll(&buf) catch return false;
        // Check for the disk label
        if (std.mem.eql(u8, buf[120..126], @tagName(self.type_id)[5..])) {
            // Currently only support the "default" number of directories for CDOS formats.
            return true;
        }
        // One of the CDOS images that ships with the Altair Duino doesn't
        // have a disk type label. So we look for the operating system instead.
        if (self.type_id == .CDOS_LGSSSD) {
            reader.seekTo(256) catch return false;
            reader.interface.readSliceAll(&buf) catch return false;
            return std.mem.eql(u8, buf[6..14], "CDOS.COM");
        }
        return false;
    }
};

// CDOS "Small"
pub const DiskImageType_CDOS_SMSSSD = struct {
    const skew_table = [_]u16{
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
            .varying_sector_format = true, // First sector contains label
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        return result;
    }
};

pub const DiskImageType_CDOS_SMSSDD = struct {
    const skew_table = [_]u16{
        0, 4, 8, 2, 6,
        1, 5, 9, 3, 7,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_SMSSDD,
            .type_name = "CDOS_SMSSDD",
            .description = "CDOS 5.25\" SS DD Disk",
            .OS = .cdos,
            .tracks = 40,
            .reserved_tracks = 2,
            .sectors_per_track = 10,
            .sector_size_raw = 512,
            .sector_size_data = 512,
            .sectors_per_track0 = 18,
            .sector_size_raw0 = 128,
            .sector_size_data0 = 128,
            .block_size = 1024,
            .directories = 64,
            .directory_allocs = 2,
            .image_size = 201984,
            .varying_sector_format = true, // First sector contains label
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        return result;
    }
};

pub const DiskImageType_CDOS_SMDSSD = struct {
    const skew_table = [_]u16{
        0, 5,  10, 15, 2, 7,  12, 17,
        4, 9,  14, 1,  6, 11, 16, 3,
        8, 13,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_SMDSSD,
            .type_name = "CDOS_SMDSSD",
            .description = "CDOS 5.25\" DS SD Disk",
            .OS = .cdos,
            .tracks = 80,
            .reserved_tracks = 3,
            .sectors_per_track = 18,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 1024,
            .directories = 64,
            .directory_allocs = 2,
            .image_size = 184320,
            .varying_sector_format = true, // First sector contains label
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        return result;
    }
};

pub const DiskImageType_CDOS_SMDSDD = struct {
    const skew_table = [_]u16{
        0, 4, 8, 2, 6,
        1, 5, 9, 3, 7,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_SMDSDD,
            .type_name = "CDOS_SMDSDD",
            .description = "CDOS 5.25\" DS DD Disk",
            .OS = .cdos,
            .tracks = 80,
            .reserved_tracks = 2,
            .sectors_per_track = 10,
            .sector_size_raw = 512,
            .sector_size_data = 512,
            .sectors_per_track0 = 18,
            .sector_size_raw0 = 128,
            .sector_size_data0 = 128,
            .block_size = 2048,
            .directories = 128,
            .directory_allocs = 2,
            .image_size = 406784,
            .varying_sector_format = true, // First sector contains label
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        return result;
    }
};

// CDOS "Large"
pub const DiskImageType_CDOS_LGSSSD = struct {
    const skew_table = [_]u16{
        0,  6,  12, 18, 24, 4,  10, 16,
        22, 2,  8,  14, 20, 1,  7,  13,
        19, 25, 5,  11, 17, 23, 3,  9,
        15, 21,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_LGSSSD,
            .type_name = "CDOS_LGSSSD",
            .description = "CDOS 8\" SSSD Disk",
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
            .varying_sector_format = true, // First sector contains a label
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        return result;
    }
};

// For all Cromemco DD disks have the, the first track is SD
// Note that no skew is performed when reading/writing the reserved track 0 and 1.
pub const DiskImageType_CDOS_LGSSDD = struct {
    const skew_table = [_]u16{
        0, 11, 6,  1, 12, 7,  2,  13,
        8, 3,  14, 9, 4,  15, 10, 5,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_LGSSDD,
            .type_name = "CDOS_LGSSDD",
            .description = "CDOS 8\" SSDD Disk",
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
            .directory_allocs = 2,
            .image_size = 625920,
            .varying_sector_format = true, // track 0 is SD, rest DD
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        // So since we're using single byte allocs on this format we have to restrict to using
        // 254 of the 300 available allocations.
        result.total_allocs = 254;
        return result;
    }
};

pub const DiskImageType_CDOS_LGDSSD = struct {
    const skew_table = [_]u16{
        0,  6,  12, 18, 24, 4,  10, 16,
        22, 2,  8,  14, 20, 1,  7,  13,
        19, 25, 5,  11, 17, 23, 3,  9,
        15, 21,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_LGDSSD,
            .type_name = "CDOS_LGDSSD",
            .description = "CDOS 8\" DSSD Disk",
            .OS = .cdos,
            .tracks = 154,
            .reserved_tracks = 2,
            .sectors_per_track = 26,
            .sector_size_raw = 128,
            .sector_size_data = 128,
            .block_size = 2048,
            .directories = 128,
            .directory_allocs = 2,
            .image_size = 512512,
            .varying_sector_format = true, // track 0 has disk type information
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        return result;
    }
};

pub const DiskImageType_CDOS_LGDSDD = struct {
    const skew_table = [_]u16{
        0, 11, 6,  1, 12, 7,  2,  13,
        8, 3,  14, 9, 4,  15, 10, 5,
    };

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CDOS_LGDSDD,
            .type_name = "CDOS_LGDSDD",
            .description = "CDOS 8\" DSDD Disk",
            .OS = .cdos,
            .tracks = 154,
            .reserved_tracks = 2,
            .sectors_per_track = 16,
            .sectors_per_track0 = 26,
            .sector_size_raw = 512,
            .sector_size_data = 512,
            .sector_size_data0 = 128,
            .sector_size_raw0 = 128,
            .block_size = 2048,
            .directories = 256,
            .directory_allocs = 4,
            .two_byte_allocs = true,
            .image_size = 1256704,
            .varying_sector_format = true, // track 0 is SD, rest DD
            .skew_table = &skew_table,
            .detect_fn = CDOS.isCorrectFormat,
        };
        result.init();
        return result;
    }
};

// Atair DOS
pub const DiskImageType_ADOS_8IN = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [32]u16{
        0,  17, 2,  19, 4,  21, 6,  23,
        8,  25, 10, 27, 12, 29, 14, 31,
        16, 1,  18, 3,  20, 5,  22, 7,
        24, 9,  26, 11, 28, 13, 30, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .ADOS_8IN,
            .type_name = "ADOS_8IN",
            .description = "Altair DOS & BASIC 8\" Floppy Disk ",
            .OS = .{
                .ados = .{ .directory_track = 70 },
            },
            .tracks = 77,
            .reserved_tracks = 6,
            .sectors_per_track = 32,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 255, // last entry is always "end of directory"
            .directory_allocs = 4,
            .image_size = 337568,
            .varying_sector_format = true,
            .skew_table = &skew_table,
            .detect_fn = isCorrectFormat,
        };
        result.init();
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (!DiskImageType.defaultDetectFn(self, io, image_file)) return false;
        var reader = image_file.reader(io, &.{});
        // Go to the directory table location on track 70
        reader.seekTo(self.OS.ados.directory_track * @as(u32, self.track_size)) catch return false;
        var sector: DiskSector = .initUnformatted(self, self.OS.ados.directory_track);

        reader.interface.readSliceAll(sector.rawBytes()) catch return false;
        var entries: []AltairDosDirEntry = std.mem.bytesAsSlice(AltairDosDirEntry, sector.dataBytes());

        // It might be a new directory with no entries.
        // std.debug.print("checking empty\n", .{});
        if (entries[0].filename[0] == 0xff) {
            // All the other entry filenames need ot start with 0 as they either never existed, or were deleted.
            for (entries[1..]) |e| {
                if (e.filename[0] != 0x00) return false;
            }
            return true;
        }
        // std.debug.print("checking dir\n", .{});

        // So there must be at least 1 entry
        var start: usize = 1;
        for (0..self.sectors_per_track) |_| {
            for (entries, start..) |e, entry_nr| {
                if (e.filename[0] == 255) return false;
                if (e.filename[0] == 0x00) continue; // deleted
                if (e.track >= self.tracks or e.sector >= self.sectors_per_track) return false;
                //                std.debug.print("not EOD or deleted\n", .{});

                for (e.filename) |ch| {
                    // invalid filename chars
                    if (!std.ascii.isPrint(ch)) return false;
                }
                //              std.debug.print("valid filename {s}\n", .{e.filename});

                // must be valid filename. so check that this entry had correct fileno.
                reader.seekTo(@as(u32, e.track) * self.track_size + 137 * @as(u32, e.sector)) catch return false;
                //             std.debug.print("Seeked to : {x}, \n", .{reader.logicalPos()});
                reader.interface.readSliceAll(sector.rawBytes()) catch return false;
                //           std.debug.print("checking file_nr {} vs {}\n", .{ sector.mits_track_6_76.file_nr, entry_nr });

                return sector.data.file_nr == entry_nr;
            }
            start = 0;
            reader.interface.readSliceAll(sector.rawBytes()) catch return false;
            entries = std.mem.bytesAsSlice(AltairDosDirEntry, sector.rawBytes());
        }

        return false;
    }
};

pub const DiskImageType_ADOS_MINI = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [16]u16{
        0, 1, 2,  3,  4,  5,  6,  7,
        8, 9, 10, 11, 12, 13, 14, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .ADOS_MINI,
            .type_name = "ADOS_MINI",
            .description = "Altair DOS & BASIC 5.25\" Data Floppy Disk ",
            .OS = .{
                .ados = .{ .directory_track = 34 },
            },
            .tracks = 35,
            .reserved_tracks = 0, // was 11
            .sectors_per_track = 16,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 127,
            .directory_allocs = 2,
            .image_size = 76720,
            .varying_sector_format = true,
            .skew_table = &skew_table,
            .detect_fn = isCorrectFormat,
        };
        result.init();
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (DiskImageType_ADOS_8IN.isCorrectFormat(self, io, image_file)) {
            var sector: [sector_size]u8 = undefined;
            var reader = image_file.reader(io, &.{});
            reader.interface.readSliceAll(&sector) catch return false;
            return sector[135] == 0xff; // Look for stop byte vs zero bytes
        }
        return false;
    }
};

pub const DiskImageType_ADOS_MINI_BOOT = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    const skew_table = [16]u16{
        0, 2, 4, 6, 8, 10, 12, 14,
        1, 3, 5, 7, 9, 11, 13, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;
    const reserved_tracks = 12;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .ADOS_MINI_BOOT,
            .type_name = "ADOS_MINI_BOOT",
            .description = "Altair DOS & BASIC 5.25\" Bootable Floppy Disk ",
            .OS = .{
                .ados = .{ .directory_track = 34 },
            },
            .tracks = 35,
            .reserved_tracks = reserved_tracks,
            .sectors_per_track = 16,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 127,
            .directory_allocs = 2,
            .image_size = 76720,
            .varying_sector_format = true,
            .skew_table = &skew_table,
            .skew_fn = skew,
            .detect_fn = isCorrectFormat,
        };
        result.init();
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, image_file: std.Io.File) bool {
        if (DiskImageType_ADOS_8IN.isCorrectFormat(self, io, image_file)) {
            var sector: [sector_size]u8 = undefined;
            var reader = image_file.reader(io, &.{});
            reader.interface.readSliceAll(&sector) catch return false;
            return sector[135] == 0x00; // Look for stop byte vs zero bytes
        }
        return false;
    }

    // This is never currently called for reserved tracks as they are written as raw 1367 byte sectors.
    pub fn skew(table: []const u16, track: u16, sector: u16) u16 {
        if (track < reserved_tracks) {
            return table[sector];
        } else {
            return sector;
        }
    }
};

pub const DiskImageType_CPM_MINI = struct {
    // Note that mits skew algorithm requires first sector to be 1, not 0
    // const skew_table = [16]u16{
    //     0, 2, 4, 6, 8, 10, 12, 14,
    //     1, 3, 5, 7, 9, 11, 13, 15,
    // };
    const skew_table = [16]u16{
        0, 2, 4, 6, 8, 10, 12, 14,
        1, 3, 5, 7, 9, 11, 13, 15,
    };

    const sector_size = 137; // Note non-standard sector size.
    const sector_data_size = 128;
    const reserved_tracks = 4;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .CPM_MINI,
            .type_name = "CPM_MINI",
            .description = "Altair CPM 5.25\" Floppy Disk",
            .OS = .cpm,
            .tracks = 35,
            .reserved_tracks = reserved_tracks,
            .sectors_per_track = 16,
            .sector_size_raw = sector_size,
            .sector_size_data = sector_data_size,
            .block_size = 1024,
            .directories = 32,
            .directory_allocs = 1,
            .image_size = 76720,
            .varying_sector_format = true,
            .skew_table = &skew_table,
        };
        result.init();
        return result;
    }
};

pub const DiskImageTypes = enum {
    FDD_8IN,
    HDD_5MB,
    HDD_5MB_1024,
    FDD_TAR,
    @"FDD_1.5MB",
    FDD_8IN_8MB,
    CDOS_SMSSSD,
    CDOS_SMSSDD,
    CDOS_SMDSSD,
    CDOS_SMDSDD,
    CDOS_LGSSSD,
    CDOS_LGSSDD,
    CDOS_LGDSSD,
    CDOS_LGDSDD,
    ADOS_8IN,
    ADOS_MINI,
    ADOS_MINI_BOOT,
    CPM_MINI,
    HD_BASIC,
    // Create an enum with just the sub-set of CDOS disk types.
    pub fn CDOSTypes() type {
        const fields = std.meta.fields(@This());
        const tag_type = @typeInfo(@This()).@"enum".tag_type;
        var names: [fields.len][]const u8 = undefined;
        var values: [fields.len]tag_type = undefined;
        var field_count: usize = 0;
        for (fields) |field| {
            if (std.mem.startsWith(u8, field.name, "CDOS_")) {
                names[field_count] = field.name;
                values[field_count] = field.value;
                field_count += 1;
            }
        }
        return @Enum(tag_type, .exhaustive, names[0..field_count], values[0..field_count]);
    }

    /// Convert a DiskImageTypes enum to a CDOSTypes enum
    /// Will panic if called for a non-cdos image type.
    pub fn toCDOS(self: DiskImageTypes) CDOSTypes() {
        return @enumFromInt(@intFromEnum(self));
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
    .CDOS_SMSSDD = DiskImageType_CDOS_SMSSDD.init(),
    .CDOS_SMDSSD = DiskImageType_CDOS_SMDSSD.init(),
    .CDOS_SMDSDD = DiskImageType_CDOS_SMDSDD.init(),
    .CDOS_LGSSSD = DiskImageType_CDOS_LGSSSD.init(),
    .CDOS_LGSSDD = DiskImageType_CDOS_LGSSDD.init(),
    .CDOS_LGDSSD = DiskImageType_CDOS_LGDSSD.init(),
    .CDOS_LGDSDD = DiskImageType_CDOS_LGDSDD.init(),
    .ADOS_8IN = DiskImageType_ADOS_8IN.init(),
    .ADOS_MINI = DiskImageType_ADOS_MINI.init(),
    .ADOS_MINI_BOOT = DiskImageType_ADOS_MINI_BOOT.init(),
    .CPM_MINI = DiskImageType_CPM_MINI.init(),
    .HD_BASIC = hd_basic.DiskImageType_HD_BASIC.init(),
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
const hd_basic = @import("hd_basic.zig");
