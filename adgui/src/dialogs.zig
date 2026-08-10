pub const Dialogs = enum { transfer, open_image, open_local, new, shortcuts, about };
const DialogState = struct {
    open: bool,
    dialog_fn: *const fn (self: *DialogState, *OperationState) void,

    pub fn init(dialog_fn: *const fn (self: *DialogState, *OperationState) void) DialogState {
        return .{
            .open = false,
            .dialog_fn = dialog_fn,
        };
    }
};

var all_dialogs: std.EnumArray(Dialogs, DialogState) = .init(.{
    .transfer = .init(transfer),
    .open_image = .init(openImage),
    .open_local = .init(openLocal),
    .new = .init(new),
    .shortcuts = .init(shortcutKeys),
    .about = .init(about),
});

pub fn displayOpen(state: *OperationState) void {
    std.debug.print("Display Open\n", .{});
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

fn openImage(self: *DialogState, state: *OperationState) void {
    std.debug.assert(state.operation == .open_image);
    if (!self.open) return;

    const operation = &state.operation.open_image;

    const image_path = dvui.native_dialogs.Native.open(state.arena.allocator(), .{
        .filter_description = "Disk image files",
        .filters = &.{ "*.dsk", "*.img" },
        .title = "Open disk image",
    }) catch |err| oom(err) orelse {
        state.endOperation();
        return;
    };
    operation.image_path = image_path;
    state.state = .processing;
}

fn openLocal(self: *DialogState, state: *OperationState) void {
    std.debug.assert(state.operation == .open_local);
    std.debug.assert(state.state == .user_input);
    if (!self.open) return;

    const operation = &state.operation.open_local;

    std.debug.print("path = {s}\n", .{operation.path});
    const folder = dvui.native_dialogs.Native.folderSelect(state.arena.allocator(), .{
        .title = "Open local directory",
        .path = operation.path,
    }) catch |err| oom(err) orelse {
        state.endOperation();
        return;
    };
    operation.path = folder;
    state.state = .processing;
}

fn transfer(self: *DialogState, state: *OperationState) void {
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

    var dialog_win = dialogWindow(@src(), title, self, state, .{ .w = 500, .h = 500 });
    defer dialog_win.deinit();
    // TODO: This is a trap.. if the window closes, the operations is sended and the arena gets pulled down, so need to return.
    if (!self.open) return;

    const wid_dialog = dialog_win.data().id;

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
        pub fn yes(s: *OperationState, result: *TransferResult) void {
            result.recovery = .retry;
            s.state = .processing;
        }
        pub fn no(s: *OperationState) void {
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

pub fn new(self: *DialogState, state: *OperationState) void {
    std.debug.assert(state.operation == .new);
    const op = &state.operation.new;

    if (!self.open) return;

    var dialog_win = dialogWindow(@src(), "Create new disk image", self, state, .{ .w = 500, .h = 500 });
    defer dialog_win.deinit();
    if (!self.open) return;

    const wid_dialog = dialog_win.data().id;
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
            state.endOperation();
        }
    }
}

fn shortcutKeys(self: *DialogState, state: *OperationState) void {
    const Shortcuts = struct {
        const Category = enum { command, file, selection };
        category: Category,
        shortcut: []const u8,
        button: ?[]const u8,
        help_text: []const u8,
    };

    const shortcuts = [_]Shortcuts{
        .{ .category = .command, .shortcut = "ALT-A", .button = "AUTO", .help_text = "Change transfer mode for get." },
        .{ .category = .command, .shortcut = "ALT-C", .button = "CLOSE", .help_text = "Close image file." },
        .{ .category = .command, .shortcut = "ALT-E", .button = "ERASE", .help_text = "Erase selected files." },
        .{ .category = .command, .shortcut = "ALT-F", .button = "INFO", .help_text = "Show technical disk information." },
        .{ .category = .command, .shortcut = "ALT-G", .button = "GET", .help_text = "Get file from image." },
        .{ .category = .command, .shortcut = "ALT-N", .button = "NEW", .help_text = "Create a new disk image." },
        .{ .category = .command, .shortcut = "ALT-P", .button = "PUT", .help_text = "Put file to image." },
        .{ .category = .command, .shortcut = "ALT-R", .button = "ORIENT", .help_text = "Change grid orientation." },
        .{ .category = .command, .shortcut = "ALT-S", .button = "GET SYS", .help_text = "Save CPM operating system tracks." },
        .{ .category = .command, .shortcut = "ALT-U", .button = "USER", .help_text = "Filter by CPM User number." },
        .{ .category = .command, .shortcut = "ALT-X", .button = "EXIT", .help_text = "Exit the application." },
        .{ .category = .selection, .shortcut = "TAB", .button = null, .help_text = "Switch between grids." },
        .{ .category = .selection, .shortcut = "CTRL-A", .button = null, .help_text = "Select / unselect all." },
        .{ .category = .selection, .shortcut = "SPACE", .button = null, .help_text = "Select highlighted file." },
        .{ .category = .selection, .shortcut = "UP", .button = null, .help_text = "Highlight prevous file." },
        .{ .category = .selection, .shortcut = "DOWN", .button = null, .help_text = "Highlight next file." },
        .{ .category = .selection, .shortcut = "PGUP", .button = null, .help_text = "Scroll grid up." },
        .{ .category = .selection, .shortcut = "PGDN", .button = null, .help_text = "Scroll grid down." },
        .{ .category = .file, .shortcut = "ALT-I", .button = null, .help_text = "Type image file name." },
        .{ .category = .file, .shortcut = "ALT-M", .button = null, .help_text = "Browse for image file." },
        .{ .category = .file, .shortcut = "ALT-O", .button = null, .help_text = "Browse for local directory." },
        .{ .category = .file, .shortcut = "ALT-L", .button = null, .help_text = "Type local directory name." },
        .{ .category = .file, .shortcut = "CTRL-C", .button = null, .help_text = "Copy image filenames to clipboard." },
    };
    var dialog_win = dialogWindow(@src(), "Keyboard shortcuts", self, state, null);
    defer dialog_win.deinit();
    if (!self.open) return;

    // var vbox = dvui.box(@src(), .{}, .{ .expand = .both, .margin = .all(5) });
    // defer vbox.deinit();
    var idx: usize = 0;
    {
        var inner_vbox = dvui.box(@src(), .{}, .{ .expand = .vertical, .gravity_x = 0.5 });
        defer inner_vbox.deinit();
        dvui.labelNoFmt(@src(), "Menu Shortcuts", .{}, .{ .font = .theme(.title), .gravity_x = 0.5 });
        while (shortcuts[idx].category == .command) : (idx += 1) {
            const s = &shortcuts[idx];
            dvui.label(@src(), "{s:<10}{s:<10}{s}", .{ s.shortcut, s.button orelse "", s.help_text }, .{ .id_extra = idx, .padding = .all(2) });
        }
    }
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer hbox.deinit();
        {
            var inner_vbox = dvui.box(@src(), .{}, .{ .expand = .both, .margin = .all(5) });
            defer inner_vbox.deinit();

            dvui.labelNoFmt(@src(), "Navigation Shortcuts", .{}, .{ .font = .theme(.title), .gravity_x = 0.5 });
            while (idx != shortcuts.len and shortcuts[idx].category == .selection) : (idx += 1) {
                const s = &shortcuts[idx];
                dvui.label(@src(), "{s:<10}{s}", .{ s.shortcut, s.help_text }, .{ .id_extra = idx, .padding = .all(2) });
            }
        }
        {
            var inner_vbox = dvui.box(@src(), .{}, .{ .expand = .both, .margin = .all(5) });
            defer inner_vbox.deinit();
            dvui.labelNoFmt(@src(), "File Shortcuts", .{}, .{ .font = .theme(.title), .gravity_x = 0.5 });
            while (idx != shortcuts.len and shortcuts[idx].category == .file) : (idx += 1) {
                const s = &shortcuts[idx];
                dvui.label(@src(), "{s:<10}{s}", .{ s.shortcut, s.help_text }, .{ .id_extra = idx, .padding = .all(2) });
            }
        }
    }
    // _ = dvui.separator(@src(), .{ .expand = .horizontal });
    // if (buttonFocussed(@src(), "Close", .{}, .{ .gravity_x = 0.5 })) {
    //     show_shortcuts = false;
    // }
}

const adgui_version = "TODO";

pub fn about(self: *DialogState, state: *OperationState) void {
    // TODO: Think how to get rid of the double return.
    if (!self.open) return;
    var dialog_win = dialogWindow(@src(), "About ADGUI", self, state, null);
    defer dialog_win.deinit();
    if (!self.open) return;
    dvui.label(@src(), "ADGUI Version: {s}", .{adgui_version}, .{ .expand = .horizontal, .gravity_x = 0.5 });
    // Now add the scroll area which will get the remaining space
    var tl = dvui.textLayout(@src(), .{}, .{ .background = false, .gravity_x = 0.5 });
    tl.addText("\n", .{});

    // Highlight the underline separator if the text is hovered.
    const evts = dvui.events();
    const hovered: bool = blk: {
        for (evts) |*evt| {
            if (evt.evt == .mouse and evt.evt.mouse.action == .position) {
                const pos_physical = evt.evt.mouse.p;
                const pos = tl.data().parent.data().contentRectScale().pointFromPhysical(pos_physical);
                if (tl.data().contentRect().contains(pos)) {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };
    const color_url: dvui.Color = .{ .r = 0x35, .g = 0x84, .b = 0xe4 };
    const url = "https://github.com/phatchman/altair_tools";
    if (tl.addTextClick(url, .{
        .color_text = if (!hovered) dvui.themeGet().text else color_url,
    })) |_| {
        _ = dvui.openURL(.{ .url = url });
    }
    const tl_rect = tl.data().contentRect();
    tl.deinit();

    const underline_rect: dvui.Rect = .{ .x = tl_rect.x, .y = tl_rect.y + 35, .h = 1, .w = tl_rect.w };
    _ = dvui.separator(@src(), .{
        .rect = underline_rect,
        .color_fill = if (!hovered) dvui.themeGet().text else color_url,
    });
}

fn dialogWindow(src: std.builtin.SourceLocation, title: []const u8, self: *DialogState, state: *OperationState, size: ?dvui.Size) *dvui.FloatingWindowWidget {
    var dialog_win = dvui.floatingWindow(
        src,
        .{ .modal = true, .open_flag = &self.open },
        .{
            .min_size_content = size,
            .max_size_content = if (size) |s| .cast(s) else null,
        },
    );
    const wid_dialog = dialog_win.data().id;
    dialog_win.dragAreaSet(dvui.windowHeader(title, "", &self.open));

    const label = switch (state.state) {
        .processing, .user_input => "Cancel",
        .completed => "Close",
    };
    var button_box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 1.0 });
    defer button_box.deinit();
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    var button_wd: dvui.WidgetData = undefined;
    if (dvui.button(@src(), label, .{}, .{ .gravity_x = 0.5, .gravity_y = 1.0, .data_out = &button_wd, .tab_index = 1 })) {
        self.open = false;
        state.endOperation();
        return dialog_win;
    }
    var close_focused = dvui.dataGetDefault(null, wid_dialog, "close_focused", bool, false);
    defer dvui.dataSet(null, wid_dialog, "close_focused", close_focused);
    if (state.state == .completed and !close_focused) {
        close_focused = true;
        dvui.focusWidget(button_wd.id, null, null);
        dvui.refresh(null, @src(), null);
    }
    return dialog_win;
}

pub fn oom(_: error{OutOfMemory}) noreturn {
    @panic("Out of memory error");
}

const app = @import("app.zig");
const operations = @import("operations.zig");
const OperationState = operations.OperationState;
const TransferResult = operations.TransferResult;
const std = @import("std");
const dvui = @import("dvui");
const DiskInterface = @import("DiskInterface.zig");
