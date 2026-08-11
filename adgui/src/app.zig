const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const window_icon_png = @embedFile("zig-favicon.png");
const DiskInterface = @import("DiskInterface.zig");
const DirectoryEntry = DiskInterface.DirectoryEntry;
const GridWidget = dvui.GridWidget;
const dialogs = @import("dialogs.zig");
const operations = @import("operations.zig");
const Operation = operations.Operation;
const OperationState = operations.OperationState;
const CopyMode = DiskInterface.CopyMode;

const UIState = struct {
    disk_interface: DiskInterface,
    operation_state: OperationState,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    shortcut_key_pressed: bool,
    filter_user: ?u8,
    copy_mode: CopyMode,

    pub fn init(self: *UIState, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) void {
        self.* = .{
            .disk_interface = init: {
                var disk_interface: DiskInterface = .init(gpa);
                disk_interface.openTestImage(io) catch |err| {
                    std.debug.print("Error opening test image: {t}\n", .{err});
                };
                break :init disk_interface;
            },
            .operation_state = .init(io, gpa, &self.disk_interface),
            .gpa = gpa,
            .arena = arena,
            .io = io,
            .filter_user = null,
            .copy_mode = .AUTO,
            .shortcut_key_pressed = false,
        };
        self.disk_interface.openLocalDirectory(io, ".") catch |err| {
            std.debug.print("Error opening current directory: {t}\n", .{err});
        };
    }
};

// Prefer to use a passed ui_state function param instead of this.
var global_ui_state: UIState = undefined;

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
// var io: std.Io = undefined;
// var gpa: std.mem.Allocator = undefined;
// var arena: std.mem.Allocator = undefined;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

pub fn appInit(_: *dvui.Window) !void {
    const io = dvui.App.main_init.?.io;
    const gpa = dvui.App.main_init.?.gpa;
    const arena = dvui.App.main_init.?.arena.allocator();

    const args = try dvui.App.main_init.?.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--debug")) {
        dvui.debug.open = true;
    }

    global_ui_state.init(io, gpa, arena);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    global_ui_state.operation_state.endOperation();
    global_ui_state.disk_interface.deinit(global_ui_state.io, global_ui_state.gpa);
}

var frame_count: usize = 0;
// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    std.debug.print("--- FRAME [{d}]---\n", .{frame_count});
    defer frame_count += 1;

    // Check for .alt key regardless of who has focus
    for (dvui.events()) |*e| {
        switch (e.evt) {
            .key => |ke| {
                if (ke.code == .left_alt or ke.code == .right_alt) {
                    global_ui_state.shortcut_key_pressed = switch (ke.action) {
                        .down, .repeat => true,
                        .up => false,
                    };
                }
            },
            else => {},
        }
    }
    {
        if (menu(&global_ui_state)) |res| return res;

        var box = dvui.box(@src(), .{}, .{ .expand = .both, .style = .window, .background = true });
        defer box.deinit();
        if (statusBar(&global_ui_state)) |res| return res;
        if (content(&global_ui_state)) |res| return res;
    }
    global_ui_state.operation_state.process();
    dialogs.displayOpen(&global_ui_state.operation_state);

    return .ok;
}

pub fn menu(ui_state: *UIState) ?dvui.App.Result {
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
            ui_state.operation_state.beginOperation(.{ .show_dialog = .init(.shortcuts) });
        }

        if (dvui.menuItemLabel(@src(), "About", .{}, .{}) != null) {
            m.close();
            ui_state.operation_state.beginOperation(.{ .show_dialog = .init(.about) });
        }
    }
    return null;
}

pub fn content(ui_state: *UIState) ?dvui.App.Result {
    const disk_interface = &ui_state.disk_interface;
    const static = struct {
        var image_grid: DirectoryGrid = .init(.image);
        var local_grid: DirectoryGrid = .init(.local);
    };
    usagePanel(ui_state);

    var paned = dvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = 0,
        .handle_size = 6,
        .handle_dynamic = .{ .handle_size_max = 6 },
    }, .{ .expand = .both });
    defer paned.deinit();
    // var hbox = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .both });
    // defer hbox.deinit();
    if (paned.showFirst()) {
        var vbox = panel(@src(), .{}, .{ .expand = .both });
        defer vbox.deinit();
        const result = widgets.filenameEntryBox(
            @src(),
            "Image:",
            "Open a disk image",
            ui_state.disk_interface.image_dir.path,
            ui_state.disk_interface.image_dir.changed,
            .{ .shortcut_key = .o, .show_shortcuts = ui_state.shortcut_key_pressed },
        );
        switch (result.response) {
            .enter => ui_state.operation_state.beginOperation(.{ .open_image = .init(result.path, ui_state.disk_interface.image_dir.path_buf) }),
            .button => ui_state.operation_state.beginOperation(.{ .open_image = .init(null, ui_state.disk_interface.image_dir.path_buf) }),
            .none => {},
        }
        static.image_grid.display(ui_state, disk_interface.image_dir.directory_list.items, disk_interface.image_dir.changed);
        disk_interface.image_dir.changed = false;
    }
    if (paned.showSecond()) {
        var vbox = panel(@src(), .{}, .{ .expand = .both });
        defer vbox.deinit();
        const result = widgets.filenameEntryBox(
            @src(),
            "Local:",
            null,
            ui_state.disk_interface.local_dir.path,
            ui_state.disk_interface.local_dir.changed,
            .{ .shortcut_key = .l, .show_shortcuts = ui_state.shortcut_key_pressed },
        );
        switch (result.response) {
            .enter => ui_state.operation_state.beginOperation(.{ .open_local = .init(
                .{ .given = result.path },
                ui_state.disk_interface.local_dir.path_buf,
            ) }),
            .button => ui_state.operation_state.beginOperation(.{ .open_local = .init(
                .{ .prompt = ui_state.disk_interface.local_dir.path },
                ui_state.disk_interface.local_dir.path_buf,
            ) }),
            .none => {},
        }
        static.local_grid.display(ui_state, disk_interface.local_dir.directory_list.items, disk_interface.local_dir.changed);
        disk_interface.local_dir.changed = false;
    }

    return null;
}

fn usagePanel(ui_state: *UIState) void {
    var usage_panel = panel(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1.0 });
    defer usage_panel.deinit();
    capacityGraph(ui_state);
    directoriesGraph(ui_state);
}

fn capacityGraph(ui_state: *UIState) void {
    dvui.labelNoFmt(@src(), "Capacity: ", .{ .align_y = 0.5 }, .{ .expand = .vertical });
    {
        var files_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .border = .all(1),
            .background = true,
            .min_size_content = .{ .h = 20, .w = 250 },
            .margin = .all(5),
        });
        defer files_box.deinit();

        if (ui_state.disk_interface.disk_image) |disk_image| {
            const total_space = disk_image.capacityTotalInKB();
            const free_space = disk_image.capacityFreeInKB();
            const used_space = total_space -| free_space;
            const percentage: f32 = @as(f32, @floatFromInt(used_space)) / @as(f32, @floatFromInt(total_space));
            const width = percentage * 250;

            var used_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .color_fill = dvui.themeGet().fill_hover,
                .background = true,
                .rect = .{ .x = 0, .y = 0, .h = 20, .w = width },
            });
            used_box.deinit();
            var msg_buf: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&msg_buf, "{:>6}K used {:>6}K remain ", .{ used_space, free_space }) catch unreachable;

            dvui.labelNoFmt(@src(), message, .{}, .{
                .padding = .all(2),
            });
        }
    }
}

fn directoriesGraph(ui_state: *UIState) void {
    dvui.labelNoFmt(@src(), "Directories: ", .{ .align_y = 0.5 }, .{ .expand = .vertical });
    {
        var files_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .border = .all(1),
            .background = true,
            .min_size_content = .{ .h = 20, .w = 250 },
            .margin = .all(5),
        });
        defer files_box.deinit();

        if (ui_state.disk_interface.disk_image) |disk_image| {
            const max_directories = disk_image.image_type.directories;
            const free_directories = disk_image.directory.rawEntryFreeCount();
            const used_directories = max_directories - free_directories;
            const percentage = @as(f32, @floatFromInt(used_directories)) / @as(f32, @floatFromInt(max_directories));
            const width = percentage * 250;

            var used_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .color_fill = dvui.themeGet().fill_hover,
                .background = true,
                .rect = .{ .x = 0, .y = 0, .h = 20, .w = width },
            });
            used_box.deinit();
            var msg_buf: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&msg_buf, "{:>7} used {:>7} remain ", .{ used_directories, free_directories }) catch unreachable;

            dvui.labelNoFmt(@src(), message, .{}, .{
                .padding = .all(2),
            });
        }
    }
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

fn statusBar(ui_state: *UIState) ?dvui.App.Result {
    var hbox = panel(@src(), .{ .dir = .horizontal, .equal_space = true }, .{});
    defer hbox.deinit();

    var label_buf: [32]u8 = undefined;
    const label = if (ui_state.filter_user) |user|
        std.fmt.bufPrint(&label_buf, "USER {d}", .{user}) catch unreachable
    else
        std.fmt.bufPrint(&label_buf, "USER *", .{}) catch unreachable;

    var any_image_selected: bool = false;
    for (ui_state.disk_interface.image_dir.directory_list.items) |item| {
        if (item.selected) {
            any_image_selected = true;
            break;
        }
    }

    var any_local_selected: bool = false;
    for (ui_state.disk_interface.local_dir.directory_list.items) |item| {
        if (item.selected) {
            any_local_selected = true;
            break;
        }
    }

    const image_open = ui_state.disk_interface.disk_image != null;
    if (statusBarButton(
        @src(),
        "GET",
        .g,
        0,
        ui_state.shortcut_key_pressed,
        image_open and any_image_selected,
    )) {
        // TODO: Copy Mode
        ui_state.operation_state.beginOperation(.{ .transfer = .init(
            ui_state.disk_interface.image_dir.directory_list.items,
            .get,
            ui_state.copy_mode,
            ui_state.filter_user,
        ) });
    }

    if (statusBarButton(
        @src(),
        "PUT",
        .p,
        0,
        ui_state.shortcut_key_pressed,
        image_open and any_local_selected,
    )) {
        // TODO: Copy Mode
        ui_state.operation_state.beginOperation(.{ .transfer = .init(
            ui_state.disk_interface.local_dir.directory_list.items,
            .put,
            ui_state.copy_mode,
            ui_state.filter_user,
        ) });
    }

    if (statusBarButton(
        @src(),
        "ERASE",
        .e,
        0,
        ui_state.shortcut_key_pressed,
        image_open and any_image_selected,
    )) {
        ui_state.operation_state.beginOperation(.{ .transfer = .init(
            ui_state.disk_interface.image_dir.directory_list.items,
            .erase,
            .AUTO,
            ui_state.filter_user,
        ) });
    }

    if (statusBarButton(@src(), label, .u, 0, ui_state.shortcut_key_pressed, true)) {
        if (ui_state.filter_user) |_| {
            ui_state.filter_user.? += 1;
            if (ui_state.filter_user == 16) ui_state.filter_user = null;
        } else {
            ui_state.filter_user = 0;
        }
        if (ui_state.filter_user) |filter| {
            for (ui_state.disk_interface.image_dir.directory_list.items) |*dir_entry| {
                if (dir_entry.user() != filter) dir_entry.selected = false;
            }
        }
    }
    const operation_state = &ui_state.operation_state;
    if (statusBarButton(@src(), "OPEN", .o, 0, ui_state.shortcut_key_pressed, true)) {
        operation_state.beginOperation(.{ .open_image = .init(null, ui_state.disk_interface.image_dir.path_buf) });
    }

    if (statusBarButton(@src(), "NEW", .n, 0, ui_state.shortcut_key_pressed, true)) {
        operation_state.beginOperation(.{ .new = .init(std.fs.path.dirname(ui_state.disk_interface.image_dir.path) orelse ".") });
    }

    if (statusBarButton(@src(), "CLOSE", .c, 0, ui_state.shortcut_key_pressed, image_open)) {
        operation_state.beginOperation(.close);
    }

    const mode_label = @tagName(ui_state.copy_mode);
    const shortcut_pos = std.mem.indexOfScalar(u8, mode_label, 'A') orelse unreachable;
    if (statusBarButton(@src(), mode_label, .a, @intCast(shortcut_pos), ui_state.shortcut_key_pressed, true)) {
        ui_state.copy_mode = switch (ui_state.copy_mode) {
            .AUTO => .ASCII,
            .ASCII => .BINARY,
            .BINARY => .BASIC,
            .BASIC => .RANDOM,
            .RANDOM => .AUTO,
        };
    }

    if (statusBarButton(@src(), "EXIT", .x, 2, ui_state.shortcut_key_pressed, true)) {
        return .close;
    }
    return null;
}

pub fn nextCopyMode(ui_state: *const UIState, mode: CopyMode) CopyMode {
    const supported = (ui_state.disk_interface.disk_image orelse return .AUTO).textModesAllSupported();
    for (supported, 0..) |supported_mode, idx| {
        if (supported_mode == DiskInterface.xlateFromCopyMode(mode)) {
            return if (idx == supported.len - 1) DiskInterface.xlateToCopyMode(supported[0]) else DiskInterface.xlateToCopyMode(supported[idx + 1]);
        }
    }
    return .AUTO;
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

fn statusBarButton(
    src: std.builtin.SourceLocation,
    label: []const u8,
    shortcut_key: dvui.enums.Key,
    shortcut_char_pos: u32,
    alt_key_pressed: bool,
    enabled: bool,
) bool {
    const char_width = dvui.themeGet().font_mono.sizeM(1, 1).w;
    const x_offset: f32 = char_width * @as(f32, @floatFromInt(shortcut_char_pos + 1));
    var wd: dvui.WidgetData = undefined;
    var box = dvui.box(src, .{}, .{});
    defer box.deinit();
    const result = widgets.buttonWithShortcut(@src(), label, .{
        .button = .{ .grayed = !enabled },
        .shortcut = shortcut_key,
    }, .{ .data_out = &wd });
    if (enabled and alt_key_pressed) {
        _ = dvui.separator(@src(), .{ .expand = .none, .rect = .{
            .x = x_offset + 3,
            .y = wd.contentRect().x + wd.contentRect().h - wd.options.padding.?.h + 4,
            .w = char_width,
            .h = 2,
        } });
    }
    return result;
}

const FilenameEntryResult = struct {
    response: enum { none, enter, button },
    path: []const u8,
};

const DirectoryGrid = struct {
    const SelectMode = enum { none, select_all, select_none };
    pub const Style = enum { image, local };

    const Ctx = struct {
        user_filter: ?u8,
        style: Style,
    };
    const DirectoryIterator = DiskInterface.DirectoryIterator(Ctx);

    all_selected: bool,
    shift_key_pressed: bool,
    style: Style,
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

    pub fn init(style: Style) DirectoryGrid {
        return .{
            .all_selected = false,
            .shift_key_pressed = false,
            .style = style,
            .selection = .{
                .mode = .none,
                .first_idx = null,
                .second_idx = null,
            },
        };
    }

    fn display(self: *DirectoryGrid, ui_state: *UIState, dir_listing: []DirectoryEntry, listing_changed: bool) void {
        const last_focus = dvui.lastFocusedIdInFrame();
        var grid = dvui.grid(@src(), .{ .cols_rigid = static_cols, .scroll_opts = .{ .horizontal = .auto } }, .{ .expand = .both, .border = .all(0) });
        defer grid.deinit();

        if (listing_changed) {
            sortDirectories(grid.sort_col, grid.sort_dir, dir_listing);
        }

        self.processKbEventsPre();

        if (dvui.firstFrame(grid.data().id)) {
            grid.sort_col = GridColumn.colNrFor(.name);
            grid.sort_dir = .ascending;
        }

        var dir_itr: DirectoryIterator = .init(dir_listing, .{
            .user_filter = ui_state.filter_user,
            .style = self.style,
        }, struct {
            pub fn selected(ctx: Ctx, entry: *const DirectoryEntry) bool {
                if (ctx.style == .image) if (ctx.user_filter) |user| {
                    return entry.user() == user;
                };
                return true;
            }
        }.selected);

        const row_count = dir_itr.count();
        self.displayHeaders(grid, dir_listing, row_count);

        const current_row = grid.cursor.row;
        const selection_changed = rowHighlight(grid);
        const cursor_changed = current_row != grid.cursor.row or selection_changed;
        if (self.style == .image and ui_state.disk_interface.disk_image == null)
            self.displayBodyClosed(grid)
        else
            self.displayBody(grid, &dir_itr, cursor_changed, selection_changed, listing_changed);

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

    fn displayBody(self: *DirectoryGrid, grid: *dvui.GridWidget, dir_itr: *DirectoryIterator, cursor_changed: bool, selection_changed: bool, listing_changed: bool) void {
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
                dvui.label(@src(), "{f}B", .{fmtCommas(dir_item.fileSizeInB())}, .{ .gravity_x = 1 });
            }
            { // Used
                var cell = grid.cell(.{ .col = 4, .row = row_idx }, row_options);
                defer cell.deinit();
                dvui.label(@src(), "{f}K", .{fmtCommas(dir_item.fileUsedInKB())}, .{ .gravity_x = 1 });
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
        if (listing_changed) {
            std.debug.print("auto sizing\n", .{});
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

    pub fn fmtCommas(number: usize) std.fmt.Alt(usize, formatNumberCommas) {
        return .{ .data = number };
    }

    fn formatNumberCommas(raw: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var num = raw;
        var nr_decs = if (num > 0) std.math.log10(num) + 1 else 1;
        var leading: bool = true;

        if (nr_decs > 3) {
            const start = if (nr_decs % 3 == 0) 3 else nr_decs % 3;
            var divisor = std.math.pow(usize, 10, nr_decs - start);
            while (nr_decs > 3) : ({
                nr_decs -= 3;
                divisor /= 1000;
            }) {
                const val = num / divisor;
                if (leading)
                    try w.print("{d},", .{val})
                else
                    try w.print("{d:03},", .{val});
                num -= val * divisor;
                leading = false;
            }
        }
        if (leading)
            try w.print("{d}", .{num})
        else
            try w.print("{d:03}", .{num});
    }
};

pub const widgets = struct {
    pub const ButtonShortCutInitOptions = struct {
        button: dvui.ButtonWidget.InitOptions,
        shortcut: dvui.enums.Key,
    };

    /// Create a button that can also be activated with an alt key combination.
    /// Note: Treats all shortcut keys as global, regardless of which widget currently has focus.
    pub fn buttonWithShortcut(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: ButtonShortCutInitOptions, opts: dvui.Options) bool {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(src, init_opts.button, opts);
        if (!init_opts.button.grayed) {
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
        }
        bw.drawBackground();

        const click = if (!init_opts.button.grayed) bw.clicked() else false;

        dvui.labelNoFmt(@src(), label_str, .{ .align_x = 0.5, .align_y = 0.5 }, opts.strip().override(bw.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
        bw.deinit();

        return click;
    }

    const FilenameEntryBoxOptions = struct {
        shortcut_key: ?dvui.enums.Key = null,
        show_shortcuts: bool = false,
    };
    pub fn filenameEntryBox(src: std.builtin.SourceLocation, label: []const u8, placeholder: ?[]const u8, init_path: []const u8, changed: bool, opts: FilenameEntryBoxOptions) FilenameEntryResult {
        var hbox = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();
        dvui.labelNoFmt(@src(), label, .{ .align_y = 0.5 }, .{ .margin = dvui.TextEntryWidget.defaults.margin });
        var te = dvui.textEntry(@src(), .{ .text = .{ .internal = .{ .limit = std.fs.max_path_bytes } }, .placeholder = placeholder }, .{ .expand = .horizontal });

        if (changed or dvui.focusedWidgetId() != te.data().id) {
            if (!std.mem.eql(u8, init_path, te.getText())) {
                te.textSet(init_path, false);
            }
        }
        var result: FilenameEntryResult = .{ .response = .none, .path = te.getText() };

        if (te.enter_pressed)
            result.response = .enter;
        te.deinit();

        var wd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "open", dvui.entypo.folder, .{}, .{}, .{
            .data_out = &wd,
            .expand = .ratio,
            //            .min_size_content = size,
        })) {
            result.response = .button;
        }
        if (opts.show_shortcuts) if (opts.shortcut_key) |key| {
            //const defaults = dvui.ButtonWidget.defaults;
            dvui.labelEx(@src(), "{c}", .{std.ascii.toUpper(@tagName(key)[0])}, .{ .align_x = 0.5, .align_y = 1.0 }, .{
                // Offset a small amount so that the key displays cleanly in the body of the folder
                .rect = wd.backgroundRect().offset(.{ .x = 0, .y = 2, .w = 0, .h = -2 }),
                .color_text = dvui.themeGet().color(.control, .fill),
                .font = dvui.themeGet().font_mono.withWeight(.bold).larger(0.25),
            });
            if (opts.shortcut_key) |shortcut_key| {
                for (dvui.events()) |*e| {
                    if (e.evt == .key and e.evt.key.action == .down and e.evt.key.code == shortcut_key and e.evt.key.mod.alt()) {
                        result.response = .button;
                    }
                }
            }
        };

        return result;
    }
};

pub fn oom() noreturn {
    @panic("Out of memory error");
}
