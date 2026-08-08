const Dialogs = enum { transfer, open, new };
const DialogState = struct {
    open: bool,
    dialog_fn: *const fn (self: *DialogState, *CommandState) void,

    pub fn init(dialog_fn: *const fn (self: *DialogState, *CommandState) void) DialogState {
        return .{
            .open = false,
            .dialog_fn = dialog_fn,
        };
    }
};

var all_dialogs: std.EnumArray(Dialogs, DialogState) = .init(.{
    .transfer = .init(transfer),
    .open = .init(open),
    .new = .init(new),
});

pub fn displayOpen(state: *CommandState) void {
    for (&all_dialogs.values) |*dialog| {
        if (dialog.open) dialog.dialog_fn(dialog, state);
    }
}

pub fn show(d: Dialogs) void {
    std.debug.print("show\n", .{});
    all_dialogs.getPtr(d).open = true;
}

pub fn hide(d: Dialogs) void {
    std.debug.print("hide\n", .{});
    all_dialogs.getPtr(d).open = false;
}

fn open(self: *DialogState, state: *CommandState) void {
    std.debug.assert(state.operation == .open);
    if (!self.open) return;

    const operation = &state.operation.open;

    if (state.state == .user_input) {
        // TODO: Move the gpa into CommandState.
        operation.image_path = dvui.native_dialogs.Native.open(state.arena.allocator(), .{
            .filter_description = "Disk image files",
            .filters = &.{ "*.dsk", "*.img" },
            .title = "Open disk image",
        }) catch oom();
        state.state = .processing;
    }
}

fn transfer(self: *DialogState, state: *CommandState) void {
    std.debug.assert(state.operation == .get);
    if (!self.open) return;
    const title = switch (state.operation) {
        .get => "Copy files from disk image",
        .put => "Copy files to disk image",
        else => unreachable,
    };
    const transfer_results = switch (state.operation) {
        .get => |op| op.transfer_result.items,
        else => unreachable,
    };

    const dirty = switch (state.operation) {
        .get => |*op| &op.dirty,
        else => unreachable,
    };

    var dialog_win = dvui.floatingWindow(
        @src(),
        .{ .modal = true, .open_flag = &self.open },
        .{
            .min_size_content = .{ .w = 500, .h = 500 },
            .max_size_content = .{ .w = 500, .h = 500 },
        },
    );
    defer dialog_win.deinit();
    const wid_dialog = dialog_win.data().id;
    dialog_win.dragAreaSet(dvui.windowHeader(title, "", &self.open));

    const label = switch (state.state) {
        .processing, .user_input => "Cancel",
        .completed => "Close",
    };
    var button_wd: dvui.WidgetData = undefined;
    if (dvui.button(@src(), label, .{}, .{ .gravity_x = 0.5, .gravity_y = 1.0, .data_out = &button_wd, .tab_index = 1 })) {
        state.endCommand();
        return;
    }
    var close_focused = dvui.dataGetDefault(null, wid_dialog, "close_focused", bool, false);
    defer dvui.dataSet(null, wid_dialog, "close_focused", close_focused);
    if (state.state == .completed and !close_focused) {
        close_focused = true;
        dvui.focusWidget(button_wd.id, null, null);
        dvui.refresh(null, @src(), null);
    }
    var scroll_info = dvui.dataGetDefault(null, wid_dialog, "si", dvui.ScrollInfo, .{});
    defer dvui.dataSet(null, wid_dialog, "si", scroll_info);
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &scroll_info }, .{
        .expand = .both,
        .min_size_content = .{ .w = 500, .h = 500 },
        .max_size_content = .{ .w = 500, .h = 500 },
    });
    defer {
        // Scroll to bottom must be done after deinit() so it applies next frame.
        scroll.deinit();
        if (dirty.*) {
            scroll_info.scrollToOffset(.vertical, std.math.floatMax(f32));
            dirty.* = false;
        }
    }

    var yes_to_all = dvui.dataGetDefault(null, wid_dialog, "yes_to_all", bool, false);
    defer dvui.dataSet(null, wid_dialog, "yes_to_all", yes_to_all);
    var no_to_all = dvui.dataGetDefault(null, wid_dialog, "no_to_all", bool, false);
    defer dvui.dataSet(null, wid_dialog, "no_to_all", no_to_all);

    var yes_focused = dvui.dataGetDefault(null, wid_dialog, "yes_focused", bool, false);
    defer dvui.dataSet(null, wid_dialog, "yes_focused", yes_focused);

    const actions = struct {
        pub fn yes(s: *CommandState, result: *TransferResult) void {
            result.recovery = .retry;
            s.state = .processing;
        }
        pub fn no(s: *CommandState) void {
            s.state = .processing;
        }
    };

    const focused_id = dvui.lastFocusedIdInFrame();
    for (transfer_results, 0..) |*result, i| {
        var wid_yes: dvui.Id = .zero;
        var wid_yesall: dvui.Id = .zero;
        var wid_no: dvui.Id = .zero;
        var wid_noall: dvui.Id = .zero;

        dvui.label(@src(), "* {s}: {t} [{s}]", .{ result.filename, result.result, (if (result.result == .err) result.message else "") }, .{ .id_extra = i });

        if (state.state == .user_input and result.result == .err and i == transfer_results.len - 1) switch (result.err.?) {
            error.PathAlreadyExists => {
                var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                defer hbox.deinit();

                var fg = dvui.focusGroup(@src(), .{ .nav_key_dir = .horizontal }, .{});
                defer fg.deinit();

                dvui.labelNoFmt(@src(), "Overwrite? ", .{}, .{ .margin = dvui.ButtonWidget.defaults.margin });
                var wd: dvui.WidgetData = undefined;
                if (dvui.button(@src(), "[y]es", .{}, .{ .data_out = &wd }) or
                    yes_to_all)
                {
                    actions.yes(state, result);
                }
                wid_yes = wd.id;
                if (!yes_focused) {
                    dvui.focusWidget(wid_yes, null, null);
                    yes_focused = true;
                }
                if (dvui.button(@src(), "[Y]es to all", .{}, .{ .data_out = &wd })) {
                    actions.yes(state, result);
                    yes_to_all = true;
                }
                wid_yesall = wd.id;
                if (dvui.button(@src(), "[n]o", .{}, .{ .data_out = &wd }) or
                    no_to_all)
                {
                    actions.no(state);
                }
                wid_no = wd.id;
                if (dvui.button(@src(), "[N]o to all", .{}, .{ .data_out = &wd })) {
                    actions.no(state);
                    no_to_all = true;
                }
                wid_noall = wd.id;
                if (dvui.lastFocusedIdInFrameSince(focused_id)) |wid| {
                    for (dvui.events()) |*e| {
                        if (!dvui.eventMatch(e, .{
                            .id = fg.data().id,
                            .r = fg.data().contentRectScale().r,
                            .focus_id = wid,
                        })) continue;
                        switch (e.evt) {
                            .key => |ke| {
                                if (ke.action != .down and (ke.mod != .none or !ke.mod.shiftOnly())) continue;
                                switch (ke.code) {
                                    .y => {
                                        e.handle(@src(), fg.data());
                                        if (ke.mod.shift()) {
                                            yes_to_all = true;
                                            actions.yes(state, result);
                                            dvui.focusWidget(wid_yesall, null, e.num);
                                        } else {
                                            actions.yes(state, result);
                                            dvui.focusWidget(wid_yes, null, e.num);
                                        }
                                    },
                                    .n => {
                                        e.handle(@src(), fg.data());
                                        if (ke.mod.shift()) {
                                            no_to_all = true;
                                            actions.no(state);
                                            dvui.focusWidget(wid_noall, null, e.num);
                                        } else {
                                            actions.no(state);
                                            dvui.focusWidget(wid_no, null, e.num);
                                        }
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                }
            }, // Prompt for overwrite

            // TODO: Turn all of these into nicer errors
            error.UnsupportedTextMode,
            error.InvalidFormat,
            error.InvalidToken,
            error.InvalidRecordNumber,
            error.InvalidTrack,
            error.InvalidSector,
            => actions.no(state), // just report these AltairDiskLib errors

            error.NoSpaceLeft,
            error.PermissionDenied,
            error.SystemResources,
            error.Unexpected,
            error.DiskQuota,
            error.FileTooBig,
            error.InputOutput,
            error.DeviceBusy,
            error.AccessDenied,
            error.BrokenPipe,
            error.NotOpenForWriting,
            error.LockViolation,
            error.WouldBlock,
            error.NoDevice,
            error.FileBusy,
            error.Canceled,
            error.EndOfStream,
            error.ReadFailed,
            error.Unseekable,
            error.IsDir,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SymLinkLoop,
            error.FileNotFound,
            error.NotDir,
            error.ReadOnlyFileSystem,
            error.NetworkNotFound,
            error.NameTooLong,
            error.BadPathName,
            error.PipeBusy,
            error.AntivirusInterference,
            error.FileLocksUnsupported,
            error.WriteFailed,
            => actions.no(state),
        };
    }
}

pub fn new(self: *DialogState, state: *CommandState) void {
    std.debug.assert(state.operation == .new);
    const op = &state.operation.new;

    // TODO: START OF COMMON DIALOG STUFF
    if (!self.open) return;

    var dialog_win = dvui.floatingWindow(
        @src(),
        .{ .modal = true, .open_flag = &self.open },
        .{
            .min_size_content = .{ .w = 500, .h = 500 },
            .max_size_content = .{ .w = 500, .h = 500 },
        },
    );
    defer dialog_win.deinit();
    const wid_dialog = dialog_win.data().id;
    dialog_win.dragAreaSet(dvui.windowHeader("Create new disk image", "", &self.open));

    const label = switch (state.state) {
        .processing, .user_input => "Cancel",
        .completed => "Close",
    };
    var button_wd: dvui.WidgetData = undefined;
    if (dvui.button(@src(), label, .{}, .{ .gravity_x = 0.5, .gravity_y = 1.0, .data_out = &button_wd, .tab_index = 1 })) {
        state.endCommand();
        return;
    }
    var close_focused = dvui.dataGetDefault(null, wid_dialog, "close_focused", bool, false);
    defer dvui.dataSet(null, wid_dialog, "close_focused", close_focused);
    if (state.state == .completed and !close_focused) {
        close_focused = true;
        dvui.focusWidget(button_wd.id, null, null);
        dvui.refresh(null, @src(), null);
    }
    // TODO: END OF COMMON DIALOG STUFF
    var vbox = dvui.box(@src(), .{}, .{ .expand = .both });
    defer vbox.deinit();
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();
        var fmt_choice = dvui.dataGetDefault(null, wid_dialog, "fmt_choice", usize, 0);
        defer dvui.dataSet(null, wid_dialog, "fmt_choice", fmt_choice);

        dvui.labelNoFmt(@src(), "Image type:", .{}, .{});
        if (dvui.dropdown(@src(), &DiskInterface.all_disk_type_names, .{ .choice = &fmt_choice }, .{}, .{})) {
            op.image_type = &DiskInterface.all_disk_types.values[fmt_choice];
        }
        // TODO: Put the proper path in there.
        if (op.image_path == null)
            op.image_path = "c:\\temp\\new.dsk";
    }
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();
        dvui.labelNoFmt(@src(), "Create Image?", .{}, .{});
        const last_focus = dvui.lastFocusedIdInFrame();
        var fg = dvui.focusGroup(@src(), .{ .nav_key_dir = .horizontal }, .{});
        defer fg.deinit();
        var wd: dvui.WidgetData = undefined;
        var yes = dvui.button(@src(), "[y]es", .{}, .{ .data_out = &wd });
        var no = dvui.button(@src(), "[n]o", .{}, .{});
        if (dvui.firstFrame(hbox.data().id)) {
            dvui.focusWidget(wd.id, null, null);
            op.image_type = &DiskInterface.all_disk_types.values[0];
        }

        for (dvui.events()) |*e| {
            switch (e.evt) {
                .key => |ke| {
                    if (dvui.eventMatch(e, .{
                        .id = fg.data().id,
                        .r = fg.data().borderRectScale().r,
                        .focus_id = dvui.lastFocusedIdInFrameSince(last_focus),
                        .debug = true,
                    })) {
                        switch (ke.code) {
                            .y => {
                                if (ke.action == .down and ke.mod == .none) {
                                    e.handle(@src(), fg.data());
                                    yes = true;
                                }
                            },
                            .n => {
                                std.debug.print("N KEY: {}\n", .{ke});
                                if (ke.action == .down and ke.mod == .none) {
                                    e.handle(@src(), fg.data());
                                    std.debug.print("no is true\n", .{});
                                    no = true;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        std.debug.print("{}:{}\n", .{ yes, no });
        if (yes) {
            std.debug.print("yes\n", .{});
            self.open = false;
            state.state = .processing;
        } else if (no) {
            std.debug.print("no\n", .{});
            state.endCommand();
        }
    }
}

pub fn oom() noreturn {
    @panic("Out of memory error");
}

const app = @import("app.zig");
const CommandState = app.CommandState;
const TransferResult = app.TransferResult;
const std = @import("std");
const dvui = @import("dvui");
const DiskInterface = @import("DiskInterface.zig");
