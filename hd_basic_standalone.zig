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
    eof_page: u16 align(1),
    eof_byte: u16 align(1),
    group_count: u16 align(1),
    last_group: u16 align(1),
    allocations: [32]u16 align(1),

    pub fn format(self: *const DirEntry, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Filename         : {s}\n", .{self.filename});
        try writer.print("Creation         : {f}\n", .{fmtDate(self.creation_date)});
        try writer.print("Modification     : {f}\n", .{fmtDate(self.modification_date)});
        try writer.print("Read Only        : {}\n", .{self.read_only});
        try writer.print("Status           : {x}\n", .{self.status});
        try writer.print("Last Page        : {}\n", .{self.eof_page});
        try writer.print("Last Byte        : {}\n", .{self.eof_byte});
        try writer.print("Group Count      : {}\n", .{self.group_count});
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

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("Usage: {s} <filename>\n", .{std.fs.path.basename(args[0])});
        return;
    }

    var image_file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{ .mode = .read_only });
    defer image_file.close(init.io);

    var read_buffer: [256]u8 = undefined;
    var reader = image_file.reader(init.io, &read_buffer);
    const vol_label = try reader.interface.takeStruct(VolumeDecriptor, .little);
    std.debug.print("{f}\n", .{&vol_label});
    try seekToPage(&reader, vol_label.directory_pages[0]);
    for (0..vol_label.directory_entry_count) |_| {
        const entry = try reader.interface.takeStruct(DirEntry, .little);
        if (entry.status == 0xff) break // End of directory
        else if (entry.status == 0x01) { // "small file"
            try dir_entries.append(init.arena.allocator(), entry);
            std.debug.print("{f}\n", .{&entry});
        }
    }
    const filename = "HELP.TXT";
    const out_file = try std.Io.Dir.cwd().createFile(init.io, filename, .{ .truncate = true });
    defer out_file.close(init.io);
    var file_writer = out_file.writer(init.io, &.{});
    try extract(&reader, &file_writer.interface, filename);
}

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
                    std.debug.print("page = {}, eof_page = {}\n", .{ start_page + offset, dir_entry.eof_page });
                    if (page_count == dir_entry.eof_page) {
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

const std = @import("std");
