const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const window_icon_png = @embedFile("zig-favicon.png");
const DiskInterface = @import("DiskInterface.zig");
const DirectoryEntry = DiskInterface.DirectoryEntry;
const GridWidget = dvui.GridWidget;
const dialogs = @import("dialogs.zig");
const operations = @import("operations.zig");
const OperationState = operations.OperationState;

var disk_interface: DiskInterface = undefined;
var operation_state: OperationState = undefined;

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
var arena: std.mem.Allocator = undefined;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

pub fn appInit(_: *dvui.Window) !void {
    io = dvui.App.main_init.?.io;
    gpa = dvui.App.main_init.?.gpa;
    arena = dvui.App.main_init.?.arena.allocator();

    const args = try dvui.App.main_init.?.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--debug")) {
        dvui.debug.open = true;
    }
    disk_interface = .init(gpa);
    disk_interface.openTestImage(io) catch |err| {
        std.debug.print("Error opening test image: {t}\n", .{err});
    };
    disk_interface.openLocalDirectory(io, ".") catch |err| {
        std.debug.print("Error opening local directory: {t}\n", .{err});
    };
    operation_state = .init(io, gpa, &disk_interface);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    operation_state.endOperation();
    disk_interface.deinit(io);
}

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    std.debug.print("--- FRAME ---\n", .{});
    {
        if (menu()) |res| return res;

        var box = dvui.box(@src(), .{}, .{ .expand = .both, .style = .window, .background = true });
        defer box.deinit();
        if (statusBar()) |res| return res;
        if (content()) |res| return res;
    }
    operation_state.process();
    dialogs.displayOpen(&operation_state);

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
        var local_grid: DirectoryGrid = .init();
    };
    var hbox = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .both });
    defer hbox.deinit();
    {
        var vbox = panel(@src(), .{}, .{ .expand = .both });
        defer vbox.deinit();
        filenameEntryBox(@src(), "Image:");
        static.image_grid.display(disk_interface.image_directory_list.items, disk_interface.local_directory_changed);
        disk_interface.local_directory_changed = false;
    }
    {
        var vbox = panel(@src(), .{}, .{ .expand = .both });
        defer vbox.deinit();
        filenameEntryBox(@src(), "Local:");
        static.local_grid.display(disk_interface.local_directory_list.items, disk_interface.local_directory_changed);
        disk_interface.local_directory_changed = false;
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
        operation_state.beginOperation(.{ .get = .init });
    }
    if (statusBarButton(@src(), label, .u, 1, static.alt_key_pressed)) {
        if (filter_user) |_| {
            filter_user.? += 1;
            if (filter_user == 16) filter_user = null;
        } else {
            filter_user = 0;
        }
        if (filter_user) |filter| {
            for (disk_interface.image_directory_list.items) |*dir_entry| {
                if (dir_entry.user() != filter) dir_entry.selected = false;
            }
        }
    }
    if (statusBarButton(@src(), "OPEN", .o, 1, static.alt_key_pressed)) {
        operation_state.beginOperation(.{ .open = .init });
    }

    if (statusBarButton(@src(), "NEW", .n, 1, static.alt_key_pressed)) {
        operation_state.beginOperation(.{ .new = .init });
    }

    if (statusBarButton(@src(), "CLOSE", .c, 1, static.alt_key_pressed)) {
        operation_state.beginOperation(.close);
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

    fn display(self: *DirectoryGrid, dir_listing: []DirectoryEntry, auto_size: bool) void {
        const last_focus = dvui.lastFocusedIdInFrame();
        var grid = dvui.grid(@src(), .{ .cols_rigid = static_cols }, .{ .expand = .both, .border = .all(0) });
        defer grid.deinit();

        self.processKbEventsPre();

        if (dvui.firstFrame(grid.data().id)) {
            grid.sort_col = GridColumn.colNrFor(.name);
            grid.sort_dir = .ascending;
        }

        var dir_itr = DiskInterface.DirectoryIterator(dir_listing, struct {
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
        if (disk_interface.disk_image != null)
            self.displayBody(grid, &dir_itr, cursor_changed, selection_changed, auto_size)
        else
            self.displayBodyClosed(grid);

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

    fn displayBodyClosed(_: *DirectoryGrid, grid: *dvui.GridWidget) void {
        grid.ensureBodyScroll();
        dvui.labelNoFmt(@src(), "Open a disk image.", .{}, .{});
    }

    fn displayBody(self: *DirectoryGrid, grid: *dvui.GridWidget, dir_itr: *DiskInterface.DirIterator, cursor_changed: bool, selection_changed: bool, auto_size: bool) void {
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
        if (auto_size) {
            grid.autoSize(.{ .auto = .cols });
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

const widgets = struct {
    pub const ButtonShortCutInitOptions = struct {
        button: dvui.ButtonWidget.InitOptions,
        shortcut: dvui.enums.Key,
    };

    /// Create a button that can also be activated with an alt key combination.
    /// Note: Treats all shortcut keys as global, regardless of which widget currently has focus.
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
                        (ke.mod == .lalt or ke.mod == .ralt))
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

pub fn oom() noreturn {
    @panic("Out of memory error");
}
