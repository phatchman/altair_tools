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

// Global key state.
var alt_held = false;
var shift_held = false;
var enter_pressed = false;
var pgdn_pressed: bool = false;
var pgup_pressed: bool = false;
var down_pressed: bool = false;
var up_pressed: bool = false;

var pane_orientation = dvui.enums.Direction.horizontal;
const SelectionMode = enum { mouse, kb };

// Image grid for disk image or local for local filesystem.
const GridType = enum(usize) {
    image = 0,
    local,
};
const num_grids = std.meta.fields(GridType).len;

// Which grid has keyboard or mouse focus.
var focussed_grid: GridType = .image;
// Whether user is currently selecting by keyboard or mouse.
var selection_mode = SelectionMode.mouse;

var current_user: usize = 16; // 16 = all users. 0-15 = individual user.
var copy_mode = CopyMode.AUTO;

// The list of directory entries for the image and local filesystems
var image_directories: ?[]DirectoryEntry = null;
var local_directories: ?[]DirectoryEntry = null;

// Selection indexes. For mouse and keyboard selection.
// Kept separately for each grid.
var kb_dir_index: [num_grids]usize = @splat(0);
var mouse_dir_index: [num_grids]usize = @splat(0);
var last_mouse_index: [num_grids]usize = @splat(0);

var scroll_info: [num_grids]dvui.ScrollInfo = @splat(.{});
var sort_column: [num_grids][]const u8 = @splat("Name");
var sort_asc: [num_grids]bool = @splat(true);
var text_box_focused: [num_grids]bool = @splat(false);

// Don't handle keyboard events if a textbvox is focussed.
fn textBoxFocused() bool {
    for (text_box_focused) |focused| {
        if (focused) return true;
    }
    return false;
}

// Layout information for each column.
const num_columns = 7;
const min_sizes = [num_columns]f32{ 10, 70, 30, 20, 70, 40, 10 };
// Used for column widths. Note is shared by both grids as used sequentially.
var header_rects: [num_columns]dvui.Rect = @splat(dvui.Rect.all(0));
const row_height: f32 = 15.0;
const status_bar_height = 35 * 2; // TODO: Calculate?

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
    main_loop: while (true) {
        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(backend.hasEvent());

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
                    sortDirectories(.image, null, false);
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
        backend.setCursor(win.cursorRequested());
        backend.textInputRect(win.textInputRequested());

        // render frame to OS
        backend.renderPresent();

        // waitTime and beginWait combine to achieve variable framerates
        const wait_event_micros = win.waitTime(end_micros, null);
        backend.waitEventTimeout(wait_event_micros);
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

fn setTheme() !void {
    if (theme_set)
        return;

    // This is a slightly modified Jungle theme
    const terminal_theme =
        \\{
        \\  "name": "Terminal",
        \\  "font_size": 16,
        \\  "font_name_body": "VeraMono",
        \\  "font_name_heading": "VeraMono",
        \\  "font_name_caption": "VeraMono",
        \\  "font_name_title": "VeraMono",
        \\  "color_focus": "#638465",
        \\  "color_text": "#82a29f",
        \\  "color_text_press": "#97af81",
        \\  "color_fill_text": "#2c3332", 
        \\  "color_fill_container": "#2b3a3a",
        \\  "color_fill_control": "#2c3334",
        \\  "color_fill_hover": "#334e57",
        \\  "color_fill_press": "#3b6357",
        \\  "color_border": "#60827d"
        \\}
    ;
    const parsed = try dvui.Theme.QuickTheme.fromString(allocator, terminal_theme);
    defer parsed.deinit();

    const quick_theme = parsed.value;
    global_theme = try quick_theme.toTheme(allocator);
    global_theme.font_title_4 = .{ .size = 14, .name = global_theme.font_title_4.name };

    dvui.themeSet(&global_theme);
    theme_set = true;
}

fn guiFrame() !bool {
    var running = true;
    if (!theme_set)
        try setTheme();

    if (!try makeMenu()) return false;

    // This vbox contains all of the UI below the menu
    var vbox = try dvui.box(@src(), .vertical, .{
        .expand = .both,
        .border = Rect.all(0),
        .background = true,
    });
    defer vbox.deinit();
    {
        // We need to contrain how far the scroll area expands so that there is room for the
        // status bar at the bottom of the screen. This vbox contails all of the UI excluding
        // the status bar.
        const location = Rect{ .x = 0, .y = 0, .h = vbox.wd.rect.h - status_bar_height, .w = vbox.wd.rect.w };
        var inner_vbox = try dvui.boxEqual(@src(), .vertical, .{
            .expand = .horizontal,
            .background = true,
            .rect = location,
        });
        defer inner_vbox.deinit();

        // Handle keyboard and other global events
        // before any of the widgets can. Because we want to globally capture the
        // alt key being pressed etc.
        processEvents();

        // Paned widget containts the two scrolling file grids.
        // User can select horizontal or vertial orientation.
        var paned = try dvui.paned(@src(), .{
            .direction = pane_orientation,
            .collapsed_size = 0,
        }, .{
            .expand = .both,
            .background = true,
        });
        defer paned.deinit();
        {

            // Top (or left) half of the pane contails the files from the Altair disk image.
            var top_half = try dvui.box(@src(), .vertical, .{
                .expand = .both,
                .color_border = .{ .name = .text },
                .border = dvui.Rect.all(2),
                .corner_radius = dvui.Rect.all(5),
                .background = true, // remove
            });
            defer top_half.deinit();
            try makeFileSelector(.image);
            {
                // Beneath the file selector is the file grid, with a fixed header
                // and scroll area for the body. This vbox contains that grid.
                var grid = try dvui.box(@src(), .vertical, .{
                    .background = true,
                    .expand = .both,
                });
                defer grid.deinit();

                var header = try dvui.box(@src(), .vertical, .{
                    .expand = .horizontal,
                });
                defer header.deinit();

                try makeGridHeader(.image);
                try makeGridBody(.image);
            }
        }
        {
            var bottom_half = try dvui.box(@src(), .vertical, .{
                .expand = .both,
                .border = dvui.Rect.all(2),
                .corner_radius = dvui.Rect.all(5),
                .background = true, // remove
            });
            defer bottom_half.deinit();
            {
                try makeFileSelector(.local);
                {
                    var grid = try dvui.box(@src(), .vertical, .{
                        .background = true,
                        .expand = .horizontal,
                    });
                    defer grid.deinit();

                    // This box is just for padding purposes
                    var header = try dvui.box(@src(), .vertical, .{
                        .expand = .horizontal,
                        .background = true,
                    });
                    defer header.deinit();

                    try makeGridHeader(.local);
                    try makeGridBody(.local);
                }
            }
        }
    }
    {
        // This vbox contains any content below the paned. i.e. the usage bar graphs
        // and the status bars.

        // Place the status bar at the bottom of the screen.
        const location = Rect{ .y = vbox.wd.rect.h - status_bar_height, .x = 0, .h = status_bar_height, .w = vbox.wd.rect.w };
        var vbox_inner = try dvui.box(@src(), .vertical, .{
            .expand = .vertical,
            .rect = location,
            .margin = Rect{},
        });
        defer vbox_inner.deinit();
        {
            var stats_box = try dvui.box(@src(), .horizontal, .{
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
        var menu_box = try dvui.boxEqual(@src(), .horizontal, .{
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
    var m = try dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
    defer m.deinit();

    if (try dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = try dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (try dvui.menuItemLabel(@src(), "Exit", .{}, .{}) != null) {
            m.close();
            return false;
        }
    }

    if (try dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{ .expand = .none })) |r| {
        var fw = try dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (try dvui.menuItemLabel(@src(), "Shortcuts", .{}, .{}) != null) {
            show_shortcuts = true;
            m.close();
        }

        if (try dvui.menuItemLabel(@src(), "About", .{}, .{}) != null) {
            m.close();
            try dvui.dialog(@src(), .{}, .{ .displayFn = aboutDialogDisplay, .message = "" });
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
    };
    var dialog_win = try dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &show_shortcuts }, .{});
    defer dialog_win.deinit();
    try dvui.windowHeader("Keyboard Shortcuts", "", &show_shortcuts);

    var vbox = try dvui.box(@src(), .vertical, .{ .expand = .both, .margin = Rect.all(5) });
    var idx: usize = 0;
    defer vbox.deinit();
    {
        var inner_vbox = try dvui.box(@src(), .vertical, .{ .expand = .vertical, .gravity_x = 0.5 });
        defer inner_vbox.deinit();
        try dvui.labelNoFmt(@src(), "Menu Shortcuts", .{ .font_style = .title_3, .gravity_x = 0.5 });
        while (shortcuts[idx].category == .command) : (idx += 1) {
            const s = &shortcuts[idx];
            try dvui.label(@src(), "{s:<10}{s:<10}{s}", .{ s.shortcut, s.button orelse "", s.help_text }, .{ .id_extra = idx, .padding = Rect.all(2) });
        }
    }
    {
        var hbox = try dvui.box(@src(), .horizontal, .{ .expand = .both });
        defer hbox.deinit();
        {
            var inner_vbox = try dvui.box(@src(), .vertical, .{ .expand = .both, .margin = Rect.all(5) });
            defer inner_vbox.deinit();

            try dvui.labelNoFmt(@src(), "Navigation Shortcuts", .{ .font_style = .title_3, .gravity_x = 0.5 });
            while (idx != shortcuts.len and shortcuts[idx].category == .selection) : (idx += 1) {
                const s = &shortcuts[idx];
                try dvui.label(@src(), "{s:<10}{s}", .{ s.shortcut, s.help_text }, .{ .id_extra = idx, .padding = Rect.all(2) });
            }
        }
        {
            var inner_vbox = try dvui.box(@src(), .vertical, .{ .expand = .both, .margin = Rect.all(5) });
            defer inner_vbox.deinit();
            try dvui.labelNoFmt(@src(), "File Shortcuts", .{ .font_style = .title_3, .gravity_x = 0.5 });
            while (idx != shortcuts.len and shortcuts[idx].category == .file) : (idx += 1) {
                const s = &shortcuts[idx];
                try dvui.label(@src(), "{s:<10}{s}", .{ s.shortcut, s.help_text }, .{ .id_extra = idx, .padding = Rect.all(2) });
            }
        }
    }
    try dvui.separator(@src(), .{ .expand = .horizontal });
    if (try buttonFocussed(@src(), "Close", .{}, .{ .gravity_x = 0.5 })) {
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

    var file_selector_box = try dvui.box(
        @src(),
        .horizontal,
        .{
            .id_extra = @intFromEnum(id),
            .background = true,
            .expand = .horizontal,
        },
    );
    defer file_selector_box.deinit();
    switch (id) {
        .image => try dvui.labelNoFmt(@src(), "Image:", .{ .id_extra = @intFromEnum(id), .gravity_y = 0.5 }),
        .local => try dvui.labelNoFmt(@src(), "Local:", .{ .id_extra = @intFromEnum(id), .gravity_y = 0.5 }),
    }
    if (alt_held) {
        try dvui.separator(@src(), .{
            .id_extra = @intFromEnum(id),
            .rect = .{ .x = 5, .y = 30, .w = 10, .h = 2 },
            .color_fill = .{ .name = .text },
        });
    }
    // TODO: I think this can be simplified by just setting the text after the folder selection,
    // So we don't need to use is_initilized on the next loop to set the text?
    var entry = try dvui.textEntry(@src(), .{}, .{
        .id_extra = @intFromEnum(id),
        .expand = .horizontal,
    });
    errdefer entry.deinit();
    text_box_focused[@intFromEnum(id)] = entry.wd.id == dvui.focusedWidgetId();
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
        entry.textLayout.selection.selectAll();
        entry.textTyped(path.*.?, false);
        entry.textLayout.selection.moveCursor(path.*.?.len, false);
        dvui.refresh(null, @src(), null);
    }
    if (entry.enter_pressed) {
        // TODO: Repeated code from the icon click.
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

    if (try buttonIcon(@src(), "toggle", folder_icon, .{ .draw_focus = false }, .{ .id_extra = @intFromEnum(id) }, id)) {
        if (id == .image) {
            const path_to_use = path: {
                if (image_path_selection) |image_path| {
                    break :path std.fs.cwd().realpathAlloc(allocator, image_path) catch OOM();
                } else {
                    break :path std.fs.cwd().realpathAlloc(allocator, ".") catch OOM();
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
                    break :path std.fs.cwd().realpathAlloc(allocator, local_path) catch OOM();
                } else {
                    break :path std.fs.cwd().realpathAlloc(allocator, ".") catch OOM();
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

fn makeGridHeader(id: GridType) !void {
    {
        // This hbox contains all of the buttons making up the grid headers.
        var hbox = try dvui.box(@src(), .horizontal, .{
            .id_extra = @intFromEnum(id),
            .expand = .horizontal,
            .background = false,
        });
        defer hbox.deinit();
        try makeGridHeading("[_]", 0, id);
        try makeGridHeading("Name", 1, id);
        try makeGridHeading("Ext", 2, id);
        try makeGridHeading("A", 3, id);
        try makeGridHeading("Size", 4, id);
        try makeGridHeading("Used", 5, id);
        try makeGridHeading("U", 6, id);
    }
}

// TODO: Thius needs some cleanup / refactoring. Especially for the guard / return cases.
fn makeGridBody(id: GridType) !void {
    const directory_list = getDirectoryById(id);
    var should_display = true;

    const loaded = switch (id) {
        .image => if (image_directories == null) false else true,
        .local => if (local_directories == null) false else true,
    };
    if (!loaded) {
        var hbox = try dvui.box(@src(), .horizontal, .{ .expand = .both, .id_extra = @intFromEnum(id) });
        defer hbox.deinit();
        switch (id) {
            .image => try dvui.labelNoFmt(@src(), "Please open a disk image.", .{ .id_extra = @intFromEnum(id), .gravity_x = 0.5, .gravity_y = 0.5, .expand = .both }),
            .local => try dvui.labelNoFmt(@src(), "Please open a local directory.", .{ .id_extra = @intFromEnum(id), .gravity_x = 0.5, .gravity_y = 0.5, .expand = .both }),
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

    // The scrollable area of the grid.
    var scroll = try dvui.scrollArea(@src(), .{
        .scroll_info = getScrollInfo(id),
    }, .{
        .id_extra = @intFromEnum(id),
        .expand = .both,
        .color_fill = .{ .name = .fill_window },
    });
    defer scroll.deinit();

    // Filter out any files that shouldn't be displayed.
    const DisplayedFile = struct {
        entry: *DirectoryEntry,
        index: usize, // Real index of the entry in the unfiltered "directory_list"
    };
    var to_display = try std.ArrayListUnmanaged(DisplayedFile).initCapacity(dvui.currentWindow().arena(), directory_list.len);
    // No need to deinit, using arena.

    for (directory_list, 0..) |*entry, i| {
        if (entry.deleted) continue;
        if (id == .image and current_user != 16 and current_user != entry.user()) continue;
        to_display.appendAssumeCapacity(.{ .entry = entry, .index = i });
    }
    if (to_display.items.len == 0) return;

    var background: ?dvui.Options.ColorOrName = null;

    if (pgdn_pressed and id == focussed_grid) {
        const nr_displayed: usize = @intFromFloat(getScrollInfo(id).viewport.h / 25);
        const rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (selection_mode == .mouse and item.index == getMouseSelectionIndex(id)) {
                break :idx idx;
            } else if (selection_mode == .kb and item.index == getKbSelectionIndex(id)) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };
        getScrollInfo(id).scrollPageDown(.vertical);
        const new_index = @min(rel_index + nr_displayed, to_display.items.len - 1);

        setMouseSelectionIndex(id, to_display.items[new_index].index);
        setKbSelectionIndex(id, to_display.items[new_index].index);
    } else if (pgup_pressed and id == focussed_grid) {
        const nr_displayed: usize = @intFromFloat(getScrollInfo(id).viewport.h / 25);
        const rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (selection_mode == .mouse and item.index == getMouseSelectionIndex(id)) {
                break :idx idx;
            } else if (selection_mode == .kb and item.index == getKbSelectionIndex(id)) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };
        getScrollInfo(id).scrollPageUp(.vertical);
        const new_index: usize = @max(rel_index, nr_displayed) - nr_displayed;
        setMouseSelectionIndex(id, to_display.items[new_index].index);
        setKbSelectionIndex(id, to_display.items[new_index].index);
    } else if (id == focussed_grid and down_pressed) {
        var rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (item.index == getKbSelectionIndex(id)) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };

        const dir_len = to_display.items.len;
        if (dir_len > 0 and rel_index < dir_len - 1) {
            rel_index += 1;
            setKbSelectionIndex(focussed_grid, to_display.items[rel_index].index);
        }
    } else if (id == focussed_grid and up_pressed) {
        var rel_index: usize = idx: for (to_display.items, 0..) |item, idx| {
            if (item.index == getKbSelectionIndex(id)) {
                break :idx idx;
            }
        } else {
            break :idx 0;
        };
        if (rel_index > 0) {
            rel_index -= 1;
            setKbSelectionIndex(focussed_grid, to_display.items[rel_index].index);
        }
    } else {
        var rel_mouse_index: usize = 0;

        const evts = dvui.events();
        for (evts) |*e| {
            if (!dvui.eventMatchSimple(e, scroll.data())) {
                continue;
            }

            switch (e.evt) {
                .mouse => |me| {
                    // TODO: Hardcoded 25's. should just be row height?
                    const offset_magic = -103; // Not sure why this magic number is required?
                    const first_displayed_f: f32 = getScrollInfo(id).viewport.y / 25;
                    const rel_mouse_index_f = @max(me.p.y + offset_magic, 0) / 25 + first_displayed_f;
                    rel_mouse_index = @intFromFloat(rel_mouse_index_f);
                    rel_mouse_index = @min(rel_mouse_index, to_display.items.len - 1);
                    const abs_mouse_index = to_display.items[rel_mouse_index].index;

                    if (me.action == .press and me.button.pointer()) {
                        e.handled = true;
                        var dirs = getDirectoryById(id);
                        if (!shift_held) {
                            dirs[abs_mouse_index].checked = !dirs[abs_mouse_index].checked;
                            setLastMouseSelectedIndex(id, abs_mouse_index);
                        } else {
                            const prev_index = getLastMouseSelectedIndex(id);
                            const prev_checked = dirs[prev_index].checked;
                            const first_idx = @min(prev_index, abs_mouse_index);
                            const last_idx = @max(prev_index, abs_mouse_index);
                            for (first_idx..last_idx + 1) |idx| {
                                dirs[idx].checked = prev_checked;
                            }
                        }
                    } else if (selection_mode == .mouse and me.action == .position) {
                        dvui.focusWidget(null, scroll.data().id, e.num);
                        setMouseSelectionIndex(id, abs_mouse_index);
                        setKbSelectionIndex(id, abs_mouse_index);
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

        if ((selection_mode == .kb and abs_index == getKbSelectionIndex(id) and id == focussed_grid) or
            (selection_mode == .mouse and abs_index == getMouseSelectionIndex(id) and id == focussed_grid))
        {
            background = .{ .name = .fill_press };
        } else {
            background = null;
        }
        var row = try dvui.box(@src(), .horizontal, .{
            .id_extra = rel_idx,
            .expand = .horizontal,
            .background = true,
            .color_fill = background,
        });

        defer row.deinit();
        var buf = std.mem.zeroes([256]u8);
        const checked_value = if (getDirectoryById(id)[abs_index].checked) "[X]" else "[ ]";
        try makeGridDataRow(@src(), id, 0, rel_idx, checked_value, false);
        try makeGridDataRow(@src(), id, 1, rel_idx, entry.entry.filename(), false);
        try makeGridDataRow(@src(), id, 2, rel_idx, entry.entry.extension(), false);
        try makeGridDataRow(@src(), id, 3, rel_idx, entry.entry.attribs(), false);

        var text = try formatNumber(&buf, "{}B", entry.entry.fileSizeInB(), "####,###B");
        try makeGridDataRow(@src(), id, 4, rel_idx, text, true);

        text = try formatNumber(&buf, "{}K", entry.entry.fileUsedInKB(), "#,###K");
        try makeGridDataRow(@src(), id, 5, rel_idx, text, true);

        text = try std.fmt.bufPrint(&buf, "{}", .{entry.entry.user()});
        try makeGridDataRow(@src(), id, 6, rel_idx, text, true);

        // TODO: Hardcoded 25's. should jsut be row height?

        const nr_displayed = getScrollInfo(id).viewport.h / 25 - 2;
        if (id == focussed_grid and selection_mode == .kb and getKbSelectionIndex(id) == abs_index) {
            const my_pos: f32 = @as(f32, @floatFromInt(rel_idx)) * 25; // relative pos
            const viewport_btm = getScrollInfo(id).viewport.y + getScrollInfo(id).viewport.h - 40;
            if (viewport_btm < my_pos) {
                const scroll_pos: f32 = my_pos - (nr_displayed * 25);
                getScrollInfo(id).scrollToOffset(.vertical, scroll_pos);
            } else if (my_pos < getScrollInfo(id).viewport.y + 40) {
                const scroll_pos: f32 = my_pos - 25;
                getScrollInfo(id).scrollToOffset(.vertical, scroll_pos);
            }
        }
    }
}

fn makeGridHeading(label: []const u8, num: u32, id: GridType) !void {
    var grp = try dvui.box(@src(), .horizontal, .{
        .id_extra = num,
        .expand = .horizontal,
    });
    defer grp.deinit();
    if (try dvui.button(
        @src(),
        label,
        .{ .draw_focus = false },
        .{
            .id_extra = num,
            .corner_radius = Rect{},
            .margin = Rect{},
            .expand = .horizontal,
            .min_size_content = .{ .h = 1, .w = min_sizes[num] },
        },
    )) {
        if (num == 0) {
            // Select all / none
            var checked = false;
            for (getDirectoryById(id)) |dir| {
                if (!dir.checked) {
                    checked = true;
                    break;
                }
            }
            for (getDirectoryById(id)) |*dir| {
                dir.checked = checked;
            }
        } else {
            sortDirectories(id, label, true);
        }
    }
    try dvui.separator(@src(), .{ .id_extra = num, .expand = .vertical, .margin = Rect.all(1) });
    header_rects[num] = grp.data().rect;
}

/// Creates one row in the grid.
/// Note the use of the cols_rects array to make sure the scolling columns
/// are kept the same size as the header columns.
fn makeGridDataRow(src: std.builtin.SourceLocation, _: GridType, col_num: u32, item_num: usize, value: []const u8, justify: bool) !void {
    // Can comfortably handle the max 1024 entries in ReleaseSafe mode.
    // TODO: Handle scolling ourselves, so that we just render the number of entries required, rather than the
    // whole area. This way we can handle an "unlimited" number of directory entries.
    if (item_num > 1024) {
        return;
    }
    // This hbox contains the row.
    var row = try dvui.box(src, .horizontal, .{
        .id_extra = item_num,
        .expand = .horizontal,
        .background = false,
        .margin = Rect.all(0),
        .padding = Rect.all(0),
        .min_size_content = .{ .w = header_rects[col_num].w, .h = row_height + 10.0 },
        .max_size_content = .{ .w = header_rects[col_num].w, .h = row_height + 10.0 },
    });
    defer row.deinit();

    if (col_num == 0 and false) {
        // TODO: Magic numbers.
        _ = try dvui.button(src, "[_]", .{}, .{
            .id_extra = item_num,
            .background = false,
        });
    } else {
        // TODO: Magic numbers.
        try dvui.labelNoFmt(@src(), value, .{
            .id_extra = item_num,
            .margin = Rect{ .x = 1, .w = 1 },
            .padding = Rect{ .x = 8, .w = 8 },
            .gravity_x = if (justify) 1.0 else 0.0,
            .gravity_y = 0.5,
            .background = false,
        });
    }
}

fn makeCapacityUsageGraph() !void {
    try dvui.label(@src(), "Capacity:", .{}, .{ .gravity_y = 0.5 });
    {
        var files_box = try dvui.box(@src(), .horizontal, .{
            .border = Rect.all(1),
            .background = true,
            .min_size_content = .{ .h = 20, .w = 250 },
            .margin = Rect.all(5),
        });
        defer files_box.deinit();
        if (commands.disk_image) |disk_image| {

            // TODO: Pull all of the UI values into a Model class or similar.
            const total_space = disk_image.capacityTotalInKB();
            const free_space = disk_image.capacityFreeInKB();
            const used_space = total_space - free_space;
            const percentage: f32 = @as(f32, @floatFromInt(used_space)) / @as(f32, @floatFromInt(total_space));
            const width = percentage * 250;
            {
                var used_box = try dvui.box(@src(), .horizontal, .{
                    .color_fill = .{ .name = .fill_hover },
                    .background = true,
                    .min_size_content = .{ .h = 20, .w = width },
                });
                defer used_box.deinit();
            }
            var msg_buf: [256]u8 = undefined;
            const message = try std.fmt.bufPrint(&msg_buf, "{:>6}K used {:>6}K remain ", .{ used_space, free_space });

            try dvui.labelNoFmt(@src(), message, .{
                // TODO: Can we remove this hardcoding of rect?
                .rect = .{ .x = 0, .y = 0, .h = 20, .w = 250 },
                .padding = Rect.all(2),
            });
        }
    }
}

fn makeDirectoriesUsageGraph() !void {
    try dvui.label(@src(), "Directories:", .{}, .{ .gravity_y = 0.5 });
    {
        var files_box = try dvui.box(@src(), .horizontal, .{
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
                var used_box = try dvui.box(@src(), .horizontal, .{
                    .color_fill = .{ .name = .fill_hover },
                    .background = true,
                    .min_size_content = .{ .h = 20, .w = width },
                });
                defer used_box.deinit();
            }
            var msg_buf: [256]u8 = undefined;
            const message = try std.fmt.bufPrint(&msg_buf, "{:>7} used {:>7} remain ", .{ used_directories, free_directories });

            try dvui.labelNoFmt(@src(), message, .{
                // TODO: Can we remove this hardcoding of rect?
                .rect = .{ .x = 0, .y = 0, .h = 20, .w = 250 },
                .padding = Rect.all(2),
            });
        }
    }
}

fn makeStatusBar() !bool {
    const reversed = dvui.Options{
        .color_text = .{ .name = .fill_window },
        .color_fill = .{ .name = .text },
        .color_fill_hover = .{ .name = .fill_press }, // Added.
        .color_fill_press = .{ .name = .fill_hover }, // Added.
        .expand = .horizontal,
        .margin = Rect{ .x = 2, .w = 2, .y = 2, .h = 0 },
        .corner_radius = Rect.all(0),
        .background = true,
    };

    if (try statusBarButton(@src(), "GET", .{}, reversed, 0, .get, image_directories != null)) {
        if (CommandState.shouldProcessCommand()) {
            try getButtonHandler();
        }
    }
    if (try statusBarButton(@src(), "PUT", .{}, reversed, 0, .put, image_directories != null)) {
        if (CommandState.shouldProcessCommand()) {
            try putButtonHandler();
        }
    }
    if (try statusBarButton(@src(), "ERASE", .{}, reversed, 0, .erase, image_directories != null) or
        CommandState.current_command == .erase)
    {
        if (CommandState.shouldProcessCommand()) {
            try eraseButtonHandler();
        }
    }
    if (try statusBarButton(@src(), "GET SYS", .{}, reversed, 4, .getsys, image_directories != null)) {
        if (CommandState.shouldProcessCommand()) {
            try getSysButtonHandler();
        }
    }
    if (try statusBarButton(@src(), "PUT SYS", .{}, reversed, 5, .putsys, image_directories != null)) {
        if (CommandState.shouldProcessCommand()) {
            try putSysButtonHandler();
        }
    }
    if (try statusBarButton(@src(), "CLOSE", .{}, reversed, 0, .close, image_directories != null)) {
        commands.closeImage();
        image_directories = null;
        CommandState.finishCommand();
    }

    if (try statusBarButton(@src(), "INFO", .{}, reversed, 2, .info, image_directories != null)) {
        if (CommandState.shouldProcessCommand()) {
            try infoButtonHandler();
        }
    }

    var buf: [20]u8 = undefined;
    var label = if (current_user == 16)
        try std.fmt.bufPrint(&buf, "USER *", .{})
    else
        try std.fmt.bufPrint(&buf, "USER {}", .{current_user});

    if (try statusBarButton(@src(), label, .{}, reversed, 0, .user, true)) {
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
    if (try statusBarButton(@src(), "NEW", .{}, reversed, 0, .new, true)) {
        if (CommandState.shouldProcessCommand()) {
            try newButtonHandler();
        }
    }
    label = try std.fmt.bufPrint(&buf, "{s}", .{@tagName(copy_mode)});
    const underline_pos: usize = if (copy_mode == .BINARY) 3 else 0;
    if (try statusBarButton(@src(), label, .{}, reversed, underline_pos, .mode, true)) {
        copy_mode = nextCopyMode(copy_mode);
    }

    if (try statusBarButton(@src(), "ORIENT", .{}, reversed, 1, .orient, true)) {
        if (pane_orientation == .horizontal) {
            pane_orientation = .vertical;
        } else {
            pane_orientation = .horizontal;
            dvui.refresh(null, @src(), null);
        }
        CommandState.finishCommand();
    }
    if (try statusBarButton(@src(), "EXIT", .{}, reversed, 1, .exit, true)) {
        return false;
    }
    return true;
}

pub fn makeTransferDialog() !void {
    const static = struct {
        var open_flag: bool = false;
        var scroll_info: dvui.ScrollInfo = .{};
        var last_nr_messages: usize = 0;
        var choice: usize = 0;
        var last_command: CommandList = .none;
    };

    if (CommandState.state != .waiting_for_input and CommandState.processed_files.items.len == 0) {
        return;
    } else {
        static.open_flag = true; // is the dialog open?
    }

    var dialog_win = try dvui.floatingWindow(
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
        .none => continue :title static.last_command, // Command will be .none when finished, so show the last state.
        .close, .exit, .mode, .user, .orient => unreachable,
    };
    if (CommandState.current_command != .none) {
        static.last_command = CommandState.current_command;
    }

    try dvui.windowHeader(title, "", &static.open_flag);
    var outer_vbox = try dvui.box(@src(), .vertical, .{
        .expand = .both,
        .min_size_content = .{ .w = 500, .h = 500 },
        .max_size_content = .{ .w = 500, .h = 500 },
    });
    const KeyState = enum { none, yes, no, yes_all, no_all, enter };
    var key_state: KeyState = .none;

    // TODO: Should we filter. this is modal, does it matter?
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
        var scroll = try dvui.scrollArea(
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
            var vbox = try dvui.box(@src(), .vertical, .{ .expand = .horizontal, .background = false });
            defer vbox.deinit();
            for (CommandState.processed_files.items, 0..) |*file, i| {
                const basename = std.fs.path.basename(file.filename);
                var text = try dvui.textLayout(@src(), .{}, .{
                    .id_extra = i,
                    .background = false,
                    .padding = Rect.all(0),
                    .margin = Rect.all(4),
                });
                defer text.deinit();
                try text.addText(try std.fmt.allocPrint(
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
            var button_box = try dvui.box(@src(), .vertical, .{ .expand = .horizontal });
            defer button_box.deinit();

            if (CommandState.buttons.image_selector or CommandState.buttons.save_file_selector or CommandState.buttons.open_file_selector) {
                var hbox = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal });
                defer hbox.deinit();
                if (CommandState.buttons.image_selector) {
                    try dvui.labelNoFmt(@src(), "Image name:", .{ .gravity_y = 0.5 });
                } else {
                    try dvui.labelNoFmt(@src(), "File name:", .{ .gravity_y = 0.5 });
                }

                var entry = try dvui.textEntry(@src(), .{}, .{});
                errdefer entry.deinit();
                if (CommandState.file_selector_buffer == null) {
                    if (CommandState.buttons.image_selector) {
                        if (image_path_selection) |image_path| {
                            const dir_path = std.fs.path.dirname(image_path) orelse ".";
                            const image_name = try findNewImageName(CommandState.arena.allocator(), dir_path);
                            try CommandState.setFileSelectorBuffer(image_name);
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(image_name, false);
                            entry.textLayout.selection.moveCursor(image_name.len, false);
                            dvui.refresh(null, @src(), null);
                        }
                    } else {
                        const current_dir = try std.fs.cwd().realpathAlloc(CommandState.arena.allocator(), ".");
                        const filename = try std.fs.path.join(CommandState.arena.allocator(), &[2][]const u8{ current_dir, "cpm.bin" });
                        try CommandState.setFileSelectorBuffer(filename);
                        entry.textLayout.selection.selectAll();
                        entry.textTyped(filename, false);
                        entry.textLayout.selection.moveCursor(filename.len, false);
                        dvui.refresh(null, @src(), null);
                    }
                }
                if (entry.enter_pressed or entry.text_changed) {
                    try CommandState.setFileSelectorBuffer(entry.getText());
                    entry.textLayout.selection.moveCursor(entry.getText().len, false);
                }
                empty_file_selector = entry.getText().len == 0;
                entry.deinit();
                if (try dvui.buttonIcon(@src(), "toggle", folder_icon, .{}, .{}, .{})) {
                    if (CommandState.buttons.image_selector) {
                        if (try dvui.dialogNativeFileSave(dvui.currentWindow().arena(), .{
                            .title = "Save image as",
                            .filters = &.{ "*.DSK", "*.IMG", "*.dsk", "*.img" },
                            .filter_description = "Altair Disk Images *.dsk;*.img",
                        })) |filename| {
                            try CommandState.setFileSelectorBuffer(filename);
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(filename, false);
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
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(filename, false);
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
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(filename, false);
                            entry.textLayout.selection.moveCursor(filename.len, false);
                            dvui.refresh(null, @src(), null);
                        }
                    }
                }
                if (CommandState.buttons.type_selector) {
                    try dvui.labelNoFmt(@src(), "Format:", .{ .gravity_y = 0.5 });

                    if (try dvui.dropdown(@src(), &ad.all_disk_type_names, &static.choice, .{})) {
                        CommandState.image_type = &ad.all_disk_types.values[static.choice];
                    }
                }
            }
            // Check we have some type of filename.
            if (empty_file_selector) {
                CommandState.err_message = "Please enter a new image filename";
            } else {
                var hbox = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal });
                defer hbox.deinit();
                if (CommandState.prompt) |prompt| {
                    try dvui.labelNoFmt(@src(), prompt, .{ .gravity_y = 0.5 });
                }

                if (CommandState.buttons.yes) {
                    if (try dvui.button(@src(), "[y] Yes", .{}, .{}) or key_state == .yes) {
                        CommandState.state = .confirm;
                    }
                }
                if (CommandState.buttons.no) {
                    if (try dvui.button(@src(), "[n] No", .{}, .{}) or key_state == .no) {
                        CommandState.state = .cancel;
                    }
                }
                if (CommandState.buttons.yes_all) {
                    if (try dvui.button(@src(), "[Y] Yes to All", .{}, .{}) or key_state == .yes_all) {
                        CommandState.confirm_all = .yes_to_all;
                        CommandState.state = .confirm;
                    }
                }
                if (CommandState.buttons.no_all) {
                    if (try dvui.button(@src(), "[N] No to All", .{}, .{}) or key_state == .no_all) {
                        CommandState.confirm_all = .no_to_all;
                        CommandState.state = .cancel;
                    }
                }
            }
            {
                if (CommandState.err_message) |message| {
                    var text = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
                    defer text.deinit();
                    try text.addText(message, .{});
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
        var vbox = try dvui.box(@src(), .vertical, .{ .expand = .horizontal, .gravity_y = 1.0 });
        defer vbox.deinit();
        try dvui.separator(@src(), .{ .expand = .horizontal });

        var hbox = try dvui.box(@src(), .horizontal, .{ .gravity_x = 0.5 });
        defer hbox.deinit();

        if (CommandState.current_command != .none) {
            _ = try dvui.button(@src(), "Working...", .{}, .{});
        } else {
            if (key_state == .enter or try buttonFocussed(@src(), "Close", .{}, .{})) {
                CommandState.finishCommand();
                CommandState.freeResources();
                dialog_win.close(); // can close the dialog this way
                if (local_directories != null) {
                    local_directories = commands.localDirectoryListing(allocator) catch null;
                    sortDirectories(.local, null, false);
                }
                if (image_directories != null) {
                    image_directories = commands.directoryListing(allocator) catch null;
                    sortDirectories(.image, null, false);
                }
            }
        }
    }
}

pub fn aboutDialogDisplay(id: dvui.WidgetId) !void {
    var win = try dvui.floatingWindow(
        @src(),
        .{ .modal = true, .window_avoid = .nudge },
        .{ .id_extra = id.asUsize() },
    );
    defer win.deinit();

    var header_openflag = true;
    try dvui.windowHeader("About ADGUI", "", &header_openflag);
    if (!header_openflag) {
        dvui.dialogRemove(id);
        return;
    }

    {
        // Add the buttons at the bottom first, so that they are guaranteed to be shown
        var hbox = try dvui.box(@src(), .horizontal, .{ .gravity_x = 0.5, .gravity_y = 1.0 });
        defer hbox.deinit();

        if (try dvui.button(@src(), "OK", .{}, .{ .tab_index = 1 })) {
            dvui.dialogRemove(id);
            return;
        }
    }
    try dvui.label(@src(), "ADGUI Version: {s}", .{adgui_version}, .{ .expand = .horizontal, .gravity_x = 0.5 });

    // Now add the scroll area which will get the remaining space
    var tl = try dvui.textLayout(@src(), .{}, .{ .background = false, .gravity_x = 0.5 });
    try tl.addText("\n", .{});
    const url = "https://github.com/phatchman/altair_tools";
    if (try tl.addTextClick(url, .{})) {
        dvui.openURL(url) catch {};
    }
    const tl_rect = tl.data().contentRect();
    tl.deinit();
    try dvui.separator(@src(), .{
        .rect = .{ .x = tl_rect.x, .y = tl_rect.y + 35, .h = 1, .w = tl_rect.w },
        .color_fill = .{ .color = .{ .r = 0x35, .g = 0x84, .b = 0xe4 } },
    });
}

fn sortAsc(which: []const u8, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
    if (std.mem.eql(u8, which, "[_]")) return lhs.checked and !rhs.checked;
    if (std.mem.eql(u8, which, "Name")) return std.mem.order(u8, lhs.filename(), rhs.filename()) == .lt;
    if (std.mem.eql(u8, which, "Ext")) return std.mem.order(u8, lhs.extension(), rhs.extension()) == .lt;
    if (std.mem.eql(u8, which, "Size")) return lhs.fileSizeInB() < rhs.fileSizeInB();
    if (std.mem.eql(u8, which, "Used")) return lhs.fileUsedInKB() < rhs.fileUsedInKB();
    if (std.mem.eql(u8, which, "A")) return std.mem.order(u8, lhs.attribs(), rhs.attribs()) == .lt;
    if (std.mem.eql(u8, which, "U")) return lhs.user() < rhs.user();
    unreachable;
}

fn sortDesc(which: []const u8, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
    if (std.mem.eql(u8, which, "[_]")) return !lhs.checked and rhs.checked;
    if (std.mem.eql(u8, which, "Name")) return std.mem.order(u8, lhs.filename(), rhs.filename()) == .gt;
    if (std.mem.eql(u8, which, "Ext")) return std.mem.order(u8, lhs.extension(), rhs.extension()) == .gt;
    if (std.mem.eql(u8, which, "Size")) return lhs.fileSizeInB() > rhs.fileSizeInB();
    if (std.mem.eql(u8, which, "Used")) return lhs.fileUsedInKB() > rhs.fileUsedInKB();
    if (std.mem.eql(u8, which, "A")) return std.mem.order(u8, lhs.attribs(), rhs.attribs()) == .gt;
    if (std.mem.eql(u8, which, "U")) return lhs.user() > rhs.user();
    unreachable;
}

fn sortDirectories(id: GridType, sort_by_opt: ?[]const u8, toggle_direction: bool) void {
    const idx = @intFromEnum(id);
    const sort_by = sort_by_opt orelse sort_column[idx];

    if (toggle_direction and std.mem.eql(u8, sort_column[idx], sort_by)) {
        sort_asc[idx] = !sort_asc[idx];
    } else {
        sort_column[idx] = sort_by;
    }
    const to_sort = getDirectoryById(id);
    if (sort_asc[idx]) {
        std.mem.sort(DirectoryEntry, to_sort, sort_by, sortAsc);
    } else {
        std.mem.sort(DirectoryEntry, to_sort, sort_by, sortDesc);
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

pub fn labelNoFmtRect(src: std.builtin.SourceLocation, str: []const u8, opts: Options) !dvui.Rect {
    var lw = dvui.LabelWidget.initNoFmt(src, str, opts);
    try lw.install();
    lw.processEvents();
    try lw.draw();
    const rect = lw.wd.rect;
    lw.deinit();
    return rect;
}

pub fn statusBarButton(src: std.builtin.SourceLocation, label_str: []const u8, _init_opts: dvui.ButtonWidget.InitOptions, opts: Options, underline_pos: usize, cmd: CommandList, enabled: bool) !bool {
    _ = _init_opts;
    const init_opts: dvui.ButtonWidget.InitOptions = .{ .draw_focus = false };
    // If running another command, just show the label.

    const selected = CommandState.current_command == cmd;
    var options2 = opts;
    if (selected) {
        options2 = options2.override(.{ .color_fill = .{ .color = opts.color(.fill_press) } });
    } else if (!enabled) {
        options2 = options2.override(.{ .color_fill = .{ .color = opts.color(.fill_press) } });
    }
    var bw = dvui.ButtonWidget.init(src, init_opts, options2);

    bw.click = selected;

    // make ourselves the new parent
    try bw.install();

    // process events (mouse and keyboard) unless another operation is in progress.
    if (CommandState.current_command == .none and !enter_pressed and enabled) {
        bw.processEvents();
    }

    // draw background/border
    try bw.drawBackground();

    // use pressed text color if desired
    const click = bw.clicked();
    var options = opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.5 });

    if (bw.pressed() or selected) options = options.override(.{ .color_text = .{ .color = opts.color(.text_press) } });

    // this child widget:
    // - has bw as parent
    // - gets a rectangle from bw
    // - draws itself
    // - reports its min size to bw
    const label_rect = try labelNoFmtRect(src, label_str, options);
    const fill_color = color: {
        if (!enabled or bw.hover) {
            break :color opts.color(.fill_press);
        } else if (alt_held) {
            break :color opts.color(.text);
        } else {
            break :color opts.color(.fill);
        }
    };
    try dvui.separator(src, .{
        .id_extra = 1, // Not sure why required.
        .rect = .{ .x = label_rect.x + @as(f32, @floatFromInt(underline_pos)) * 8, .y = 15, .w = 10, .h = 2 },
        .color_fill = .{ .color = fill_color },
        .background = true,
    });
    // draw focus
    try bw.drawFocus();

    // restore previous parent
    // send our min size to parent
    bw.deinit();
    if (selected) {
        dvui.refresh(null, @src(), null);
    }

    return click;
}

pub fn buttonIcon(src: std.builtin.SourceLocation, name: []const u8, tvg_bytes: []const u8, init_opts: dvui.ButtonWidget.InitOptions, opts: Options, id: GridType) !bool {
    const defaults = Options{ .padding = Rect.all(4) };
    var bw = dvui.ButtonWidget.init(src, init_opts, defaults.override(opts));
    try bw.install();
    bw.processEvents();
    try bw.drawBackground();

    // When someone passes min_size_content to buttonIcon, they want the icon
    // to be that size, so we pass it through.

    try dvui.icon(@src(), name, tvg_bytes, .{}, opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.0, .min_size_content = opts.min_size_content, .expand = .ratio }));

    if (alt_held) {
        const label_rect = try labelNoFmtRect(@src(), if (id == .image) "M" else "O", .{
            .color_fill = .{ .name = .text },
            .color_text = .{ .name = .fill_control },
            .background = true,
        });
        try dvui.separator(src, .{
            .id_extra = 1, // Not sure why required.
            .rect = .{ .x = label_rect.x + 5, .y = 20, .w = 10, .h = 2 },
            .color_fill = .{ .name = .fill_control },
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
        try dvui.labelNoFmt(@src(), " ", .{ .font_style = .body, .gravity_x = 0.5, .gravity_y = 0.5 });
    }

    const click = bw.clicked();
    try bw.drawFocus();
    bw.deinit();
    return click;
}

pub fn buttonFocussed(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: dvui.ButtonWidget.InitOptions, opts: Options) !bool {
    // initialize widget and get rectangle from parent
    var bw = dvui.ButtonWidget.init(src, init_opts, opts);

    // make ourselves the new parent
    try bw.install();

    dvui.focusWidget(bw.wd.id, null, null);

    // process events (mouse and keyboard)
    bw.processEvents();

    // draw background/border
    try bw.drawBackground();

    // use pressed text color if desired
    const click = bw.clicked();
    var options = opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.5 });

    if (bw.pressed()) options = options.override(.{ .color_text = .{ .color = opts.color(.text_press) } });

    // this child widget:
    // - has bw as parent
    // - gets a rectangle from bw
    // - draws itself
    // - reports its min size to bw
    try dvui.labelNoFmt(@src(), label_str, options);

    // draw focus
    try bw.drawFocus();

    // restore previous parent
    // send our min size to parent

    bw.deinit();

    return click;
}

pub fn dialogDisplay(id: dvui.WidgetId) !void {
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

    var win = try dvui.floatingWindow(
        @src(),
        .{ .modal = modal, .center_on = center_on, .window_avoid = .nudge },
        .{ .id_extra = id.asUsize(), .max_size_content = maxSize },
    );
    defer win.deinit();

    var header_openflag = true;
    try dvui.windowHeader(title, "", &header_openflag);
    if (!header_openflag) {
        dvui.dialogRemove(id);
        if (callafter) |ca| {
            try ca(id, .cancel);
        }
        return;
    }

    {
        // Add the buttons at the bottom first, so that they are guaranteed to be shown
        var hbox = try dvui.box(@src(), .horizontal, .{ .gravity_x = 0.5, .gravity_y = 1.0 });
        defer hbox.deinit();

        if (try buttonFocussed(@src(), ok_label, .{}, .{ .tab_index = 1 })) {
            dvui.dialogRemove(id);
            if (callafter) |ca| {
                try ca(id, .ok);
            }
            return;
        }

        if (cancel_label) |cl| {
            if (try dvui.button(@src(), cl, .{}, .{ .tab_index = 2 })) {
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
    var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = .{ .name = .fill_window } });
    var tl = try dvui.textLayout(@src(), .{}, .{ .background = false, .gravity_x = 0.5 });
    try tl.addText(message, .{});
    tl.deinit();
    scroll.deinit();
}

pub fn processEvents() void {
    const evts = dvui.events();
    pgdn_pressed = false;
    pgup_pressed = false;
    up_pressed = false;
    down_pressed = false;

    for (evts) |*e| {
        // This doesn't return events, even when the scrollbar is focused.
        //        if (!dvui.eventMatch(e, .{ .id = scroll2.data().id, .r = scroll2.data().borderRectScale().r })) {
        //            continue;
        //        }
        if (e.handled or e.evt != .key) continue;

        const ke = e.evt.key;
        switch (ke.code) {
            .space => {
                if (textBoxFocused()) break;
                e.handled = true;
                switch (ke.action) {
                    .down => {
                        var dirs = getDirectoryById(focussed_grid);
                        const current_selection = getKbSelectionIndex(focussed_grid);
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
                    //getScrollInfo(focussed_grid).scrollPageUp(.vertical);
                    // selection_mode = .mouse;
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

pub fn getScrollInfo(id: GridType) *dvui.ScrollInfo {
    return &scroll_info[@intFromEnum(id)];
}

pub fn getKbSelectionIndex(id: GridType) usize {
    return kb_dir_index[@intFromEnum(id)];
}

pub fn setKbSelectionIndex(id: GridType, value: usize) void {
    kb_dir_index[@intFromEnum(id)] = value;
}

pub fn setLastMouseSelectedIndex(id: GridType, value: usize) void {
    last_mouse_index[@intFromEnum(id)] = value;
}

pub fn getLastMouseSelectedIndex(id: GridType) usize {
    return last_mouse_index[@intFromEnum(id)];
}

pub fn getMouseSelectionIndex(id: GridType) usize {
    return mouse_dir_index[@intFromEnum(id)];
}

pub fn setMouseSelectionIndex(id: GridType, value: usize) void {
    mouse_dir_index[@intFromEnum(id)] = value;
}

pub fn getLastMouseSelectionIndex(id: GridType) usize {
    return last_mouse_index[@intFromEnum(id)];
}

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
            sortDirectories(.image, null, false);
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
    }) catch |err| {
        std.debug.panic("Can't open error dialog: {}", .{err});
    };
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

    // TODO: Would rather just call openImageFile with an image type once it is known.
    // But need to keep the duplicated filename somewhere, so may as well store the image
    // type as well.
    const dialogFollowup = struct {
        var img_type: ?ad.DiskImageTypes = null;
        var selected_filename: ?[]const u8 = null;
        fn handleResponse(_: dvui.WidgetId, response: dvui.enums.DialogResponse) dvui.Error!void {
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
            }) catch {};
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
        sortDirectories(.image, null, false);
        success = true;
    }
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
        sortDirectories(.local, null, false);
        success = true;
    }
    if (!success) {
        local_directories = null;
    }
}

// Copy altiar filenames to the clipboard
fn copyFilenamesToClipboard() !void {
    var buf_len: usize = 1; // For the null
    if (image_directories) |dirs| {
        for (dirs) |*entry| {
            buf_len += entry.filenameAndExtension().len + 1;
        }

        const clip_text = try allocator.allocSentinel(u8, buf_len, 0);
        defer allocator.free(clip_text);
        var buf_pos: usize = 0;

        for (dirs) |*entry| {
            std.debug.print("pre buf len = {}, buf_pos = {}\n", .{ buf_len, buf_pos });

            const fmt_slice = try std.fmt.bufPrintZ(clip_text[buf_pos..], "{s}\n", .{entry.filenameAndExtension()});
            buf_pos += fmt_slice.len;

            std.debug.print("post buf len = {}, buf_pos = {}\n", .{ buf_len, buf_pos });
        }

        const result = Backend.c.SDL_SetClipboardText(clip_text.ptr);

        std.debug.print("buf len = {}, result = {}\n", .{ buf_len, result });

        if (buf_len > 1 and result == 0) {
            try dvui.dialog(@src(), .{}, .{ .title = "Copy Filenames", .message = "Altair filenames copied\nto the clipboard." });
        }
    } else {
        std.debug.print("image dirs is null?\n", .{});
    }
}

fn OOM() noreturn {
    @panic("Out of Memory");
}

// Optional: windows os only
const winapi = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn AttachConsole(dwProcessId: std.os.windows.DWORD) std.os.windows.BOOL;
} else struct {};

pub const std_options: std.Options = .{
    // Set the log level to info
    .log_level = .err,
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
const Backend = dvui.backend;
