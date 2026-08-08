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
        self.operation.end(self);
        self.operation = .none;
        self.state = .completed;
        self.err = null;
        _ = self.arena.reset(.free_all);
    }

    pub fn process(self: *OperationState) void {
        //        std.debug.print("op = {}, state = {}\n", .{ self.operation, self.state });
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
    get: GetOperation,
    put,
    erase,
    info,
    new: NewOperation,

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

    pub fn init(path: ?[]u8, path_buf: []u8) OpenImageOperation {
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

// TODO: Fix issue with initial path.
const OpenLocalOperation = struct {
    initial_path: ?[]const u8,
    path_buffer: []u8,
    path: []const u8,

    pub fn init(init_path: ?[]const u8, path_buffer: []u8) OpenLocalOperation {
        return .{
            .initial_path = init_path,
            .path_buffer = path_buffer,
            .path = init_path orelse "",
        };
    }

    pub fn begin(self: *OpenLocalOperation, state: *OperationState) void {
        if (self.initial_path) |_| {
            state.state = .processing;
        } else {
            dialogs.show(.open_local);
            state.state = .user_input;
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
    image_path: ?[]const u8 = null,
    image_type: ?*const DiskInterface.DiskImageType = null,

    pub const init: NewOperation = .{
        .image_path = null,
        .image_type = null,
    };

    pub fn begin(_: *NewOperation, state: *OperationState) void {
        dialogs.show(.new);
        state.state = .user_input;
    }

    pub fn process(self: *NewOperation, state: *OperationState) void {
        // TODO: Labeling.
        std.debug.print("new operation: process\n", .{});
        state.disk_interface.createNewImage(state.io, self.image_path.?, self.image_type.?, null) catch |err| {
            state.err = .{
                .message = std.fmt.allocPrint(
                    state.arena.allocator(),
                    "Error creating new disk image: {t}",
                    .{err},
                ) catch |e| oom(e),
                .err = err,
            };
            return;
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
        };

        state.state = .completed;
    }

    pub fn end(_: *NewOperation, _: *OperationState) void {
        dialogs.hide(.new);
    }
};

pub const TransferResult = struct {
    const Result = enum { ok, err, err_retryable };
    filename: []const u8,
    result: Result,
    err: ?DiskInterface.GetFileError = null,
    message: []const u8 = "",
    recovery: enum { skip, retry } = .skip,
};

pub const GetOperation = struct {
    dir_idx: usize,
    transfer_result: std.ArrayList(TransferResult),
    dirty: bool,

    pub const init: GetOperation = .{
        .dir_idx = 0,
        .transfer_result = .empty,
        .dirty = false,
    };

    pub fn begin(self: *GetOperation, state: *OperationState) void {
        state.state = .processing;
        const selected_count = count: {
            var selected_count: usize = 0;
            for (state.disk_interface.image_dir.directory_list.items) |*dir| {
                if (dir.selected) selected_count += 1;
            }
            break :count selected_count;
        };
        if (selected_count > 0) {
            self.transfer_result = std.ArrayList(TransferResult).initCapacity(state.arena.allocator(), state.disk_interface.image_dir.directory_list.items.len) catch |err| oom(err);
            dialogs.show(.transfer);
        } else {
            state.err = .{
                .message = "Select at least one image file to get",
                .err = error.User,
            };
        }
    }

    pub fn process(self: *GetOperation, state: *OperationState) void {
        const directories = state.disk_interface.image_dir.directory_list.items;

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
        while (self.dir_idx != directories.len) : (self.dir_idx += 1) {
            if (directories[self.dir_idx].selected) {
                // TODO: Would pass -force if the recovery mode is retry.
                //                    state.disk_interface.getFile(io, &directories[self.dir_idx], ".", .AUTO, false) catch unreachable;

                if (self.dir_idx % 3 == 0 and !retry) {
                    self.transfer_result.appendAssumeCapacity(.{ .filename = directories[self.dir_idx].filenameAndExtension(), .result = .err, .err = error.PathAlreadyExists, .message = "File already exists" });
                    state.state = .user_input;
                } else if (self.dir_idx % 5 == 0 and !retry) {
                    self.transfer_result.appendAssumeCapacity(.{ .filename = directories[self.dir_idx].filenameAndExtension(), .result = .err, .err = error.DiskQuota, .message = "Disk quota" });
                    self.dir_idx += 1;
                } else {
                    self.transfer_result.appendAssumeCapacity(.{ .filename = directories[self.dir_idx].filenameAndExtension(), .result = .ok });
                    self.dir_idx += 1;
                }
                self.dirty = true;
                return;
            }
        }
        state.state = .completed;
        return;
    }

    pub fn end(_: GetOperation, _: *OperationState) void {
        dialogs.hide(.transfer);
    }
};

pub fn oom(_: error{OutOfMemory}) noreturn {
    @panic("Out of memory error");
}

const DiskInterface = @import("DiskInterface.zig");
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("dialogs.zig");
