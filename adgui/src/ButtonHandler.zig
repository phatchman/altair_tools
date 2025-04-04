const Options = struct {
    prompt_file: ?[]const u8 = null,
    prompt_error: ?[]const u8 = null,
    prompt_success: ?[]const u8 = null,
    prompt_skip: ?[]const u8 = null,
    prompt_retry: ?[]const u8 = null,
};

pub fn newHandler(
    action_function: fn (file: *DirectoryEntry) anyerror!void,
    custom_error_handler: fn (current: *FileStatus, err: anyerror) void,
    options: Options,
) type {
    return struct {
        pub fn process(
            directories: []DirectoryEntry,
        ) !void {
            std.debug.print("PROCESS!!\n", .{});
            var dir_itr = CommandState.directoryEntryIterator(directories);

            blk: switch (CommandState.state) {
                .processing => {
                    CommandState.prompt = null;
                    if (dir_itr.next()) |file| {
                        try CommandState.addProcessedFile(.init(file.filenameAndExtension(), options.prompt_file orelse ""));
                        if (CommandState.confirm_all == .yes_to_all) {
                            CommandState.state = .confirm;
                            // Continue to the .confirm case.
                            continue :blk .confirm;
                        } else if (CommandState.confirm_all == .no_to_all) {
                            CommandState.currentFile().?.message = options.prompt_skip orelse "Skip";
                        } else {
                            CommandState.state = .processing;
                            continue :blk .confirm;
                        }
                    } else {
                        // No more files. Done.
                        CommandState.finishCommand();
                    }
                },
                .confirm => {
                    std.debug.print(".confirm\n", .{});
                    if (dir_itr.peek()) |file| {
                        var success: bool = true;
                        action_function(file) catch |err| {
                            std.debug.print("err = {}\n", .{err});
                            success = false;
                            var current = CommandState.currentFile().?;
                            custom_error_handler(current, err);
                            if (CommandState.confirm_all == .yes_to_all) {
                                current.message = formatErrorMessage(err);
                                CommandState.state = .processing;
                            } else if (CommandState.confirm_all == .no_to_all) {
                                current.message = options.prompt_skip orelse "Skipped.";
                            } else {
                                std.debug.print("here\n", .{});

                                switch (err) {
                                    error.PathAlreadyExists => {
                                        current.message = "Overwrite existing file?";
                                        CommandState.buttons = .yes_no_all;
                                        CommandState.state = .waiting_for_input;
                                    },
                                    else => {
                                        CommandState.prompt = options.prompt_retry orelse "Retry?";
                                        current.message = formatErrorMessage(err);
                                        CommandState.buttons = .yes_no_all;
                                        CommandState.state = .waiting_for_input;
                                    },
                                }
                            }
                        };
                        if (success) {
                            CommandState.state = .processing;
                            CommandState.currentFile().?.message = options.prompt_success orelse "OK";
                        }
                    } else {
                        std.debug.print("else\n", .{});
                        CommandState.finishCommand();
                    }
                },
                .cancel => {
                    if (CommandState.currentFile()) |current| {
                        current.message = options.prompt_skip orelse "Skipped.";
                        CommandState.state = .processing;
                    } else {
                        CommandState.finishCommand();
                    }
                },
                else => unreachable,
            }
        }
    };
}

const std = @import("std");
const DirectoryEntry = @import("commands.zig").DirectoryEntry;
const CommandState = @import("main.zig").CommandState;
const FileStatus = @import("main.zig").FileStatus;
const formatErrorMessage = @import("main.zig").formatErrorMessage;
