const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const window_icon_png = @embedFile("zig-favicon.png");
const Commands = @import("commands.zig");
const DirectoryEntry = Commands.DirectoryEntry;
const GridWidget = dvui.GridWidget;

var commands: Commands = .{};

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "ADGUI Grid Proto",
            .icon = window_icon_png,
            .window_init_options = .{
                .theme = @import("terminal_theme.zig").theme,
            },
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;
var io: std.Io = undefined;
var gpa: std.mem.Allocator = undefined;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

pub fn appInit(_: *dvui.Window) !void {
    io = dvui.App.main_init.?.io;
    gpa = dvui.App.main_init.?.gpa;
    const arena = dvui.App.main_init.?.arena.allocator();
    const args = try dvui.App.main_init.?.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--debug")) {
        dvui.debug.open = true;
    }

    commands.openTestImage(io) catch |err| {
        std.debug.print("Error opening test image: {t}\n", .{err});
    };
    // TODO: Make this a proper init;
    command_state.disk_interface = &commands;
    command_state.arena = .init(gpa);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    command_state.cancelCommand();
    commands.deinit(gpa, io);
}

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    {
        if (menu()) |res| return res;

        var box = dvui.box(@src(), .{}, .{ .expand = .both, .style = .window, .background = true });
        defer box.deinit();
        if (statusBar()) |res| return res;
        if (content()) |res| return res;
    }
    command_state.process();
    dialogs.displayOpen();

    return .ok;
}

pub fn menu() ?dvui.App.Result {
    var m = dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Exit", .{}, .{}) != null) {
            m.close();
            return .close;
        }
    }

    if (dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Shortcuts", .{}, .{}) != null) {
            m.close();
        }

        if (dvui.menuItemLabel(@src(), "About", .{}, .{}) != null) {
            m.close();
        }
    }
    return null;
}

pub fn content() ?dvui.App.Result {
    const static = struct {
        var image_grid: DirectoryGrid = .init();
    };
    var hbox = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .both });
    defer hbox.deinit();
    {
        var vbox = panel(@src(), .{}, .{ .expand = .both });
        defer vbox.deinit();
        filenameEntryBox(@src(), "Image:");
        static.image_grid.display();
    }
    {
        var vbox = panel(@src(), .{}, .{ .expand = .both });
        defer vbox.deinit();
        filenameEntryBox(@src(), "Local:");
    }

    return null;
}

const GridColumn = struct {
    const Tag = enum(u3) { checked = 0, name, ext, size, used, attribs, user };

    label: []const u8,
    tag: Tag,
    min_width: ?f32 = null,
    fixed: bool = false,

    fn colNrFor(tag: Tag) usize {
        return @intFromEnum(tag);
    }
};

const grid_columns: []const GridColumn = &[_]GridColumn{
    .{ .tag = .checked, .label = "[_]", .fixed = true },
    .{ .tag = .name, .label = "Name", .fixed = true, .min_width = 10 },
    .{ .tag = .ext, .label = "Ext", .fixed = true },
    .{ .tag = .size, .label = "Size", .fixed = true },
    .{ .tag = .used, .label = "Used", .fixed = true },
    .{ .tag = .attribs, .label = "At", .fixed = true },
    .{ .tag = .user, .label = "U", .fixed = true },
};

pub fn sortDirectories(sort_col: usize, direction: GridWidget.SortDirection, dir_entries: []DirectoryEntry) void {
    const sort = struct {
        fn sortAsc(col: GridColumn.Tag, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
            return switch (col) {
                .checked => lhs.selected and !rhs.selected,
                .name => std.mem.order(u8, lhs.filename(), rhs.filename()) == .lt,
                .ext => std.mem.order(u8, lhs.extension(), rhs.extension()) == .lt,
                .size => lhs.fileSizeInB() < rhs.fileSizeInB(),
                .used => lhs.fileUsedInKB() < rhs.fileUsedInKB(),
                .attribs => std.mem.order(u8, lhs.attribs(), rhs.attribs()) == .lt,
                .user => lhs.user() < rhs.user(),
            };
        }

        fn sortDesc(col: GridColumn.Tag, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
            return switch (col) {
                .checked => !lhs.selected and rhs.selected,
                .name => std.mem.order(u8, lhs.filename(), rhs.filename()) == .gt,
                .ext => std.mem.order(u8, lhs.extension(), rhs.extension()) == .gt,
                .size => lhs.fileSizeInB() > rhs.fileSizeInB(),
                .used => lhs.fileUsedInKB() > rhs.fileUsedInKB(),
                .attribs => std.mem.order(u8, lhs.attribs(), rhs.attribs()) == .gt,
                .user => lhs.user() > rhs.user(),
            };
        }
    };

    switch (direction) {
        .unsorted, .ascending => std.mem.sort(DirectoryEntry, dir_entries, grid_columns[sort_col].tag, sort.sortAsc),
        .descending => std.mem.sort(DirectoryEntry, dir_entries, grid_columns[sort_col].tag, sort.sortDesc),
    }
}

const static_cols: []const usize = blk: {
    var fixed: [grid_columns.len]usize = undefined;
    var fixed_idx: usize = 0;
    for (grid_columns, 0..) |col, idx| {
        if (col.fixed) {
            fixed[fixed_idx] = idx;
            fixed_idx += 1;
        }
    }
    const result = fixed;
    break :blk result[0..fixed_idx];
};

fn statusBar() ?dvui.App.Result {
    const static = struct {
        var alt_key_pressed: bool = false;
    };
    // Check for .alt key regardless of who has focus
    for (dvui.events()) |*e| {
        switch (e.evt) {
            .key => |ke| {
                if (ke.code == .left_alt or ke.code == .right_alt) {
                    static.alt_key_pressed = switch (ke.action) {
                        .down, .repeat => true,
                        .up => false,
                    };
                }
            },
            else => {},
        }
    }

    var hbox = panel(@src(), .{ .dir = .horizontal, .equal_space = true }, .{});
    defer hbox.deinit();

    var label_buf: [32]u8 = undefined;
    const label = if (filter_user) |user|
        std.fmt.bufPrint(&label_buf, "USER {d}", .{user}) catch unreachable
    else
        std.fmt.bufPrint(&label_buf, "USER *", .{}) catch unreachable;

    if (statusBarButton(@src(), "GET", .g, 1, static.alt_key_pressed)) {
        button_handlers.get();
    }
    if (statusBarButton(@src(), label, .u, 1, static.alt_key_pressed)) {
        if (filter_user) |_| {
            filter_user.? += 1;
            if (filter_user == 16) filter_user = null;
        } else {
            filter_user = 0;
        }
        if (filter_user) |filter| {
            for (commands.image_directory_list.items) |*dir_entry| {
                if (dir_entry.user() != filter) dir_entry.selected = false;
            }
        }
    }
    if (statusBarButton(@src(), "EXIT", .x, 2, static.alt_key_pressed)) {
        return .close;
    }
    return null;
}

fn panel(src: std.builtin.SourceLocation, init_opts: dvui.BoxWidget.InitOptions, opts: dvui.Options) *dvui.BoxWidget {
    const defaults: dvui.Options = .{
        .expand = .horizontal,
        .border = .all(1),
        .gravity_y = 1,
        .corners = .round(5),
    };
    return dvui.box(src, init_opts, defaults.override(opts));
}

var filter_user: ?u8 = null;

fn statusBarButton(
    src: std.builtin.SourceLocation,
    label: []const u8,
    shortcut_key: dvui.enums.Key,
    shortcut_char_pos: u32,
    alt_key_pressed: bool,
) bool {
    const char_width = dvui.themeGet().font_mono.sizeM(1, 1).w;
    const x_offset: f32 = char_width * @as(f32, @floatFromInt(shortcut_char_pos));
    var wd: dvui.WidgetData = undefined;
    var box = dvui.box(src, .{}, .{});
    defer box.deinit();
    const result = widgets.buttonWithShortcut(@src(), label, .{
        .button = .{},
        .shortcut = shortcut_key,
    }, .{ .data_out = &wd });
    if (alt_key_pressed) {
        _ = dvui.separator(@src(), .{ .expand = .none, .rect = .{
            .x = x_offset + 3,
            .y = wd.contentRect().x + wd.contentRect().h - wd.options.padding.?.h + 4,
            .w = char_width,
            .h = 2,
        } });
    }
    return result;
}

fn filenameEntryBox(src: std.builtin.SourceLocation, label: []const u8) void {
    var hbox = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer hbox.deinit();
    dvui.labelNoFmt(@src(), label, .{ .align_y = 0.5 }, .{ .margin = dvui.TextEntryWidget.defaults.margin });
    var te = dvui.textEntry(@src(), .{}, .{ .expand = .horizontal });
    defer te.deinit();
}

const DirectoryGrid = struct {
    const SelectMode = enum { none, select_all, select_none };
    all_selected: bool,
    shift_key_pressed: bool,
    selection: struct {
        const Selection = @This();

        mode: SelectMode,
        first_idx: ?usize,
        second_idx: ?usize,

        pub fn set(self: *Selection, row_index: usize, should_select: bool, is_shift_pressed: bool) void {
            if (!is_shift_pressed or self.first_idx == null) {
                // Single select or shift held on first selection
                self.first_idx = row_index;
                self.second_idx = row_index;
                self.mode = if (should_select) .select_all else .select_none;
            } else {
                // Shift-select
                self.second_idx = row_index;
                self.mode = if (should_select) .select_all else .select_none;
            }
        }

        pub fn setAll(self: *Selection, mode: SelectMode, count: usize) void {
            self.* = .{
                .mode = mode,
                .first_idx = 0,
                .second_idx = count,
            };
        }

        fn inRange(self: Selection, row_index: usize) bool {
            const start = self.first_idx orelse 0;
            const end = self.second_idx orelse 0;
            if (start <= end) {
                return row_index >= start and row_index <= end;
            } else {
                return row_index >= end and row_index <= start;
            }
        }
    },

    pub fn init() DirectoryGrid {
        return .{
            .all_selected = false,
            .shift_key_pressed = false,
            .selection = .{
                .mode = .none,
                .first_idx = null,
                .second_idx = null,
            },
        };
    }

    fn display(self: *DirectoryGrid) void {
        const last_focus = dvui.lastFocusedIdInFrame();
        var grid = dvui.grid(@src(), .{ .cols_rigid = static_cols }, .{ .expand = .both, .border = .all(0) });
        defer grid.deinit();

        // TODO: This is a hack for now
        const dir_listing: []DirectoryEntry = if (dvui.firstFrame(grid.data().id))
            commands.directoryListing(gpa) catch @panic("TODO")
        else
            commands.image_directory_list.items;

        self.processKbEventsPre();

        if (dvui.firstFrame(grid.data().id)) {
            grid.sort_col = GridColumn.colNrFor(.name);
            grid.sort_dir = .ascending;
        }

        var dir_itr = Commands.DirectoryIterator(dir_listing, struct {
            pub fn selected(entry: *const DirectoryEntry) bool {
                if (filter_user) |user| {
                    return entry.user() == user;
                } else {
                    return true;
                }
            }
        }.selected);

        const row_count = dir_itr.count();
        self.displayHeaders(grid, dir_listing, row_count);

        const current_row = grid.cursor.row;
        const selection_changed = rowHighlight(grid);
        const cursor_changed = current_row != grid.cursor.row or selection_changed;
        self.displayBody(grid, &dir_itr, cursor_changed, selection_changed);

        if (dvui.lastFocusedIdInFrameSince(last_focus)) |wid| {
            self.processKbEventsPost(grid, wid, row_count);
        }
        {
            self.all_selected = row_count != 0;
            dir_itr.idx = 0;
            var idx: usize = 0;
            while (dir_itr.next()) |dir_item| : (idx += 1) {
                if (self.selection.mode != .none and self.selection.inRange(idx)) {
                    dir_item.selected = self.selection.mode == .select_all;
                }
                if (dir_item.selected == false) self.all_selected = false;
            }
        }
        self.selection.mode = .none;
    }

    fn displayHeaders(self: *DirectoryGrid, grid: *dvui.GridWidget, dir_listing: []DirectoryEntry, displayed_row_count: usize) void {
        for (grid_columns, 0..) |column, col| {
            const cell = grid.colHeader(col, .{});
            defer cell.deinit();
            const min_size: ?dvui.Size = if (column.min_width) |min_width| dvui.themeGet().font_body.sizeM(min_width + 2, 1) else null;
            if (col == 0) {
                const label = if (self.all_selected) "[X]" else "[ ]";
                if (dvui.button(@src(), label, .{}, .{ .gravity_x = 0.5, .margin = .all(0) })) {
                    self.selection.setAll(if (self.all_selected) .select_none else .select_all, displayed_row_count);
                }
            } else {
                if (cell.headerSortable(column.label, .{ .min_size_content = min_size })) |sort_dir| {
                    sortDirectories(col, sort_dir, dir_listing);
                }
                _ = dvui.separator(@src(), .{ .expand = .vertical, .margin = .{ .y = 5, .h = 5 } });
            }
        }
    }

    fn displayBody(self: *DirectoryGrid, grid: *dvui.GridWidget, dir_itr: *Commands.DirIterator, cursor_changed: bool, selection_changed: bool) void {
        var row_idx: usize = 0;
        while (dir_itr.next()) |dir_item| : (row_idx += 1) {
            const row_options: dvui.Options =
                if (grid.cursor.row == row_idx) .{
                    .color_fill = dvui.themeGet().color(.control, .fill_press),
                    .background = true,
                } else .{};

            { // "Checkbox"
                var cell = grid.cell(.{ .col = 0, .row = row_idx }, row_options);
                defer cell.deinit();
                const src = @src();
                const id = dvui.parentGet().extendId(src, 0);
                if ((cursor_changed and grid.cursor.row == row_idx) or cell.grid_focus) {
                    dvui.focusWidget(id, null, null);
                    if (selection_changed)
                        self.selection.set(row_idx, !dir_item.selected, self.shift_key_pressed);
                }
                if (dvui.button(src, if (dir_item.selected) "[X]" else "[ ]", .{ .draw_focus = false }, .{ .background = false, .margin = .all(0), .gravity_x = 0.5 })) {
                    self.selection.set(row_idx, !dir_item.selected, self.shift_key_pressed);
                }
            }
            { // Name
                var cell = grid.cell(.{ .col = 1, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.labelNoFmt(@src(), dir_item.filename(), .{}, .{ .gravity_y = 0.5 });
            }
            { // Ext
                var cell = grid.cell(.{ .col = 2, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.labelNoFmt(@src(), dir_item.extension(), .{}, .{});
            }
            { // Size
                var cell = grid.cell(.{ .col = 3, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.label(@src(), "{}B", .{dir_item.fileSizeInB()}, .{ .gravity_x = 1 });
            }
            { // Used
                var cell = grid.cell(.{ .col = 4, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.label(@src(), "{}K", .{dir_item.fileUsedInKB()}, .{ .gravity_x = 1 });
            }
            { // At
                var cell = grid.cell(.{ .col = 5, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.labelNoFmt(@src(), dir_item.attribs(), .{}, .{ .gravity_x = 0.5 });
            }
            { // U
                var cell = grid.cell(.{ .col = 6, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.label(@src(), "{}", .{dir_item.user()}, .{ .gravity_x = 0.5 });
            }
        }
    }

    fn processKbEventsPre(self: *DirectoryGrid) void {
        // Check for .shift key regardless of who has focus
        for (dvui.events()) |*e| {
            switch (e.evt) {
                .key => |ke| {
                    if (ke.code == .left_shift or ke.code == .right_shift) {
                        self.shift_key_pressed = switch (ke.action) {
                            .down, .repeat => true,
                            .up => false,
                        };
                    }
                },
                else => {},
            }
        }
    }

    /// Check for select_all kb event. Must only be called if something in the grid has focus.
    fn processKbEventsPost(self: *DirectoryGrid, grid: *dvui.GridWidget, focus_wid: dvui.Id, nr_rows: usize) void {
        for (dvui.events()) |*e| {
            switch (e.evt) {
                .key => |ke| {
                    if (ke.action == .down and ke.matchBind("select_all")) {
                        if (dvui.eventMatch(e, .{ .id = focus_wid, .r = grid.data().borderRectScale().r })) {
                            e.handle(@src(), grid.data());
                            self.selection.setAll(.select_all, nr_rows);
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Set grid.cursor to the first cell of the highlighted row.
    /// Return true if there was a mouse click on the row.
    fn rowHighlight(grid: *dvui.GridWidget) bool {
        var clicked = false;
        var cell_hovered: ?dvui.GridWidget.Cell = null;
        var controlled_by: enum { keyboard, mouse } = .keyboard;
        grid.ensureBodyScroll();
        const evts = dvui.events();
        for (evts) |*e| {
            if (!dvui.eventMatchSimple(e, grid.data())) continue;

            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .motion) {
                        controlled_by = .mouse;
                    } else if (me.action == .position) {
                        cell_hovered = grid.cellFromPoint(me.p);
                    } else if (false and me.action == .press and me.button.pointer()) {
                        e.handle(@src(), grid.data());
                        dvui.captureMouse(grid.data(), e.num);
                        dvui.dragPreStart(me.button, me.p, .{});
                        if (grid.cellFromPoint(me.p)) |cell| {
                            // move to the checkbox
                            grid.moveCursor(0, cell.row);
                        }
                    } else if (me.action == .motion and me.button.touch()) {
                        if (dvui.captured(grid.data().id)) {
                            if (dvui.dragging(me.p, null)) |_| {
                                dvui.captureMouse(null, e.num);
                                dvui.dragEnd();
                            }
                        }
                    } else if (me.action == .release and me.button.pointer()) {
                        if (dvui.captured(grid.data().id)) {
                            e.handle(@src(), grid.data());
                            dvui.captureMouse(null, e.num);
                            if (grid.cellFromPoint(me.p)) |cell| {
                                if (dvui.dragging(me.p, null)) |_| {
                                    dvui.dragEnd();
                                } else {
                                    grid.moveCursor(0, cell.row);
                                    clicked = true;
                                    dvui.refresh(null, @src(), null);
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
        if (controlled_by == .mouse and cell_hovered != null) {
            grid.moveCursor(0, cell_hovered.?.row);
        } else {
            grid.moveCursor(0, grid.cursor.row);
        }
        return clicked;
    }
};

const button_handlers = struct {
    pub fn get() void {
        command_state.beginCommand(.get);
    }
};

const widgets = struct {
    pub const ButtonShortCutInitOptions = struct {
        button: dvui.ButtonWidget.InitOptions,
        shortcut: dvui.enums.Key,
    };

    /// Create a button that can also be activated with an alt key combination.
    /// Note: Treats all shortcut keys as global, regardless of what widget currently has focus.
    pub fn buttonWithShortcut(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: ButtonShortCutInitOptions, opts: dvui.Options) bool {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(src, init_opts.button, opts);
        bw.processEvents();

        // Check if shortcut was prressed.
        for (dvui.events()) |*e| {
            switch (e.evt) {
                .key => |ke| {
                    if (ke.action == .down and
                        ke.code == init_opts.shortcut and
                        (ke.mod == .none or ke.mod == .lalt or ke.mod == .ralt))
                    {
                        e.handle(@src(), bw.data());
                        bw.click = true;
                    }
                },
                else => {},
            }
        }
        bw.drawBackground();

        const click = bw.clicked();

        dvui.labelNoFmt(@src(), label_str, .{ .align_x = 0.5, .align_y = 0.5 }, opts.strip().override(bw.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
        bw.deinit();

        return click;
    }
};

const TransferResult = struct {
    filename: []const u8,
    result: enum { ok, err, err_retryable },
    err: ?Commands.GetFileError = null,
    message: []const u8 = "", // TODO: Make this into an init.
    recovery: enum { skip, retry } = .skip,
};

const Operation = union(CommandState.OperationType) {
    none: void,
    open,
    close,
    get: struct {
        const GetOperation = @This();

        dir_idx: usize,
        transfer_result: std.ArrayList(TransferResult),

        pub fn init() GetOperation {
            return .{
                .dir_idx = 0,
                .transfer_result = .empty,
            };
        }

        pub fn begin(self: *GetOperation, state: *CommandState) void {
            if (state.disk_interface.image_directory_list.items.len > 0) {
                self.transfer_result = std.ArrayList(TransferResult).initCapacity(state.arena.allocator(), state.disk_interface.image_directory_list.items.len) catch oom();
                dialogs.show(.transfer);
                state.state = .processing;
            } else {
                state.state = .completed;
            }
        }

        pub fn process(self: *GetOperation, state: *CommandState) void {
            const directories = state.disk_interface.image_directory_list.items;

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
                    } else {
                        self.transfer_result.appendAssumeCapacity(.{ .filename = directories[self.dir_idx].filenameAndExtension(), .result = .ok });
                        self.dir_idx += 1;
                    }
                    return;
                }
            }
            state.state = .completed;
            return;
        }

        pub fn cancel(self: GetOperation, state: *CommandState) void {
            _ = self;
            dialogs.hide(.transfer);
            state.state = .completed;
        }

        pub fn err(self: GetOperation, state: *CommandState) void {
            _ = self;
            _ = state;
        }
    },
    put,
    erase,
    info,
    format,

    pub fn begin(self: *Operation, state: *CommandState) void {
        switch (self.*) {
            .none, .open, .close, .put, .erase, .info, .format => unreachable,
            inline else => |*op| op.begin(state),
        }
    }

    pub fn process(self: *Operation, state: *CommandState) void {
        switch (self.*) {
            .none, .open, .close, .put, .erase, .info, .format => unreachable,
            inline else => |*op| op.process(state),
        }
    }

    pub fn cancel(self: Operation, state: *CommandState) void {
        switch (self) {
            .none => {},
            .open, .close, .put, .erase, .info, .format => unreachable,
            inline else => |op| op.cancel(state),
        }
    }

    pub fn err(self: Operation, state: *CommandState) void {
        switch (self) {
            .none, .open, .close, .put, .erase, .info, .format => unreachable,
            inline else => |op| op.err(state),
        }
    }
};

const CommandState = struct {
    const OperationType = enum { none, open, close, get, put, erase, info, format };
    const OperationState = enum { init, processing, user_input, completed };
    operation: Operation = .none,
    state: OperationState = .completed,
    //    options: CommandOptions,
    disk_interface: *Commands,
    arena: std.heap.ArenaAllocator,

    pub fn beginCommand(self: *CommandState, op: OperationType) void {
        std.debug.assert(op != .none);
        self.operation = switch (op) {
            .get => |o| @unionInit(Operation, @tagName(o), .init()),
            inline else => |o| @unionInit(Operation, @tagName(o), {}),
        };
        self.state = .init;
        // TODO: This needs to be initted differently
        self.arena = .init(gpa);
        //        self.options = options;
    }

    // TODO: Need a complete command??
    pub fn cancelCommand(self: *CommandState) void {
        self.operation.cancel(self);
        // TODO: Best place to update state?
        self.operation = .none;
        self.state = .completed;
        _ = self.arena.reset(.free_all);
    }

    pub fn process(self: *CommandState) void {
        if (self.operation != .none) {
            switch (self.state) {
                .init => self.operation.begin(self),
                .processing => self.operation.process(self),
                .user_input => {},
                .completed => {},
            }
        }
    }
};

var command_state: CommandState = .{
    .operation = .none,
    .disk_interface = undefined,
    .arena = undefined,
};

const dialogs = struct {
    const Dialogs = enum { transfer };
    const DialogState = struct {
        open: bool,
        dialog_fn: *const fn (*CommandState) void,

        pub fn init(dialog_fn: *const fn (*CommandState) void) DialogState {
            return .{
                .open = false,
                .dialog_fn = dialog_fn,
            };
        }
    };

    var all_dialogs: std.EnumArray(Dialogs, DialogState) = .init(.{
        .transfer = .init(transfer),
    });

    pub fn displayOpen() void {
        for (all_dialogs.values) |dialog| {
            if (dialog.open) dialog.dialog_fn(&command_state);
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

    fn transfer(
        state: *CommandState,
    ) void {
        std.debug.assert(state.operation == .get);
        const dialog_state = all_dialogs.getPtr(.transfer);
        if (!dialog_state.open) return;
        const title = switch (state.operation) {
            .get => "Copy files from disk image",
            .put => "Copy files to disk image",
            else => unreachable,
        };
        const transfer_results = switch (state.operation) {
            .get => |op| op.transfer_result.items,
            else => unreachable,
        };

        var dialog_win = dvui.floatingWindow(
            @src(),
            .{ .modal = true, .open_flag = &dialog_state.open },
            .{
                .min_size_content = .{ .w = 500, .h = 500 },
                .max_size_content = .{ .w = 500, .h = 500 },
            },
        );
        defer dialog_win.deinit();
        dialog_win.dragAreaSet(dvui.windowHeader(title, "", &dialog_state.open));

        const label = switch (state.state) {
            .init, .processing, .user_input => "Cancel",
            .completed => "Close",
        };
        var button_wd: dvui.WidgetData = undefined;
        if (dvui.button(@src(), label, .{}, .{ .gravity_x = 0.5, .gravity_y = 1.0, .data_out = &button_wd })) {
            state.cancelCommand();
            return;
        }
        if (dvui.dataGet(null, button_wd.id, "focused", bool) == null) {
            dvui.dataSet(null, button_wd.id, "focused", true);
            dvui.focusWidget(button_wd.id, null, null);
        }

        var outer_vbox = dvui.box(@src(), .{}, .{
            .expand = .both,
            .min_size_content = .{ .w = 500, .h = 500 },
            .max_size_content = .{ .w = 500, .h = 500 },
        });
        defer outer_vbox.deinit();
        const yes_to_all = dvui.dataGetDefault(null, dialog_win.data().id, "yes_to_all", bool, false);
        const no_to_all = dvui.dataGetDefault(null, dialog_win.data().id, "no_to_all", bool, false);
        var yes_key: bool = false;
        var no_key: bool = false;
        var yes_all_key: bool = false;
        var no_all_key: bool = false;

        for (dvui.events()) |*e| {
            //            if (!dvui.eventMatchSimple(e, dialog_win.data())) continue;
            switch (e.evt) {
                .key => |ke| {
                    if (ke.action != .down and (ke.mod != .none or !ke.mod.shiftOnly())) continue;
                    switch (ke.code) {
                        .y => {
                            e.handle(@src(), dialog_win.data());
                            if (ke.mod.shift()) {
                                yes_all_key = true;
                            } else {
                                yes_key = true;
                            }
                        },
                        .n => {
                            e.handle(@src(), dialog_win.data());
                            if (ke.mod.shift()) {
                                no_all_key = true;
                            } else {
                                no_key = true;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        for (transfer_results, 0..) |*result, i| {
            dvui.label(@src(), "* {s}: {t} [{s}]", .{ result.filename, result.result, (if (result.result == .err) result.message else "") }, .{ .id_extra = i });
            // TODO: fix up this condition
            if (state.state == .user_input and result.result == .err and i == transfer_results.len - 1) switch (result.err.?) {
                error.PathAlreadyExists => {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                    defer hbox.deinit();
                    dvui.labelNoFmt(@src(), "Overwrite? ", .{}, .{});
                    var wd: dvui.WidgetData = undefined;
                    if (dvui.button(@src(), "[y]es", .{}, .{ .data_out = &wd }) or
                        yes_key or
                        yes_to_all)
                    {
                        result.recovery = .retry;
                        state.state = .processing;
                        if (yes_key)
                            dvui.focusWidget(wd.id, null, null);
                    }
                    // if (!dvui.dataGetDefault(null, wd.id, "focussed", bool, false)) {
                    //     dvui.focusWidget(wd.id, null, null);
                    //     dvui.dataSet(null, wd.id, "focussed", true);
                    // }
                    if (dvui.button(@src(), "[Y]es to all", .{}, .{ .data_out = &wd }) or
                        yes_all_key)
                    {
                        result.recovery = .retry;
                        state.state = .processing;
                        dvui.dataSet(null, dialog_win.data().id, "yes_to_all", true);
                        if (yes_all_key)
                            dvui.focusWidget(wd.id, null, null);
                    }
                    if (dvui.button(@src(), "[n]o", .{}, .{ .data_out = &wd }) or
                        no_key or
                        no_to_all)
                    {
                        state.state = .processing;
                        if (no_key)
                            dvui.focusWidget(wd.id, null, null);
                    }
                    if (dvui.button(@src(), "[N]o to all", .{}, .{ .data_out = &wd }) or
                        no_all_key)
                    {
                        state.state = .processing;
                        dvui.dataSet(null, dialog_win.data().id, "no_to_all", true);
                        if (no_all_key)
                            dvui.focusWidget(wd.id, null, null);
                    }
                }, // Prompt for overwrite

                error.UnsupportedTextMode,
                error.InvalidFormat,
                error.InvalidToken,
                error.InvalidRecordNumber,
                error.InvalidTrack,
                error.InvalidSector,
                => {}, // just report this error

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
                => {}, // Also just report this error?

            };
        }
    }
};

pub fn oom() noreturn {
    @panic("Out of memory error");
}
