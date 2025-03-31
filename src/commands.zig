//! Implements the user interface between the command line and the user output.
//! Dispatches command line options to the appropriate command and prints the results
//! Any errors are reported back via the error context.

const all_disk_types = @import("disk_types.zig").all_disk_types;
const CookedDirEntry = @import("directory_table.zig").CookedDirEntry;

const global_allocator = @import("main.zig").global_allocator;
const log = std.log.scoped(.altair_disk);
const Commands = @This();

pub const Command = struct {
    option: []const u8,
    name: []const u8,
    write: bool,
    action: fn (disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) anyerror!void,
};

const command_list = [_]Command{
    .{ .option = "do_directory", .name = "directory listing", .write = false, .action = directoryList },
    .{ .option = "do_raw_dir", .name = "raw directory listing", .write = false, .action = directoryListRaw },
    .{ .option = "do_get", .name = "get file", .write = false, .action = getFile },
    .{ .option = "do_get_multi", .name = "get multiple files", .write = false, .action = getFileMultiple },
    .{ .option = "do_put", .name = "put file", .write = true, .action = putFile },
    .{ .option = "do_put_multi", .name = "put multiple files", .write = true, .action = putFileMultiple },
    .{ .option = "do_erase", .name = "erase file", .write = true, .action = eraseFile },
    .{ .option = "do_erase_multi", .name = "erase multiple files", .write = true, .action = eraseFileMultiple },
    .{ .option = "do_cpm_get", .name = "extract cpm", .write = false, .action = extractCPM },
    .{ .option = "do_cpm_put", .name = "install cpm", .write = true, .action = installCPM },
    .{ .option = "do_format", .name = "format", .write = true, .action = formatImage },
    .{ .option = "do_recover", .name = "recover", .write = false, .action = recoverImage },
};

/// Used to report errors back to the caller.
/// keeps the current command and operation and a filename stack.
pub const CommandErrorContext = struct {
    command: []const u8,
    operation: []const u8,
    _filenames: std.ArrayListUnmanaged([]const u8),

    pub fn init() CommandErrorContext {
        return .{
            .command = "",
            .operation = "",
            ._filenames = .empty,
        };
    }

    pub fn deinit(self: *CommandErrorContext) void {
        self._filenames.deinit(global_allocator);
    }

    pub fn pushFilename(self: *CommandErrorContext, filename: []const u8) !void {
        try self._filenames.append(global_allocator, filename);
    }

    pub fn popFilename(self: *CommandErrorContext) []const u8 {
        return self._filenames.pop() orelse unreachable;
    }
};

/// Dispatch the correct command based on the supplied command line options.
pub fn dispatch(options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    var write_access: bool = undefined;

    // Create a table that sets write_access and last_command_description
    // based on which do_xxxx flag is true in the options struct
    inline for (command_list) |command| {
        // If there is a field in options with the same name as command.option
        if (@field(options, command.option)) {
            write_access = command.write;
            err_ctx.command = command.name;
        }
    }

    err_ctx.operation = "open disk image";
    try err_ctx.pushFilename(options.image_file);
    var file = try openDiskImage(options.image_file, write_access, options.do_format);

    // Get or detect this image type.
    const image_type: *const DiskImageType = image_type: {
        errdefer file.close();
        var trial_image_type: *const DiskImageType = undefined;
        var requested_disk_image_type = options.disk_image_type;
        if (options.do_format and options.disk_image_type == null) {
            requested_disk_image_type = .FDD_8IN;
        }

        err_ctx.operation = "detect image type";
        if (requested_disk_image_type) |requested_type| {
            trial_image_type = all_disk_types.getPtrConst(requested_type);
        } else {
            trial_image_type = DiskImage.detectImageType(file) orelse
                return error.CantDetectImage;
        }

        if (!options.do_format and !trial_image_type.isCorrectFormat(file)) {
            err_ctx.operation = "Image type is not set correctly. Aborting";
            return error.InvalidImageType;
        }
        break :image_type trial_image_type;
    };
    log.info("Image type set to or detected as: {s}", .{image_type.type_name});

    err_ctx.operation = "load disk image";
    var disk_image = disk_image: {
        errdefer file.close();
        break :disk_image try DiskImage.init(global_allocator, file, image_type);
    };
    // Once the file is given to disk_image, it will look after closing the file in deinit()
    defer disk_image.deinit();

    err_ctx.operation = "load directory entries";
    if (!options.do_format and !options.do_recover)
        try disk_image.loadDirectories(options.do_raw_dir);

    // Create a dispatch that calls the correct command based on
    // which do_xxx options is true in the options struct.
    inline for (command_list) |command| {
        // If there is a field in options with the same name as command.option
        if (@field(options, command.option)) {
            defer Console.flushOut() catch {};
            return command.action(&disk_image, options, err_ctx);
        }
    }
}

/// Do a standard directory listing.
pub fn directoryList(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    err_ctx.operation = "directory";
    var file_count: u32 = 0;
    var kb_used: u32 = 0;

    try Console.stdout.print("Name     Ext   Length Used U At\n", .{});

    for (disk_image.directory.cooked_directories.items) |entry| {
        if (options.cpm_user) |user| {
            if (user != entry.user) continue;
        }
        const this_kb = entry.allocsUsedInKB();
        kb_used += this_kb;
        try Console.stdout.print("{s:<8} {s:<3} {:>7}B {:>3}K {} {s}\n", .{
            entry.filenameOnly(),
            entry.extension(),
            entry.recordsUsedInB(),
            this_kb,
            entry.user,
            entry.attribs,
        });
        file_count += 1;
    }
    const kb_free = disk_image.capacityFreeInKB();
    const kb_total = disk_image.capacityTotalInKB();

    try Console.stdout.print(
        "{} file(s), occupying {}K of {}K total capacity\n",
        .{ file_count, kb_used, kb_total },
    );
    try Console.stdout.print(
        "{} directory entries and {}K bytes remain\n",
        .{ disk_image.directoryFreeCount(), kb_free },
    );

    return;
}

/// Show the raw CPM directory entries
pub fn directoryListRaw(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    _ = options;
    err_ctx.operation = "directory";
    try Console.stdout.print("IDX:U:FILENAME:TYP:AT:EXT:REC:[ALLOCATIONS]\n", .{});

    for (disk_image.directory.raw_directories.items, 0..) |entry, extent_nr| {
        if (!entry.isDeleted()) {
            const attribs = [2]u8{
                if (entry.attribReadOnly()) 'R' else 'W',
                if (entry.attribSystem()) 'S' else ' ',
            };

            try Console.stdout.print("{:0>3}:{}:{s:<8}:{s:<3}:{s}:{:0>3}:{:0>3}", .{
                extent_nr,         entry.user, entry.filename,
                entry.filetype,    attribs,    entry.extentGet(),
                entry.num_records,
            });

            // The allocations are really little endian u16's
            try Console.stdout.print("[", .{});
            for (0..entry.allocationsCount() - 1) |i| {
                const value = try entry.allocationGet(i, disk_image.image_type);
                try Console.stdout.print("{},", .{value});
            }
            const value = try entry.allocationGet(entry.allocationsCount() - 1, disk_image.image_type);
            try Console.stdout.print("{}]\n", .{value});
        }
    }
    const free_allocations = disk_image.directory.free_allocations;
    try Console.stdout.print("FREE ALLOCATIONS: ({})\n", .{free_allocations.count()});
    var nr_output: usize = 0;
    for (0..disk_image.directory.free_allocations.capacity()) |alloc_nr| {
        if (disk_image.directory.free_allocations.isSet(alloc_nr)) {
            try Console.stdout.print("{:0>3} ", .{alloc_nr});
            nr_output += 1;
            if (nr_output % 16 == 0) {
                try Console.stdout.print("\n", .{});
            }
        }
    }
    try Console.stdout.print("\n", .{});
}

/// Get a file from the image.
pub fn getFile(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    try _getFile(disk_image, .{ .filename = options.multiple_files[0] }, options, err_ctx);
}

/// Get multiple files from the image.
pub fn getFileMultiple(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    for (options.multiple_files) |file_pattern| {
        var found_file: bool = false;
        var itr = disk_image.directory.findByFileNameWildcards(file_pattern, options.cpm_user);

        while (itr.next()) |entry| {
            found_file = true;
            log.info("Processing file: {s}", .{entry.filenameAndExtension()});
            try _getFile(disk_image, .{ .dir_entry = entry }, options, err_ctx);
        } else {
            if (!found_file) {
                err_ctx.operation = "find file";
                try err_ctx.pushFilename(file_pattern);
                return error.FileNotFound;
            }
        }
    }
}

pub const FileNameOrCookedDir = union(enum) {
    filename: []const u8,
    dir_entry: *const CookedDirEntry,
};
pub fn _getFile(disk_image: *DiskImage, lookup: FileNameOrCookedDir, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    const directory_table = disk_image.directory;

    err_ctx.operation = "get";
    // If passed in a filename, then look it up. Otherwise use the dir_entry passed in.
    const dir_entry = blk: switch (lookup) {
        .filename => |filename| {
            try err_ctx.pushFilename(filename);
            const result = directory_table.findByFilename(filename, options.cpm_user);
            if (result != null) {
                _ = err_ctx.popFilename();
                break :blk result.?;
            } else {
                return std.fs.File.OpenError.FileNotFound;
            }
        },
        .dir_entry => |entry| entry,
    };

    err_ctx.operation = "create file";
    var cwd = std.fs.cwd();
    var out_file = try cwd.createFile(dir_entry.filenameAndExtension(), .{ .read = false });
    errdefer out_file.close();
    var text_mode: DiskImage.TextMode = .Auto;
    if (options.text_mode) {
        text_mode = .Text;
    } else if (options.bin_mode) {
        text_mode = .Binary;
    }
    err_ctx.operation = "copy file";
    try disk_image.copyFromImage(dir_entry, out_file, text_mode);
}

/// Copy a file to the image
pub fn putFile(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    try _putFile(disk_image, options.multiple_files[0], options.cpm_user, err_ctx);
}

/// Copy multiple files to the image
pub fn putFileMultiple(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    for (options.multiple_files) |filename| {
        try _putFile(disk_image, filename, options.cpm_user, err_ctx);
    }
}

pub fn _putFile(disk_image: *DiskImage, filename: []const u8, user: ?u8, err_ctx: *CommandErrorContext) !void {
    log.info("Putting file {s}", .{filename});

    const cpm_user = user orelse 0;

    var cwd = std.fs.cwd();

    err_ctx.operation = "open file";
    try err_ctx.pushFilename(filename);
    var in_file = try cwd.openFile(filename, .{ .mode = .read_only });
    defer in_file.close();
    _ = err_ctx.popFilename();

    err_ctx.operation = "copy file";
    try err_ctx.pushFilename(filename);
    try disk_image.copyToImage(in_file, filename, cpm_user, false);
    _ = err_ctx.popFilename();
}

/// Remove a file from the image
pub fn eraseFile(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    try err_ctx.pushFilename(options.multiple_files[0]);
    err_ctx.operation = "find file";
    if (disk_image.directory.findByFilename(options.multiple_files[0], options.cpm_user)) |dir_entry| {
        try disk_image.erase(dir_entry);
        err_ctx.operation = "erase";
        _ = err_ctx.popFilename();
    } else {
        return error.FileNotFound; // TODO: Fix error return
    }
}

/// Remove multiple files from the image.
pub fn eraseFileMultiple(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    for (options.multiple_files) |file_pattern| {
        var found_file: bool = false;
        var itr = disk_image.directory.findByFileNameWildcards(file_pattern, options.cpm_user);
        err_ctx.operation = "erase";
        while (itr.next()) |entry| {
            found_file = true;
            log.info("Erasing file {s}", .{entry.filenameAndExtension()});
            try err_ctx.pushFilename(entry.filenameAndExtension());
            try disk_image.erase(entry);
            _ = err_ctx.popFilename();
        } else {
            if (!found_file) {
                try err_ctx.pushFilename(file_pattern);
                return error.FileNotFound;
            }
        }
    }
}

/// Extract system tracks
pub fn extractCPM(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    log.info("Extract CPM to:{s}\n", .{options.system_image_get});
    var cwd = std.fs.cwd();
    err_ctx.operation = "open file";
    try err_ctx.pushFilename((options.system_image_get));
    const out_file = try cwd.createFile(options.system_image_get, .{ .read = false });
    defer out_file.close();
    err_ctx.operation = "extract";
    try disk_image.extractCPM(out_file);
    _ = err_ctx.popFilename();
}

/// Write to system tracks
pub fn installCPM(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    log.info("Install CPM from:{s}\n", .{options.system_image_put});
    var cwd = std.fs.cwd();
    err_ctx.operation = "open file";
    try err_ctx.pushFilename(options.system_image_put);
    const in_file = try cwd.openFile(options.system_image_put, .{ .mode = .read_only });
    defer in_file.close();
    err_ctx.operation = "install";
    try disk_image.installCPM(in_file);
    _ = err_ctx.popFilename();
}

// TODO: Detect if target image exists and if so format it to the type of the exiting image.
pub fn formatImage(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    _ = options;
    err_ctx.operation = "format";
    try disk_image.formatImage();
}

/// Try and recover an image with corrupted directory entries.
pub fn recoverImage(disk_image: *DiskImage, options: CommandLineOptions, err_ctx: *CommandErrorContext) !void {
    var cwd = std.fs.cwd();
    // Copy the image to the new file first
    err_ctx.operation = "open file";
    try err_ctx.pushFilename(options.recovery_image_file); // No need to pop as this will become the image filename.
    const out_image = try cwd.createFile(options.recovery_image_file, .{ .read = true });
    {
        // recoverImage owns the file until disk_image.reinit(), so close it on error.
        errdefer out_image.close();
        var read_buf: [4096]u8 = undefined;
        var eof = false;
        err_ctx.operation = "recover";
        // Copy the corrupt image to a new file.
        while (!eof) {
            const nbytes = try disk_image.image_file.reader().readAll(&read_buf);
            try out_image.writeAll(read_buf[0..nbytes]);
            eof = nbytes != read_buf.len;
        }
        try out_image.seekTo(0);
    }
    // reinit() will close underlying file even on error.
    try disk_image.reinit(global_allocator, out_image);
    // the file out_image now belongs to disk_image;
    try disk_image.tryRecovery();
}

fn openDiskImage(filename: []const u8, writeable: bool, create_file: bool) !std.fs.File {
    const cwd = std.fs.cwd();
    if (create_file) {
        return cwd.createFile(filename, .{ .read = false });
    } else if (writeable) {
        return cwd.openFile(filename, .{ .mode = .read_write });
    } else {
        return cwd.openFile(filename, .{ .mode = .read_only });
    }
}

const std = @import("std");
const DI = @import("disk_image.zig");
const DiskImage = DI.DiskImage;
const DirectoryTable = DI.DirectoryTable;
const DiskImageType = @import("disk_types.zig").DiskImageType;
const RawDirectoryEntry = @import("disk_image.zig").RawDirEntry;
const CommandLineOptions = @import("main.zig").CommandLineOptions;
const Console = @import("console.zig");
