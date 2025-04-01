//!*****************************************************************************
//! ALTAIR Disk Tools
//!
//! Manipulate Altair CPM Disk Images
//!
//!*****************************************************************************
//
// MIT License
//
// Copyright (c) 2025 Paul Hatchman
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
pub const global_allocator = gpa.allocator();

// This arena lasts the lifetime of the application.
pub var arena = std.heap.ArenaAllocator.init(global_allocator);
const all_disk_types = @import("disk_types.zig").all_disk_types;
const all_disk_type_names = @import("disk_types.zig").all_disk_type_names;

/// Main processing takes place here
fn do_main() !void {
    var stdin_buffered = std.io.bufferedReader(std.io.getStdIn().reader());
    const stdin_buffered_reader = stdin_buffered.reader().any();
    var stdout_buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout_buffered_writer = stdout_buffered.writer().any();
    const stderr_writer_any = std.io.getStdErr().writer().any();

    Console.init(
        &stdin_buffered,
        &stdin_buffered_reader,
        &stdout_buffered,
        &stdout_buffered_writer,
        &stderr_writer_any,
    );
    defer Console.deinit();

    if (!(validateOptions() catch false)) {
        // validate options prints the error.
        return;
    }

    // Print out log messages in verbose mode on exit.
    defer {
        if (error_collection.items.len > 0) {
            Console.stderr.print("The following errors were encountered:\n", .{}) catch {};
            for (error_collection.items) |message| {
                Console.stderr.print("{s}\n", .{message}) catch {};
            }
            if (options.do_recover) {
                Console.stderr.print("It is normal to see errors when running --recover\n", .{}) catch {};
            }
        }
    }

    // Start of processing.
    Commands.dispatch(options) catch |err| {
        switch (err) {
            error.CommandFailed, error.CommandFailedCanContinue => return error.ErrorExit,
            else => return err,
        }
    };
}

pub const CommandLineOptions = struct {
    image_file: []const u8 = undefined,
    multiple_files: [][]const u8 = undefined,
    system_image_get: []const u8 = undefined,
    system_image_put: []const u8 = undefined,
    recovery_image_file: []const u8 = undefined,
    // All command options need to be in the format do_xxxx to be
    // included in the dispatch table.
    do_directory: bool = false,
    do_raw_dir: bool = false,
    do_information: bool = false,
    do_format: bool = false,
    do_get: bool = false,
    do_get_multi: bool = false,
    do_put: bool = false,
    do_put_multi: bool = false,
    do_erase: bool = false,
    do_erase_multi: bool = false,
    do_cpm_get: bool = false,
    do_cpm_put: bool = false,
    do_recover: bool = false,
    text_mode: bool = false,
    bin_mode: bool = false,
    verbose: bool = false,
    very_verbose: bool = false,
    cpm_user: ?u8 = null,
    disk_image_type: ?ImageType = null,
};

var options = CommandLineOptions{};
var app: cli.App = undefined;
pub fn main() !void {
    defer {
        arena.deinit();
        _ = gpa.deinit();
    }

    var r = try cli.AppRunner.init(arena.allocator());
    app = cli.App{
        .command = cli.Command{
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .positional_args = cli.PositionalArgs{
                        .required = try r.allocPositionalArgs(&.{
                            .{
                                .name = "disk_image",
                                .help = "Filename of Altair disk image",
                                .value_ref = r.mkRef(&options.image_file),
                            },
                        }),
                        .optional = try r.allocPositionalArgs(&.{
                            .{
                                .name = "filename",
                                .help = "List of filesnames. Wildcards * and ? are supported e.g. '*.COM'",
                                .value_ref = r.mkRef(&options.multiple_files),
                            },
                        }),
                    },
                    .exec = do_main,
                },
            },
            .name = "altair_disk",
            .description = cli.Description{
                .one_line = "Altair Disk Image Utility",
            },
            .options = &.{
                .{
                    .long_name = "dir",
                    .help = "Directory listing (default)",
                    .short_alias = 'd',
                    .value_ref = r.mkRef(&options.do_directory),
                },
                .{
                    .long_name = "raw",
                    .help = "Raw directory listing",
                    .short_alias = 'r',
                    .value_ref = r.mkRef(&options.do_raw_dir),
                },
                .{
                    .long_name = "info",
                    .help = "Prints disk format information",
                    .short_alias = 'i',
                    .value_ref = r.mkRef(&options.do_information),
                },
                .{
                    .long_name = "format",
                    .help = "Format existing or create new disk image. Defaults to FDD_8IN",
                    .short_alias = 'F',
                    .value_ref = r.mkRef(&options.do_format),
                },
                .{
                    .long_name = "get",
                    .help = "Copy file from Altair disk image to host",
                    .short_alias = 'g',
                    .value_ref = r.mkRef(&options.do_get),
                },
                .{
                    .long_name = "get-multiple",
                    .help = "Copy multiple files from Altair disk image to host. Wildcards * and ? are supported e.g '*.COM'",
                    .short_alias = 'G',
                    .value_ref = r.mkRef(&options.do_get_multi),
                },
                .{
                    .long_name = "put",
                    .help = "Copy file from host to Altair disk image",
                    .short_alias = 'p',
                    .value_ref = r.mkRef(&options.do_put),
                },
                .{
                    .long_name = "put-multiple",
                    .help = "Copy multiple files from host to Altair disk image",
                    .short_alias = 'P',
                    .value_ref = r.mkRef(&options.do_put_multi),
                },
                .{
                    .long_name = "erase",
                    .help = "Erase a file",
                    .short_alias = 'e',
                    .value_ref = r.mkRef(&options.do_erase),
                },
                .{
                    .long_name = "erase-multiple",
                    .help = "Erase multiple files - wildcards supported",
                    .short_alias = 'E',
                    .value_ref = r.mkRef(&options.do_erase_multi),
                },
                .{
                    .long_name = "text",
                    .help = "Put or get a file in text mode",
                    .short_alias = 't',
                    .value_ref = r.mkRef(&options.text_mode),
                },
                .{
                    .long_name = "bin",
                    .help = "Put or get a file in binary mode",
                    .short_alias = 'b',
                    .value_ref = r.mkRef(&options.bin_mode),
                },
                .{
                    .long_name = "user",
                    .help = "Restrict operation to this CP/M user",
                    .short_alias = 'u',
                    .value_name = "user",
                    .value_ref = r.mkRef(&options.cpm_user),
                },
                .{
                    .long_name = "extract-cpm",
                    .help = "Extract CP/M system (from a bootable disk image) to a file",
                    .short_alias = 'x',
                    .value_name = "system_image",
                    .value_ref = r.mkRef(&options.system_image_get),
                },
                .{
                    .long_name = "write-cpm",
                    .help = "Write saved CP/M system image to disk image (make disk bootable)",
                    .short_alias = 's',
                    .value_name = "system_image",
                    .value_ref = r.mkRef(&options.system_image_put),
                },
                .{
                    .long_name = "recover",
                    .help = "Try to recover a corrupt image",
                    .short_alias = 'R',
                    .value_name = "new_disk_image",
                    .value_ref = r.mkRef(&options.recovery_image_file),
                },
                .{
                    .long_name = "type",
                    .help = "Disk image type. Auto-detected if possible. Supported types are:\n" ++
                        comptime generateDiskImageList() ++
                            "!!! The " ++ all_disk_type_names[@intFromEnum(ImageType.HDD_5MB_1024)] ++
                            " type cannot be auto-detected. Always use -T with this format.",
                    .short_alias = 'T',
                    .value_ref = r.mkRef(&options.disk_image_type),
                    .value_name = "type",
                },
                .{
                    .long_name = "verbose",
                    .help = "Verbose - Prints information about operations being performed",
                    .short_alias = 'v',
                    .value_ref = r.mkRef(&options.verbose),
                },
                .{
                    .long_name = "very-verbose",
                    .help = "Very verbose - Additionally prints sector read/write information",
                    .short_alias = 'V',
                    .value_ref = r.mkRef(&options.very_verbose),
                },
            },
        },
        .version = "0.9",
        .author = "Paul Hatchman",
    };

    app.help_config.print_help_on_error = false;
    r.run(&app) catch {
        // De-init in the error case because exit(1) skips the defers
        arena.deinit();
        _ = gpa.deinit();
        std.process.exit(1);
    };
}

/// Generate help text for all disk image types. The first entry is considered the default.
fn generateDiskImageList() []const u8 {
    var image_list: []const u8 = "";
    inline for (all_disk_types.values, 0..) |image_type, i| {
        image_list = image_list ++ "      * " ++ image_type.type_name ++ " - " ++ image_type.description ++ if (i == 0) " (Default)\n" else "\n";
    }
    const result = image_list;
    return result;
}

pub fn validateOptions() !bool {
    if (options.very_verbose)
        options.verbose = true;

    options.do_cpm_get = options.system_image_get.len != 0;
    options.do_cpm_put = options.system_image_put.len != 0;
    options.do_recover = options.recovery_image_file.len != 0;

    // Can only by one of directory, get/multi, put/multi, etc
    const single_options = [_]bool{
        options.do_directory,   options.do_erase,     options.do_erase_multi,
        options.do_format,      options.do_get,       options.do_get_multi,
        options.do_put,         options.do_put_multi, options.do_raw_dir,
        options.do_cpm_get,     options.do_cpm_put,   options.do_recover,
        options.do_information,
    };

    var option_count: usize = 0;
    for (single_options) |value| {
        if (value)
            option_count += 1;
    }
    if (option_count == 0) {
        // Default to directory listing
        options.do_directory = true;
    }

    if (option_count > 1) {
        cli.printError(&app,
            \\You may only specify one of:
            \\       --directory, 
            \\       --raw
            \\       --info
            \\       --format,
            \\       --get, --get-multiple,
            \\       --put, --put-multiple,
            \\       --erase, --erase-multiple,
            \\       --extract-cpm, --write-cpm
            \\       --recover
            \\
        , .{});
        return false;
    }

    if (options.do_directory or options.do_raw_dir or options.do_information) {
        if (options.multiple_files.len != 0) {
            cli.printError(&app,
                \\No filenames are allowed for:
                \\       --directory, 
                \\       --raw
                \\       --info
                \\
            , .{});
            return false;
        }
    }
    if (options.do_get or options.do_put or options.do_erase) {
        if (options.multiple_files.len != 1) {
            cli.printError(&app,
                \\You must specify exactly one filename for:
                \\       --get, --put, --erase
                \\
            , .{});
            return false;
        }
    }
    if (options.cpm_user) |user| {
        if (user > 15) {
            cli.printError(&app, "User must be between 0 and 15.", .{});
            return false;
        }
    }
    return true;
}

pub const std_options: std.Options = .{
    // Set the log level to info
    .log_level = .debug,

    // Define logFn to override the std implementation
    .logFn = log,
};

// Errors are placeds in this collection so they can be priinted after the command finishes and any othe output.
var error_collection: std.ArrayListUnmanaged([]const u8) = .empty;

/// Custom log function that collects errors to be displayed at the end for:
/// .altair_disk, .altair_disk_lib scopes
/// Redirects .debug, .infor and .warn to stdout.
/// Any errors not for .altair_disk, .altair_disk_lib are logged straight to stderr instead.
pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (scope) {
        .altair_disk, .altair_disk_lib => {}, // Continue to below for these 2 scopes.
        else => return std.io.getStdErr().writer().print(@tagName(message_level) ++ ": " ++ format, args) catch {},
    }
    switch (message_level) {
        .info, .warn => {
            if (options.verbose) {
                Console.stdout.print(@tagName(message_level) ++ ": " ++ format ++ "\n", args) catch {};
                Console.flushOut() catch {};
            }
        },
        .debug => {
            if (options.very_verbose) {
                Console.stdout.print(format, args) catch {};
                Console.flushOut() catch {};
            }
        },
        .err => {
            const message = std.fmt.allocPrint(arena.allocator(), format, args) catch {
                return;
            };
            error_collection.append(arena.allocator(), message) catch {};
        },
    }
}

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("zig-cli");
const Console = @import("console.zig");
const Commands = @import("commands.zig");
const RawDirError = @import("directory_table.zig").RawDirError;
const DirectoryError = @import("directory_table.zig").DirectoryTable.DirectoryError;
const ImageType = @import("disk_types.zig").DiskImageTypes;
