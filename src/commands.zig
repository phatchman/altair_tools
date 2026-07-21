//! Implements the user interface between the command line and the user output.
//! Dispatches command line options to the appropriate command and prints the results
//! Any errors are reported back via the error context.

const all_disk_types = @import("disk_types.zig").all_disk_types;
const all_disk_type_names = @import("disk_types.zig").all_disk_type_names;
const CookedDirEntry = @import("directory_table.zig").CookedDirEntry;

const log = std.log.scoped(.altair_disk);
const Commands = @This();

pub const Command = struct {
    option: []const u8,
    name: []const u8,
    write: bool,
    action: fn (context: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void,
};

// Commands should only return these. Print and log any errors before returning.
// WriteFailed must only be returned for stdout / stderr.
const CommandError = error{ CommandFailed, CommandFailedCanContinue, WriteFailed };

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
    .{ .option = "do_label_set", .name = "set disk label", .write = true, .action = labelSet },
    .{ .option = "do_label_get", .name = "show disk label", .write = false, .action = labelShow },
};

var current_command: []const u8 = undefined;

const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
};

/// Dispatch the correct command based on the supplied command line options.
pub fn dispatch(io: std.Io, gpa: std.mem.Allocator, options: CommandLineOptions) CommandError!void {
    var write_access: bool = undefined;
    // Create a table that sets write_access and last_command_description
    // based on which do_xxxx flag is true in the options struct
    var found_command: bool = false;
    inline for (command_list) |command| {
        // If there is a field in options with the same name as command.option
        if (@field(options, command.option)) {
            write_access = command.write;
            current_command = command.name;
            found_command = true;
        }
    }
    std.debug.assert(found_command);

    var file = openDiskImage(io, options.image_file, write_access, options.do_format) catch |err| {
        printErrorMessage(current_command, .open_image, .{options.image_file}, err);
        return error.CommandFailed;
    };
    const existing_file = (file.length(io) catch 0) != 0;

    // Get or detect this image type.
    const image_type: *const DiskImageType = image_type: {
        errdefer file.close(io);
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
            trial_image_type = DiskImage.detectImageType(io, file, &unique) orelse {
                printErrorMessage(current_command, .image_type_detect, .{}, error.CantDetectImage);
                return error.CommandFailed;
            };
            if (!unique and !options.quiet) {
                try Console.stderr().print(
                    "WARNING: {s} and {s} formats cannot be distinuished with autodection. Assuming {s}. Use -T to set correct image type.\n",
                    .{
                        all_disk_type_names[@intFromEnum(DiskImageTypes.HDD_5MB)],
                        all_disk_type_names[@intFromEnum(DiskImageTypes.HDD_5MB_1024)],
                        trial_image_type.type_name,
                    },
                );
            }
        }

        if (!options.do_format and !trial_image_type.isCorrectFormat(io, file)) {
            printErrorMessage(current_command, .image_type_set, .{}, error.None);
            // For raw dir listings, try anyway.
            if (!options.do_raw_dir) {
                return error.CommandFailed;
            }
        }
        break :image_type trial_image_type;
    };
    log.info("Image type set to or detected as: {s}", .{image_type.type_name});

    // We do out own buffering.
    var image_reader = file.reader(io, &.{});
    var image_writer = file.writer(io, &.{});

    var disk_image = disk_image: {
        errdefer file.close(io);
        break :disk_image DiskImage.init(gpa, .{ .on_disk = &image_reader }, .{ .on_disk = &image_writer }, image_type) catch |err| {
            printErrorMessage(current_command, .image_init, .{options.image_file}, err);
            return error.CommandFailed;
        };
    };
    defer disk_image.deinit();
    defer file.close(io);

    if (!options.do_format and !options.do_recover and !options.do_information) {
        disk_image.loadDirectories(if (options.do_raw_dir) .raw_only else .full) catch |err| {
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
            try command.action(.{ .io = io, .gpa = gpa }, &disk_image, options);
            return;
        }
    }
    // Command was not displatched?
    unreachable;
}

/// Do a standard directory listing.
pub fn directoryList(_: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    var file_count: u32 = 0;
    var kb_used: u32 = 0;

    print_label: {
        var label: DiskLabel = undefined;
        disk_image.labelGet(&label) catch {
            break :print_label;
        };
        try Console.stdout().print("{f}\n", .{label});
    }

    switch (disk_image.image_type.OS) {
        inline else => |_, tag| {
            const padding: [CookedDirEntry.filenameOnlyMaxLen(tag) -| 4]u8 = @splat(' ');
            try Console.stdout().print("Name{s}{s}   Length  Used U At", .{ padding, switch (tag) {
                .cpm, .cdos => " Ext",
                .hd_basic, .ados => "",
            } });
        },
    }
    if (disk_image.image_type.OS == .hd_basic) {
        try Console.stdout().print(" Created  Modified\n", .{});
    } else {
        try Console.stdout().writeByte('\n');
    }

    for (disk_image.directory.cooked_directories.items) |entry| {
        if (options.cpm_user) |user| {
            if (user != entry.user) continue;
        }
        const this_kb = entry.used_in_kbytes;
        kb_used += this_kb;
        switch (disk_image.image_type.OS) {
            inline else => |_, tag| {
                // TODO: In future we need display capabilities like has extension, has creation time.
                const max_len = std.fmt.comptimePrint("{}", .{comptime CookedDirEntry.filenameOnlyMaxLen(tag)});
                switch (tag) {
                    .cpm, .cdos => try Console.stdout().print("{s:<" ++ max_len ++ "} {s:<3} {:>7}B {:>4}K {} {s}", .{
                        entry.filenameOnly(),
                        entry.extensionOnly(),
                        entry.size_in_bytes,
                        this_kb,
                        entry.user,
                        entry.attribs,
                    }),
                    .ados, .hd_basic => try Console.stdout().print("{s:<" ++ max_len ++ "} {:>7}B {:>4}K {} {s}", .{
                        entry.filenameOnly(),
                        entry.size_in_bytes,
                        this_kb,
                        entry.user,
                        entry.attribs,
                    }),
                }
            },
        }

        if (disk_image.image_type.OS == .hd_basic) {
            try Console.stdout().print(" {f} {f}\n", .{
                hd_basic.fmtDate(entry.createdDate().?),
                hd_basic.fmtDate(entry.modifiedDate().?),
            });
        } else {
            try Console.stdout().writeByte('\n');
        }
        file_count += 1;
    }
    const kb_free = disk_image.capacityFreeInKB();
    const kb_total = disk_image.capacityTotalInKB();

    try Console.stdout().print(
        "{} file(s), occupying {}K of {}K total capacity\n",
        .{ file_count, kb_used, kb_total },
    );
    try Console.stdout().print(
        "{} directory entries and {}K bytes remain\n",
        .{ disk_image.directory.rawEntryFreeCount(), kb_free },
    );

    return;
}

pub fn directoryListRaw(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    try switch (disk_image.directory.raw_directories) {
        .cpm => directoryListRawCPM(ctx, disk_image, options),
        .ados => directoryListRawADOS(ctx, disk_image, options),
        .hd_basic => directoryListRawHDB(ctx, disk_image, options),
    };
}

/// Show the raw CPM directory entries
pub fn directoryListRawCPM(_: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    _ = options;
    try Console.stdout().print("IDX:U:FILENAME:TYP:AT:EXT:REC:[ALLOCATIONS]\n", .{});

    for (disk_image.directory.raw_directories.cpm.items, 0..) |entry, extent_nr| {
        if (!entry.isDeleted()) {
            const attribs = [2]u8{
                if (entry.attribReadOnly()) 'R' else 'W',
                if (entry.attribSystem()) 'S' else ' ',
            };

            try Console.stdout().print("{:0>3}:{}:{s:<8}:{s:<3}:{s}:{:0>3}:{:0>3}", .{
                extent_nr,         entry.user, entry.filename,
                entry.filetype,    attribs,    entry.extentGet(disk_image.image_type),
                entry.num_records,
            });

            // The allocations are really little endian u16's
            try Console.stdout().print("[", .{});
            for (0..entry.allocationsCount(disk_image.image_type) - 1) |i| {
                const value = entry.allocationGet(i, disk_image.image_type) catch |err| {
                    printErrorMessage(current_command, .directory_list, .{}, err);
                    return error.CommandFailed;
                };
                try Console.stdout().print("{},", .{value});
            }
            const value = entry.allocationGet(entry.allocationsCount(disk_image.image_type) - 1, disk_image.image_type) catch |err| {
                printErrorMessage(current_command, .directory_list, .{}, err);
                return error.CommandFailed;
            };

            try Console.stdout().print("{}]\n", .{value});
        }
    }
    try Console.stdout().print("FREE DIRECTORIES: ({})\n", .{disk_image.directory.rawEntryFreeCount()});
    const free_allocations = disk_image.directory.free_allocations;
    try Console.stdout().print("FREE ALLOCATIONS: ({})\n", .{free_allocations.count()});
    var nr_output: usize = 0;
    for (0..free_allocations.capacity()) |alloc_nr| {
        if (free_allocations.isSet(alloc_nr)) {
            try Console.stdout().print("{:0>3} ", .{alloc_nr});
            nr_output += 1;
            if (nr_output % 16 == 0) {
                try Console.stdout().print("\n", .{});
            }
        }
    }
    try Console.stdout().print("\n", .{});
}

pub fn directoryListRawADOS(_: Context, disk_image: *DiskImage, _: CommandLineOptions) CommandError!void {
    try Console.stdout().print("FNR:FILENAME:MD:TK:SC\n", .{});

    for (disk_image.directory.raw_directories.ados.items, 1..) |entry, file_nr| {
        if (entry.isLastEntry()) break;
        if (!entry.isDeleted()) {
            try Console.stdout().print("{d:03}:{s}:{x:02}:{x:02}:{x:02}\n", .{
                file_nr,
                entry.filename,
                entry.mode,
                entry.track,
                entry.sector,
            });
        }
    }
    try Console.stdout().print("FREE DIRECTORIES: ({})\n", .{disk_image.directory.rawEntryFreeCount()});
    const free_allocations = disk_image.directory.free_allocations;
    try Console.stdout().print("FREE ALLOCATIONS: ({})\n", .{free_allocations.count()});
    var nr_output: usize = 0;
    for (0..free_allocations.capacity()) |alloc_nr| {
        if (free_allocations.isSet(alloc_nr)) {
            try Console.stdout().print("{:0>3} ", .{alloc_nr});
            nr_output += 1;
            if (nr_output % 16 == 0) {
                try Console.stdout().print("\n", .{});
            }
        }
    }
    try Console.stdout().print("\n", .{});
}

pub fn directoryListRawHDB(_: Context, disk_image: *DiskImage, _: CommandLineOptions) CommandError!void {
    try Console.stdout().print("IDX:FILENAME                :CREATE:MODIFY:R:S:NRPGS:LPEOF:NRGPS:LSTGP:[ALLOCATIONS]\n", .{});

    for (disk_image.directory.raw_directories.hd_basic.items, 1..) |entry, file_nr| {
        if (entry.isLastEntry()) break;
        if (!entry.isDeleted()) {
            try Console.stdout().print("{d:03}:{s}:{x}:{x}:{x}:{x}:{d:05}:{d:05}:{d:05}:{d:05}:[", .{
                file_nr,
                entry.filename,
                entry.creation_date,
                entry.modification_date,
                entry.read_only,
                entry.status,
                entry.npages,
                entry.eof_byte,
                entry.ngroups,
                entry.last_group,
            });
            try Console.stdout().print("{d:04}", .{entry.allocations[0]});
            for (entry.allocations[1..]) |alloc| {
                if (alloc == 0xffff) break;
                try Console.stdout().print(", {d:04}", .{alloc});
            }
            try Console.stdout().print("]\n", .{});
        }
    }
    try Console.stdout().print("FREE DIRECTORIES: ({})\n", .{disk_image.directory.rawEntryFreeCount()});

    const free_allocations = disk_image.directory.free_allocations;
    try Console.stdout().print("FREE ALLOCATIONS: ({})\n", .{free_allocations.count()});
    var nr_output: usize = 0;
    for (0..free_allocations.capacity()) |alloc_nr| {
        if (free_allocations.isSet(alloc_nr)) {
            try Console.stdout().print("{:0>3} ", .{alloc_nr});
            nr_output += 1;
            if (nr_output % 16 == 0) {
                try Console.stdout().print("\n", .{});
            }
        }
    }
    try Console.stdout().print("\n", .{});
}

/// Get a file from the image.
pub fn getFile(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    try _getFile(ctx, disk_image, .{ .filename = options.multiple_files[0] }, options);
}

/// Get multiple files from the image.
pub fn getFileMultiple(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    var had_error = false;
    for (options.multiple_files) |file_pattern| {
        var found_file: bool = false;
        var itr = disk_image.directory.findByFileNameWildcards(file_pattern, options.cpm_user);

        while (itr.next()) |entry| {
            found_file = true;
            _getFile(ctx, disk_image, .{ .dir_entry = entry }, options) catch |err| {
                return switch (err) {
                    error.CommandFailedCanContinue => continue,
                    else => error.CommandFailed,
                };
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
fn _getFile(ctx: Context, disk_image: *DiskImage, lookup: FileNameOrCookedDir, options: CommandLineOptions) CommandError!void {
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

    var cwd = std.Io.Dir.cwd();
    if (options.get_out_dir.len > 0) {
        cwd = cwd.openDir(ctx.io, options.get_out_dir, .{}) catch |err| {
            printErrorMessage(current_command, .open_directory, .{options.get_out_dir}, err);
            return error.CommandFailed;
        };
    }
    defer if (options.get_out_dir.len > 0) cwd.close(ctx.io);

    var filename_buf: [dir_entry.filename.len + 3]u8 = undefined; // Underlying filename + _nn for the user.
    const out_filename = if (add_user_extension)
        std.fmt.bufPrint(&filename_buf, "{s}_{d}", .{ dir_entry.filenameAndExtension(), dir_entry.user }) catch unreachable
    else
        std.fmt.bufPrint(&filename_buf, "{s}", .{dir_entry.filenameAndExtension()}) catch unreachable;
    var safe_buf: [std.fs.max_name_bytes]u8 = undefined;

    var out_file = cwd.createFile(ctx.io, host_os.toSafeHostFilename(out_filename, &safe_buf) catch unreachable, .{ .read = false, .exclusive = !options.force }) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {
                printErrorMessage(current_command, .file_exists, .{out_filename}, err);
            },
            else => {
                printErrorMessage(current_command, .file_create, .{out_filename}, err);
            },
        }
        return error.CommandFailedCanContinue;
    };
    defer out_file.close(ctx.io);

    var text_mode: DiskImage.TextMode = .Auto;
    if (options.text_mode) { // FUTURE TODO: Change this to work as an enum option.. three options is just too much?
        // We should also restrict to the OS it applies to... maybe twe add a "BASIC" enum instead of abusing Ascii?
        text_mode = .Text;
    } else if (options.bin_mode) {
        text_mode = .Binary;
    } else if (options.rand_mode) {
        text_mode = .Rand;
    }

    var write_buffer: [4096]u8 = undefined;
    var file_writer = out_file.writer(ctx.io, &write_buffer);
    defer file_writer.flush() catch |err| {
        printErrorMessage(current_command, .file_copy, .{out_filename}, err);
    };
    disk_image.copyFromImage(dir_entry, &file_writer.interface, text_mode) catch |err| {
        printErrorMessage(current_command, .file_copy, .{out_filename}, err);
        if (file_writer.pos == 0) {
            cwd.deleteFile(ctx.io, out_filename) catch {
                log.err("Error deleting empty output file: {s}.", .{out_filename});
            };
        }
        return error.CommandFailed;
    };
    log.info("Copied file {s} to {s}", .{ dir_entry.filenameAndExtension(), out_filename });
}

/// Copy a file to the image
pub fn putFile(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    try _putFile(ctx, disk_image, options.multiple_files[0], options);
}

/// Copy multiple files to the image
pub fn putFileMultiple(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    var had_error = false;
    for (options.multiple_files) |filename| {
        _putFile(ctx, disk_image, filename, options) catch |err| {
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

pub fn _putFile(ctx: Context, disk_image: *DiskImage, filename: []const u8, options: CommandLineOptions) !void {
    const cpm_user = options.cpm_user orelse 0;

    var text_mode: DiskImage.TextMode = .Auto;
    if (options.text_mode) { // TODO: Change this to work as an enum option.. three options is just too much?
        // We should also restrict to the OS it applies to... maybe twe add a "BASIC" enum instead of abusing Ascii?
        text_mode = .Text;
    } else if (options.bin_mode) {
        text_mode = .Binary;
    } else if (options.rand_mode) {
        text_mode = .Rand;
    }

    var cwd = std.Io.Dir.cwd();

    var in_file = cwd.openFile(ctx.io, filename, .{ .mode = .read_only }) catch |err| {
        printErrorMessage(current_command, .file_open, .{filename}, err);
        return error.CommandFailedCanContinue;
    };
    defer in_file.close(ctx.io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = in_file.reader(ctx.io, &read_buffer);
    var conv_buf: [std.fs.max_name_bytes]u8 = undefined;

    const basename = host_os.fromSafeHostFilename(std.fs.path.basename(filename), &conv_buf) catch unreachable;
    disk_image.copyToImage(&file_reader.interface, basename, cpm_user, options.force, text_mode) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {
                printErrorMessage(current_command, .file_exists, .{basename}, err);
                return error.CommandFailedCanContinue;
            },
            error.CookedDirEntryNotFound => {
                printErrorMessage(current_command, .file_copy, .{basename}, err);
                return error.CommandFailedCanContinue;
            },
            error.ReadOnlySupport => {
                printErrorMessage(current_command, .read_only_support, .{disk_image.image_type.type_id}, err);
                return error.CommandFailed;
            },
            else => {
                printErrorMessage(current_command, .file_copy, .{basename}, err);
                return error.CommandFailed;
            },
        }
    };
    log.info("Copied file {s} to {s}", .{ filename, basename });
}

/// Remove a file from the image
pub fn eraseFile(_: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    const filename = std.fs.path.basename(options.multiple_files[0]);
    if (disk_image.directory.findByFilename(filename, options.cpm_user)) |dir_entry| {
        disk_image.erase(dir_entry) catch |err| switch (err) {
            error.ReadOnlySupport => {
                printErrorMessage(current_command, .read_only_support, .{disk_image.image_type.type_id}, err);
                return error.CommandFailed;
            },
            else => {
                printErrorMessage(current_command, .file_erase, .{filename}, err);
                return error.CommandFailed;
            },
        };
    } else {
        printErrorMessage(current_command, .file_not_found, .{filename}, error.None);
        return error.CommandFailed;
    }
}

/// Remove multiple files from the image.
pub fn eraseFileMultiple(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    var had_error = false;
    var to_erase: std.ArrayListUnmanaged(CookedDirEntry) = .empty;
    defer to_erase.deinit(ctx.gpa);

    for (options.multiple_files) |file_pattern| {
        var found_file: bool = false;
        var itr = disk_image.directory.findByFileNameWildcards(file_pattern, options.cpm_user);

        while (itr.next()) |entry| {
            found_file = true;
            to_erase.append(ctx.gpa, entry.*) catch OOM();
        } else {
            if (!found_file) {
                printErrorMessage(current_command, .no_matching_files, .{file_pattern}, error.None);
                had_error = true;
            }
        }
    }
    for (to_erase.items) |*entry| {
        blk: {
            disk_image.erase(entry) catch |err| switch (err) {
                error.ReadOnlySupport => {
                    printErrorMessage(current_command, .read_only_support, .{disk_image.image_type.type_id}, err);
                    return error.CommandFailed;
                },
                else => {
                    printErrorMessage(current_command, .file_erase, .{entry.filenameAndExtension()}, err);
                    had_error = true;
                    break :blk;
                },
            };
            log.info("Erased file {s}", .{entry.filenameAndExtension()});
        }
    }
    if (had_error) {
        return error.CommandFailed;
    }
}

/// Extract system tracks
pub fn extractCPM(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    log.info("Extract CPM to {s}", .{options.system_image_get});
    var cwd = std.Io.Dir.cwd();
    const out_file = cwd.createFile(ctx.io, options.system_image_get, .{ .read = false }) catch |err| {
        printErrorMessage(current_command, .file_create, .{options.system_image_get}, err);
        return error.CommandFailed;
    };
    defer out_file.close(ctx.io);
    disk_image.extractOperatingSystem(ctx.io, out_file) catch |err| switch (err) {
        else => {
            printErrorMessage(current_command, .extract_cpm, .{options.system_image_get}, err);
            return error.CommandFailed;
        },
    };
}

/// Write to system tracks
pub fn installCPM(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    log.info("Install CPM from {s}", .{options.system_image_put});
    var cwd = std.Io.Dir.cwd();
    const in_file = cwd.openFile(ctx.io, options.system_image_put, .{ .mode = .read_only }) catch |err| {
        printErrorMessage(current_command, .file_open, .{options.system_image_put}, err);
        return error.CommandFailed;
    };
    defer in_file.close(ctx.io);
    disk_image.installOperatingSystem(ctx.io, in_file) catch |err| switch (err) {
        error.ReadOnlySupport => {
            printErrorMessage(current_command, .read_only_support, .{disk_image.image_type.type_id}, err);
            return error.CommandFailed;
        },
        else => {
            printErrorMessage(current_command, .install_cpm, .{options.system_image_put}, err);
            return error.CommandFailed;
        },
    };
}

pub fn formatImage(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    log.info("Formatting {s} ....", .{options.image_file});
    disk_image.formatImage() catch |err| switch (err) {
        error.ReadOnlySupport => {
            printErrorMessage(current_command, .read_only_support, .{disk_image.image_type.type_id}, err);
            return error.CommandFailed;
        },
        else => {
            printErrorMessage(current_command, .format, .{options.image_file}, err);
            return error.CommandFailed;
        },
    };
    if (options.disk_label.len > 0) {
        disk_image.loadDirectories(.full) catch |err| {
            printErrorMessage(current_command, .unexpected, .{}, err);
            return error.CommandFailed;
        };
        try labelSet(ctx, disk_image, options);
    }
}

pub fn labelSet(_: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    const label_len: u32 = switch (disk_image.image_type.OS) {
        .cdos => @field(@FieldType(DiskLabel, "cdos"), "user_label_len"),
        .hd_basic => @field(@FieldType(DiskLabel, "hd_basic"), "user_label_len"),
        else => 0,
    };

    log.info("Setting disk label to: {s}", .{options.disk_label});
    doLabelSet(disk_image, options) catch |err| {
        switch (err) {
            error.InvalidLabelFormat => printErrorMessage(current_command, .label_invalid, .{ options.disk_label, label_len }, err),
            error.LabelingNotSupported => printErrorMessage(current_command, .labeling_not_supported, .{}, err),
            error.LabelNotFound => printErrorMessage(current_command, .label_not_found, .{}, err),
            else => printErrorMessage(current_command, .unexpected, .{}, err),
        }
        return error.CommandFailed;
    };
}

fn doLabelSet(disk_image: *DiskImage, options: CommandLineOptions) !void {
    // TODO: make the label length come from disk image type
    const label_len: u32 = switch (disk_image.image_type.OS) {
        .cdos => @field(@FieldType(DiskLabel, "cdos"), "user_label_len"),
        .hd_basic => @field(@FieldType(DiskLabel, "hd_basic"), "user_label_len"),
        else => 0,
    };

    switch (disk_image.image_type.OS) {
        .cdos, .hd_basic => {
            // Format for CDOS label is llllllll:mm/dd/yy
            // where l can be 1-8 chars long and 20 chars long for hd_basic
            const colon_pos = std.mem.indexOfScalarPos(u8, options.disk_label, 0, ':') orelse
                return error.InvalidLabelFormat;

            // make sure both the label is at most 8 chars and the date is exactly 8 chars
            if (colon_pos > label_len or colon_pos + 9 != options.disk_label.len)
                return error.InvalidLabelFormat;

            // Make sure it is valid date in mm/dd/yy format.
            if (options.disk_label[colon_pos + 3] != '/' or
                options.disk_label[colon_pos + 6] != '/')
                return error.InvalidLabelFormat;
            if (options.disk_label[colon_pos + 1] != '0' and
                options.disk_label[colon_pos + 1] != '1')
                return error.InvalidLabelFormat;
            if (options.disk_label[colon_pos + 2] < '0' or
                options.disk_label[colon_pos + 2] > '9')
                return error.InvalidLabelFormat;
            if (options.disk_label[colon_pos + 4] < '0' or
                options.disk_label[colon_pos + 4] > '3')
                return error.InvalidLabelFormat;
            if (options.disk_label[colon_pos + 5] < '0' or
                options.disk_label[colon_pos + 5] > '9')
                return error.InvalidLabelFormat;
            if (options.disk_label[colon_pos + 7] < '0' or
                options.disk_label[colon_pos + 7] > '9')
                return error.InvalidLabelFormat;
            if (options.disk_label[colon_pos + 8] < '0' or
                options.disk_label[colon_pos + 8] > '9')
                return error.InvalidLabelFormat;

            const mm: u8 = (options.disk_label[colon_pos + 1] - '0') * 10 + options.disk_label[colon_pos + 2] - '0';
            const dd: u8 = (options.disk_label[colon_pos + 4] - '0') * 10 + options.disk_label[colon_pos + 5] - '0';
            const yy: u8 = (options.disk_label[colon_pos + 7] - '0') * 10 + options.disk_label[colon_pos + 8] - '0';
            if (dd < 1 or dd > 31 or mm < 1 or mm > 12)
                return error.InvalidLabelFormat;

            switch (disk_image.image_type.OS) {
                .cdos => {
                    var disk_label: DiskLabel = .{ .cdos = undefined };
                    const copy_size = @min(disk_label.cdos.user_label.len, colon_pos);
                    @memset(&disk_label.cdos.user_label, ' ');
                    @memcpy(disk_label.cdos.user_label[0..copy_size], options.disk_label[0..copy_size]);

                    disk_label.cdos.date_mmddyy[0] = mm;
                    disk_label.cdos.date_mmddyy[1] = dd;
                    disk_label.cdos.date_mmddyy[2] = yy;

                    try disk_image.labelDisk(disk_label);
                },
                .hd_basic => {
                    var disk_label: DiskLabel = .{ .hd_basic = undefined };

                    const copy_size = @min(disk_label.hd_basic.user_label.len, colon_pos);
                    @memset(&disk_label.hd_basic.user_label, ' ');
                    @memcpy(disk_label.hd_basic.user_label[0..copy_size], options.disk_label[0..copy_size]);
                    disk_label.hd_basic.created_yymmdd[0] = yy;
                    disk_label.hd_basic.created_yymmdd[1] = mm;
                    disk_label.hd_basic.created_yymmdd[2] = dd;

                    disk_label.hd_basic.modified_yymmdd[0] = yy;
                    disk_label.hd_basic.modified_yymmdd[1] = mm;
                    disk_label.hd_basic.modified_yymmdd[2] = dd;

                    try disk_image.labelDisk(disk_label);
                },
                else => unreachable,
            }
        },
        .cpm, .ados => return error.LabelingNotSupported,
    }
}

pub fn labelShow(_: Context, disk_image: *DiskImage, _: CommandLineOptions) CommandError!void {
    switch (disk_image.image_type.OS) {
        .cdos, .hd_basic => {},
        .cpm, .ados => {
            printErrorMessage(current_command, .labeling_not_supported, .{}, error.LabelingNotSupported);
            return error.CommandFailed;
        },
    }
    var label: DiskLabel = undefined;
    disk_image.labelGet(&label) catch |err| {
        switch (err) {
            error.LabelingNotSupported => {
                printErrorMessage(current_command, .labeling_not_supported, .{}, err);
                return error.CommandFailed;
            },
            error.LabelNotFound => {
                printErrorMessage(current_command, .label_not_found, .{}, err);
                return error.CommandFailed;
            },
        }
    };

    switch (label) {
        .cdos => try Console.stdout().print(
            "Label: {s}\nDate:  {d:02}/{d:02}/{d:02} (mm/dd/yy)\n",
            .{
                label.cdos.user_label,
                label.cdos.date_mmddyy[0],
                label.cdos.date_mmddyy[1],
                label.cdos.date_mmddyy[2],
            },
        ),
        .hd_basic => try Console.stdout().print(
            "Label:    {s}\nCreated:  {d:02}/{d:02}/{d:02} (mm/dd/yy)\nModified: {d:02}/{d:02}/{d:02} (mm/dd/yy)\n",
            .{
                label.hd_basic.user_label,
                label.hd_basic.created_yymmdd[1],
                label.hd_basic.created_yymmdd[2],
                label.hd_basic.created_yymmdd[0],
                label.hd_basic.modified_yymmdd[1],
                label.hd_basic.modified_yymmdd[2],
                label.hd_basic.modified_yymmdd[0],
            },
        ),
        .cpm, .ados => unreachable,
    }
}

/// Try and recover an image with corrupted directory entries.
pub fn recoverImage(ctx: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    log.info("Recovering {s} to {s}", .{ options.image_file, options.recovery_image_file });

    var cwd = std.Io.Dir.cwd();
    // Copy the image to the new file first
    const out_image = cwd.createFile(ctx.io, options.recovery_image_file, .{ .read = true }) catch |err| {
        printErrorMessage(current_command, .recover, .{options.recovery_image_file}, err);
        return error.CommandFailed;
    };
    defer out_image.close(ctx.io);

    var buffer: [4096]u8 = undefined;
    var writer = out_image.writer(ctx.io, &buffer);
    _ = disk_image.reader.interface().streamRemaining(&writer.interface) catch |err| {
        printErrorMessage(current_command, .unexpected, .{}, err);
        return error.CommandFailed;
    };
    writer.seekTo(0) catch |err| {
        printErrorMessage(current_command, .unexpected, .{}, err);
        return error.CommandFailed;
    };
    var reader = out_image.reader(ctx.io, &.{});

    var recovery_image: DiskImage = DiskImage.init(
        ctx.gpa,
        .{ .on_disk = &reader },
        .{ .on_disk = &writer },
        disk_image.image_type,
    ) catch |err| {
        printErrorMessage(current_command, .image_init, .{options.recovery_image_file}, err);
        return error.CommandFailed;
    };
    defer recovery_image.deinit();

    recovery_image.tryRecovery() catch |err| {
        printErrorMessage(current_command, .recover, .{options.image_file}, err);
        return error.CommandFailed;
    };
    writer.flush() catch {};
}

/// Print image parameters
pub fn printImageInfo(_: Context, disk_image: *DiskImage, options: CommandLineOptions) CommandError!void {
    _ = options;
    disk_image.image_type.dump();
}

fn openDiskImage(io: std.Io, filename: []const u8, writeable: bool, create_file: bool) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    if (create_file) {
        return cwd.createFile(io, filename, .{ .read = true, .truncate = false });
    } else if (writeable) {
        return cwd.openFile(io, filename, .{ .mode = .read_write });
    } else {
        return cwd.openFile(io, filename, .{ .mode = .read_only });
    }
}

fn printErrorMessage(command: []const u8, comptime message: ErrorMessage, args: anytype, err: anyerror) void {
    Console.stderr().print("Error performing {s}: ", .{command}) catch {};
    Console.stderr().print(error_messages.get(message), args) catch {};

    switch (err) {
        error.None => {
            Console.stderr().writeAll("\n") catch {};
        },
        error.CantDetectImage => {
            Console.stderr().print(": Not a supported disk image.\n", .{}) catch {};
        },
        RawDirError.InvalidAllocation,
        RawDirError.InvalidEntryNumber,
        RawDirError.InvalidExtent,
        RawDirError.InvalidRecordNumber,
        RawDirError.InvalidUser,
        => {
            Console.stderr().print(
                ": The directory entries in this image are invalid. Error = {s}.\n",
                .{@errorName(err)},
            ) catch {};
        },
        DirectoryError.OutOfAllocs,
        => {
            Console.stderr().print(": The disk is full\n", .{}) catch {};
        },
        DirectoryError.OutOfExtents,
        => {
            Console.stderr().print(": No more directory entries available\n", .{}) catch {};
        },
        error.FileNotFound => {
            Console.stderr().print(": File not found\n", .{}) catch {};
        },
        error.AccessDenied => {
            Console.stderr().print(": Access is denied\n", .{}) catch {};
        },
        error.PathAlreadyExists => {
            Console.stderr().print(": File already exists\n", .{}) catch {};
        },
        else => {
            Console.stderr().print(": {s}\n", .{@errorName(err)}) catch {};
        },
    }
}

fn OOM() noreturn {
    @panic("Out of Memory");
}

const ErrorMessage = enum {
    unexpected,
    open_image,
    open_directory,
    image_type_detect,
    image_type_set,
    image_init,
    image_load,
    no_matching_files,
    file_not_found_user,
    file_not_found,
    file_create,
    file_exists,
    file_open,
    file_copy,
    file_erase,
    file_write,
    file_seek,
    extract_cpm,
    install_cpm,
    format,
    recover,
    labeling_not_supported,
    label_invalid,
    label_not_found,
    directory_list,
    read_only_support,
};

const error_messages = std.EnumArray(ErrorMessage, []const u8).init(
    .{
        .unexpected = "Unexpected error",
        .open_image = "Error opening disk image {s}",
        .open_directory = "Error opening directory {s}",
        .image_type_detect = "Can't detect image type. Use -h to see supported types and -T to force a type.",
        .image_type_set = "Image type is not set correctly. Use -h to see supported types or -v to see the detected type.",
        .image_init = "Initializing disk image {s}",
        .image_load = "Loading directory table",
        .no_matching_files = "No files found matching {s}",
        .file_not_found_user = "File {s} does not exist for user {d}",
        .file_not_found = "File {s} does not exist",
        .file_create = "Error creating file {s}",
        .file_exists = "Error creating file {s}. Use --force to overwrite",
        .file_open = "Error opening file {s}",
        .file_copy = "Error copying file {s}",
        .file_erase = "Error erasing {s}",
        .file_write = "Error writing to {s}",
        .file_seek = "Error seeking {s}",
        .extract_cpm = "Error extracting sytem image to {s}",
        .install_cpm = "Error installing system image from {s}",
        .format = "Error formatting {s}",
        .recover = "Error recovering image {s}",
        .labeling_not_supported = "Labels are not supported for this image type",
        .label_invalid = "Invalid label format {s}. Use <label>:mm/dd/yy where <label> is up to {d} characters",
        .label_not_found = "The first directory entry is not a disk label",
        .directory_list = "Error listing directory",
        .read_only_support = "Writing is not supported for format {t}",
    },
);

const std = @import("std");
const di = @import("disk_image.zig");
const DiskImage = di.DiskImage;
const DirectoryTable = @import("directory_table.zig").DirectoryTable;
const DiskImageType = @import("disk_types.zig").DiskImageType;
const DiskImageTypes = @import("disk_types.zig").DiskImageTypes;
const DiskLabel = @import("disk_types.zig").DiskLabel;
const RawDirError = DirectoryTable.RawDirError;
const DirectoryError = DirectoryTable.DirectoryError;
const CommandLineOptions = @import("main.zig").CommandLineOptions;
const Console = @import("console.zig");
const hd_basic = @import("os_hd_basic.zig");
const host_os = @import("host_os.zig");
