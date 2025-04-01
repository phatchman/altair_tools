//! Implements the user interface between the command line and the user output.
//! Dispatches command line options to the appropriate command and prints the results
//! Any errors are reported back via the error context.
//
const all_disk_types = @import("disk_types.zig").all_disk_types;
const all_disk_type_names = @import("disk_types.zig").all_disk_type_names;
const CookedDirEntry = @import("directory_table.zig").CookedDirEntry;

const global_allocator = @import("main.zig").global_allocator;

const log = std.log.scoped(.altair_disk);
const Commands = @This();

pub const Command = struct {
    option: []const u8,
    name: []const u8,
    write: bool,
    action: fn (disk_image: *DiskImage, options: CommandLineOptions) anyerror!void,
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
    .{ .option = "do_information", .name = "image information", .write = false, .action = printImageInfo },
};

var current_command: []const u8 = undefined;

/// Dispatch the correct command based on the supplied command line options.
pub fn dispatch(options: CommandLineOptions) !void {
    var write_access: bool = undefined;

    // Create a table that sets write_access and last_command_description
    // based on which do_xxxx flag is true in the options struct
    inline for (command_list) |command| {
        // If there is a field in options with the same name as command.option
        if (@field(options, command.option)) {
            write_access = command.write;
            current_command = command.name;
        }
    }

    var file = openDiskImage(options.image_file, write_access, options.do_format) catch |err| {
        printErrorMessage(current_command, .open_image, .{options.image_file}, err);
        return error.CommandFailed;
    };
    const existing_file = (file.getEndPos() catch 0) != 0;

    // Get or detect this image type.
    const image_type: *const DiskImageType = image_type: {
        errdefer file.close();
        var trial_image_type: *const DiskImageType = undefined;
        var requested_disk_image_type = options.disk_image_type;
        // Default format to FDD_8IN unless it's an existing image file.
        if (!existing_file and options.do_format and options.disk_image_type == null) {
            requested_disk_image_type = .FDD_8IN;
        }

        if (requested_disk_image_type) |requested_type| {
            trial_image_type = all_disk_types.getPtrConst(requested_type);
        } else {
            var unique = false;
            trial_image_type = DiskImage.detectImageType(file, &unique) orelse {
                printErrorMessage(current_command, .image_type_detect, .{}, error.CantDetectImage);
                return error.CommandFailed;
            };
            if (!unique) {
                try Console.stderr.print(
                    "WARNING: {s} and {s} formats cannot be distinuished with autodection. Assuming {s}. Use -T to set correct image type.\n",
                    .{
                        all_disk_type_names[@intFromEnum(DiskImageTypes.HDD_5MB)],
                        all_disk_type_names[@intFromEnum(DiskImageTypes.HDD_5MB_1024)],
                        trial_image_type.type_name,
                    },
                );
            }
        }

        if (!options.do_format and !trial_image_type.isCorrectFormat(file)) {
            printErrorMessage(current_command, .image_type_set, .{}, error.None);
            return error.CommandFailed;
        }
        break :image_type trial_image_type;
    };
    log.info("Image type set to or detected as: {s}", .{image_type.type_name});

    var disk_image = disk_image: {
        errdefer file.close();
        break :disk_image DiskImage.init(global_allocator, file, image_type) catch |err| {
            printErrorMessage(current_command, .image_init, .{options.image_file}, err);
            return error.CommandFailed;
        };
    };
    // Once the file is given to disk_image, it will look after closing the file in deinit()
    defer disk_image.deinit();

    if (!options.do_format and !options.do_recover) {
        disk_image.loadDirectories(options.do_raw_dir) catch |err| {
            printErrorMessage(current_command, .image_load, .{}, err);
            return error.CommandFailed;
        };
    }

    // Create a dispatch that calls the correct command based on
    // which do_xxx options is true in the options struct.
    inline for (command_list) |command| {
        // If there is a field in options with the same name as command.option
        if (@field(options, command.option)) {
            defer Console.flushOut() catch {};
            try command.action(&disk_image, options);
            return;
        }
    }
}

/// Do a standard directory listing.
pub fn directoryList(disk_image: *DiskImage, options: CommandLineOptions) !void {
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
pub fn directoryListRaw(disk_image: *DiskImage, options: CommandLineOptions) !void {
    _ = options;
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
pub fn getFile(disk_image: *DiskImage, options: CommandLineOptions) !void {
    try _getFile(disk_image, .{ .filename = options.multiple_files[0] }, options);
}

/// Get multiple files from the image.
pub fn getFileMultiple(disk_image: *DiskImage, options: CommandLineOptions) !void {
    var had_error = false;
    for (options.multiple_files) |file_pattern| {
        var found_file: bool = false;
        var itr = disk_image.directory.findByFileNameWildcards(file_pattern, options.cpm_user);

        while (itr.next()) |entry| {
            found_file = true;
            _getFile(disk_image, .{ .dir_entry = entry }, options) catch |err| {
                if (err == error.CommandFailCanContinue) {
                    continue;
                } else {
                    return error.CommandFail;
                }
            };
        } else {
            if (!found_file) {
                had_error = true;
                printErrorMessage(current_command, .no_matching_files, .{file_pattern}, error.None);
            }
        }
    }
    if (had_error) {
        return error.CommandFailed;
    }
}

pub const FileNameOrCookedDir = union(enum) {
    filename: []const u8,
    dir_entry: *const CookedDirEntry,
};
pub fn _getFile(disk_image: *DiskImage, lookup: FileNameOrCookedDir, options: CommandLineOptions) !void {
    const directory_table = disk_image.directory;

    // If passed in a filename, then look it up. Otherwise use the dir_entry passed in.
    const dir_entry = blk: switch (lookup) {
        .filename => |filename| {
            const result = directory_table.findByFilename(filename, options.cpm_user);
            if (result != null) {
                break :blk result.?;
            } else {
                if (options.cpm_user) |user| {
                    printErrorMessage(current_command, .file_not_found_user, .{ filename, user }, error.None);
                } else {
                    printErrorMessage(current_command, .file_not_found, .{filename}, error.None);
                }
                return error.CommandFailedCanContinue;
            }
        },
        .dir_entry => |entry| entry,
    };

    // If this file exists for multiple users, add the _user to the filename.
    const add_user_extension = extension: {
        if (options.cpm_user == null) {
            const result = directory_table.findByFilename(dir_entry.filenameAndExtension(), null);
            if (result.?.user != dir_entry.user) {
                break :extension true;
            }
        }
        break :extension false;
    };

    var cwd = std.fs.cwd();
    var filename_buf: [dir_entry._filename.len + 3]u8 = undefined; // Underlying filename + _nn for the user.
    const out_filename = try if (add_user_extension)
        std.fmt.bufPrint(&filename_buf, "{s}_{d}", .{ dir_entry.filenameAndExtension(), dir_entry.user })
    else
        std.fmt.bufPrint(&filename_buf, "{s}", .{dir_entry.filenameAndExtension()});

    var out_file = cwd.createFile(out_filename, .{ .read = false }) catch |err| {
        printErrorMessage(current_command, .file_create, .{out_filename}, err);
        return error.CommandFailedCanContinue;
    };
    defer out_file.close();

    var text_mode: DiskImage.TextMode = .Auto;
    if (options.text_mode) {
        text_mode = .Text;
    } else if (options.bin_mode) {
        text_mode = .Binary;
    }

    disk_image.copyFromImage(dir_entry, out_file, text_mode) catch |err| {
        printErrorMessage(current_command, .file_copy, .{out_filename}, err);
        return error.CommandFailed;
    };
    log.info("Copied file {s} to {s}", .{ dir_entry.filenameAndExtension(), out_filename });
}

/// Copy a file to the image
pub fn putFile(disk_image: *DiskImage, options: CommandLineOptions) !void {
    try _putFile(disk_image, options.multiple_files[0], options.cpm_user);
}

/// Copy multiple files to the image
pub fn putFileMultiple(disk_image: *DiskImage, options: CommandLineOptions) !void {
    var had_error = false;
    for (options.multiple_files) |filename| {
        _putFile(disk_image, filename, options.cpm_user) catch |err| {
            if (err == error.CommandFailedCanContinue) {
                had_error = true;
                continue;
            } else {
                return err;
            }
        };
    }
    if (had_error) {
        return error.CommandFailed;
    }
}

pub fn _putFile(disk_image: *DiskImage, filename: []const u8, user: ?u8) !void {
    const cpm_user = user orelse 0;

    var cwd = std.fs.cwd();

    var in_file = cwd.openFile(filename, .{ .mode = .read_only }) catch |err| {
        printErrorMessage(current_command, .file_open, .{filename}, err);
        return error.CommandFailedCanContinue;
    };
    defer in_file.close();

    disk_image.copyToImage(in_file, filename, cpm_user, false) catch |err| {
        printErrorMessage(current_command, .file_copy, .{filename}, err);
        switch (err) {
            error.PathAlreadyExists, error.CookedDirEntryNotFound => return error.CommandFailedCanContinue,
            else => return error.CommandFailed,
        }
    };
    log.info("Copied file {s}", .{filename});
}

/// Remove a file from the image
pub fn eraseFile(disk_image: *DiskImage, options: CommandLineOptions) !void {
    const filename = options.multiple_files[0];
    if (disk_image.directory.findByFilename(filename, options.cpm_user)) |dir_entry| {
        disk_image.erase(dir_entry) catch |err| {
            printErrorMessage(current_command, .file_erase, .{filename}, err);
            return error.CommandFailed;
        };
    } else {
        printErrorMessage(current_command, .file_not_found, .{filename}, error.None);
        return error.CommandFailed;
    }
}

/// Remove multiple files from the image.
pub fn eraseFileMultiple(disk_image: *DiskImage, options: CommandLineOptions) !void {
    var had_error = false;
    var to_erase: std.ArrayListUnmanaged(CookedDirEntry) = .empty;
    defer to_erase.deinit(global_allocator);

    for (options.multiple_files) |file_pattern| {
        var found_file: bool = false;
        var itr = disk_image.directory.findByFileNameWildcards(file_pattern, options.cpm_user);

        while (itr.next()) |entry| {
            found_file = true;
            try to_erase.append(global_allocator, entry.*);
        } else {
            if (!found_file) {
                printErrorMessage(current_command, .no_matching_files, .{file_pattern}, error.None);
                had_error = true;
            }
        }
    }
    for (to_erase.items) |*entry| {
        blk: {
            disk_image.erase(entry) catch |err| {
                printErrorMessage(current_command, .file_erase, .{entry.filenameAndExtension()}, err);
                had_error = true;
                break :blk;
            };
            log.info("Erased file {s}", .{entry.filenameAndExtension()});
        }
    }
    if (had_error) {
        return error.CommandFailed;
    }
}

/// Extract system tracks
pub fn extractCPM(disk_image: *DiskImage, options: CommandLineOptions) !void {
    log.info("Extract CPM to {s}", .{options.system_image_get});
    var cwd = std.fs.cwd();
    const out_file = cwd.createFile(options.system_image_get, .{ .read = false }) catch |err| {
        printErrorMessage(current_command, .file_create, .{options.system_image_get}, err);
        return error.CommandFailed;
    };
    defer out_file.close();
    disk_image.extractCPM(out_file) catch |err| {
        printErrorMessage(current_command, .extract_cpm, .{options.system_image_get}, err);
        return error.CommandFailed;
    };
}

/// Write to system tracks
pub fn installCPM(disk_image: *DiskImage, options: CommandLineOptions) !void {
    log.info("Install CPM from {s}", .{options.system_image_put});
    var cwd = std.fs.cwd();
    const in_file = cwd.openFile(options.system_image_put, .{ .mode = .read_only }) catch |err| {
        printErrorMessage(current_command, .file_open, .{options.system_image_put}, err);
        return error.CommandFailed;
    };
    defer in_file.close();
    disk_image.installCPM(in_file) catch |err| {
        printErrorMessage(current_command, .install_cpm, .{options.system_image_put}, err);
        return error.CommandFailed;
    };
}

pub fn formatImage(disk_image: *DiskImage, options: CommandLineOptions) !void {
    log.info("Formatting {s} ....", .{options.image_file});
    disk_image.formatImage() catch |err| {
        printErrorMessage(current_command, .format, .{options.image_file}, err);
        return error.CommandFailed;
    };
    log.info("Format complete", .{});
}

/// Try and recover an image with corrupted directory entries.
pub fn recoverImage(disk_image: *DiskImage, options: CommandLineOptions) !void {
    log.info("Recovering {s} to {s}", .{ options.image_file, options.recovery_image_file });

    var cwd = std.fs.cwd();
    // Copy the image to the new file first
    const out_image = cwd.createFile(options.recovery_image_file, .{ .read = true }) catch |err| {
        printErrorMessage(current_command, .recover, .{options.recovery_image_file}, err);
        return error.CommandFailed;
    };
    {
        // recoverImage owns the file until disk_image.reinit(), so close it on error.
        errdefer out_image.close();
        var read_buf: [4096]u8 = undefined;
        var eof = false;
        // Copy the corrupt image to a new file.
        while (!eof) {
            const nbytes = try disk_image.image_file.reader().readAll(&read_buf);
            out_image.writeAll(read_buf[0..nbytes]) catch |err| {
                printErrorMessage(current_command, .file_write, .{options.recovery_image_file}, err);
                return error.CommandFailed;
            };
            eof = nbytes != read_buf.len;
        }
        out_image.seekTo(0) catch |err| {
            printErrorMessage(current_command, .file_seek, .{options.recovery_image_file}, err);
            return error.CommandFailed;
        };
    }
    // reinit() will close underlying file even on error.
    disk_image.reinit(global_allocator, out_image) catch |err| {
        printErrorMessage(current_command, .image_init, .{options.recovery_image_file}, err);
        return error.CommandFailed;
    };
    // the file out_image now belongs to disk_image;
    disk_image.tryRecovery() catch |err| {
        printErrorMessage(current_command, .recover, .{options.image_file}, err);
        return error.CommandFailed;
    };
}

/// Print image parameters
pub fn printImageInfo(disk_image: *DiskImage, options: CommandLineOptions) !void {
    _ = options;
    disk_image.image_type.dump();
}

fn openDiskImage(filename: []const u8, writeable: bool, create_file: bool) !std.fs.File {
    const cwd = std.fs.cwd();
    if (create_file) {
        return cwd.createFile(filename, .{ .read = false, .truncate = false });
    } else if (writeable) {
        return cwd.openFile(filename, .{ .mode = .read_write });
    } else {
        return cwd.openFile(filename, .{ .mode = .read_only });
    }
}

fn printErrorMessage(command: []const u8, comptime message: ErrorMessage, args: anytype, err: anyerror) void {
    Console.stderr.print("Error performing {s}: ", .{command}) catch {};
    Console.stderr.print(error_messages.get(message), args) catch {};

    switch (err) {
        error.None => {
            Console.stderr.writeAll("\n") catch {};
        },
        error.CantDetectImage => {
            Console.stderr.print(": Not a valid Altair disk image.\n", .{}) catch {};
        },
        RawDirError.InvalidAllocation,
        RawDirError.InvalidEntryNumber,
        RawDirError.InvalidExtent,
        RawDirError.InvalidRecordNumber,
        RawDirError.InvalidUser,
        => {
            Console.stderr.print(
                ": The directory entries in this image are invalid. Error = {s}.\n",
                .{@errorName(err)},
            ) catch {};
        },
        DirectoryError.OutOfAllocs,
        => {
            Console.stderr.print(": The disk is full\n", .{}) catch {};
        },
        DirectoryError.OutOfExtents,
        => {
            Console.stderr.print(": No more directory entries available\n", .{}) catch {};
        },
        error.FileNotFound => {
            Console.stderr.print(": File not found\n", .{}) catch {};
        },
        error.AccessDenied => {
            Console.stderr.print(": Access is denied\n", .{}) catch {};
        },
        error.PathAlreadyExists => {
            Console.stderr.print(": File already exists\n", .{}) catch {};
        },
        else => {
            Console.stderr.print(": {s}\n", .{@errorName(err)}) catch {};
        },
    }
}

const ErrorMessage = enum {
    open_image,
    image_type_detect,
    image_type_set,
    image_init,
    image_load,
    no_matching_files,
    file_not_found_user,
    file_not_found,
    file_create,
    file_open,
    file_copy,
    file_erase,
    file_write,
    file_seek,
    extract_cpm,
    install_cpm,
    format,
    recover,
};

const error_messages = std.EnumArray(ErrorMessage, []const u8).init(.{
    .open_image = "Error opening disk image {s}",
    .image_type_detect = "Can't detect image type. Use -h to see supported types and -T to force a type.",
    .image_type_set = "Image type is not set correctly. Use -h to see supported types or -v to see the detected type.",
    .image_init = "Initializing disk image {s}",
    .image_load = "Loading directory table",
    .no_matching_files = "No files found matching {s}",
    .file_not_found_user = "File {s} does not exist for user {d}",
    .file_not_found = "File {s} does not exist",
    .file_create = "Error creating file {s}",
    .file_open = "Error opening file {s}",
    .file_copy = "Error copying file {s}",
    .file_erase = "Error erasing {s}",
    .file_write = "Error writing to {s}",
    .file_seek = "Error seeking {s}",
    .extract_cpm = "Error extracting sytem image to {s}",
    .install_cpm = "Error installing system image from {s}",
    .format = "Error formatting {s}",
    .recover = "Error recovering image {s}",
});

const std = @import("std");
const DI = @import("disk_image.zig");
const DiskImage = DI.DiskImage;
const DirectoryTable = DI.DirectoryTable;
const DiskImageType = @import("disk_types.zig").DiskImageType;
const DiskImageTypes = @import("disk_types.zig").DiskImageTypes;
const RawDirectoryEntry = @import("disk_image.zig").RawDirEntry;
const RawDirError = @import("directory_table.zig").RawDirError;
const DirectoryError = @import("directory_table.zig").DirectoryTable.DirectoryError;
const CommandLineOptions = @import("main.zig").CommandLineOptions;
const Console = @import("console.zig");
