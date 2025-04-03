const std = @import("std");
const ad = @import("altair_disk");
const DiskImage = ad.DiskImage;
const allocator = @import("main.zig").gpa;

disk_image: ?ad.DiskImage = null,
current_dir: ?std.fs.Dir = null,
image_directory_list: std.ArrayListUnmanaged(DirectoryEntry) = .empty,
local_directory_list: std.ArrayListUnmanaged(DirectoryEntry) = .empty,

const Self = @This(); // TODO: This should be Commands?
pub const CopyMode = enum { AUTO, ASCII, BINARY };

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    freeDirList(gpa, &self.image_directory_list);
    freeDirList(gpa, &self.local_directory_list);
    if (self.disk_image) |*disk_image| {
        disk_image.deinit();
    }
}

pub const LocalDirEntry = struct {
    filename: []const u8,
    extension: []const u8,
    full_filename: []const u8,
    size: usize,

    pub fn init(gpa: std.mem.Allocator, filename: []const u8, size: usize) !LocalDirEntry {
        var filename_buf: [12]u8 = undefined;
        const xlated_filename = ad.DirectoryTable.translateToCPMFilename(filename, &filename_buf);
        const dotIndex = std.mem.indexOf(u8, xlated_filename, ".") orelse xlated_filename.len;
        const filename_only = xlated_filename[0..dotIndex];
        const extension = if (dotIndex < filename.len - 1) xlated_filename[dotIndex + 1 .. xlated_filename.len] else "";
        return .{
            // TODO: There should be errdefers here? OR some other cleanup mechanism.
            .filename = try gpa.dupe(u8, filename_only),
            .extension = try gpa.dupe(u8, extension),
            .full_filename = try gpa.dupe(u8, filename),
            .size = size,
        };
    }

    pub fn deinit(self: *const LocalDirEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.filename);
        gpa.free(self.extension);
        gpa.free(self.full_filename);
    }
};

pub const DirectoryUnion = union(enum) {
    image: ad.CookedDirEntry,
    local: LocalDirEntry,
};

pub const DirectoryEntry = struct {
    entry: DirectoryUnion,
    checked: bool,
    deleted: bool,

    pub fn init(entry: DirectoryUnion) DirectoryEntry {
        return .{
            .entry = entry,
            .checked = false,
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
            .image => |*dir| dir.extension(),
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
            .image => |*dir| dir.recordsUsedInB(),
            .local => |*dir| dir.size,
        };
    }

    pub fn fileUsedInKB(self: *const DirectoryEntry) usize {
        return switch (self.entry) {
            .image => |*dir| dir.allocsUsedInKB(),
            .local => |*dir| dir.size / 1024,
        };
    }

    pub fn user(self: *const DirectoryEntry) usize {
        return switch (self.entry) {
            .image => |*dir| dir.user,
            .local => 0,
        };
    }

    pub fn deinit(self: *DirectoryEntry, gpa: std.mem.Allocator) void {
        switch (self.entry) {
            .image => {}, // We didn;t init these. don't deinit.
            .local => |*dir| dir.deinit(gpa),
        }
    }

    pub fn isSelected(self: *const DirectoryEntry) bool {
        return self.checked;
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

    pub fn peek(self: *DirIterator) ?*DirectoryEntry {
        if (self.idx == 0 or self.idx > self.collection.len) {
            return null;
        } else {
            return &self.collection[self.idx - 1];
        }
    }
};

pub fn openExistingImage(self: *Self, filename: []const u8) !void {
    var cwd = std.fs.cwd();

    if (self.disk_image) |*existing| {
        existing.deinit();
    }
    const image_file = try cwd.openFile(filename, .{ .mode = .read_write });
    var is_unique = false;
    const image_type = DiskImage.detectImageType(image_file, &is_unique);
    // TODO: Need ot handle the non-unique with a dialog warning or something?

    if (image_type) |valid_type| {
        self.disk_image = DiskImage.init(allocator, image_file, valid_type) catch |err| {
            image_file.close();
            return err;
        };
        try self.disk_image.?.loadDirectories(false);
    } else {
        std.debug.print("Invalid image\n", .{});
    }
}

pub fn closeImage(self: *Self) void {
    if (self.disk_image) |*existing| {
        existing.deinit();
        self.disk_image = null;
    }
}

pub fn createNewImage(self: *Self, filename: []const u8, image_type: *const ad.DiskImageType) !void {
    var cwd = std.fs.cwd();

    self.closeImage();
    const image_file = try cwd.createFile(filename, .{ .read = true });
    self.disk_image = try .init(allocator, image_file, image_type);
    try self.disk_image.?.formatImage();
    try self.disk_image.?.loadDirectories(false);
}

pub fn directoryListing(self: *Self, gpa: std.mem.Allocator) ![]DirectoryEntry {
    freeDirList(gpa, &self.image_directory_list);
    if (self.disk_image) |image| {
        for (image.directory.cooked_directories.items) |dir| {
            if (dir.user <= 15) { // TODO: Should be isDeleted?
                try self.image_directory_list.append(gpa, DirectoryEntry.init(.{ .image = dir }));
            }
        }

        return self.image_directory_list.items;
    }
    return error.ImageNotOpen;
}

pub fn dump(self: *Self) void {
    std.debug.print("DUMPING\n", .{});
    for (self.image_directory_list.items) |dir| {
        std.debug.print("dump = {s}.{s}\n", .{ dir.filename(), dir.extensio() });
    }
}

pub fn openLocalDirectory(self: *Self, dir_path: []const u8) !void {
    if (self.current_dir) |*current_dir| {
        current_dir.close();
    }
    self.current_dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
}

pub fn localDirectoryListing(self: *Self, gpa: std.mem.Allocator) ![]DirectoryEntry {
    freeDirList(gpa, &self.local_directory_list);

    if (self.current_dir) |dir| {
        var itr = dir.iterate();
        while (try itr.next()) |entry| {
            if (entry.kind == .file) {
                const size = size: {
                    const stat = dir.statFile(entry.name) catch {
                        break :size 0;
                    };
                    break :size stat.size;
                };
                try self.local_directory_list.append(
                    gpa,
                    DirectoryEntry.init(.{ .local = try LocalDirEntry.init(
                        gpa,
                        entry.name,
                        size,
                    ) }),
                );
            }
        }
    }
    return self.local_directory_list.items;
}

pub fn getFile(self: *Self, src: *const DirectoryEntry, dest_dir: []const u8, copy_mode: CopyMode, force: bool) !void {
    const Local = struct {
        fn xlateCopyMode(mode: CopyMode) ad.DiskImage.TextMode {
            return switch (mode) {
                .AUTO => .Auto,
                .ASCII => .Text,
                .BINARY => .Binary,
            };
        }
    };

    if (self.disk_image) |*image| {
        std.debug.print("Dest dir = {s}\n,", .{dest_dir});
        var dir = try std.fs.cwd().openDir(dest_dir, .{});
        defer dir.close();
        switch (src.entry) {
            .image => |cooked_entry| {
                var out_file = try dir.createFile(cooked_entry.filenameAndExtension(), .{ .exclusive = if (force) false else true });
                defer out_file.close();
                try image.copyFromImage(&cooked_entry, out_file, Local.xlateCopyMode(copy_mode));
            },
            else => {
                std.debug.panic("{s} needs a {s}", .{ @src().fn_name, @typeName(@TypeOf(.image)) });
            },
        }
    }
}

pub fn putFile(self: *Self, filename: []const u8, dirname: []const u8, user: usize, force: bool) !void {
    const cpm_user = if (user < 16) @as(u8, @intCast(user)) else null;
    if (self.disk_image) |*image| {
        var cwd = try std.fs.cwd().openDir(dirname, .{});
        defer cwd.close();
        var in_file = try cwd.openFile(filename, .{ .mode = .read_only });
        defer in_file.close();

        try image.copyToImage(in_file, filename, cpm_user, force);
    }
}

// TODO: Check constnesses.
pub fn eraseFile(self: *Self, to_erase: *DirectoryEntry, dest_dir: []const u8) !void {
    if (self.disk_image) |*image| {
        switch (to_erase.entry) {
            .image => |*cooked_entry| {
                try image.erase(cooked_entry);
            },
            .local => |local_entry| {
                var dir = try std.fs.cwd().openDir(dest_dir, .{});
                defer dir.close();
                try dir.deleteFile(local_entry.full_filename);
            },
        }
    }
}

pub fn getSystem(self: *Self, out_filename: []const u8) !void {
    if (self.disk_image) |*image| {
        var out_file = try std.fs.cwd().createFile(out_filename, .{});
        defer out_file.close();
        try image.extractCPM(out_file);
    }
}

pub fn putSystem(self: *Self, in_filename: []const u8) !void {
    if (self.disk_image) |*image| {
        var in_file = try std.fs.cwd().openFile(in_filename, .{ .mode = .read_only });
        defer in_file.close();
        try image.installCPM(in_file);
    }
}

fn freeDirList(gpa: std.mem.Allocator, dir_list: *std.ArrayListUnmanaged(DirectoryEntry)) void {
    for (dir_list.items) |*entry| {
        entry.deinit(gpa);
    }
    dir_list.clearAndFree(gpa);
}
