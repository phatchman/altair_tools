pub const OperationState = struct {
    const State = enum { processing, user_input, completed };
    operation: Operation,
    state: State,
    disk_interface: *DiskInterface,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    err: ?struct {
        message: []const u8,
        err: anyerror, // TODO: Make this a restricted error set in future.
        // TODO: We can prob get rid of err and do all of the fancy printing elsewhere?
    },

    pub fn init(io: std.Io, gpa: std.mem.Allocator, disk_interface: *DiskInterface) OperationState {
        return .{
            .operation = .none,
            .state = .completed,
            .disk_interface = disk_interface,
            .io = io,
            .arena = .init(gpa),
            .err = null,
        };
    }

    pub fn beginOperation(self: *OperationState, operation: Operation) void {
        std.debug.assert(operation != .none);
        std.debug.print("Begin {t}\n", .{operation});
        self.operation = operation;
        switch (self.operation) {
            .none => unreachable,
            .put, .erase, .info => {},
            inline else => |*op| {
                op.begin(self);
            },
        }
        const state = self.state;
        std.debug.assert(state == .processing or state == .user_input or state == .completed);
    }

    pub fn endOperation(self: *OperationState) void {
        std.debug.print("End {t}\n", .{self.operation});
        self.operation.end(self);
        self.operation = .none;
        self.state = .completed;
        self.err = null;
        _ = self.arena.reset(.free_all);
    }

    pub fn process(self: *OperationState) void {
        std.debug.print("op = {t}, state = {}\n", .{ self.operation, self.state });
        if (self.operation != .none) {
            if (self.err) |err| {
                dvui.dialog(@src(), .{}, .{
                    .title = "Error!",
                    .message = err.message,
                    .modal = true,
                    .default = .ok,
                });
                self.endOperation();
            } else {
                switch (self.state) {
                    .processing => self.operation.process(self),
                    .user_input, .completed => {},
                }
            }
        }
    }
};

pub const Operation = union(enum) {
    none: void,
    open_image: OpenImageOperation,
    open_local: OpenLocalOperation,
    close: CloseOperation,
    transfer: TransferOperation,
    put,
    erase,
    info,
    new: NewOperation,
    show_dialog: ShowDialogOperation,

    pub fn begin(self: *Operation, state: *OperationState) void {
        switch (self.*) {
            .none, .put, .erase, .info => unreachable,
            inline else => |*op| op.begin(state),
        }
    }

    pub fn process(self: *Operation, state: *OperationState) void {
        switch (self.*) {
            .none, .put, .erase, .info => unreachable,
            inline else => |*op| op.process(state),
        }
    }

    pub fn end(self: *Operation, state: *OperationState) void {
        switch (self.*) {
            .none => {},
            .put, .erase, .info => unreachable,
            inline else => |*op| op.end(state),
        }
    }
};

const OpenImageOperation = struct {
    image_path: ?[]const u8,
    path_buf: []u8,

    pub fn init(path: ?[]const u8, path_buf: []u8) OpenImageOperation {
        return .{
            .image_path = path,
            .path_buf = path_buf,
        };
    }

    pub fn begin(self: *OpenImageOperation, state: *OperationState) void {
        if (self.image_path) |_| {
            state.state = .processing;
        } else {
            dialogs.show(.open_image);
            state.state = .user_input;
        }
    }

    pub fn process(self: *OpenImageOperation, state: *OperationState) void {
        self.processFallible(state) catch |err| {
            state.err = .{
                .message = std.fmt.allocPrint(state.arena.allocator(), "Error opening image: {t}", .{err}) catch |e| oom(e),
                .err = err,
            };
            state.state = .completed;
            return;
        };
        state.endOperation();
    }

    fn processFallible(self: *OpenImageOperation, state: *OperationState) !void {
        const image_type = try state.disk_interface.detectImageType(state.io, self.image_path.?);
        if (image_type) |it| {
            try state.disk_interface.openExistingImage(state.io, self.image_path.?, it);
        } else {
            return error.UnknownImageType;
        }
    }

    pub fn end(_: *OpenImageOperation, _: *OperationState) void {
        dialogs.hide(.open_image);
    }
};

const OpenLocalOperation = struct {
    path_buffer: []u8,
    path: []const u8,
    prompt_user: bool,

    pub fn init(
        // `prompt` prompts user for new path, using passed path as default
        // `given`. path is used directly without prompting.
        path: union(enum) { prompt: []const u8, given: []const u8 },
        path_buffer: []u8,
    ) OpenLocalOperation {
        switch (path) {
            .prompt => |p| {
                return .{
                    .path_buffer = path_buffer,
                    .path = p,
                    .prompt_user = true,
                };
            },
            .given => |p| {
                return .{
                    .path_buffer = path_buffer,
                    .path = p,
                    .prompt_user = false,
                };
            },
        }
    }

    pub fn begin(self: *OpenLocalOperation, state: *OperationState) void {
        if (self.prompt_user) {
            dialogs.show(.open_local);
            state.state = .user_input;
        } else {
            state.state = .processing;
        }
    }

    pub fn process(_: *OpenLocalOperation, state: *OperationState) void {
        std.debug.assert(state.operation == .open_local);
        const operation = &state.operation.open_local;
        state.disk_interface.openLocalDirectory(state.io, operation.path) catch |err| {
            state.err = .{
                .message = std.fmt.allocPrint(state.arena.allocator(), "Error opening directory {s}: {t}", .{ operation.path, err }) catch |e| oom(e),
                .err = err,
            };
            state.state = .completed;
            return;
        };
        state.endOperation();
    }

    pub fn end(_: *OpenLocalOperation, _: *OperationState) void {
        dialogs.hide(.open_local);
    }
};

pub const CloseOperation = struct {
    pub fn begin(_: *CloseOperation, state: *OperationState) void {
        state.disk_interface.closeImage(state.io);
        state.endOperation();
    }

    pub fn process(_: *CloseOperation, _: *OperationState) void {
        unreachable;
    }

    pub fn end(_: *CloseOperation, _: *OperationState) void {}
};

pub const NewOperation = struct {
    init_path: []const u8,
    image_path: ?[]const u8 = null,
    image_type: ?*const DiskInterface.DiskImageType = null,

    pub fn init(init_path: []const u8) NewOperation {
        return .{
            .init_path = init_path,
            .image_path = null,
            .image_type = null,
        };
    }

    pub fn begin(self: *NewOperation, state: *OperationState) void {
        dialogs.show(.new);
        state.state = .user_input;
        // TODO: Scan and find the first free entry.
        self.image_path = std.fs.path.join(
            state.arena.allocator(),
            &.{ self.init_path, "IMG000.DSK" },
        ) catch |err| oom(err);
    }

    pub fn process(self: *NewOperation, state: *OperationState) void {
        // TODO: Labeling.
        std.debug.print("new operation: process\n", .{});
        // TODO: Check that image doesn't already exist and force overwrite if so.
        // TODO: Pass force flag correctly.
        create: {
            state.disk_interface.createNewImage(state.io, self.image_path.?, self.image_type.?, null, false) catch |err| {
                state.err = .{
                    .message = std.fmt.allocPrint(
                        state.arena.allocator(),
                        "Error creating new disk image: {t}",
                        .{err},
                    ) catch |e| oom(e),
                    .err = err,
                };
                break :create;
            };

            state.disk_interface.openExistingImage(state.io, self.image_path.?, self.image_type.?.type_id) catch |err| {
                state.err = .{
                    .message = std.fmt.allocPrint(
                        state.arena.allocator(),
                        "Error creating new disk image: {t}",
                        .{err},
                    ) catch |e| oom(e),
                    .err = err,
                };
                break :create;
            };
            state.state = .completed;
        }
    }

    pub fn end(_: *NewOperation, _: *OperationState) void {
        dialogs.hide(.new);
    }
};

pub const TransferResult = struct {
    const Result = enum { ok, err, skipped };
    filename: []const u8,
    result: Result,
    err: ?(DiskInterface.GetFileError || DiskInterface.PutFileError) = null,
    message: []const u8 = "",
    recovery: enum { skip, retry } = .skip,
};

pub const TransferOperation = struct {
    const TransferType = enum { get, put, erase };
    dir_idx: usize,
    cpm_user: ?u8,
    copy_mode: DiskInterface.CopyMode,
    transfer_type: TransferType,
    transfer_result: std.ArrayList(TransferResult),
    directories: []DiskInterface.DirectoryEntry,
    skip_remaining: bool,
    dirty: bool,

    pub fn init(directories: []DiskInterface.DirectoryEntry, transfer_type: TransferType, copy_mode: DiskInterface.CopyMode, cpm_user: ?u8) TransferOperation {
        return .{
            .dir_idx = 0,
            .copy_mode = copy_mode,
            .cpm_user = cpm_user,
            .transfer_type = transfer_type,
            .transfer_result = .empty,
            .directories = directories,
            .skip_remaining = false,
            .dirty = false,
        };
    }

    pub fn begin(self: *TransferOperation, state: *OperationState) void {
        state.state = .processing;
        self.transfer_result = std.ArrayList(TransferResult).initCapacity(state.arena.allocator(), self.directories.len) catch |err| oom(err);
        dialogs.show(.transfer);
    }

    pub fn process(self: *TransferOperation, state: *OperationState) void {
        // Check if the last transfer was in error and if it needs to be retried.
        const transfer_results = self.transfer_result.items;
        const retry = retry: {
            if (transfer_results.len > 0) {
                const result = &transfer_results[transfer_results.len - 1];
                if (result.result == .err) {
                    switch (result.recovery) {
                        .skip => {
                            self.dir_idx += 1;
                            break :retry false;
                        },
                        .retry => {
                            _ = self.transfer_result.pop();
                            break :retry true;
                        },
                    }
                }
            }
            break :retry false;
        };
        while (self.dir_idx != self.directories.len) : (self.dir_idx += 1) {
            if (self.directories[self.dir_idx].selected) {
                self.dirty = true;
                // TODO: Would pass -force if the recovery mode is retry.
                //                    state.disk_interface.getFile(io, &directories[self.dir_idx], ".", .AUTO, false) catch unreachable;
                switch (self.transfer_type) {
                    .get => {
                        if (self.dir_idx % 3 == 0 and !retry) {
                            self.transfer_result.appendAssumeCapacity(.{ .filename = self.directories[self.dir_idx].filenameAndExtension(), .result = .err, .err = error.PathAlreadyExists, .message = "File already exists" });
                            state.state = .user_input;
                        } else if (self.dir_idx % 5 == 0 and !retry) {
                            self.transfer_result.appendAssumeCapacity(.{ .filename = self.directories[self.dir_idx].filenameAndExtension(), .result = .err, .err = error.DiskQuota, .message = "Disk quota" });
                            self.dir_idx += 1;
                        } else {
                            self.transfer_result.appendAssumeCapacity(.{ .filename = self.directories[self.dir_idx].filenameAndExtension(), .result = .ok });
                            self.dir_idx += 1;
                        }
                    },
                    .put => {
                        // TODO: Prob remove this.. Just report Disk Full and stop.
                        if (self.skip_remaining) {
                            self.transfer_result.appendAssumeCapacity(.{
                                .filename = self.directories[self.dir_idx].filenameAndExtension(),
                                .result = .skipped,
                            });
                            self.dir_idx += 1;
                            return;
                        }
                        state.disk_interface.putFile(state.io, self.directories[self.dir_idx].filenameAndExtension(), state.disk_interface.local_dir.path, self.cpm_user, self.copy_mode, retry) catch |err| {
                            switch (err) {
                                error.PathAlreadyExists => {
                                    self.transfer_result.appendAssumeCapacity(.{
                                        .filename = self.directories[self.dir_idx].filenameAndExtension(),
                                        .result = .err,
                                        .err = err,
                                        .message = "File already exists",
                                    });
                                    state.state = .user_input;
                                    return;
                                },
                                error.ReadOnlySupport => {
                                    self.transfer_result.appendAssumeCapacity(.{
                                        .filename = self.directories[self.dir_idx].filenameAndExtension(),
                                        .result = .err,
                                        .err = err,
                                        .message = "Image type only supports reading",
                                    });
                                    state.state = .completed;
                                    return;
                                },
                                error.OutOfExtents, error.OutOfAllocs => {
                                    const message = std.fmt.allocPrint(state.arena.allocator(), "Disk Full: {t}", .{err}) catch |e| oom(e);
                                    self.transfer_result.appendAssumeCapacity(.{
                                        .filename = self.directories[self.dir_idx].filenameAndExtension(),
                                        .result = .err,
                                        .err = err,
                                        .message = message,
                                    });
                                    state.state = .completed;
                                    return;
                                },
                                else => {
                                    self.transfer_result.appendAssumeCapacity(.{
                                        .filename = self.directories[self.dir_idx].filenameAndExtension(),
                                        .result = .err,
                                        .err = null, // TODO: Need to expand error set? Or not use errors
                                        .message = @errorName(err),
                                    });
                                    self.dir_idx += 1;
                                    return;
                                },
                            }
                        };
                        self.transfer_result.appendAssumeCapacity(.{
                            .filename = self.directories[self.dir_idx].filenameAndExtension(),
                            .result = .ok,
                        });
                        self.dir_idx += 1;
                        return;
                    },
                    .erase => {
                        state.disk_interface.eraseFile(&self.directories[self.dir_idx]) catch |err| {
                            self.transfer_result.appendAssumeCapacity(
                                .{
                                    .filename = self.directories[self.dir_idx].filenameAndExtension(),
                                    .result = .err,
                                    .err = null, // TODO: Need to expand error set? Or not use errors
                                    .message = @errorName(err),
                                },
                            );
                            self.dir_idx += 1;
                            return;
                        };
                        self.transfer_result.appendAssumeCapacity(
                            .{
                                .filename = self.directories[self.dir_idx].filenameAndExtension(),
                                .result = .ok,
                            },
                        );
                        self.dir_idx += 1;
                    },
                }
                std.debug.print("dirty return\n", .{});
                return;
            }
        }
        std.debug.print("completed return\n", .{});
        state.state = .completed;
        return;
    }

    pub fn end(self: *TransferOperation, state: *OperationState) void {
        // Unselect any relevant selections
        const to_unselect = switch (self.transfer_type) {
            .get, .erase => state.disk_interface.image_dir.directory_list.items,
            .put => state.disk_interface.local_dir.directory_list.items,
        };
        for (to_unselect) |*dir| {
            dir.selected = false;
        }
        // Rebuild the directory list as it has changed.
        switch (self.transfer_type) {
            .put, .erase => state.disk_interface.loadImageDirectory() catch |err| {
                const message = std.fmt.allocPrint(state.arena.allocator(), "Error loading image directory: {t}", .{err}) catch unreachable;
                state.err = .{
                    .message = message,
                    .err = err,
                };
            },
            .get => state.disk_interface.loadLocalDirectory(state.io) catch |err| {
                const message = std.fmt.allocPrint(state.arena.allocator(), "Error loading local directory: {t}", .{err}) catch unreachable;
                state.err = .{
                    .message = message,
                    .err = err,
                };
            },
        }
        dialogs.hide(.transfer);
    }
};

pub const ShowDialogOperation = struct {
    dialog_to_show: dialogs.Dialogs,

    pub fn init(dialog_to_show: dialogs.Dialogs) ShowDialogOperation {
        return .{
            .dialog_to_show = dialog_to_show,
        };
    }

    pub fn begin(self: *ShowDialogOperation, state: *OperationState) void {
        dialogs.show(self.dialog_to_show);
        state.state = .completed;
    }

    pub fn process(_: *ShowDialogOperation, _: *OperationState) void {
        unreachable;
    }

    pub fn end(self: *ShowDialogOperation, _: *OperationState) void {
        dialogs.hide(self.dialog_to_show);
    }
};

pub fn oom(_: error{OutOfMemory}) noreturn {
    @panic("Out of memory error");
}

const DiskInterface = @import("DiskInterface.zig");
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("dialogs.zig");
