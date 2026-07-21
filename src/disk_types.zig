//!
//! Contains all parameters required to process the various altair disk formats.
//! Provides generic routines to skew logical to physical disk sectors and
//! other various quirks of the raw disk layouts.

const log = std.log.scoped(.altair_disk_lib);
const logerr = if (@import("builtin").fuzz) log.info else log.err;

/// all available disk image formats.
pub const all_disk_types: std.enums.EnumArray(DiskImageTypes, DiskImageType) = .init(.{
    .FDD_8IN = cpm.DiskImageType_MITS_8IN.init(),
    .HDD_5MB = cpm.DiskImageType_MITS_5MB_HDD.init(),
    .HDD_5MB_1024 = cpm.DiskImageType_MITS_5MB_HDD_1024.init(),
    .FDD_TAR = cpm.DiskImageType_TARBELL_FDD.init(),
    .@"FDD_1.5MB" = cpm.@"DiskImageType_FDD_1.5MB".init(),
    .FDD_8IN_8MB = cpm.DiskImageType_MITS_8IN_8MB.init(),
    .CPM_MINI = cpm.DiskImageType_CPM_MINI.init(),
    .CDOS_SMSSSD = cdos.DiskImageType_CDOS_SMSSSD.init(),
    .CDOS_SMSSDD = cdos.DiskImageType_CDOS_SMSSDD.init(),
    .CDOS_SMDSSD = cdos.DiskImageType_CDOS_SMDSSD.init(),
    .CDOS_SMDSDD = cdos.DiskImageType_CDOS_SMDSDD.init(),
    .CDOS_LGSSSD = cdos.DiskImageType_CDOS_LGSSSD.init(),
    .CDOS_LGSSDD = cdos.DiskImageType_CDOS_LGSSDD.init(),
    .CDOS_LGDSSD = cdos.DiskImageType_CDOS_LGDSSD.init(),
    .CDOS_LGDSDD = cdos.DiskImageType_CDOS_LGDSDD.init(),
    .ADOS_8IN = ados.DiskImageType_ADOS_8IN.init(),
    .ADOS_MINI = ados.DiskImageType_ADOS_MINI.init(),
    .TIMESHARE_BASIC = ados.DiskImageType_TIMESHARE_BASIC.init(),
    .ADOS_MINI_BOOT = ados.DiskImageType_ADOS_MINI_BOOT.init(),
    .HD_BASIC = hd_basic.DiskImageType_HD_BASIC.init(),
});

/// The display names for each image type.
pub const all_disk_type_names = init: {
    var r: [all_disk_types.values.len][]const u8 = undefined;
    for (0..all_disk_types.values.len) |i| {
        r[i] = all_disk_types.values[i].type_name;
    }
    const result = r;
    break :init result;
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
    TIMESHARE_BASIC,
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

pub const OperatingSystem = enum {
    cpm,
    cdos,
    ados,
    hd_basic,
};

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
                std.mem.trimEnd(u8, &lbl.user_label, " "),
                lbl.date_mmddyy[0] / 10 + '0',
                lbl.date_mmddyy[0] % 10 + '0',
                lbl.date_mmddyy[1] / 10 + '0',
                lbl.date_mmddyy[1] % 10 + '0',
                lbl.date_mmddyy[2] / 10 + '0',
                lbl.date_mmddyy[2] % 10 + '0',
            }),
            .hd_basic => |lbl| try writer.print("Label: {s}  Created: {f}  Modified: {f}", .{
                std.mem.trimEnd(u8, &lbl.user_label, " "),
                hd_basic.fmtDate(lbl.created_yymmdd),
                hd_basic.fmtDate(lbl.modified_yymmdd),
            }),
        }
    }
};

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
/// For MITS hard-sectored disks, the raw on-disk sector length (137) is different to the data length (128).
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
            // FUTURE TODO: Need to make this so when add a new 137 byte format we
            // either get a compile error here, or don't have to update this switch. Either one.
            .FDD_8IN,
            .FDD_8IN_8MB,
            => if (track_nr < 6)
                .{ .reserved = undefined }
            else
                .{ .data = undefined },
            .ADOS_8IN,
            .TIMESHARE_BASIC,
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

    // FUTURE TODO: In future think of a better way to split this out.
    // Issue is that some things change on OS, some on OS within format and some just on format.
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
                        if (image_type.type_id == .TIMESHARE_BASIC) unreachable;
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
                    if (page > hd_basic.DiskImageType_HD_BASIC.directory_page and page < hd_basic.DiskImageType_HD_BASIC.directory_page + 256) {
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
                    .ados => {
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
    // How many allocations are reserved e.g. for the directory table.
    reserved_allocs: u16,
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
        std.debug.print("Sect / Alloc: {}\n", .{self.sectors_per_alloc});
        std.debug.print("Dir Allocs:   {}\n", .{self.reserved_allocs});
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
        return (self.total_allocs - self.reserved_allocs - adjustment) * self.block_size;
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

const std = @import("std");
const hd_basic = @import("os_hd_basic.zig");
const cpm = @import("os_cpm.zig");
const cdos = @import("os_cdos.zig");
const ados = @import("os_altair_dos.zig");
