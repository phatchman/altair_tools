const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const window_icon_png = @embedFile("zig-favicon.png");
const Commands = @import("commands.zig");
const DirectoryEntry = Commands.DirectoryEntry;

var commands: Commands = .{};

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "DVUI App Example",
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
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    commands.deinit(gpa, io);
}

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    {
        if (menu()) |res| return res;

        var box = dvui.box(@src(), .{}, .{ .expand = .both, .style = .window, .background = true });
        defer box.deinit();

        if (content()) |res| return res;
    }

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
            //show_shortcuts = true;
            m.close();
        }

        if (dvui.menuItemLabel(@src(), "About", .{}, .{}) != null) {
            m.close();
            // dvui.dialog(@src(), .{}, .{
            //     .displayFn = aboutDialogDisplay,
            //     .message = "",
            // });
        }
    }
    return null;
}

const GridWidget = dvui.GridWidget;

pub fn content() ?dvui.App.Result {
    const static = struct {
        var image_grid: DirectoryGrid = .init();
    };

    //statusBar();
    filenameEntryBox("Image:");
    static.image_grid.display();
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

pub fn sortGrid(sort_col: usize, direction: GridWidget.SortDirection, dir_entries: []DirectoryEntry) void {
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

fn statusBar() void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .border = .all(1), .gravity_y = 1 });
    defer hbox.deinit();
    statusBarButton("User", 1);
}

var filter_user: ?u8 = null;

fn statusBarButton(label: []const u8, shortcut_char_pos: u32) void {
    _ = shortcut_char_pos;
    if (dvui.button(@src(), label, .{}, .{})) {
        if (filter_user) |_| {
            filter_user.? += 1;
            if (filter_user == 16) filter_user = null;
        } else {
            filter_user = 0;
        }
    }
}

fn filenameEntryBox(label: []const u8) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer hbox.deinit();
    dvui.labelNoFmt(@src(), label, .{ .align_y = 0.5 }, .{});
    var te = dvui.textEntry(@src(), .{}, .{ .expand = .horizontal });
    defer te.deinit();
}

const DirectoryGrid = struct {
    const SelectAll = enum { none, select_all, select_none };
    all_selected: bool,
    select_all: SelectAll,
    shift_key_pressed: bool,
    selection: struct {
        mode: SelectAll,
        start_idx: ?usize,
        end_idx: ?usize,
    },

    pub fn init() DirectoryGrid {
        return .{
            .all_selected = false,
            .select_all = .none,
            .shift_key_pressed = false,
            .selection = .{
                .mode = .none,
                .start_idx = null,
                .end_idx = null,
            },
        };
    }

    fn setSelection(self: *DirectoryGrid, sel_index: usize, selected: bool) void {
        if (!self.shift_key_pressed or self.selection.start_idx == null) {
            // Single select or shift held on first selection
            self.selection.start_idx = sel_index;
            self.selection.end_idx = sel_index;
            self.selection.mode = if (selected) .select_all else .select_none;
            return true;
        } else {
            // Shift-select
            self.selection.end_idx = sel_index;
            self.selection.mode = if (selected) .select_all else .select_none;
            return true;
        }
    }

    fn inSelectionRange(self: *DirectoryGrid, index: usize) bool {
        const start = self.selection.start_idx orelse 0;
        const end = self.selection.end_idx orelse 0;
        if (start <= end) {
            return index >= start and index <= end;
        } else {
            return index >= end and index <= start;
        }
    }

    fn display(self: *DirectoryGrid) void {
        var grid = dvui.grid(@src(), .{ .cols_rigid = static_cols }, .{ .expand = .both, .border = .all(0) });
        defer grid.deinit();

        // TODO: This is a hack for now
        const dir_listing: []DirectoryEntry = if (dvui.firstFrame(grid.data().id))
            commands.directoryListing(gpa) catch @panic("TODO")
        else
            commands.image_directory_list.items;

        if (dvui.firstFrame(grid.data().id)) {
            grid.sort_col = GridColumn.colNrFor(.name);
            grid.sort_dir = .ascending;
        }
        for (grid_columns, 0..) |column, col| {
            const cell = grid.colHeader(col, .{});
            defer cell.deinit();
            const min_size: ?dvui.Size = if (column.min_width) |min_width| dvui.themeGet().font_body.sizeM(min_width + 2, 1) else null;
            if (col == 0) {
                const label = if (self.all_selected) "[X]" else "[ ]";
                self.select_all = .none;
                if (dvui.button(@src(), label, .{}, .{ .gravity_x = 0.5 })) {
                    if (self.all_selected) {
                        self.select_all = .select_none;
                    } else {
                        self.select_all = .select_all;
                    }
                }
            } else {
                if (cell.headerSortable(column.label, .{ .min_size_content = min_size })) |sort_dir| {
                    sortGrid(col, sort_dir, dir_listing);
                }
                _ = dvui.separator(@src(), .{ .expand = .vertical, .margin = .{ .y = 5, .h = 5 } });
            }
        }
        const current_row = grid.cursor.row;
        const selected = rowHighlight(grid);
        const row_changed = current_row != grid.cursor.row or selected;

        self.processKbModifiers();

        self.all_selected = true;
        for (dir_listing, 0..) |*dir_item, row_idx| {
            const row_options: dvui.Options =
                if (grid.cursor.row == row_idx) .{
                    .color_fill = dvui.themeGet().color(.control, .fill_press),
                    .background = true,
                } else .{};

            switch (self.select_all) {
                .none => {},
                .select_all => dir_item.selected = true,
                .select_none => dir_item.selected = false,
            }
            {
                var cell = grid.cell(.{ .col = 0, .row = row_idx }, row_options);
                defer cell.deinit();
                const src = @src();
                const id = dvui.parentGet().extendId(src, 0);
                if ((row_changed and grid.cursor.row == row_idx) or cell.grid_focus) { //  and highlight_cell.row == row_idx) {
                    dvui.focusWidget(id, null, null);
                    if (selected) {
                        dir_item.toggleSelected();
                    }
                }
                if (dvui.button(src, if (dir_item.selected) "[X]" else "[ ]", .{ .draw_focus = false }, .{ .background = false, .margin = .all(0) })) {
                    dir_item.toggleSelected();
                }
                if (!dir_item.selected) self.all_selected = false;
            }
            {
                var cell = grid.cell(.{ .col = 1, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.labelNoFmt(@src(), dir_item.filename(), .{}, .{ .gravity_y = 0.5 });
            }
            {
                var cell = grid.cell(.{ .col = 2, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.labelNoFmt(@src(), dir_item.extension(), .{}, .{});
            }
            {
                var cell = grid.cell(.{ .col = 3, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.label(@src(), "{}B", .{dir_item.fileSizeInB()}, .{ .gravity_x = 1 });
            }
            {
                var cell = grid.cell(.{ .col = 4, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.label(@src(), "{}K", .{dir_item.fileUsedInKB()}, .{ .gravity_x = 1 });
            }
            {
                var cell = grid.cell(.{ .col = 5, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.labelNoFmt(@src(), dir_item.attribs(), .{}, .{ .gravity_x = 0.5 });
            }
            {
                var cell = grid.cell(.{ .col = 6, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.label(@src(), "{}", .{dir_item.user()}, .{ .gravity_x = 0.5 });
            }
        }
    }

    fn processKbModifiers(self: *DirectoryGrid) void {
        // KB modifiers are global, no need to check for event match?
        for (dvui.events()) |e| {
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
                        // TODO:: Check this change with david. Otherwise it eats events that should go to the header??
                        if (grid.cellFromPoint(me.p)) |cell| {
                            std.debug.print("handled\n", .{});
                            e.handle(@src(), grid.data());
                            dvui.captureMouse(grid.data(), e.num);
                            dvui.dragPreStart(me.button, me.p, .{});
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

    const SelectionRange = union {
        all: void,
        range: struct {
            start: usize,
            end: usize,
        },
    };

    fn extendedSelection(grid: *dvui.GridWidget) ?SelectionRange {
        const evts = dvui.events();
        for (evts) |*e| {
            if (!dvui.eventMatchSimple(e, grid.data())) continue;

            switch (e.evt) {
                .key => |ke| {
                    if (ke.matchBind("select_all")) {
                        e.handle(@src(), grid.data());
                        return .{.all};
                    }
                },
                else => {},
            }
        }
        return null;
    }
};
