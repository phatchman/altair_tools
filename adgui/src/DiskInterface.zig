const std = @import("std");
const ad = @import("altair_disk");
const host_os = ad.host_os;
const DiskImage = ad.DiskImage;
const DiskImageType = ad.DiskImageType;
const DiskImageTypes = ad.DiskImageTypes;
const allocator = @import("main.zig").allocator;

disk_image: ?ad.DiskImage,
// Only valid when disk_image is not null;
image_file: ?std.Io.File,
reader: ?std.Io.File.Reader,
writer: ?std.Io.File.Writer,

current_dir: ?std.Io.Dir,
image_directory_list: std.ArrayListUnmanaged(DirectoryEntry),
image_directory_changed: bool,
local_directory_list: std.ArrayListUnmanaged(DirectoryEntry),
local_directory_changed: bool,
image_arena: std.heap.ArenaAllocator,
local_arena: std.heap.ArenaAllocator,

const DiskInterface = @This();
pub const CopyMode = enum { AUTO, ASCII, BINARY, RANDOM, BASIC };

pub fn init(gpa: std.mem.Allocator) DiskInterface {
    return .{
        .disk_image = null,
        .image_file = null,
        .reader = null,
        .writer = null,
        .current_dir = null,
        .image_directory_list = .empty,
        .local_directory_list = .empty,
        .image_directory_changed = false,
        .local_directory_changed = false,
        .image_arena = .init(gpa),
        .local_arena = .init(gpa),
    };
}

pub fn deinit(self: *DiskInterface, io: std.Io) void {
    _ = self.local_arena.reset(.free_all);
    self.closeImage(io);
    if (self.current_dir) |*current_dir| {
        current_dir.close(io);
        self.current_dir = null;
    }
}

pub const LocalDirEntry = struct {
    filename: []const u8,
    extension: []const u8,
    full_filename: []const u8,
    size: usize,

    pub fn init(arena: std.mem.Allocator, os: ad.OperatingSystem, filename: []const u8, size: usize) !LocalDirEntry {
        var filename_buf: [12]u8 = undefined;
        const xlated_filename = try ad.DirectoryTable.translateToFilename(os, filename, &filename_buf);
        const dotIndex = std.mem.indexOf(u8, xlated_filename, ".") orelse xlated_filename.len;
        const filename_only = xlated_filename[0..dotIndex];
        const extension = if (dotIndex < xlated_filename.len - 1) xlated_filename[dotIndex + 1 .. xlated_filename.len] else "";
        return .{
            // TODO: There should be errdefers here? OR some other cleanup mechanism.
            .filename = try arena.dupe(u8, filename_only),
            .extension = try arena.dupe(u8, extension),
            .full_filename = try arena.dupe(u8, filename),
            .size = size,
        };
    }
};

pub const DirectoryUnion = union(enum) {
    image: ad.CookedDirEntry,
    local: LocalDirEntry,
};

pub const DirectoryEntry = struct {
    entry: DirectoryUnion,
    selected: bool,
    // TODO: is deleted actually needed for anything?
    deleted: bool,

    pub fn init(entry: DirectoryUnion) DirectoryEntry {
        return .{
            .entry = entry,
            .selected = false,
            .deleted = false,
        };
    }

    pub fn filename(self: *const DirectoryEntry) []const u8 {
        return switch (self.entry) {
            //TODO: figure out why these need to be pointers.
            // Otherwise it returns a temportary slice pointer or something.
            // But will use all pointers anyway as there is no need to create copies of anything.
            .image => |*dir| dir.filenameOnly(),
            .local => |*dir| dir.filename,
        };
    }

    pub fn extension(self: *const DirectoryEntry) []const u8 {
        return switch (self.entry) {
            .image => |*dir| dir.extensionOnly(),
            .local => |*dir| dir.extension,
        };
    }

    pub fn filenameAndExtension(self: *const DirectoryEntry) []const u8 {
        return switch (self.entry) {
            .image => |*dir| dir.filenameAndExtension(),
            .local => |*dir| dir.full_filename,
        };
    }

    pub fn attribs(self: *const DirectoryEntry) []const u8 {
        return switch (self.entry) {
            .image => |*dir| &dir.attribs,
            .local => "",
        };
    }

    pub fn fileSizeInB(self: *const DirectoryEntry) usize {
        return switch (self.entry) {
            .image => |*dir| dir.size_in_bytes,
            .local => |*dir| dir.size,
        };
    }

    pub fn fileUsedInKB(self: *const DirectoryEntry) usize {
        return switch (self.entry) {
            .image => |*dir| dir.used_in_kbytes,
            .local => |*dir| dir.size / 1024,
        };
    }

    pub fn user(self: *const DirectoryEntry) usize {
        return switch (self.entry) {
            .image => |*dir| dir.user,
            .local => 0,
        };
    }

    pub fn toggleSelected(self: *DirectoryEntry) void {
        self.selected = !self.selected;
    }
};

pub fn DirectoryIterator(to_iterate: []DirectoryEntry, element_selector: fn (entry: *const DirectoryEntry) bool) DirIterator {
    return .{
        .collection = to_iterate,
        .selector = element_selector,
        .idx = 0,
    };
}

pub const DirIterator = struct {
    collection: []DirectoryEntry,
    selector: *const fn (entry: *const DirectoryEntry) bool,
    idx: usize,

    pub fn next(self: *DirIterator) ?*DirectoryEntry {
        while (self.idx < self.collection.len) : (self.idx += 1) {
            const value = &self.collection[self.idx];
            if (self.selector(value)) {
                self.idx += 1;
                return value;
            }
        }
        return null;
    }

    /// Count number of items that match filter.
    /// Note: O(n), walks the entire collection.
    pub fn count(self: *DirIterator) usize {
        const orig_idx = self.idx;
        self.idx = 0;
        var total: usize = 0;
        while (self.next()) |_| {
            total += 1;
        }
        self.idx = orig_idx;
        return total;
    }
};

pub fn detectImageType(_: *DiskInterface, io: std.Io, filename: []const u8) !?DiskImageTypes {
    var image_file = try std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only });
    defer image_file.close(io);
    var is_unique = true;
    if (DiskImage.detectImageType(io, image_file, &is_unique)) |image_type| {
        return image_type.type_id;
    } else {
        return null;
    }
}

pub fn openExistingImage(self: *DiskInterface, io: std.Io, filename: []const u8, img_type: DiskImageTypes) !void {
    var cwd = std.Io.Dir.cwd();

    self.closeImage(io);
    self.image_file = try cwd.openFile(io, filename, .{ .mode = .read_write });
    errdefer self.closeImage(io);
    const image_type = ad.all_disk_types.getPtrConst(img_type);
    self.reader = self.image_file.?.reader(io, &.{});
    self.writer = self.image_file.?.writer(io, &.{});
    self.disk_image = try DiskImage.init(allocator, .{ .on_disk = &self.reader.? }, .{ .on_disk = &self.writer.? }, image_type);
    try self.loadImageDirectory();
}

pub fn openTestImage(self: *DiskInterface, io: std.Io) !void {
    self.closeImage(io);
    errdefer self.closeImage(io);
    const static = struct {
        var test_file = @embedFile("test_images/8in_dirs.dsk").*;
        var reader: std.Io.Reader = undefined;
        var writer: std.Io.Writer = undefined;
    };
    static.reader = .fixed(&static.test_file);
    static.writer = .fixed(&static.test_file);
    self.disk_image = try .init(allocator, .{ .in_memory = &static.reader }, .{ .in_memory = &static.writer }, ad.all_disk_types.getPtrConst(.FDD_8IN));
    try self.loadImageDirectory();
}

pub fn closeImage(self: *DiskInterface, io: std.Io) void {
    self.image_directory_list = .empty;
    _ = self.image_arena.reset(.free_all);
    if (self.disk_image) |*existing| {
        existing.deinit();
        self.disk_image = null;
    }
    if (self.image_file) |image_file| {
        image_file.close(io);
        self.image_file = null;
    }

    self.reader = null;
    self.writer = null;
}

pub fn createNewImage(self: *DiskInterface, io: std.Io, filename: []const u8, image_type: *const ad.DiskImageType, label: ?ad.DiskLabel) !void {
    var cwd = std.Io.Dir.cwd();

    self.closeImage(io);
    self.image_file = try cwd.createFile(io, filename, .{ .read = true });
    errdefer self.closeImage(io);

    self.reader = self.image_file.?.reader(io, &.{});
    self.writer = self.image_file.?.writer(io, &.{});
    self.disk_image = try .init(allocator, .{ .on_disk = &self.reader.? }, .{ .on_disk = &self.writer.? }, image_type);

    try self.disk_image.?.formatImage();
    try self.loadImageDirectory();
    if (label) |lbl| {
        try self.disk_image.?.labelDisk(lbl);
    }
}

pub fn labelGet(self: *DiskInterface, label: *ad.DiskLabel) !void {
    try self.disk_image.?.labelGet(label);
}

// TODO: This should just be cached right? And then freed when the image is closed?
pub fn loadImageDirectory(self: *DiskInterface) !void {
    try self.disk_image.?.loadDirectories(.full);
    if (self.disk_image) |image| {
        for (image.directory.cooked_directories.items) |dir| {
            // TODO: The < 15 user check was here.
            try self.image_directory_list.append(self.local_arena.allocator(), DirectoryEntry.init(.{ .image = dir }));
        }
        self.image_directory_changed = true;
        return;
    }
    return error.ImageNotOpen;
}

pub fn dump(self: *DiskInterface) void {
    std.debug.print("DUMPING\n", .{});
    for (self.image_directory_list.items) |dir| {
        std.debug.print("dump = {s}.{s}\n", .{ dir.filename(), dir.extensio() });
    }
}

pub fn openLocalDirectory(self: *DiskInterface, io: std.Io, dir_path: []const u8) !void {
    if (self.current_dir) |*current_dir| {
        current_dir.close(io);
        self.current_dir = null;
    }
    self.current_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
}

fn loadLocalDirectory(self: *DiskInterface, io: std.Io) void {
    self.local_directory_list = .empty;
    _ = self.local_arena.reset(.free_all);
    if (self.current_dir) |dir| {
        var itr = dir.iterate();
        while (try itr.next(io)) |entry| {
            if (entry.kind == .file) {
                const size = size: {
                    const stat = dir.statFile(io, entry.name, .{}) catch {
                        break :size 0;
                    };
                    break :size stat.size;
                };
                try self.local_directory_list.append(
                    self.local_arena.allocator(),
                    DirectoryEntry.init(.{ .local = try LocalDirEntry.init(
                        self.local_arena.allocator(),
                        if (self.disk_image) |disk_image| disk_image.image_type.OS else .cpm,
                        entry.name,
                        @truncate(size),
                    ) }),
                );
            }
        }
    }
    self.local_directory_changed = true;
}

pub fn xlateFromCopyMode(mode: CopyMode) ad.DiskImage.TextMode {
    return switch (mode) {
        .AUTO => .Auto,
        .ASCII => .Text,
        .BINARY => .Binary,
        .RANDOM => .Rand,
        .BASIC => .BASIC,
    };
}

pub fn xlateToCopyMode2(mode: ad.DiskImage.TextMode) CopyMode {
    return switch (mode) {
        .Auto => .AUTO,
        .Text => .ASCII,
        .Binary => .BINARY,
        .Rand => .RANDOM,
        .BASIC => .BASIC,
    };
}

pub const GetFileError = (std.Io.Dir.OpenError || std.Io.File.OpenError || std.Io.File.Writer.Error || DiskImage.CopyFromImageError);
pub fn getFile(self: *DiskInterface, io: std.Io, src: *const DirectoryEntry, dest_dir: []const u8, copy_mode: CopyMode, force: bool) GetFileError!void {
    if (self.disk_image) |*image| {
        var dir = try std.Io.Dir.cwd().openDir(io, dest_dir, .{});
        defer dir.close(io);
        switch (src.entry) {
            .image => |cooked_entry| {
                var conv_buffer: [std.fs.max_name_bytes]u8 = undefined;
                const out_filename = host_os.toSafeHostFilename(cooked_entry.filenameAndExtension(), &conv_buffer) catch unreachable;
                var out_file = try dir.createFile(io, out_filename, .{ .exclusive = if (force) false else true });
                defer out_file.close(io);
                var write_buffer: [4096]u8 = undefined;
                var writer = out_file.writer(io, &write_buffer);
                image.copyFromImage(&cooked_entry, &writer.interface, xlateFromCopyMode(copy_mode)) catch |err| {
                    try writer.flush();
                    return err;
                };
                try writer.flush();
            },
            else => {
                std.debug.panic("{s} needs a {s}", .{ @src().fn_name, @typeName(@TypeOf(.image)) });
            },
        }
    }
}

pub fn putFile(self: *DiskInterface, io: std.Io, filename: []const u8, dirname: []const u8, user: usize, copy_mode: CopyMode, force: bool) !void {
    const cpm_user = if (user < 16) @as(u8, @intCast(user)) else null;
    if (self.disk_image) |*image| {
        var cwd = try std.Io.Dir.cwd().openDir(io, dirname, .{});
        defer cwd.close(io);
        var in_file = try cwd.openFile(io, filename, .{ .mode = .read_only });
        defer in_file.close(io);

        var buf: [4096]u8 = undefined;
        var reader = in_file.reader(io, &buf);
        var conv_buf: [std.fs.max_name_bytes]u8 = undefined;
        const basename = host_os.fromSafeHostFilename(std.fs.path.basename(filename), &conv_buf) catch unreachable;
        try image.copyToImage(&reader.interface, basename, cpm_user, force, xlateFromCopyMode(copy_mode));
    }
}

// TODO: Check constnesses.
pub fn eraseFile(self: *DiskInterface, to_erase: *DirectoryEntry) !void {
    if (self.disk_image) |*image| {
        switch (to_erase.entry) {
            .image => |*cooked_entry| {
                try image.erase(cooked_entry);
            },
            .local => return error.NotSupported,
        }
    }
}

pub fn getSystem(self: *DiskInterface, io: std.Io, out_filename: []const u8) !void {
    if (self.disk_image) |*image| {
        var out_file = try std.Io.Dir.cwd().createFile(io, out_filename, .{});
        defer out_file.close(io);
        try image.extractOperatingSystem(io, out_file);
    }
}

pub fn putSystem(self: *DiskInterface, io: std.Io, in_filename: []const u8) !void {
    if (self.disk_image) |*image| {
        var in_file = try std.Io.Dir.cwd().openFile(io, in_filename, .{ .mode = .read_only });
        defer in_file.close(io);
        try image.installOperatingSystem(io, in_file);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
