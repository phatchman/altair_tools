//! Cromemco CDOS Support
//! Functionality is shared with CPM.

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
            .description = "5.25\" SS SD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
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
            .description = "CROMEMCO 5.25\" SS DD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
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
            .description = "CROMEMCO 5.25\" DS SD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
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
            .description = "CROMEMCO 5.25\" DS DD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
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
            .description = "CROMEMCO 8\" SSSD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
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
            .description = "CROMEMCO 8\" SSDD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
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
            .description = "CROMEMCO 8\" DSSD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
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
            .description = "CROMEMCO 8\" DSDD Disk (CDOS)",
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
            .detect_fn = isCorrectFormat,
        };
        result.init();
        return result;
    }
};

/// Shared CDOS functions.
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

const disk_types = @import("disk_types.zig");
const DiskImageType = disk_types.DiskImageType;
const std = @import("std");
