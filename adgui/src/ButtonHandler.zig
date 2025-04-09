pub const Options = struct {
    default_to_confirm: bool = false,
    prompt_file: []const u8 = "",
    prompt_success: []const u8 = "OK",
    prompt_skip: []const u8 = "Skipped",
    prompt_retry: []const u8 = "Retry",
    input_buttons: CommandState.Buttons = .none,
    skip_when_no_to_all: bool = false, // How should no to all work? Skip the command or process, but not force.
    //  TODO: Consider making this "stop when no to all" so we don't just keep showin the list.
};

pub fn newDirectoryListHandler(
    action_function: fn (file: *DirectoryEntry) anyerror!void,
    error_function: fn (current: *FileStatus, err: anyerror) bool,
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
                        try CommandState.addProcessedFile(.init(file.filenameAndExtension(), options.prompt_file));
                        if (CommandState.confirm_all == .yes_to_all) {
                            CommandState.state = .confirm;
                            // Continue to the .confirm case.
                            continue :blk .confirm;
                        } else if (CommandState.confirm_all == .no_to_all) {
                            if (options.skip_when_no_to_all) {
                                CommandState.currentFile().?.message = options.prompt_skip;
                            } else {
                                CommandState.state = .processing;
                                continue :blk .confirm;
                            }
                        } else {
                            if (options.default_to_confirm) {
                                CommandState.buttons = .yes_no_all;
                                CommandState.state = .waiting_for_input;
                                CommandState.currentFile().?.message = options.prompt_file;
                            } else {
                                //CommandState.state = .processing;
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
                            success = false;
                            var current = CommandState.currentFile().?;
                            if (error_function(current, err)) {
                                return;
                            }
                            if (CommandState.confirm_all == .yes_to_all) {
                                current.message = formatErrorMessage(err);
                                CommandState.state = .processing;
                            } else if (CommandState.confirm_all == .no_to_all) {
                                current.message = options.prompt_skip;
                            } else {
                                switch (err) {
                                    error.PathAlreadyExists => {
                                        current.message = "Overwrite existing file?";
                                        CommandState.buttons = .yes_no_all;
                                        CommandState.state = .waiting_for_input;
                                    },
                                    else => {
                                        CommandState.prompt = options.prompt_retry;
                                        current.message = formatErrorMessage(err);
                                        CommandState.buttons = .yes_no_all;
                                        CommandState.state = .waiting_for_input;
                                    },
                                }
                            }
                        };
                        if (success) {
                            CommandState.state = .processing;
                            CommandState.currentFile().?.message = options.prompt_success;
                        }
                    } else {
                        CommandState.finishCommand();
                    }
                },
                .cancel => {
                    if (CommandState.currentFile()) |current| {
                        current.message = options.prompt_skip;
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

pub fn newPromptForFileHandler(
    action_function: fn (filename: []const u8, options: Options) anyerror!void,
    error_function: fn (current: *FileStatus, err: anyerror) bool,
    options: Options,
) type {
    return struct {
        pub fn process() !void {
            switch (CommandState.state) {
                .processing => {
                    CommandState.prompt = options.prompt_file;
                    CommandState.state = .waiting_for_input;
                    CommandState.buttons = options.input_buttons;
                },
                .confirm => {
                    if (CommandState.file_selector_buffer) |path| {
                        try CommandState.addProcessedFile(.init(path, ""));
                        main: {
                            const current = CommandState.currentFile().?;

                            action_function(path, options) catch |err| {
                                if (!error_function(current, err)) {
                                    current.message = formatErrorMessage(err);
                                }
                                break :main;
                            };
                            current.message = options.prompt_success;
                        }
                        CommandState.finishCommand();
                    }
                },
                .cancel => {
                    // Free resources here because a "No" doesn't
                    // got through the "Close" button cleanup.
                    CommandState.finishCommand();
                    CommandState.freeResources();
                },
                else => unreachable,
            }
        }
    };
}

test "directory list handler" {
    const LocalDirEntry = @import("commands.zig").LocalDirEntry;
    var directories = [_]DirectoryEntry{
        .init(.{ .local = LocalDirEntry{ .filename = "test", .extension = "txt", .full_filename = "test.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test2", .extension = "txt", .full_filename = "test2.txt", .size = 999 } }),
    };
    for (&directories) |*dir| {
        dir.checked = true;
    }
    const handler = newDirectoryListHandler(
        struct {
            pub fn testAction(file: *DirectoryEntry) anyerror!void {
                _ = file;
            }
        }.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
        },
    );
    CommandState.current_command = .get;

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test2.txt", CommandState.currentFile().?.filename);

    try handler.process(&directories);
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

test "prompt for file handler" {
    const handler = newPromptForFileHandler(
        struct {
            pub fn testAction(_: []const u8, _: Options) anyerror!void {}
        }.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
            .input_buttons = .{ .open_file_selector = true },
        },
    );
    CommandState.current_command = .getsys;
    CommandState.file_selector_buffer = "test.img";

    try handler.process();
    try std.testing.expectEqual(.getsys, CommandState.current_command);
    try std.testing.expectEqual(.waiting_for_input, CommandState.state);

    CommandState.state = .confirm;

    try handler.process();
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

test "directory list handler errors" {
    const LocalDirEntry = @import("commands.zig").LocalDirEntry;
    var directories = [_]DirectoryEntry{
        .init(.{ .local = LocalDirEntry{ .filename = "test", .extension = "txt", .full_filename = "test.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test2", .extension = "txt", .full_filename = "test2.txt", .size = 999 } }),
    };
    for (&directories) |*dir| {
        dir.checked = true;
    }

    const local = struct {
        var err_to_return: ?anyerror = null;
        pub fn testAction(_: *DirectoryEntry) anyerror!void {
            if (err_to_return) |err| {
                return err;
            }
        }
    };

    const handler = newDirectoryListHandler(
        local.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
        },
    );
    CommandState.current_command = .get;

    local.err_to_return = std.fs.Dir.MakeError.PathAlreadyExists;
    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.waiting_for_input, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);

    CommandState.state = .confirm;
    local.err_to_return = null;

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test2.txt", CommandState.currentFile().?.filename);

    try handler.process(&directories);
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

test "prompt for file handler errors" {
    const local = struct {
        var err_to_return: ?anyerror = null;
        pub fn testAction(_: []const u8, _: Options) anyerror!void {
            if (err_to_return) |err| {
                return err;
            }
        }
    };
    const handler = newPromptForFileHandler(
        local.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
            .input_buttons = .{ .open_file_selector = true },
        },
    );

    CommandState.current_command = .getsys;
    CommandState.file_selector_buffer = "test.img";

    try handler.process();
    try std.testing.expectEqual(.getsys, CommandState.current_command);
    try std.testing.expectEqual(.waiting_for_input, CommandState.state);

    CommandState.state = .confirm;
    local.err_to_return = std.fs.Dir.MakeError.BadPathName;

    try handler.process();
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

test "directory list handler confirm errors" {
    const LocalDirEntry = @import("commands.zig").LocalDirEntry;
    var directories = [_]DirectoryEntry{
        .init(.{ .local = LocalDirEntry{ .filename = "test", .extension = "txt", .full_filename = "test.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test2", .extension = "txt", .full_filename = "test2.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test3", .extension = "txt", .full_filename = "test3.txt", .size = 999 } }),
    };
    for (&directories) |*dir| {
        dir.checked = true;
    }

    const local = struct {
        var err_to_return: ?anyerror = null;
        pub fn testAction(_: *DirectoryEntry) anyerror!void {
            if (err_to_return) |err| {
                return err;
            }
        }
    };

    const handler = newDirectoryListHandler(
        local.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
        },
    );
    CommandState.current_command = .get;

    local.err_to_return = std.fs.Dir.MakeError.PathAlreadyExists;
    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.waiting_for_input, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);

    CommandState.state = .confirm;
    CommandState.confirm_all = .yes_to_all;

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test2.txt", CommandState.currentFile().?.filename);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test3.txt", CommandState.currentFile().?.filename);

    try handler.process(&directories);
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

test "prompt for file handler cancel" {
    const handler = newPromptForFileHandler(
        struct {
            pub fn testAction(_: []const u8, _: Options) anyerror!void {
                return;
            }
        }.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
            .input_buttons = .{ .open_file_selector = true },
        },
    );

    CommandState.current_command = .getsys;
    CommandState.file_selector_buffer = "test.img";

    try handler.process();
    try std.testing.expectEqual(.getsys, CommandState.current_command);
    try std.testing.expectEqual(.waiting_for_input, CommandState.state);

    CommandState.state = .cancel;
    CommandState.file_selector_buffer = null;

    try handler.process();
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

test "directory list handler cancel errors with skip" {
    const LocalDirEntry = @import("commands.zig").LocalDirEntry;
    var directories = [_]DirectoryEntry{
        .init(.{ .local = LocalDirEntry{ .filename = "test", .extension = "txt", .full_filename = "test.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test2", .extension = "txt", .full_filename = "test2.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test3", .extension = "txt", .full_filename = "test3.txt", .size = 999 } }),
    };
    for (&directories) |*dir| {
        dir.checked = true;
    }

    const local = struct {
        var err_to_return: ?anyerror = null;
        var action_count: usize = 0;
        pub fn testAction(_: *DirectoryEntry) anyerror!void {
            // No to all should keep running the command, but ignore any errors
            // generated.
            action_count += 1;
            if (err_to_return) |err| {
                return err;
            }
        }
    };

    const handler = newDirectoryListHandler(
        local.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
        },
    );
    CommandState.current_command = .get;

    local.err_to_return = std.fs.Dir.MakeError.PathAlreadyExists;
    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.waiting_for_input, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(1, local.action_count);
    CommandState.state = .cancel;
    CommandState.confirm_all = .no_to_all;

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(1, local.action_count);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test2.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(2, local.action_count);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test3.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(3, local.action_count);

    try handler.process(&directories);
    try std.testing.expectEqual(3, local.action_count);
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

test "directory list handler cancel errors no skip" {
    const LocalDirEntry = @import("commands.zig").LocalDirEntry;
    var directories = [_]DirectoryEntry{
        .init(.{ .local = LocalDirEntry{ .filename = "test", .extension = "txt", .full_filename = "test.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test2", .extension = "txt", .full_filename = "test2.txt", .size = 999 } }),
        .init(.{ .local = LocalDirEntry{ .filename = "test3", .extension = "txt", .full_filename = "test3.txt", .size = 999 } }),
    };
    for (&directories) |*dir| {
        dir.checked = true;
    }

    const local = struct {
        var err_to_return: ?anyerror = null;
        var action_count: usize = 0;
        pub fn testAction(_: *DirectoryEntry) anyerror!void {
            // No to all should keep running the command, but ignore any errors
            // generated.
            action_count += 1;
            if (err_to_return) |err| {
                return err;
            }
        }
    };

    const handler = newDirectoryListHandler(
        local.testAction,
        struct {
            pub fn testError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.testError,
        Options{
            .default_to_confirm = false,
            .skip_when_no_to_all = true,
        },
    );
    CommandState.current_command = .get;

    local.err_to_return = std.fs.Dir.MakeError.PathAlreadyExists;
    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.waiting_for_input, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(1, local.action_count);
    CommandState.state = .cancel;
    CommandState.confirm_all = .no_to_all;

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(1, local.action_count);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test2.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(1, local.action_count);

    try handler.process(&directories);
    try std.testing.expectEqual(.get, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
    try std.testing.expectEqualStrings("test3.txt", CommandState.currentFile().?.filename);
    try std.testing.expectEqual(1, local.action_count);

    try handler.process(&directories);
    try std.testing.expectEqual(1, local.action_count);
    try std.testing.expectEqual(.none, CommandState.current_command);
    try std.testing.expectEqual(.processing, CommandState.state);
}

const std = @import("std");
const DirectoryEntry = @import("commands.zig").DirectoryEntry;
const CommandState = @import("CommandState.zig");
const FileStatus = CommandState.FileStatus;
const formatErrorMessage = @import("main.zig").formatErrorMessage;
