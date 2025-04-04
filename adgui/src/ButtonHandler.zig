const Options = struct {
    default_to_confirm: bool = false,
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
                            CommandState.currentFile().?.message = options.prompt_skip orelse "Skipped.";
                        } else {
                            if (options.default_to_confirm) {
                                CommandState.buttons = .yes_no_all;
                                CommandState.state = .waiting_for_input;
                                CommandState.currentFile().?.message = options.prompt_file orelse "Skip?";
                            } else {
                                CommandState.state = .processing;
                                // Continue to the .confirm case.
                                // Note that state stays as processing so that "action handlers" can
                                // tell if it is a new file or a file being confirmed.
                                continue :blk .confirm;
                            }
                        }
                    } else {
                        // No more files. Done.
                        CommandState.finishCommand();
                    }
                },
                .confirm => {
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
