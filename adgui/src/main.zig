//! Altair Disk GUI
//
// MIT License
//
// Copyright (c) 2025 Paul Hatchman
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

//
// POTENTIAL TODO:
//       [_] Ask to do a recovery if the disk image is corrupted
//       [_] Keep a backup image of any file opened? OR at least make that an option.
//       [_] Cleanup how directory paths and image paths etc are stored, updated and displayed.
//       [_] Cleanup all of the global state for selection, key handling etc.
//       [_] Measure the width of header columns based on data column widths, rather than the other way around
//           This would allow us to make the column expand to the width of the data.
//       [x] Drag and Drop
//              1) From windows into app
//              2) From app to local OS (SDL doesn't currently support this)
//              2) Between application grids - "Phase 2"
//       [_]
//

const adgui_version = "0.9.5";

const folder_icon = @embedFile("icons/folder.tvg");

const window_icon_png = @embedFile("altair.png");

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
pub const allocator = gpa_instance.allocator();

const vsync = false;

const alt_label_margin = Rect.all(4);

// Global key state.
var alt_held = false;
var shift_held = false;
var enter_pressed = false;
var pgdn_pressed: bool = false;
var pgup_pressed: bool = false;
var down_pressed: bool = false;
var up_pressed: bool = false;
var showing_dialog = false;

var pane_orientation = dvui.enums.Direction.horizontal;
const SelectionMode = enum { mouse, kb };

// Which grid has keyboard or mouse focus.
var focussed_grid: GridType = .image;
// Whether user is currently selecting by keyboard or mouse.
var selection_mode = SelectionMode.mouse;

var current_user: usize = 16; // 16 = all users. 0-15 = individual user.
var copy_mode = CopyMode.AUTO;

// The list of directory entries for the image and local filesystems
var image_directories: ?[]DirectoryEntry = null;
var local_directories: ?[]DirectoryEntry = null;

const GridType = enum {
    image,
    local,

    fn toUSize(self: GridType) usize {
        return @intFromEnum(self);
    }

    fn fromUSize(self: *GridType, val: usize) void {
        self.* = @enumFromInt(val);
    }
    const num_grids = std.meta.fields(GridType).len;
};

const GridColumns = enum {
    @"[_]",
    Name,
    Ext,
    A,
    Size,
    Used,
    U,

    const count = std.meta.fields(GridColumns).len;

    pub const default_sort_col = .Name;

    pub fn toUsize(self: GridColumns) usize {
        return @intCast(@intFromEnum(self));
    }

    pub fn fromUsize(val: usize) GridColumns {
        return @enumFromInt(val);
    }
};

const FileGridData = struct {
    // Image grid for disk image or local for local filesystem.
    const num_cols = GridColumns.count;

    kb_dir_index: usize = 0,
    mouse_dir_index: usize = 0,
    last_mouse_index: usize = 0,

    scroll_info: dvui.ScrollInfo = .{}, // TODO
    sort_order: [num_cols]dvui.GridWidget.SortDirection = @splat(.unsorted),
};

var grid_data: [GridType.num_grids]FileGridData = .{ .{}, .{} };

fn gridData(id: GridType) *FileGridData {
    return &grid_data[id.toUSize()];
}

// Don't handle keyboard events if a textbvox is focussed.
fn textBoxFocused() bool {
    return false; // // TODO
    //    for (text_box_focused) |focused| {
    //        if (focused) return true;
    //    }
    //    return false;
}

// Layout information for each column.
const num_columns = 7;
var initial_col_widths = [num_columns]f32{ 45, -70, -30, -20, -70, -40, -20 };
var image_col_widths = [num_columns]f32{ 45, -70, -30, -20, -70, -40, -20 };
var local_col_widths = [num_columns]f32{ 10, 70, 30, 20, 70, 40, 10 };
// Used for column widths. Note is shared by both grids as used sequentially.
var header_rects: [num_columns]dvui.Rect = @splat(dvui.Rect.all(0));
const row_height: f32 = 25.0;
const status_bar_height = 35 * 2;

var image_path_initialized = false;
var image_path_selection: ?[]const u8 = null;

var local_path_initialized = false;
var local_path_selection: ?[]const u8 = null;

fn setLocalPath(path: []const u8) !void {
    if (local_path_selection) |local_path| {
        allocator.free(local_path);
    }
    local_path_selection = try allocator.dupe(u8, path);
    local_path_initialized = false;
}

fn setImagePath(path: []const u8) !void {
    if (image_path_selection) |image_path| {
        allocator.free(image_path);
    }
    image_path_selection = try allocator.dupe(u8, path);
    image_path_initialized = false;
}
const empty_directory_list: [0]DirectoryEntry = .{};

var commands = Commands{};

const os = @import("builtin").os;
pub fn main() !void {
    if (os.tag == .windows and os.isAtLeast(.windows, .win10) orelse false) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        std.debug.print("attaching\n", .{});
        _ = winapi.AttachConsole(0xFFFFFFFF);
    }
    std.log.info("SDL version: {}", .{Backend.getSDLVersion()});

    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");
    defer commands.deinit(allocator);
    CommandState.init(allocator);
    defer CommandState.freeResources();

    // init SDL backend (creates and owns OS window)
    var backend = try Backend.initWindow(.{
        .allocator = allocator,
        .size = .{ .w = 900.0, .h = 600.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = vsync,
        .title = "Altair Disk Viewer",
        .icon = window_icon_png, // can also call setIconFromFileContent()
    });
    defer backend.deinit();
    Backend.c.SDL_SetWindowMinimumSize(backend.window, 900, 600);

    try setImagePath("");
    defer allocator.free(image_path_selection.?);
    try setLocalPath(".");
    defer allocator.free(local_path_selection.?);

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), allocator, backend.backend(), .{});
    defer win.deinit();
    defer {
        if (theme_set)
            global_theme.deinit(allocator);
    }

    open_local: {
        commands.openLocalDirectory(local_path_selection.?) catch {
            break :open_local;
        };
        local_directories = commands.localDirectoryListing(allocator) catch null;
    }

    _ = Backend.c.SDL_EventState(Backend.c.SDL_DROPFILE, Backend.c.SDL_ENABLE);
    var interrupted = false;
    main_loop: while (true) {
        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(interrupted);

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        var event: Backend.c.SDL_Event = undefined;
        while (Backend.c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                Backend.c.SDL_DROPFILE => {
                    const dropped_file = event.drop.file;
                    const filename = std.mem.span(dropped_file);

                    commands.putFile(std.fs.path.basename(filename), std.fs.path.dirname(filename) orelse ".", current_user, false) catch |err| {
                        const message = try std.fmt.allocPrint(dvui.currentWindow().arena(), "Unable to Put file {s}\n", .{filename});
                        errorDialog("Copying file", message, err);
                    };
                    image_directories = commands.directoryListing(allocator) catch null;
                    sortDirectories(.image, null);
                    Backend.c.SDL_free(dropped_file);
                },
                Backend.c.SDL_QUIT => break :main_loop,
                else => _ = try backend.addEvent(&win, event),
            }
        }

        // send all SDL events to dvui for processing
        //const quit = try backend.addAllEvents(&win);
        //if (quit) break :main_loop;

        // if dvui widgets might not cover the whole window, then need to clear
        // the previous frame's render
        _ = Backend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 255);
        _ = Backend.c.SDL_RenderClear(backend.renderer);

        const running = guiFrame() catch |err| {
            std.log.err("Encountered an unrecovereable error: {s}", .{@errorName(err)});
            return err;
        };
        if (!running) {
            break :main_loop;
        }

        // marks end of dvui frame, don't call dvui functions after this
        // - sends all dvui stuff to backend for rendering, must be called before renderPresent()
        const end_micros = try win.end(.{});

        // cursor management
        backend.setCursor(win.cursorRequested()) catch {};
        backend.textInputRect(win.textInputRequested()) catch {};

        // render frame to OS
        backend.renderPresent() catch {};

        // waitTime and beginWait combine to achieve variable framerates
        const wait_event_micros = win.waitTime(end_micros);
        interrupted = backend.waitEventTimeout(wait_event_micros) catch false;
    }
}

fn handleEvent(event: *const Backend.c.SDL_Event) void {
    switch (event.*.type) {
        Backend.c.SDL_DROPFILE => {
            const dropped_file = event.*.drop.file;
            Backend.c.SDL_free(dropped_file);
        },
        else => {},
    }
}
var theme_set = false;
var global_theme: dvui.Theme = undefined;
var reversed_theme: dvui.Theme = undefined;

const terminal_theme: dvui.Theme.QuickTheme = @import("theme.zon");

fn setTheme() !void {
    if (theme_set)
        return;

    // This is a slightly modified Jungle theme
    //const terminal_theme =
    //    \\{
    //    \\  "name": "Terminal",
    //    \\  "font_size": 16,
    //    \\  "font_name_body": "VeraMono",
    //    \\  "font_name_heading": "VeraMono",
    //    \\  "font_name_caption": "VeraMono",
    //    \\  "font_name_title": "VeraMono",
    //    \\  "color_focus": "#638465",
    //    \\  "color_text": "#82a29f",
    //    \\  "color_text_press": "#97af81",
    //    \\  "color_fill_text": "#2c3332",
    //    \\  "color_fill_container": "#2b3a3a",
    //    \\  "color_fill_control": "#2c3334",
    //    \\  "color_fill_hover": "#334e57",
    //    \\  "color_fill_press": "#3b6357",
    //    \\  "color_border": "#60827d"
    //    \\}
    //;
    //const parsed = try dvui.Theme.QuickTheme.fromString(allocator, terminal_theme);
    //defer parsed.deinit();
    //
    //const quick_theme = parsed.value;

    global_theme = try terminal_theme.toTheme(allocator);
    global_theme.font_title_4 = .{ .size = 14, .id = global_theme.font_title_4.id };

    dvui.themeSet(global_theme);
    reversed_theme = global_theme;
    reversed_theme.text = global_theme.control.fill.?;
    reversed_theme.control.fill = global_theme.text;
    reversed_theme.fill_press = global_theme.control.fill_hover.?;
    reversed_theme.fill_hover = global_theme.control.fill_press.?;

    theme_set = true;
}

var resize_image_grid: bool = false; // TODO: Should not be required anymore?

fn guiFrame() !bool {
    var running = true;
    if (!theme_set)
        try setTheme();
    if (!dvui.currentWindow().debug.open) dvui.toggleDebugWindow();
    if (!try makeMenu()) return false;

    // This vbox contains all of the UI below the menu
    var vbox = dvui.box(@src(), .{}, .{
        .expand = .both,
        .border = Rect.all(0),
        .background = true,
    });
    defer vbox.deinit();
    {
        // We need to contrain how far the scroll area expands so that there is room for the
        // status bar at the bottom of the screen. This vbox contails all of the UI excluding
        // the status bar.
        // TODO: fix this.
        const location = Rect{ .x = 0, .y = 0, .h = vbox.wd.rect.h - status_bar_height, .w = vbox.wd.rect.w };
        var inner_vbox = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .rect = location,
        });
        defer inner_vbox.deinit();

        // Handle keyboard and other global events
        // before any of the widgets can. Because we want to globally capture the
        // alt key being pressed etc.
        // TODO: This needs to be split up to events that should happen before widgets can handle them and
        // those that should be handled after all widgets.
        processEvents();

        // Paned widget containts the two scrolling file grids.
        // User can select horizontal or vertial orientation.
        var paned = dvui.paned(@src(), .{
            .direction = pane_orientation,
            .collapsed_size = 0,
        }, .{
            .expand = .both,
            .background = true,
        });
        defer paned.deinit();
        if (paned.showFirst()) {
            // Top (or left) half of the pane contaims the files from the Altair disk image.
            var top_half = dvui.box(@src(), .{}, .{
                .expand = .both,
                .color_border = dvui.themeGet().text,
                .border = dvui.Rect.all(2),
                .corner_radius = dvui.Rect.all(5),
                .background = true, // remove
            });
            defer top_half.deinit();
            try makeFileSelector(.image);

            for (image_col_widths[1..]) |*w| {
                if (w.* > 0) w.* = -w.*;
            }
            dvui.columnLayoutProportional(&image_col_widths, &image_col_widths, top_half.data().contentRect().w - GridWidget.scrollbar_padding_defaults.w);

            var grid = dvui.grid(@src(), .colWidths(&image_col_widths), .{ .resize_cols = resize_image_grid }, .{ .expand = .both, .background = true });
            defer grid.deinit();
            resize_image_grid = false;
            try makeGridHeader(.image, grid);
            makeGridBody(.image, grid);
        }
        if (paned.showSecond()) {
            // The bottom or right half is for displaying local system files.
            var bottom_half = dvui.box(@src(), .{}, .{
                .expand = .both,
                .border = dvui.Rect.all(2),
                .corner_radius = dvui.Rect.all(5),
                .background = true, // remove
            });
            defer bottom_half.deinit();
            try makeFileSelector(.local);
            var grid = dvui.box(@src(), .{}, .{
                .background = true,
                .expand = .horizontal,
            });
            defer grid.deinit();

            // This box is just for padding purposes
            var header = dvui.box(@src(), .{}, .{
                .expand = .horizontal,
                .background = true,
            });
            defer header.deinit();

            //try makeGridHeader(.local);
            //try makeGridBody(.local);
        }
    }
    {
        // This vbox contains any content below the paned. i.e. the usage bar graphs
        // and the status bars.

        // Place the status bar at the bottom of the screen.
        const location = Rect{ .y = vbox.wd.rect.h - status_bar_height, .x = 0, .h = status_bar_height, .w = vbox.wd.rect.w };
        var vbox_inner = dvui.box(@src(), .{}, .{
            .expand = .vertical,
            .rect = location,
            .margin = Rect{},
        });
        defer vbox_inner.deinit();
        {
            var stats_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .gravity_y = 0.0,
                .border = Rect.all(1),
                .corner_radius = Rect.all(5),
                .background = true,
            });
            defer stats_box.deinit();

            try makeCapacityUsageGraph();
            try makeDirectoriesUsageGraph();
        }

        // And below the usage graphs is the status bar menu.
        var menu_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .margin = Rect{ .y = 3 },
        });
        defer menu_box.deinit();
        running = try makeStatusBar();

        try makeTransferDialog();
    }

    return running;
}

// Create the application menus.
// Returns: false if quitting, true if running.
fn makeMenu() !bool {
    var m = dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Exit", .{}, .{}) != null) {
            m.close();
            return false;
        }
    }

    if (dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Shortcuts", .{}, .{}) != null) {
            show_shortcuts = true;
            m.close();
        }

        if (dvui.menuItemLabel(@src(), "About", .{}, .{}) != null) {
            m.close();
            dvui.dialog(@src(), .{}, .{
                .displayFn = aboutDialogDisplay,
                .message = "",
            });
        }
    }
    if (show_shortcuts) {
        try showShortcuts();
    }
    return true;
}

var show_shortcuts = false;
fn showShortcuts() !void {
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
    var dialog_win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &show_shortcuts }, .{});
    defer dialog_win.deinit();
    _ = dvui.windowHeader("Keyboard Shortcuts", "", &show_shortcuts);

    var vbox = dvui.box(@src(), .{}, .{ .expand = .both, .margin = Rect.all(5) });
    var idx: usize = 0;
    defer vbox.deinit();
    {
        var inner_vbox = dvui.box(@src(), .{}, .{ .expand = .vertical, .gravity_x = 0.5 });
        defer inner_vbox.deinit();
        dvui.labelNoFmt(@src(), "Menu Shortcuts", .{ .align_x = 0.5 }, .{ .font_style = .title_3 });
        while (shortcuts[idx].category == .command) : (idx += 1) {
            const s = &shortcuts[idx];
            dvui.label(@src(), "{s:<10}{s:<10}{s}", .{ s.shortcut, s.button orelse "", s.help_text }, .{ .id_extra = idx, .padding = Rect.all(2) });
        }
    }
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer hbox.deinit();
        {
            var inner_vbox = dvui.box(@src(), .{}, .{ .expand = .both, .margin = Rect.all(5) });
            defer inner_vbox.deinit();

            dvui.labelNoFmt(@src(), "Navigation Shortcuts", .{ .align_x = 0.5 }, .{ .font_style = .title_3 });
            while (idx != shortcuts.len and shortcuts[idx].category == .selection) : (idx += 1) {
                const s = &shortcuts[idx];
                dvui.label(@src(), "{s:<10}{s}", .{ s.shortcut, s.help_text }, .{ .id_extra = idx, .padding = Rect.all(2) });
            }
        }
        {
            var inner_vbox = dvui.box(@src(), .{}, .{ .expand = .both, .margin = Rect.all(5) });
            defer inner_vbox.deinit();
            dvui.labelNoFmt(@src(), "File Shortcuts", .{ .align_x = 0.5 }, .{ .font_style = .title_3 });
            while (idx != shortcuts.len and shortcuts[idx].category == .file) : (idx += 1) {
                const s = &shortcuts[idx];
                dvui.label(@src(), "{s:<10}{s}", .{ s.shortcut, s.help_text }, .{ .id_extra = idx, .padding = Rect.all(2) });
            }
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    if (buttonFocussed(@src(), "Close", .{}, .{ .gravity_x = 0.5 })) {
        show_shortcuts = false;
    }
}

fn makeFileSelector(id: GridType) !void {
    const path = switch (id) {
        .image,
        => &image_path_selection,
        .local => &local_path_selection,
    };

    const is_initialised = switch (id) {
        .image => &image_path_initialized,
        .local => &local_path_initialized,
    };

    var file_selector_box = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{
            .id_extra = id.toUSize(),
            .background = true,
            .expand = .horizontal,
        },
    );
    defer file_selector_box.deinit();
    switch (id) {
        .image => dvui.labelNoFmt(@src(), "Image:", .{ .align_x = 0.5 }, .{ .id_extra = id.toUSize(), .margin = alt_label_margin }),
        .local => dvui.labelNoFmt(@src(), "Local:", .{ .align_x = 0.5 }, .{ .id_extra = id.toUSize(), .margin = alt_label_margin }),
    }
    if (alt_held) {
        _ = dvui.separator(@src(), .{
            .id_extra = id.toUSize(),
            .rect = .{ .x = 5, .y = 30, .w = 10, .h = 2 },
            .color_fill = dvui.themeGet().text,
        });
    }

    var entry = dvui.textEntry(@src(), .{}, .{
        .id_extra = id.toUSize(),
        .expand = .horizontal,
    });
    errdefer entry.deinit();
    // TODO:
    //text_box_focused[id.toUSize()] = entry.wd.id == dvui.focusedWidgetId();
    if (alt_held) {
        const events = dvui.events();
        for (events) |*evt| {
            if (evt.handled or evt.evt != .key)
                continue;
            switch (evt.evt) {
                .key => |ke| {
                    if (ke.action == .down and (id == .image and ke.code == .i) or (id == .local and ke.code == .l)) {
                        evt.handled = true;
                        dvui.focusWidget(entry.wd.id, null, null);
                    }
                },
                else => {},
            }
        }
    }

    if (is_initialised.* == false) {
        is_initialised.* = true;
        entry.textSet(path.*.?, false);
        entry.textLayout.selection.moveCursor(path.*.?.len, false);
        dvui.refresh(null, @src(), null);
    }
    if (entry.enter_pressed) {
        switch (id) {
            .image => {
                try setImagePath(entry.getText());
                openImageFile(entry.getText());
            },
            .local => {
                try setLocalPath(entry.getText());
                openLocalDirectory(entry.getText());
            },
        }
        dvui.focusWidget(dvui.currentWindow().wd.id, null, null);
    }
    entry.deinit();

    if (buttonIcon(@src(), "toggle", folder_icon, .{ .draw_focus = false }, .{ .id_extra = id.toUSize() }, id)) {
        if (id == .image) {
            const path_to_use = path: {
                if (image_path_selection) |image_path| {
                    break :path std.fs.cwd().realpathAlloc(allocator, image_path) catch defaultPath();
                } else {
                    break :path std.fs.cwd().realpathAlloc(allocator, ".") catch defaultPath();
                }
            };
            defer allocator.free(path_to_use);
            try setImagePath(path_to_use);
            const filename = try dvui.dialogNativeFileOpen(dvui.currentWindow().arena(), .{
                .title = "Select disk image",
                .filters = &.{ "*.dsk", "*.img" },
                .filter_description = "images",
                .path = path_to_use,
            });
            if (filename) |f| {
                image_directories = null;
                openImageFile(f);
                try setImagePath(f);
                is_initialised.* = false;
            }
        } else {
            const path_to_use = path: {
                if (local_path_selection) |local_path| {
                    break :path std.fs.cwd().realpathAlloc(allocator, local_path) catch defaultPath();
                } else {
                    break :path std.fs.cwd().realpathAlloc(allocator, ".") catch defaultPath();
                }
            };
            defer allocator.free(path_to_use);
            try setLocalPath(path_to_use);

            const dirname =
                try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{ .title = "Select a Folder", .path = path_to_use });
            if (dirname) |dir| {
                openLocalDirectory(dir);
                try setLocalPath(dir);
            }
        }
    }
}

// TODO: Convert sorting to use numbers instead of names?
fn sortDir(id: GridType, col_num: usize) *dvui.GridWidget.SortDirection {
    return &gridData(id).sort_order[col_num];
}

fn makeGridHeader(id: GridType, grid: *dvui.GridWidget) !void {
    var col_num: usize = 0;
    {
        const col_name = "[_]";
        const sort_dir = sortDir(id, col_num);
        defer col_num += 1;
        _ = dvui.gridHeadingSortable(@src(), grid, col_num, col_name, sort_dir, .fixed, CellStyle{ .cell_opts = .{ .size = .{ .w = 45 } } });
    }
    {
        const col_name = "Name";
        const sort_dir = sortDir(id, col_num);
        defer col_num += 1;

        if (dvui.gridHeadingSortable(@src(), grid, col_num, col_name, sort_dir, .{
            .sizes = &image_col_widths,
            .num = col_num,
            .min_size = @abs(initial_col_widths[col_num]),
        }, .{})) {
            sortDirectories(id, col_num);
        }
    }
    {
        const col_name = "Ext";
        const sort_dir = sortDir(id, col_num);
        defer col_num += 1;

        if (dvui.gridHeadingSortable(@src(), grid, col_num, col_name, sort_dir, .{
            .sizes = &image_col_widths,
            .num = col_num,
            .min_size = @abs(initial_col_widths[col_num]),
        }, .{})) {
            sortDirectories(id, col_num);
        }
    }
    {
        const col_name = "A";
        const sort_dir = sortDir(id, col_num);
        defer col_num += 1;

        if (dvui.gridHeadingSortable(@src(), grid, col_num, col_name, sort_dir, .{
            .sizes = &image_col_widths,
            .num = col_num,
            .min_size = @abs(initial_col_widths[col_num]),
        }, .{})) {
            sortDirectories(id, col_num);
        }
    }
    {
        const col_name = "Size";
        const sort_dir = sortDir(id, col_num);
        defer col_num += 1;

        if (dvui.gridHeadingSortable(@src(), grid, col_num, col_name, sort_dir, .{
            .sizes = &image_col_widths,
            .num = col_num,
            .min_size = @abs(initial_col_widths[col_num]),
        }, .{})) {
            sortDirectories(id, col_num);
        }
    }
    {
        const col_name = "Used";
        const sort_dir = sortDir(id, col_num);
        defer col_num += 1;

        if (dvui.gridHeadingSortable(@src(), grid, col_num, col_name, sort_dir, .{
            .sizes = &image_col_widths,
            .num = col_num,
            .min_size = @abs(initial_col_widths[col_num]),
        }, .{})) {
            sortDirectories(id, col_num);
        }
    }
    {
        const col_name = "U";
        const sort_dir = sortDir(id, col_num);
        defer col_num += 1;

        if (dvui.gridHeadingSortable(@src(), grid, col_num, col_name, sort_dir, .{
            .sizes = &image_col_widths,
            .num = col_num,
            .min_size = @abs(initial_col_widths[col_num]),
        }, .{})) {
            sortDirectories(id, col_num);
        }
    }
}

// TODO: Thius needs some cleanup / refactoring. Especially for the guard / return cases.
fn makeGridBody(id: GridType, grid: *dvui.GridWidget) void {
    const directory_list = getDirectoryById(id);
    var should_display = true;

    const loaded = switch (id) {
        .image => if (image_directories == null) false else true,
        .local => if (local_directories == null) false else true,
    };
    if (!loaded) {
        var cell = grid.bodyCell(@src(), .colRow(0, 0), .{});
        cell.deinit();
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = id.toUSize() });
        defer hbox.deinit();
        switch (id) {
            .image => dvui.labelNoFmt(@src(), "Please open a disk image.", .{ .align_x = 0.5, .align_y = 0.5 }, .{ .id_extra = id.toUSize(), .expand = .both }),
            .local => dvui.labelNoFmt(@src(), "Please open a local directory.", .{ .align_x = 0.5, .align_y = 0.5 }, .{ .id_extra = id.toUSize(), .expand = .both }),
        }
        return;
    }

    // Don't display the body if:
    // 1) There are no directory entries
    // 2) There are no directory entries for the selected user id.
    if (directory_list.len == 0) {
        should_display = false;
    } else {
        switch (id) {
            .local => {}, // Always display local entires if there are some
            .image => { // Check if there are any files ot display for the current user.
                for (directory_list) |dir| {
                    if (current_user == 16 or current_user == dir.user()) {
                        should_display = true;
                        break;
                    }
                }
            },
        }
    }

    if (!should_display) {
        return;
    }

    // Filter out any files that shouldn't be displayed.
    const DisplayedFile = struct {
        entry: *DirectoryEntry,
        index: usize, // Real index of the entry in the unfiltered "directory_list"
    };
    var to_display = std.ArrayListUnmanaged(DisplayedFile).initCapacity(dvui.currentWindow().arena(), directory_list.len) catch return;
    // No need to deinit, as using arena.

    for (directory_list, 0..) |*entry, i| {
        if (entry.deleted) continue;
        if (id == .image and current_user != 16 and current_user != entry.user()) continue;
        to_display.appendAssumeCapacity(.{ .entry = entry, .index = i });
    }
    if (to_display.items.len == 0) return;

    var background: ?dvui.Color = null;

    if (pgdn_pressed and id == focussed_grid) {
        const nr_displayed: usize = @intFromFloat(gridData(id).scroll_info.viewport.h / row_height);
        const rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (selection_mode == .mouse and item.index == gridData(id).mouse_dir_index) {
                break :idx idx;
            } else if (selection_mode == .kb and item.index == gridData(id).kb_dir_index) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };
        gridData(id).scroll_info.scrollPageDown(.vertical);
        const new_index = @min(rel_index + nr_displayed, to_display.items.len - 1);

        gridData(id).mouse_dir_index = to_display.items[new_index].index;
        gridData(id).kb_dir_index = to_display.items[new_index].index;
    } else if (pgup_pressed and id == focussed_grid) {
        const nr_displayed: usize = @intFromFloat(gridData(id).scroll_info.viewport.h / row_height);
        const rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (selection_mode == .mouse and item.index == gridData(id).mouse_dir_index) {
                break :idx idx;
            } else if (selection_mode == .kb and item.index == gridData(id).kb_dir_index) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };
        gridData(id).scroll_info.scrollPageUp(.vertical);
        const new_index: usize = @max(rel_index, nr_displayed) - nr_displayed;
        gridData(id).mouse_dir_index = to_display.items[new_index].index;
        gridData(id).kb_dir_index = to_display.items[new_index].index;
    } else if (id == focussed_grid and down_pressed) {
        var rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (item.index == gridData(id).kb_dir_index) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };

        const dir_len = to_display.items.len;
        if (dir_len > 0 and rel_index < dir_len - 1) {
            rel_index += 1;
            gridData(focussed_grid).kb_dir_index = to_display.items[rel_index].index;
        }
    } else if (id == focussed_grid and up_pressed) {
        var rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (item.index == gridData(id).kb_dir_index) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };
        if (rel_index > 0) {
            rel_index -= 1;
            gridData(focussed_grid).kb_dir_index = to_display.items[rel_index].index;
        }
    } else {
        var rel_mouse_index: usize = 0;

        const evts = dvui.events();
        for (evts) |*e| {
            //            if (!dvui.eventMatchSimple(e, grid.data())) {
            //                continue;
            //            }

            switch (e.evt) {
                .mouse => |me| {
                    var dirs = getDirectoryById(id);
                    rel_mouse_index = if (grid.pointToCell(me.p)) |cell| cell.row_num else 0;
                    rel_mouse_index = @min(rel_mouse_index, dirs.len - 1);
                    const abs_mouse_index = to_display.items[rel_mouse_index].index;

                    if (me.action == .press and me.button.pointer()) {
                        e.handled = true;
                        if (!shift_held) {
                            dirs[abs_mouse_index].checked = !dirs[abs_mouse_index].checked;
                            gridData(id).last_mouse_index = abs_mouse_index;
                        } else {
                            const prev_index = gridData(id).last_mouse_index;
                            const prev_checked = dirs[prev_index].checked;
                            const first_idx = @min(prev_index, abs_mouse_index);
                            const last_idx = @max(prev_index, abs_mouse_index);
                            for (first_idx..last_idx + 1) |idx| {
                                dirs[idx].checked = prev_checked;
                            }
                        }
                    } else if (selection_mode == .mouse and me.action == .position) {
                        dvui.focusWidget(null, grid.data().id, e.num);
                        gridData(id).mouse_dir_index = abs_mouse_index;
                        gridData(id).kb_dir_index = abs_mouse_index;
                        focussed_grid = id;
                        selection_mode = .mouse;
                    } else if (me.action == .motion) {
                        selection_mode = .mouse;
                    }
                },
                else => {},
            }
        }
    }

    for (to_display.items, 0..) |entry, rel_idx| {
        // TODO: Make this nicer
        const abs_index = to_display.items[rel_idx].index;

        if ((selection_mode == .kb and abs_index == gridData(id).kb_dir_index and id == focussed_grid) or
            (selection_mode == .mouse and abs_index == gridData(id).mouse_dir_index and id == focussed_grid))
        {
            std.debug.print("Setting background for {d} to fill press\n", .{abs_index});
            background = dvui.themeGet().fill_press;
        } else {
            background = null;
        }
        var cell_num: dvui.GridWidget.Cell = .colRow(0, rel_idx);
        const cell_style: CellStyle = .{
            .cell_opts = .{ .background = true, .color_fill = background },
            .opts = .{ .margin = Rect.all(4), .padding = Rect.all(0) },
        };
        const cell_style_right = cell_style.optionsOverride(.{ .gravity_x = 1.0 });
        const cell_style_fixed = cell_style.cellOptionsOverride(.{ .size = .{ .w = 45 } });

        const invalid_number_display = "####";
        var buf = std.mem.zeroes([256]u8);
        const checked_value = if (getDirectoryById(id)[abs_index].checked) "[X]" else "[ ]";
        makeGridDataRow(@src(), grid, cell_num, rel_idx, checked_value, &cell_style_fixed);
        cell_num.col_num += 1;
        makeGridDataRow(@src(), grid, cell_num, rel_idx, entry.entry.filename(), &cell_style);
        cell_num.col_num += 1;
        makeGridDataRow(@src(), grid, cell_num, rel_idx, entry.entry.extension(), &cell_style);
        cell_num.col_num += 1;
        makeGridDataRow(@src(), grid, cell_num, rel_idx, entry.entry.attribs(), &cell_style);
        cell_num.col_num += 1;

        var text = formatNumber(&buf, "{}B", entry.entry.fileSizeInB(), "####,###B") catch invalid_number_display;
        makeGridDataRow(@src(), grid, cell_num, rel_idx, text, &cell_style_right);
        cell_num.col_num += 1;

        text = formatNumber(&buf, "{}K", entry.entry.fileUsedInKB(), "#,###K") catch invalid_number_display;
        makeGridDataRow(@src(), grid, cell_num, rel_idx, text, &cell_style_right);
        cell_num.col_num += 1;

        text = std.fmt.bufPrint(&buf, "{}", .{entry.entry.user()}) catch "##";
        makeGridDataRow(@src(), grid, cell_num, rel_idx, text, &cell_style_right);
        cell_num.col_num += 1;

        const nr_displayed = gridData(id).scroll_info.viewport.h / row_height - 2;
        if (id == focussed_grid and selection_mode == .kb and gridData(id).kb_dir_index == abs_index) {
            const my_pos: f32 = @as(f32, @floatFromInt(rel_idx)) * row_height; // relative pos
            const viewport_btm = gridData(id).scroll_info.viewport.y + gridData(id).scroll_info.viewport.h - 40;
            if (viewport_btm < my_pos) {
                const scroll_pos: f32 = my_pos - (nr_displayed * row_height);
                gridData(id).scroll_info.scrollToOffset(.vertical, scroll_pos);
            } else if (my_pos < gridData(id).scroll_info.viewport.y + 40) {
                const scroll_pos: f32 = my_pos - row_height;
                gridData(id).scroll_info.scrollToOffset(.vertical, scroll_pos);
            }
        }
    }
}

//fn makeGridHeading(label: []const u8, num: u32, id: GridType) void {
//    var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{
//        .id_extra = num,
//        .expand = .horizontal,
//    });
//    defer grp.deinit();
//    if (dvui.button(
//        @src(),
//        label,
//        .{ .draw_focus = false },
//        .{
//            .id_extra = num,
//            .corner_radius = Rect{},
//            .margin = Rect{},
//            .expand = .horizontal,
//            .min_size_content = .{ .h = 1, .w = min_sizes[num] },
//        },
//    )) {
//        if (num == 0) {
//            // Select all / none
//            var checked = false;
//            for (getDirectoryById(id)) |dir| {
//                if (!dir.checked) {
//                    checked = true;
//                    break;
//                }
//            }
//            for (getDirectoryById(id)) |*dir| {
//                dir.checked = checked;
//            }
//        } else {
//            sortDirectories(id, label, true);
//        }
//    }
//    _ = dvui.separator(@src(), .{ .id_extra = num, .expand = .vertical, .margin = Rect.all(1) });
//    header_rects[num] = grp.data().rect;
//}

/// Creates one row in the grid.
/// Note the use of the cols_rects array to make sure the scolling columns
/// are kept the same size as the header columns.
fn makeGridDataRow(src: std.builtin.SourceLocation, grid: *GridWidget, cell_num: Cell, item_num: usize, value: []const u8, cell_style: *const CellStyle) void {
    // Can comfortably handle the max 1024 entries in ReleaseSafe mode.
    // TODO: Handle scolling ourselves, so that we just render the number of entries required, rather than the
    // whole area. This way we can handle an "unlimited" number of directory entries.
    if (item_num > 1024) {
        return;
    }
    var cell = grid.bodyCell(src, cell_num, cell_style.cell_opts);
    defer cell.deinit();
    dvui.labelNoFmt(@src(), value, .{ .align_y = 0.5, .align_x = cell_style.opts.gravityGet().x }, cell_style.opts);
}

fn makeCapacityUsageGraph() !void {
    dvui.label(@src(), "Capacity:", .{}, .{ .gravity_y = 0.5 });
    {
        var files_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .border = Rect.all(1),
            .background = true,
            .min_size_content = .{ .h = 20, .w = 250 },
            .margin = Rect.all(5),
        });
        defer files_box.deinit();
        if (commands.disk_image) |disk_image| {
            const total_space = disk_image.capacityTotalInKB();
            const free_space = disk_image.capacityFreeInKB();
            const used_space = total_space - free_space;
            const percentage: f32 = @as(f32, @floatFromInt(used_space)) / @as(f32, @floatFromInt(total_space));
            const width = percentage * 250;
            {
                var used_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .color_fill = dvui.themeGet().fill_hover,
                    .background = true,
                    .min_size_content = .{ .h = 20, .w = width },
                });
                defer used_box.deinit();
            }
            var msg_buf: [256]u8 = undefined;
            const message = try std.fmt.bufPrint(&msg_buf, "{:>6}K used {:>6}K remain ", .{ used_space, free_space });

            dvui.labelNoFmt(@src(), message, .{}, .{
                // TODO: Can we remove this hardcoding of rect?
                .rect = .{ .x = 0, .y = 0, .h = 20, .w = 250 },
                .padding = Rect.all(2),
            });
        }
    }
}

fn makeDirectoriesUsageGraph() !void {
    dvui.label(@src(), "Directories:", .{}, .{ .gravity_y = 0.5 });
    {
        var files_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .border = Rect.all(1),
            .background = true,
            .min_size_content = .{ .h = 20, .w = 250 },
            .margin = Rect.all(5),
        });
        defer files_box.deinit();
        if (commands.disk_image) |disk_image| {
            const max_directories = disk_image.image_type.directories;
            const used_directories = disk_image.directoryFreeCount();
            const free_directories = max_directories - used_directories;
            const percentage = @as(f32, @floatFromInt(used_directories)) / @as(f32, @floatFromInt(max_directories));
            const width = percentage * 250;
            {
                var used_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .color_fill = dvui.themeGet().fill_hover,
                    .background = true,
                    .min_size_content = .{ .h = 20, .w = width },
                });
                defer used_box.deinit();
            }
            var msg_buf: [256]u8 = undefined;
            const message = try std.fmt.bufPrint(&msg_buf, "{:>7} used {:>7} remain ", .{ used_directories, free_directories });

            dvui.labelNoFmt(@src(), message, .{}, .{
                // TODO: Can we remove this hardcoding of rect?
                .rect = .{ .x = 0, .y = 0, .h = 20, .w = 250 },
                .padding = Rect.all(2),
            });
        }
    }
}

fn makeStatusBar() !bool {
    //const theme = dvui.themeGet();
    const reversed = dvui.Options{
        //        .color_text = theme.window.fill,
        //        .color_fill = theme.text,
        //        .color_fill_hover = .{ .name = .fill_press }, // Added.
        //        .color_fill_press = .{ .name = .fill_hover }, // Added.
        .expand = .horizontal,
        .margin = Rect{ .x = 2, .w = 2, .y = 2, .h = 0 },
        .corner_radius = Rect.all(0),
        .background = true,
    };

    dvui.themeSet(reversed_theme);
    {
        defer dvui.themeSet(global_theme);

        if (statusBarButton(@src(), "GET", .{}, reversed, 0, .get, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try getButtonHandler();
            }
        }
        if (statusBarButton(@src(), "PUT", .{}, reversed, 0, .put, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try putButtonHandler();
            }
        }
        if (statusBarButton(@src(), "ERASE", .{}, reversed, 0, .erase, image_directories != null) or
            CommandState.current_command == .erase)
        {
            if (CommandState.shouldProcessCommand()) {
                try eraseButtonHandler();
            }
        }
        if (statusBarButton(@src(), "GET SYS", .{}, reversed, 4, .getsys, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try getSysButtonHandler();
            }
        }
        if (statusBarButton(@src(), "PUT SYS", .{}, reversed, 5, .putsys, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try putSysButtonHandler();
            }
        }
        if (statusBarButton(@src(), "CLOSE", .{}, reversed, 0, .close, image_directories != null)) {
            commands.closeImage();
            image_directories = null;
            CommandState.finishCommand();
        }

        if (statusBarButton(@src(), "INFO", .{}, reversed, 2, .info, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try infoButtonHandler();
            }
        }

        var buf: [20]u8 = undefined;
        var label = if (current_user == 16)
            try std.fmt.bufPrint(&buf, "USER *", .{})
        else
            try std.fmt.bufPrint(&buf, "USER {}", .{current_user});

        if (statusBarButton(@src(), label, .{}, reversed, 0, .user, true)) {
            current_user += 1;
            current_user %= 17;
            if (current_user != 16) {
                if (image_directories) |directories| {
                    for (directories) |*entry| {
                        if (entry.user() != current_user) {
                            entry.checked = false;
                        }
                    }
                }
            }
            CommandState.finishCommand();
        }

        if (statusBarButton(@src(), "NEW", .{}, reversed, 0, .new, true)) {
            if (CommandState.shouldProcessCommand()) {
                try newButtonHandler();
            }
        }
        label = try std.fmt.bufPrint(&buf, "{s}", .{@tagName(copy_mode)});
        const underline_pos: usize = if (copy_mode == .BINARY) 3 else 0;
        if (statusBarButton(@src(), label, .{}, reversed, underline_pos, .mode, true)) {
            copy_mode = nextCopyMode(copy_mode);
            CommandState.finishCommand();
        }

        if (statusBarButton(@src(), "ORIENT", .{}, reversed, 1, .orient, true)) {
            if (pane_orientation == .horizontal) {
                pane_orientation = .vertical;
            } else {
                pane_orientation = .horizontal;
                dvui.refresh(null, @src(), null);
            }
            CommandState.finishCommand();
        }
        if (statusBarButton(@src(), "EXIT", .{}, reversed, 1, .exit, true)) {
            return false;
        }
    }
    return true;
}

pub fn makeTransferDialog() !void {
    const static = struct {
        var open_flag: bool = false;
        var scroll_info: dvui.ScrollInfo = .{};
        var last_nr_messages: usize = 0;
        var choice: usize = 0;
    };
    showing_dialog = false;
    if (CommandState.state != .waiting_for_input and CommandState.processed_files.items.len == 0) {
        return;
    } else {
        static.open_flag = true; // is the dialog open?
        showing_dialog = true;
    }
    var dialog_win = dvui.floatingWindow(
        @src(),
        .{ .modal = true, .open_flag = &static.open_flag },
        .{
            .min_size_content = .{ .w = 500, .h = 500 },
            .max_size_content = .{ .w = 500, .h = 500 },
        },
    );
    defer dialog_win.deinit();

    const title = title: switch (CommandState.current_command) {
        .get => "Copy from Altair to Local",
        .put => "Copy from Local to Altair",
        .erase => "Erase file from Altair",
        .getsys => "Copy system image from Altair",
        .putsys => "Copy system image to Altair",
        .info => "Altair disk image information",
        .new => "Create new Altair disk iamge",
        .none => continue :title if (CommandState.prev_command != .none) CommandState.prev_command else @panic("Invalid Command State"),
        .close, .exit, .mode, .user, .orient => unreachable,
    };

    _ = dvui.windowHeader(title, "", &static.open_flag);
    var outer_vbox = dvui.box(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .w = 500, .h = 500 },
        .max_size_content = .{ .w = 500, .h = 500 },
    });
    const KeyState = enum { none, yes, no, yes_all, no_all, enter };
    var key_state: KeyState = .none;

    const evts = dvui.events();
    for (evts) |*e| {
        if (e.handled or e.evt != .key) continue;
        const ke = e.evt.key;
        if (ke.action != .down) continue;

        switch (ke.code) {
            .y => {
                if (ke.mod == .lshift or ke.mod == .rshift) {
                    key_state = .yes_all;
                } else {
                    key_state = .yes;
                }
            },
            .n => {
                if (ke.mod == .lshift or ke.mod == .rshift) {
                    key_state = .no_all;
                } else {
                    key_state = .no;
                }
            },
            .space, .enter => {
                key_state = .enter;
            },
            else => {},
        }
    }

    defer outer_vbox.deinit();
    {
        var scroll = dvui.scrollArea(
            @src(),
            .{ .horizontal_bar = .hide, .scroll_info = &static.scroll_info },
            .{
                .expand = .horizontal,
                .background = false,
                .max_size_content = .{ .w = 500, .h = 500 - 75 },
            },
        );
        defer scroll.deinit();
        var current_file: *FileStatus = undefined; // We already know there are files by the time wer get here.
        {
            // Display the files.
            var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .background = false });
            defer vbox.deinit();
            for (CommandState.processed_files.items, 0..) |*file, i| {
                const basename = std.fs.path.basename(file.filename);
                var text = dvui.textLayout(@src(), .{}, .{
                    .id_extra = i,
                    .background = false,
                    .padding = Rect.all(0),
                    .margin = Rect.all(4),
                });
                defer text.deinit();
                text.addText(try std.fmt.allocPrint(
                    dvui.currentWindow().arena(),
                    "{s:<12} {s} {s}",
                    .{ basename, if (basename.len > 0) "-->" else "", file.message },
                ), .{
                    .id_extra = i,
                });
                current_file = file;
            }
        }

        var empty_file_selector = false;
        if (CommandState.state == .waiting_for_input) {
            var button_box = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer button_box.deinit();

            if (CommandState.buttons.image_selector or CommandState.buttons.save_file_selector or CommandState.buttons.open_file_selector) {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                defer vbox.deinit();
                {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer hbox.deinit();
                    if (CommandState.buttons.image_selector) {
                        dvui.labelNoFmt(@src(), "Image name:", .{ .align_y = 0.5 }, .{});
                    } else {
                        dvui.labelNoFmt(@src(), "File name:", .{ .align_y = 0.5 }, .{});
                    }

                    var entry = dvui.textEntry(@src(), .{}, .{ .expand = .horizontal });
                    errdefer entry.deinit();
                    if (CommandState.file_selector_buffer == null) {
                        if (CommandState.buttons.image_selector) {
                            if (image_path_selection) |image_path| {
                                const dir_path = std.fs.path.dirname(image_path) orelse ".";
                                const image_name = try findNewImageName(CommandState.arena.allocator(), dir_path);
                                try CommandState.setFileSelectorBuffer(image_name);
                                entry.textSet(image_name, false);

                                entry.textLayout.selection.moveCursor(image_name.len, false);
                                dvui.refresh(null, @src(), null);
                            }
                        } else {
                            const current_dir = try std.fs.cwd().realpathAlloc(CommandState.arena.allocator(), ".");
                            const filename = try std.fs.path.join(CommandState.arena.allocator(), &[2][]const u8{ current_dir, "cpm.bin" });
                            try CommandState.setFileSelectorBuffer(filename);
                            entry.textSet(filename, false);
                            entry.textLayout.selection.moveCursor(filename.len, false);

                            dvui.refresh(null, @src(), null);
                        }
                    }
                    if (entry.enter_pressed or entry.text_changed) {
                        try CommandState.setFileSelectorBuffer(entry.getText());
                    }
                    empty_file_selector = entry.getText().len == 0;
                    entry.deinit();
                    if (dvui.buttonIcon(@src(), "toggle", folder_icon, .{}, .{}, .{})) {
                        if (CommandState.buttons.image_selector) {
                            if (try dvui.dialogNativeFileSave(dvui.currentWindow().arena(), .{
                                .title = "Save image as",
                                .filters = &.{ "*.DSK", "*.IMG", "*.dsk", "*.img" },
                                .filter_description = "Altair Disk Images *.dsk;*.img",
                            })) |filename| {
                                try CommandState.setFileSelectorBuffer(filename);
                                entry.textSet(filename, false);
                                entry.textLayout.selection.moveCursor(filename.len, false);
                                dvui.refresh(null, @src(), null);
                            }
                        } else if (CommandState.buttons.save_file_selector) {
                            const current_dir = try std.fs.cwd().realpathAlloc(CommandState.arena.allocator(), ".");
                            const default_name = try std.fs.path.join(CommandState.arena.allocator(), &[2][]const u8{ current_dir, "cpm.bin" });
                            try CommandState.setFileSelectorBuffer(default_name);
                            if (try dvui.dialogNativeFileSave(dvui.currentWindow().arena(), .{
                                .title = "Save file as",
                                .filters = &.{ "*.bin", "*.cpm", "*.BIN", "*.CPM" },
                                .filter_description = "System Images *.bin;*.cpm",
                            })) |filename| {
                                try CommandState.setFileSelectorBuffer(filename);
                                entry.textSet(filename, false);
                                entry.textLayout.selection.moveCursor(filename.len, false);
                                dvui.refresh(null, @src(), null);
                            }
                        } else {
                            // TODO: Remember the last thing they saved / loaded?
                            const current_dir = try std.fs.cwd().realpathAlloc(CommandState.arena.allocator(), ".");
                            const default_name = try std.fs.path.join(CommandState.arena.allocator(), &[2][]const u8{ current_dir, "cpm.bin" });
                            try CommandState.setFileSelectorBuffer(default_name);

                            if (try dvui.dialogNativeFileOpen(dvui.currentWindow().arena(), .{
                                .title = "Save file as",
                                .filters = &.{ "*.bin", "*.cpm", "*.BIN", "*.CPM" },
                                .filter_description = "System Images *.bin;*.cpm",
                            })) |filename| {
                                try CommandState.setFileSelectorBuffer(filename);
                                entry.textSet(filename, false);
                                entry.textLayout.selection.moveCursor(filename.len, false);
                                dvui.refresh(null, @src(), null);
                            }
                        }
                    }
                }

                if (CommandState.buttons.type_selector) {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer hbox.deinit();

                    dvui.labelNoFmt(@src(), "Format:    ", .{ .align_y = 0.5 }, .{});

                    if (dvui.dropdown(@src(), &ad.all_disk_type_names, &static.choice, .{})) {
                        CommandState.image_type = &ad.all_disk_types.values[static.choice];
                    }
                }
            }
            // Check we have some type of filename.
            if (empty_file_selector) {
                CommandState.err_message = "Please enter a new image filename";
            } else {
                var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer hbox.deinit();
                if (CommandState.prompt) |prompt| {
                    dvui.labelNoFmt(@src(), prompt, .{ .align_y = 0.5 }, .{});
                }

                if (CommandState.buttons.yes) {
                    if (dvui.button(@src(), "[y] Yes", .{}, .{}) or key_state == .yes) {
                        CommandState.state = .confirm;
                    }
                }
                if (CommandState.buttons.no) {
                    if (dvui.button(@src(), "[n] No", .{}, .{}) or key_state == .no) {
                        CommandState.state = .cancel;
                    }
                }
                if (CommandState.buttons.yes_all) {
                    if (dvui.button(@src(), "[Y] Yes to All", .{}, .{}) or key_state == .yes_all) {
                        CommandState.confirm_all = .yes_to_all;
                        CommandState.state = .confirm;
                    }
                }
                if (CommandState.buttons.no_all) {
                    if (dvui.button(@src(), "[N] No to All", .{}, .{}) or key_state == .no_all) {
                        CommandState.confirm_all = .no_to_all;
                        CommandState.state = .cancel;
                    }
                }
            }

            {
                if (CommandState.err_message) |message| {
                    var text = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
                    defer text.deinit();
                    text.addText(message, .{});
                    if (empty_file_selector) {
                        CommandState.err_message = null;
                    }
                }
            }
        }
        // Scroll to end if list is bigger
        const nr_messages = CommandState.processed_files.items.len;
        if (nr_messages > static.last_nr_messages or !CommandState.buttons.isNone()) {
            static.scroll_info.scrollToOffset(.vertical, 99999);
        }
        static.last_nr_messages = nr_messages;
    }

    {
        var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 1.0 });
        defer vbox.deinit();
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer hbox.deinit();

        if (CommandState.current_command != .none) {
            _ = dvui.button(@src(), "Working...", .{}, .{});
        } else {
            if (key_state == .enter or buttonFocussed(@src(), "Close", .{}, .{})) {
                CommandState.finishCommand();
                CommandState.freeResources();
                dialog_win.close(); // can close the dialog this way
                if (local_directories != null) {
                    local_directories = commands.localDirectoryListing(allocator) catch null;
                    sortDirectories(.local, null);
                }
                if (image_directories != null) {
                    image_directories = commands.directoryListing(allocator) catch null;
                    sortDirectories(.image, null);
                }
            }
        }
    }

    for (evts) |*e| {
        if (e.handled or e.evt != .key) continue;
        if (!e.handled) e.handle(@src(), dialog_win.data());
    }
}

pub fn aboutDialogDisplay(id: dvui.Id) !void {
    var win = dvui.floatingWindow(
        @src(),
        .{ .modal = true, .window_avoid = .nudge },
        .{ .id_extra = id.asUsize() },
    );
    defer win.deinit();

    var header_openflag = true;
    _ = dvui.windowHeader("About ADGUI", "", &header_openflag);
    if (!header_openflag) {
        dvui.dialogRemove(id);
        return;
    }

    {
        // Add the buttons at the bottom first, so that they are guaranteed to be shown
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 1.0 });
        defer hbox.deinit();

        if (buttonFocussed(@src(), "OK", .{}, .{ .tab_index = 1 })) {
            dvui.dialogRemove(id);
            return;
        }
    }
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
    })) {
        _ = dvui.openURL(url);
    }
    const tl_rect = tl.data().contentRect();
    tl.deinit();

    const underline_rect: dvui.Rect = .{ .x = tl_rect.x, .y = tl_rect.y + 35, .h = 1, .w = tl_rect.w };
    _ = dvui.separator(@src(), .{
        .rect = underline_rect,
        .color_fill = if (!hovered) dvui.themeGet().text else color_url,
    });
}

fn sortAsc(col_num: usize, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
    return switch (GridColumns.fromUsize(col_num)) {
        .@"[_]" => lhs.checked and !rhs.checked,
        .Name => std.mem.order(u8, lhs.filename(), rhs.filename()) == .lt,
        .Ext => std.mem.order(u8, lhs.extension(), rhs.extension()) == .lt,
        .Size => lhs.fileSizeInB() < rhs.fileSizeInB(),
        .Used => lhs.fileUsedInKB() < rhs.fileUsedInKB(),
        .A => std.mem.order(u8, lhs.attribs(), rhs.attribs()) == .lt,
        .U => lhs.user() < rhs.user(),
    };
}

fn sortDesc(col_num: usize, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
    return switch (GridColumns.fromUsize(col_num)) {
        .@"[_]" => !lhs.checked and rhs.checked,
        .Name => std.mem.order(u8, lhs.filename(), rhs.filename()) == .gt,
        .Ext => std.mem.order(u8, lhs.extension(), rhs.extension()) == .gt,
        .Size => lhs.fileSizeInB() > rhs.fileSizeInB(),
        .Used => lhs.fileUsedInKB() > rhs.fileUsedInKB(),
        .A => std.mem.order(u8, lhs.attribs(), rhs.attribs()) == .gt,
        .U => lhs.user() > rhs.user(),
    };
}

fn currentSortCol(id: GridType) usize {
    for (gridData(id).sort_order, 0..) |order, col_num| {
        if (order != .unsorted) return col_num;
    }
    const default_col = GridColumns.Name.toUsize();
    gridData(id).sort_order[default_col] = .ascending;
    return default_col;
}

fn sortOrderForCol(id: GridType, col_num: usize) dvui.GridWidget.SortDirection {
    return gridData(id).sort_order[col_num];
}

fn sortDirectories(id: GridType, sort_by_opt: ?usize) void {
    if (sort_by_opt) |new_col| {
        const current_sort_col = currentSortCol(id);

        if (new_col != current_sort_col) {
            gridData(id).sort_order[current_sort_col] = .unsorted;
        }
    }
    const sort_col = sort_by_opt orelse currentSortCol(id);
    const to_sort = getDirectoryById(id);

    if (sortOrderForCol(id, sort_col) == .ascending) {
        std.mem.sort(DirectoryEntry, to_sort, sort_col, sortAsc);
    } else {
        std.mem.sort(DirectoryEntry, to_sort, sort_col, sortDesc);
    }
}

// We need another format that does B/K/M/G
fn formatNumber(buf: []u8, comptime fmt: []const u8, value: usize, overflow: []const u8) ![]const u8 {
    var tmp_buf = std.mem.zeroes([20]u8);
    const slice = try std.fmt.bufPrint(&tmp_buf, fmt, .{value});

    // reverse the number ot make it easier to process
    var digit_count: usize = 0;
    var buf_idx: usize = 0;
    var slice_idx = slice.len;
    while (slice_idx != 0) : (slice_idx -= 1) {
        const c = slice[slice_idx - 1];
        if (!std.ascii.isDigit(c)) {
            digit_count = 0;
        } else {
            digit_count += 1;
            if (digit_count == 4) {
                buf[buf_idx] = ',';
                buf_idx += 1;
            }
        }
        buf[buf_idx] = c;
        buf_idx += 1;
    }
    if (buf_idx > overflow.len) {
        return overflow[0..];
    } else {
        const result_slice = buf[0..buf_idx];
        std.mem.reverse(u8, result_slice);
        return result_slice;
    }
}

pub fn labelNoFmtRect(src: std.builtin.SourceLocation, str: []const u8, opts: Options) dvui.Rect {
    var lw = dvui.LabelWidget.initNoFmt(src, str, .{}, opts);
    lw.install();
    lw.draw();
    const rect = lw.wd.rect;
    lw.deinit();
    return rect;
}

pub fn statusBarButton(
    src: std.builtin.SourceLocation,
    label_str: []const u8,
    _init_opts: dvui.ButtonWidget.InitOptions,
    opts: Options,
    underline_pos: usize,
    cmd: CommandList,
    enabled: bool,
) bool {
    _ = _init_opts;
    const init_opts: dvui.ButtonWidget.InitOptions = .{ .draw_focus = false };
    // If running another command, just show the label.

    const selected = CommandState.current_command == cmd;
    var options2 = opts;
    if (selected) {
        options2 = options2.override(.{ .color_fill = dvui.themeGet().fill });
    } else if (!enabled) {
        options2 = options2.override(.{ .color_fill = opts.color(.fill_press) });
    }
    var bw = dvui.ButtonWidget.init(src, init_opts, options2);

    bw.click = selected;

    // make ourselves the new parent
    bw.install();

    // process events (mouse and keyboard) unless another operation is in progress.
    if (CommandState.current_command == .none and !enter_pressed and enabled) {
        bw.processEvents();
    }

    // draw background/border
    bw.drawBackground();

    // use pressed text color if desired
    const click = bw.clicked();
    var options = opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.5 });

    if (bw.pressed() or selected) options = options.override(.{ .color_text = opts.color(.text_press) });

    // this child widget:
    // - has bw as parent
    // - gets a rectangle from bw
    // - draws itself
    // - reports its min size to bw
    const label_rect = labelNoFmtRect(src, label_str, options);
    const fill_color = color: {
        if (!enabled or bw.hover) {
            break :color opts.color(.fill_press);
        } else if (alt_held) {
            break :color opts.color(.text);
        } else {
            break :color opts.color(.fill);
        }
    };
    _ = dvui.separator(@src(), .{
        .rect = .{ .x = label_rect.x + @as(f32, @floatFromInt(underline_pos)) * 8, .y = 15, .w = 10, .h = 2 },
        .color_fill = fill_color,
        .background = true,
    });
    // draw focus
    bw.drawFocus();

    // restore previous parent
    // send our min size to parent
    bw.deinit();
    if (selected) {
        dvui.refresh(null, @src(), null);
    }

    return click;
}

pub fn buttonIcon(src: std.builtin.SourceLocation, name: []const u8, tvg_bytes: []const u8, init_opts: dvui.ButtonWidget.InitOptions, opts: Options, id: GridType) bool {
    const defaults = Options{ .padding = Rect.all(4) };
    var bw = dvui.ButtonWidget.init(src, init_opts, defaults.override(opts));
    bw.install();
    bw.processEvents();
    bw.drawBackground();

    // When someone passes min_size_content to buttonIcon, they want the icon
    // to be that size, so we pass it through.

    dvui.icon(@src(), name, tvg_bytes, .{}, opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.0, .min_size_content = opts.min_size_content, .expand = .ratio }));

    if (alt_held) {
        const theme = dvui.themeGet();
        const label_rect = labelNoFmtRect(@src(), if (id == .image) "M" else "O", .{
            .color_fill = theme.text,
            .color_text = theme.control.fill,
            .background = true,
        });
        _ = dvui.separator(src, .{
            .id_extra = 1, // Not sure why required.
            .rect = .{ .x = label_rect.x + 5, .y = 20, .w = 10, .h = 2 },
            .color_fill = theme.control.fill,
        });

        const events = dvui.events();
        for (events) |*evt| {
            if (evt.handled or evt.evt != .key)
                continue;
            switch (evt.evt) {
                .key => |ke| {
                    if (id == .image and ke.code == .m) {
                        evt.handled = true;
                        bw.click = true;
                    } else if (id == .local and ke.code == .o) {
                        evt.handled = true;
                        bw.click = true;
                    }
                },
                else => {},
            }
        }
    } else {
        dvui.labelNoFmt(@src(), " ", .{ .align_x = 0.5, .align_y = 0.5 }, .{ .font_style = .body });
    }

    const click = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return click;
}

pub fn buttonFocussed(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: dvui.ButtonWidget.InitOptions, opts: Options) bool {
    // initialize widget and get rectangle from parent
    var bw = dvui.ButtonWidget.init(src, init_opts, opts);

    // make ourselves the new parent
    bw.install();

    dvui.focusWidget(bw.wd.id, null, null);

    // process events (mouse and keyboard)
    bw.processEvents();

    // draw background/border
    bw.drawBackground();

    // use pressed text color if desired
    const click = bw.clicked();
    var options = opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.5 });

    if (bw.pressed()) options = options.override(.{ .color_text = opts.color(.text_press) });

    // this child widget:
    // - has bw as parent
    // - gets a rectangle from bw
    // - draws itself
    // - reports its min size to bw
    dvui.labelNoFmt(@src(), label_str, .{}, options);

    // draw focus
    bw.drawFocus();

    // restore previous parent
    // send our min size to parent

    bw.deinit();

    return click;
}

pub fn dialogDisplay(id: dvui.Id) !void {
    const modal = dvui.dataGet(null, id, "_modal", bool) orelse {
        std.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const title = dvui.dataGetSlice(null, id, "_title", []u8) orelse {
        std.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const message = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
        std.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const ok_label = dvui.dataGetSlice(null, id, "_ok_label", []u8) orelse {
        std.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const center_on = dvui.dataGet(null, id, "_center_on", Rect.Natural) orelse dvui.currentWindow().subwindow_currentRect;

    const cancel_label = dvui.dataGetSlice(null, id, "_cancel_label", []u8);

    const callafter = dvui.dataGet(null, id, "_callafter", dvui.DialogCallAfterFn);

    const maxSize = dvui.dataGet(null, id, "_max_size", dvui.Options.MaxSize);

    var win = dvui.floatingWindow(
        @src(),
        .{ .modal = modal, .center_on = center_on, .window_avoid = .nudge },
        .{ .id_extra = id.asUsize(), .max_size_content = maxSize },
    );
    defer win.deinit();

    var header_openflag = true;
    _ = dvui.windowHeader(title, "", &header_openflag);
    if (!header_openflag) {
        dvui.dialogRemove(id);
        if (callafter) |ca| {
            try ca(id, .cancel);
        }
        return;
    }

    {
        // Add the buttons at the bottom first, so that they are guaranteed to be shown
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 1.0 });
        defer hbox.deinit();

        if (buttonFocussed(@src(), ok_label, .{}, .{ .tab_index = 1 })) {
            dvui.dialogRemove(id);
            if (callafter) |ca| {
                try ca(id, .ok);
            }
            return;
        }

        if (cancel_label) |cl| {
            if (dvui.button(@src(), cl, .{}, .{ .tab_index = 2 })) {
                dvui.dialogRemove(id);
                if (callafter) |ca| {
                    try ca(id, .cancel);
                }
                return;
            }
        }

        const evts = dvui.events();
        for (evts) |*e| {
            if (e.handled or e.evt != .key) continue;
            const ke = e.evt.key;
            if (ke.action != .down) continue;

            switch (ke.code) {
                .enter, .one => {
                    e.handled = true;
                    dvui.dialogRemove(id);
                    if (callafter) |ca| {
                        try ca(id, .ok);
                    }
                    return;
                },
                .escape, .two => {
                    e.handled = true;
                    dvui.dialogRemove(id);
                    if (callafter) |ca| {
                        try ca(id, .cancel);
                    }
                    return;
                },
                else => {},
            }
        }
    }

    // Now add the scroll area which will get the remaining space
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = dvui.themeGet().control.fill });
    var tl = dvui.textLayout(@src(), .{}, .{ .background = false, .gravity_x = 0.5 });
    tl.addText(message, .{});
    tl.deinit();
    scroll.deinit();
}

pub fn processEvents() void {
    const evts = dvui.events();
    pgdn_pressed = false;
    pgup_pressed = false;
    up_pressed = false;
    down_pressed = false;

    if (showing_dialog) {
        alt_held = false;
        shift_held = false;
        return;
    }

    for (evts) |*e| {
        if (e.handled or e.evt != .key) continue;
        const ke = e.evt.key;
        switch (ke.code) {
            .space => {
                if (textBoxFocused()) break;
                e.handled = true;
                switch (ke.action) {
                    .down => {
                        var dirs = getDirectoryById(focussed_grid);
                        const current_selection = gridData(focussed_grid).kb_dir_index;
                        if (current_selection < dirs.len)
                            dirs[current_selection].checked = !dirs[current_selection].checked;
                    },
                    else => {},
                }
            },
            .down => {
                selection_mode = .kb;
                e.handled = true;
                dvui.focusWidget(dvui.currentWindow().wd.id, null, null);
                switch (ke.action) {
                    .down, .repeat => {
                        down_pressed = true;
                    },
                    else => {},
                }
            },
            .up => {
                selection_mode = .kb;
                e.handled = true;
                dvui.focusWidget(dvui.currentWindow().wd.id, null, null);
                switch (ke.action) {
                    .down, .repeat => {
                        up_pressed = true;
                    },
                    else => {},
                }
            },
            .right_alt, .left_alt, .left_command, .right_command => {
                switch (ke.action) {
                    .down => {
                        alt_held = true;
                    },
                    .up => {
                        alt_held = false;
                    },
                    else => {},
                }
            },
            .left_shift, .right_shift => {
                switch (ke.action) {
                    .down => {
                        shift_held = true;
                    },
                    .up => {
                        shift_held = false;
                    },
                    else => {},
                }
            },
            .enter => {
                if (textBoxFocused()) break;
                switch (ke.action) {
                    .down => {
                        enter_pressed = true;
                    },
                    .up => {
                        enter_pressed = false;
                    },
                    else => {},
                }
            },
            .g => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .get;
                }
            },
            .p => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .put;
                }
            },
            .a => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .mode;
                } else if (ke.action == .down and (ke.mod == .lcontrol or ke.mod == .rcontrol)) {
                    if (textBoxFocused()) break;

                    const dir_list = getDirectoryById(focussed_grid);
                    // if everything is selected, then select none.
                    var select_all = false;
                    for (dir_list) |entry| {
                        if (!entry.isSelected()) {
                            select_all = true;
                            break;
                        }
                    }
                    for (dir_list) |*entry| {
                        entry.checked = select_all;
                    }
                }
            },
            .u => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .user;
                }
            },
            .e => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .erase;
                }
            },
            .c => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .close;
                } else if (ke.action == .down and (ke.mod == .lcontrol or ke.mod == .rcontrol)) {
                    copyFilenamesToClipboard() catch |err| {
                        std.log.info("Clipboard copy error: {s}", .{@errorName(err)});
                    };
                }
            },
            .r => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .orient;
                }
            },
            .x => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .exit;
                }
            },
            .s => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .getsys;
                }
            },
            .y => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .putsys;
                }
            },
            .n => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .new;
                }
            },
            .f => {
                if (ke.action == .down and alt_held) {
                    e.handled = true;
                    CommandState.current_command = .info;
                }
            },
            .tab => {
                e.handled = true;
                dvui.focusWidget(dvui.currentWindow().wd.id, null, null);

                if (ke.action == .down) {
                    swapFocussedGrid();
                    if (getDirectoryById(focussed_grid).len == 0) {
                        // swap back if other grid is empty.
                        // Note there is a bug here when the user filter is on.. hmph!
                        swapFocussedGrid();
                    }
                    selection_mode = .kb;
                }
            },
            .page_down => {
                e.handled = true;
                if (ke.action == .down) {
                    pgdn_pressed = true;
                    selection_mode = .kb;
                }
            },
            .page_up => {
                e.handled = true;
                if (ke.action == .down) {
                    pgup_pressed = true;
                    selection_mode = .kb;
                }
            },
            else => {},
        }
    }
}

pub fn getDirectoryById(id: GridType) []DirectoryEntry {
    switch (id) {
        .image => {
            return image_directories orelse &empty_directory_list;
        },
        .local => {
            return local_directories orelse &empty_directory_list;
        },
    }
}

//pub fn getScrollInfo(id: GridType) *dvui.ScrollInfo {
//    return &scroll_info[id.toUSize()];
//}

//pub fn getKbSelectionIndex(id: GridType) usize {
//    return kb_dir_index[id.toUSize()];
//}

//pub fn setKbSelectionIndex(id: GridType, value: usize) void {
//    kb_dir_index[id.toUSize()] = value;
//}

//pub fn setLastMouseSelectedIndex(id: GridType, value: usize) void {
//    last_mouse_index[id.toUSize()] = value;
//}
//
//pub fn getLastMouseSelectedIndex(id: GridType) usize {
//    return last_mouse_index[id.toUSize()];
//}
//
//pub fn getMouseSelectionIndex(id: GridType) usize {
//    return mouse_dir_index[id.toUSize()];
//}
//
//pub fn setMouseSelectionIndex(id: GridType, value: usize) void {
//    mouse_dir_index[id.toUSize()] = value;
//}
//
//pub fn getLastMouseSelectionIndex(id: GridType) usize {
//    return last_mouse_index[id.toUSize()];
//}

pub fn swapFocussedGrid() void {
    switch (focussed_grid) {
        .local => focussed_grid = .image,
        .image => focussed_grid = .local,
    }
}

pub fn nextCopyMode(mode: CopyMode) CopyMode {
    return switch (mode) {
        .AUTO => .ASCII,
        .ASCII => .BINARY,
        .BINARY => .AUTO,
    };
}

/// Get selected files from image to local
/// Should be called each frame until CommandState.current_command != .get
/// Handles at most 1 file per frame.
fn getButtonHandler() !void {
    if (image_directories == null or local_path_selection == null) {
        CommandState.finishCommand();
        CommandState.freeResources();
        return;
    }
    CommandState.current_command = .get;

    const handler = ButtonHandler.newDirectoryListHandler(
        struct {
            pub fn getFile(file: *DirectoryEntry) !void {
                const local_path = local_path_selection.?;
                try commands.getFile(file, local_path, copy_mode, CommandState.state == .confirm);
            }
        }.getFile,
        struct {
            pub fn handleError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.handleError,
        .{},
    );
    try handler.process(image_directories.?);
}

fn putButtonHandler() !void {
    if (local_path_selection == null or local_directories == null) {
        CommandState.finishCommand();
        CommandState.freeResources();
        return;
    }
    CommandState.current_command = .put;

    const handler = ButtonHandler.newDirectoryListHandler(
        struct {
            pub fn putFile(file: *DirectoryEntry) !void {
                const local_path = local_path_selection.?;
                try commands.putFile(file.filenameAndExtension(), local_path, current_user, CommandState.state == .confirm);
                // TODO: Think of a way to make the grid get filled as files are copied.
            }
        }.putFile,
        struct {
            pub fn handleError(current: *FileStatus, err: anyerror) bool {
                switch (err) {
                    // Ignore the confirm state for disk full"
                    error.OutOfExtents,
                    error.OutOfAllocs,
                    => {
                        current.message = "Disk Full";
                        CommandState.finishCommand();
                        return true;
                    },
                    else => return false,
                }
            }
        }.handleError,
        .{},
    );
    try handler.process(local_directories.?);
}

fn eraseButtonHandler() !void {
    if (image_path_selection == null) {
        CommandState.finishCommand();
        CommandState.freeResources();
        return;
    }
    CommandState.current_command = .erase;

    const handler = ButtonHandler.newDirectoryListHandler(
        struct {
            pub fn eraseFile(file: *DirectoryEntry) !void {
                try commands.eraseFile(file);
                file.deleted = true;
            }
        }.eraseFile,
        struct {
            pub fn handleError(_: *FileStatus, _: anyerror) bool {
                return false;
            }
        }.handleError,
        .{
            .default_to_confirm = true,
            .prompt_file = "Erase?",
            .prompt_success = "Erased.",
            .skip_when_no_to_all = true,
        },
    );
    try handler.process(image_directories.?);
}

fn newButtonHandler() !void {
    CommandState.current_command = .new;

    const handler = ButtonHandler.newPromptForFileHandler(struct {
        pub fn createNewImage(image_path: []const u8, _: ButtonHandler.Options) !void {
            image_directories = null;
            const image_type = CommandState.image_type orelse ad.all_disk_types.getPtrConst(.FDD_8IN);
            try commands.createNewImage(image_path, image_type);
            try setImagePath(image_path);
            image_directories = try commands.directoryListing(allocator);
            sortDirectories(.image, null);
        }
    }.createNewImage, struct {
        pub fn errorHandler(_: *FileStatus, _: anyerror) bool {
            return false;
        }
    }.errorHandler, .{
        .prompt_file = "Create new image?",
        .prompt_success = "Created",
        .input_buttons = .{ .image_selector = true, .type_selector = true, .yes = true, .no = true },
    });

    try handler.process();
}

fn getSysButtonHandler() !void {
    CommandState.current_command = .getsys;

    const handler = ButtonHandler.newPromptForFileHandler(struct {
        pub fn getSystem(sys_path: []const u8, _: ButtonHandler.Options) !void {
            try commands.getSystem(sys_path);
        }
    }.getSystem, struct {
        pub fn errorHandler(_: *FileStatus, _: anyerror) bool {
            return false;
        }
    }.errorHandler, .{
        .prompt_file = "Extract system image to?",
        .prompt_success = "Done.",
        .input_buttons = .{ .save_file_selector = true, .yes = true, .no = true },
    });

    try handler.process();
}

fn putSysButtonHandler() !void {
    CommandState.current_command = .putsys;

    const handler = ButtonHandler.newPromptForFileHandler(struct {
        pub fn putSystem(sys_path: []const u8, _: ButtonHandler.Options) !void {
            try commands.putSystem(sys_path);
        }
    }.putSystem, struct {
        pub fn errorHandler(_: *FileStatus, _: anyerror) bool {
            return false;
        }
    }.errorHandler, .{
        .prompt_file = "Install system image from?",
        .prompt_success = "Done.",
        .input_buttons = .{ .open_file_selector = true, .yes = true, .no = true },
    });

    try handler.process();
}

// TODO: Make this a nicer screen. Prob don't use the hack of process_files list to display.
fn infoButtonHandler() !void {
    CommandState.current_command = .info;

    switch (CommandState.state) {
        .processing => {
            if (commands.disk_image) |disk_image| {
                const image_type = disk_image.image_type;
                const arena = CommandState.arena.allocator();
                // This is a bit hacky - using the filename to display the info.
                // If the display of this goes wonky, it"", 's probably because we are treng it as a filename, rather than a label.
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {s}", .{ "Format", image_type.type_name })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Tracks", image_type.tracks })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Track Len", image_type.track_size })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Res Track", image_type.reserved_tracks })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Sects/Track", image_type.sectors_per_track })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Sect Len", image_type.sector_size })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Block Size", image_type.block_size })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Directories", image_type.directories })));
                try CommandState.addProcessedFile(.init("", try std.fmt.allocPrint(arena, "{s:<12}: {d}", .{ "Allocations", image_type.total_allocs })));
                CommandState.state = .waiting_for_input;
                CommandState.finishCommand();
            } else {
                CommandState.finishCommand();
                CommandState.freeResources();
            }
        },
        else => unreachable,
    }
}

fn errorDialog(title: []const u8, message: []const u8, opt_err: ?anyerror) void {
    const display_message = message: {
        if (opt_err) |err| {
            break :message std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}\n\nError is: {s}", .{ message, @errorName(err) }) catch message;
        } else {
            break :message message;
        }
    };
    dvui.dialog(@src(), .{}, .{
        .title = title,
        .message = display_message,
        .modal = true,
        .displayFn = dialogDisplay,
    });
}

/// finds the next available name in NEWnnn.DSK
pub fn findNewImageName(gpa: std.mem.Allocator, directory: []const u8) ![]const u8 {
    var filename: [10]u8 = undefined;
    @memcpy(&filename, "IMG000.DSK");
    var num_part = filename[3..6];
    var cwd = try std.fs.cwd().openDir(directory, .{});
    for (0..999) |file_num| {
        num_part[2] = '0' + @as(u8, @intCast(file_num % 10));
        if (file_num % 10 == 0) {
            num_part[1] = '0' + @as(u8, @intCast((file_num / 10) % 10));
        }
        if (file_num % 100 == 0) {
            num_part[0] = '0' + @as(u8, @intCast((file_num / 100) % 10));
        }
        _ = cwd.statFile(&filename) catch |err| {
            switch (err) {
                error.FileNotFound => break,
                else => continue,
            }
        };
    }
    const current_path = try cwd.realpathAlloc(gpa, ".");
    defer gpa.free(current_path);
    return try std.fs.path.join(gpa, &[2][]const u8{ current_path, filename[0..] });
}

pub fn openImageFile(filename: []const u8) void {
    var success = false;

    const dialogFollowup = struct {
        var img_type: ?ad.DiskImageTypes = null;
        var selected_filename: ?[]const u8 = null;
        fn handleResponse(_: dvui.Id, response: dvui.enums.DialogResponse) dvui.Error!void {
            switch (response) {
                .cancel => img_type = .HDD_5MB_1024,
                .ok => img_type = .HDD_5MB,
                else => unreachable,
            }
            openImageFile(selected_filename.?);
        }

        fn deinit() void {
            if (selected_filename) |f| {
                allocator.free(f);
                selected_filename = null;
            }
            img_type = null;
        }
    };

    main: {
        const error_title = "Error opening image";
        var image_type = image_type: {
            const img_type = commands.detectImageType(filename) catch |err| {
                break :main errorDialog(error_title, "Could not detect image type", err);
            };
            if (img_type == null) {
                break :main errorDialog(error_title, "Not a supported Altair disk image format", null);
            }
            break :image_type img_type.?;
        };

        if (dialogFollowup.img_type == null and image_type == .HDD_5MB) {
            dialogFollowup.selected_filename = allocator.dupe(u8, filename) catch unreachable;
            dvui.dialog(@src(), .{}, .{
                .title = "Select image type",
                .message = "The HDD_5MB and HDD_5MB_1024 formats cannot be auto-detected.\n\nPlease select the correct format.",
                .ok_label = "1) HDD_5MB",
                .cancel_label = " 2) HDD_5MB_1024",
                .modal = true,
                .callafterFn = dialogFollowup.handleResponse,
                .displayFn = dialogDisplay,
            });
            return;
        } else if (image_type == .HDD_5MB) {
            image_type = dialogFollowup.img_type.?;
        }
        image_directories = null;
        commands.openExistingImage(filename, image_type) catch |err| {
            break :main errorDialog(error_title, "Could not open image file.", err);
        };
        image_directories = commands.directoryListing(allocator) catch |err| {
            break :main errorDialog(error_title, "Could not open directory table.", err);
        };
        sortDirectories(.image, null);
        success = true;
    }
    resize_image_grid = true;
    if (!success) {
        commands.closeImage();
        image_directories = null;
    }
    dialogFollowup.deinit();
}

pub fn openLocalDirectory(path: []const u8) void {
    var success = false;

    main: {
        const error_title = "Error opening directory";
        local_directories = null;
        commands.openLocalDirectory(path) catch |err| {
            break :main errorDialog(error_title, "Could not open directory.", err);
        };
        local_directories = commands.localDirectoryListing(allocator) catch |err| {
            break :main errorDialog(error_title, "Could not get directtory listing.", err);
        };
        sortDirectories(.local, null);
        success = true;
    }
    if (!success) {
        local_directories = null;
    }
}

// Copy altiar filenames to the clipboard
fn copyFilenamesToClipboard() !void {
    var buf_len: usize = 1; // For the null
    var any_selected: bool = false;
    if (image_directories) |dirs| {
        for (dirs) |*entry| {
            buf_len += entry.filenameAndExtension().len + 1;
            any_selected = any_selected or entry.isSelected();
        }

        const clip_text = try allocator.allocSentinel(u8, buf_len, 0);
        defer allocator.free(clip_text);
        var buf_pos: usize = 0;

        for (dirs) |*entry| {
            if (!any_selected or entry.isSelected()) {
                const fmt_slice = try std.fmt.bufPrintZ(clip_text[buf_pos..], "{s}\n", .{entry.filenameAndExtension()});
                buf_pos += fmt_slice.len;
            }
        }

        const result = Backend.c.SDL_SetClipboardText(clip_text.ptr);

        if (buf_len > 1 and result == 0) {
            dvui.dialog(@src(), .{}, .{
                .title = "Copy Filenames",
                .message = if (any_selected) "Selected Altair filenames\ncopied to the clipboard." else "All Altair filenames\ncopied to the clipboard.",
                .default = .ok,
            });
        }
    }
}

fn defaultPath() []u8 {
    return allocator.dupe(u8, ".") catch @panic("OOM");
}

// Optional: windows os only
const winapi = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn AttachConsole(dwProcessId: std.os.windows.DWORD) std.os.windows.BOOL;
} else struct {};

pub const std_options: std.Options = .{
    // Set the log level to info
    .log_level = .debug,
};

const ButtonHandler = @import("ButtonHandler.zig");
const CommandState = @import("CommandState.zig");
const CommandList = CommandState.CommandList;
const FileStatus = CommandState.FileStatus;
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const GridWidget = dvui.GridWidget;
const Rect = dvui.Rect;
const Options = dvui.Options;
const ad = @import("altair_disk");
const DiskImage = ad.DiskImage;
const Commands = @import("commands.zig");
const DirectoryEntry = Commands.DirectoryEntry;
const CopyMode = Commands.CopyMode;
const CellStyle = dvui.GridWidget.CellStyle;
const Cell = dvui.GridWidget.Cell;
const Backend = dvui.backend;
