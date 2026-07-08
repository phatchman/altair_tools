pub const VolumeDecriptor = extern struct {
    label: [20]u8,
    date: [6]u8,
    backup_set: u16 align(1),
    allocation_pages: [3]u16 align(1),
    directory_pages: [3]u16 align(1),
    os_start_page: u16 align(1),
    os_page_count: u16 align(1),
    mount_flag: u16 align(1),
    unused: [18]u8,
    allocation_page_current: u16 align(1),
    allocation_page_count: u16 align(1),
    directory_entry_current: u16 align(1),
    directory_entry_count: u16 align(1),
    unknown: [4]u8,
    last_page: u16 align(1),
    free_groups: u16 align(1),
    reserved_groups: u16 align(1),
    unusable_groups: u16 align(1),
    swap_area: [2]u16 align(1),
    swap_area2: [2]u16 align(1),
    unused3: [164]u8,

    pub fn format(self: *const VolumeDecriptor, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Label             : {s}\n", .{self.label});
        try writer.print("Date              : {f}\n", .{fmtDate(self.date[0..3].*)});
        try writer.print("Backup Set        : {}\n", .{self.backup_set});
        try writer.print("Allocation Pages  : {any}\n", .{self.allocation_pages});
        try writer.print("Directory Pages   : {any}\n", .{self.directory_pages});
        try writer.print("OS Start Page     : {d}\n", .{self.os_start_page});
        try writer.print("Mounted           : {d}\n", .{self.mount_flag});
        try writer.print("Alloc Page Current: {d}\n", .{self.allocation_page_current});
        try writer.print("Alloc Page Count  : {d}\n", .{self.allocation_page_count});
        try writer.print("Dir Entry Current : {d}\n", .{self.directory_entry_current});
        try writer.print("Dir Entry Count   : {d}\n", .{self.directory_entry_count});
        try writer.print("Last Page         : {d}\n", .{self.last_page});
        try writer.print("Free Groups       : {d}\n", .{self.free_groups});
        try writer.print("Reserved Groups   : {d}\n", .{self.reserved_groups});
        try writer.print("Unusable? Groups  : {d}\n", .{self.unusable_groups});
        try writer.print("Swap Area         : {any}\n", .{self.swap_area});
        try writer.print("Swap Area2        : {any}\n", .{self.swap_area2});
    }
};

pub const DirEntry = extern struct {
    filename: [24]u8,
    creation_date: [3]u8,
    modification_date: [3]u8,
    read_only: u8,
    unused: [23]u8,
    status: u8,
    unused2: u8,
    npages: u16 align(1),
    eof_byte: u16 align(1),
    ngroups: u16 align(1),
    last_group: u16 align(1),
    allocations: [32]u16 align(1),

    pub fn isDeleted(self: *const DirEntry) bool {
        return self.status != 0x01;
    }

    pub fn setDeleted(self: *DirEntry) void {
        self.status = 0x00; // TODO: Confirm correct.
    }

    pub fn isLastEntry(self: *const DirEntry) bool {
        return self.status == 0xff;
    }

    pub fn eql(self: *DirEntry, cooked: *directory_table.CookedDirEntry) bool {
        _ = self;
        _ = cooked;
        @panic("TODO");
    }

    pub fn format(self: *const DirEntry, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Filename         : {s}\n", .{self.filename});
        try writer.print("Creation         : {f}\n", .{fmtDate(self.creation_date)});
        try writer.print("Modification     : {f}\n", .{fmtDate(self.modification_date)});
        try writer.print("Read Only        : {}\n", .{self.read_only});
        try writer.print("Status           : {x}\n", .{self.status});
        try writer.print("Last Page        : {}\n", .{self.npages});
        try writer.print("Last Byte        : {}\n", .{self.eof_byte});
        try writer.print("Group Count      : {}\n", .{self.ngroups});
        try writer.print("Last Group       : {}\n", .{self.last_group});
        try writer.print("Allocations      : {any}\n", .{self.allocations});
    }
};

pub fn fmtDate(date: [3]u8) std.fmt.Alt([3]u8, formatDate) {
    return .{ .data = date };
}
fn formatDate(date: [3]u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d:02}/{d:02}/{d:02}", .{ date[1], date[2], date[0] });
}

comptime {
    std.debug.assert(@sizeOf(VolumeDecriptor) == 256);
    std.debug.assert(@sizeOf(DirEntry) == 128);
}

const page_size: u16 = 256;
var dir_entries: std.ArrayList(DirEntry) = .empty;

// pub fn main(init: std.process.Init) !void {
//     var stdout_buffer: [256]u8 = undefined;
//     var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
//     const stdout = &stdout_writer.interface;
//     defer stdout.flush() catch {};

//     const args = try init.minimal.args.toSlice(init.arena.allocator());
//     if (args.len != 2) {
//         std.debug.print("Usage: {s} <filename>\n", .{std.fs.path.basename(args[0])});
//         return;
//     }

//     var image_file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{ .mode = .read_only });
//     defer image_file.close(init.io);

//     var read_buffer: [256]u8 = undefined;
//     var reader = image_file.reader(init.io, &read_buffer);
//     const vol_label = try reader.interface.takeStruct(VolumeDecriptor, .little);
//     std.debug.print("{f}\n", .{&vol_label});
//     try seekToPage(&reader, vol_label.directory_pages[0]);
//     for (0..vol_label.directory_entry_count) |_| {
//         const entry = try reader.interface.takeStruct(DirEntry, .little);
//         if (entry.status == 0xff) break // End of directory
//         else if (entry.status == 0x01) { // "small file"
//             try dir_entries.append(init.arena.allocator(), entry);
//             std.debug.print("{f}\n", .{&entry});
//         }
//     }
//     const filename = "HELP.TXT";
//     const out_file = try std.Io.Dir.cwd().createFile(init.io, filename, .{ .truncate = true });
//     defer out_file.close(init.io);
//     var file_writer = out_file.writer(init.io, &.{});
//     try extract(&reader, &file_writer.interface, filename);
// }

fn seekToPage(reader: *std.Io.File.Reader, page_nr: u16) !void {
    try reader.seekTo(@as(u64, page_nr) * page_size);
}

fn extract(reader: *std.Io.File.Reader, writer: *std.Io.Writer, filename: []const u8) !void {
    defer writer.flush() catch {};
    for (dir_entries.items) |dir_entry| {
        if (std.mem.eql(u8, filename, std.mem.trimEnd(u8, &dir_entry.filename, " "))) {
            var buffer: [256]u8 = undefined;
            var page_count: usize = 0;
            for (dir_entry.allocations) |alloc| {
                if (alloc == 0xffff) {
                    @panic("Shouldn't get here");
                    //                    return;
                }
                const start_page = alloc * 8;
                try seekToPage(reader, start_page);
                for (0..8) |offset| {
                    try reader.interface.readSliceAll(&buffer);
                    std.debug.print("page = {}, eof_page = {}\n", .{ start_page + offset, dir_entry.npages });
                    if (page_count == dir_entry.npages) {
                        std.debug.print("eof_byte = {}\n", .{dir_entry.eof_byte});
                        try writer.writeAll(buffer[0..dir_entry.eof_byte]);
                        return;
                    } else {
                        try writer.writeAll(&buffer);
                    }
                    page_count += 1;
                }
                if (alloc == dir_entry.last_group) return;
            }
        }
    }
}

pub const DiskImageType_HD_BASIC = struct {
    const skew_table = [48]u16{
        0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11,
        12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
        36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    };
    const directory_page = 192;
    const allocation_page = 1;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .HD_BASIC,
            .type_name = "HD_BASIC",
            .description = "Altair 5MB HD BASIC Disk",
            .OS = .hd_basic,
            .tracks = 406,
            .reserved_tracks = 4,
            .sectors_per_track = 48,
            .sector_size_raw = 256,
            .sector_size_data = 256,
            .block_size = 2048,
            .directories = 512,
            .directory_allocs = 56,
            .image_size = 4988928,
            .varying_sector_format = false,
            .skew_table = &skew_table,
        };
        result.init();
        result.total_allocs = @as(u32, result.tracks) * result.sectors_per_track * result.sector_size_data / result.block_size;
        return result;
    }
};

fn unsupported() void {
    @panic("TODO: unsupported");
}

pub fn loadDirectory(arena: std.mem.Allocator, dir: *DirectoryTable, image: *DiskImage, option: LoadOption) DirectoryTable.DirectoryLoadError!void {
    var label_sector: DiskSector = undefined;
    const label = try loadVolumeLabel(image, &label_sector);
    if (label.directory_pages[0] != DiskImageType_HD_BASIC.directory_page) {
        return unsupported();
    } else if (label.allocation_pages[0] != DiskImageType_HD_BASIC.allocation_page) {
        return unsupported();
    }

    var dir_page: u16 = DiskImageType_HD_BASIC.directory_page;
    var dir_location = toPhysicalAddress(image.image_type, dir_page);
    var dir_sector: DiskSector = .initUnformatted(image.image_type, dir_location.track);
    var dir_count: u16 = 0;
    while (dir_count < image.image_type.directories) {
        try image.readSectorPhysical(dir_location, &dir_sector);
        // Each 256B sector contains 2 x 128B diectory entries
        const entries = bytesAsSliceLE(DirEntry, dir_sector.dataBytes());
        dir.raw_directories.hd_basic.appendSliceAssumeCapacity(entries);
        dir_count += @intCast(entries.len);
        dir_page += 1;
        dir_location = toPhysicalAddress(image.image_type, dir_page);
    }
    for (0..image.image_type.directory_allocs) |alloc| {
        dir.free_allocations.unset(alloc);
    }
    // Last sector is used to store a duplicate volume label. TODO: So we assume that
    // means the last allocation is also unusable?
    dir.free_allocations.unset(image.image_type.total_allocs - 1);
    for (dir.raw_directories.hd_basic.items) |entry| {
        // TODO: validate external data
        for (entry.allocations) |alloc| {
            if (alloc == 0xffff) break;
            dir.free_allocations.unset(alloc);
        }
    }
    if (option == .full) {
        for (dir.raw_directories.hd_basic.items) |entry| {
            // TODO: Validate each entry. We need to do it in the non-full case as well to generate the error
            // messages even for raw extract.
            if (entry.isLastEntry()) break;
            if (!entry.isDeleted()) {
                const cooked: directory_table.CookedDirEntry = try .initHDBasic(arena, &entry, image.image_type);
                try dir.cooked_directories.append(arena, cooked);
            }
        }
    }
}

fn toPhysicalAddress(image_type: *const DiskImageType, page_nr: u16) PhysicalAddress {
    // TODO: Add validation
    // Pages are sequentially numbered sectors starting from track 0
    return .{
        .track = page_nr / image_type.sectors_per_track,
        .sector = page_nr % image_type.sectors_per_track,
    };
}

// TODO: Support get / set volume label for user.
fn loadVolumeLabel(image: *DiskImage, sector: *DiskSector) !*VolumeDecriptor {
    const location: PhysicalAddress = .{ .track = 0, .sector = 0 };
    sector.* = .initUnformatted(image.image_type, location.track);
    try image.readSectorPhysical(location, sector);
    const result = std.mem.bytesAsValue(VolumeDecriptor, sector.dataBytes());
    // TODO: Make this a bytesAsValueLE function.
    if (@import("builtin").target.cpu.arch.endian() == .big)
        byteSwapAllFields(VolumeDecriptor, result);
    return result;
}

// Cast as slice and byte-swap from little endian on big endian machines
pub fn bytesAsSliceLE(comptime T: type, bytes: anytype) @TypeOf(std.mem.bytesAsSlice(T, bytes)) {
    const result = std.mem.bytesAsSlice(T, bytes);
    for (result) |*val| {
        if (@import("builtin").target.cpu.arch.endian() == .big)
            byteSwapAllFields(T, val);
    }
    return result;
}

//pub fn bytesAsSliceEndian
// We need our own version as the std lib version doesn;t respect alignment on arrays correctly
const Alignment = std.mem.Alignment;
pub fn byteSwapAllFields(comptime S: type, ptr: *S) void {
    byteSwapAllFieldsAligned(S, .of(S), ptr);
}

fn byteSwapAllFieldsAligned(comptime S: type, comptime a: Alignment, ptr: *align(a.toByteUnits()) S) void {
    switch (@typeInfo(S)) {
        .@"struct" => |struct_info| {
            if (struct_info.backing_integer) |Int| {
                ptr.* = @bitCast(@byteSwap(@as(Int, @bitCast(ptr.*))));
            } else inline for (std.meta.fields(S)) |f| {
                switch (@typeInfo(f.type)) {
                    .array => |arr_info| {
                        for (0..arr_info.len) |i| {
                            const elem_ptr = &@field(ptr, f.name)[i];
                            switch (@typeInfo(arr_info.child)) {
                                .@"struct", .@"union", .array => byteSwapAllFieldsAligned(arr_info.child, .@"1", elem_ptr),
                                .@"enum" => elem_ptr.* = @enumFromInt(@byteSwap(@intFromEnum(elem_ptr.*))),
                                .bool => {},
                                .float => |float_info| elem_ptr.* = @bitCast(@byteSwap(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(elem_ptr.*)))),
                                else => elem_ptr.* = @byteSwap(elem_ptr.*),
                            }
                        }
                    },
                    .@"struct", .@"union" => byteSwapAllFieldsAligned(
                        f.type,
                        .fromByteUnits(f.alignment orelse @alignOf(f.type)),
                        &@field(ptr, f.name),
                    ),
                    .@"enum" => @field(ptr, f.name) = @enumFromInt(@byteSwap(@intFromEnum(@field(ptr, f.name)))),
                    .bool => {},
                    .float => |float_info| {
                        @field(ptr, f.name) = @bitCast(@byteSwap(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(@field(ptr, f.name)))));
                    },
                    else => @field(ptr, f.name) = @byteSwap(@field(ptr, f.name)),
                }
            }
        },
        else => @compileError("byteSwapAllFields: only structs supported"),
    }
}

const std = @import("std");
const disk_types = @import("disk_types.zig");
const DiskSector = disk_types.DiskSector;
const DiskImageType = disk_types.DiskImageType;
const directory_table = @import("directory_table.zig");
const DirectoryTable = directory_table.DirectoryTable;
const LoadOption = DirectoryTable.LoadOption;
const hd_basic = @import("hd_basic.zig");
const DiskImage = @import("disk_image.zig").DiskImage;
const PhysicalAddress = disk_types.PhysicalAddress;
