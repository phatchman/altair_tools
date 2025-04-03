//
// TODO: [_] Not to all should only no errors, not working. e.g. no to all overwriting should still copy the files it can copy.
//       [_] Fix up the size of the "transfer window"
//       [X] Fix up the "yes" / "no" on the transfer window
//       [_] Implement get/put sys
//       [_] Ask to do a recovery if the disk image is corrupted
//       [_] Handle errors properly so app doesn't exit unexpectedly
//       [_] Keep a backup image of any file opened? OR at least make that an option.
//       [_] Add a help screen with keyboard shortcuts
//       [X] Keyboard shortcuts for the open image and open local directory
//       [X] Something better to display if no image has been opened yet
//       [_] Title bars on transfer window
//       [X] Ctrl-A - select all
//       [_] Fix issue with new images being created in local dir, not same as the dir used for open file.
//       [_] Disable menu buttons that aren't valid for the current selection / action.
//       [_] Handle errors when invalid filesnames types into the text box
//       [X] Change shortcuts.  Alt I - manually enter an image name.
//                              Alt M - opens an image browser.
//                              Alt L - manually enter disk directory.
//                              Alt O - open the local dir brownser.
//                              Alt F - info.
//                              Alt R - orient.
//       [_] Fix up all the places that die because there is no selected image and keyboard selection commands are used.
//       [_]
//

const folder_icon = @embedFile("icons/folder.tvg");
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

const window_icon_png = @embedFile("altair.png");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
pub const gpa = gpa_instance.allocator();

const CommandList = enum {
    none,
    get,
    put,
    mode,
    close,
    erase,
    user,
    new,
    info,
    getsys,
    putsys,
    orient,
    exit,
};

const vsync = true;
var alt_held = false;
var shift_held = false;
var enter_pressed = false;
var pgdn_pressed: bool = false;
var pgup_pressed: bool = false;
var down_pressed: bool = false;
var up_pressed: bool = false;
var current_command: CommandList = .none;
var current_user: usize = 16; // all users
var paned_collapsed_width: f32 = 400;
var pane_orientation = dvui.enums.Direction.horizontal;
const SelectionMode = enum { mouse, kb };
var selection_mode = SelectionMode.mouse;

// TODO: make everything based on grid type and add a state / model class that holds the globasl state
const GridType = enum(usize) {
    image = 0,
    local,
};

var commands = Commands{};
// TODO: The entries themselves should be const.
var image_directories: ?[]DirectoryEntry = null;
var local_directories: ?[]DirectoryEntry = null;
var kb_dir_index: [2]usize = @splat(0); // Selection index for keyboard
var mouse_dir_index: [2]usize = @splat(0); // Selection index for mouse
var last_mouse_index: [2]usize = @splat(0);
var scroll_info: [2]dvui.ScrollInfo = @splat(.{});
var sort_column: [2][]const u8 = @splat("Name");
var sort_asc: [2]bool = @splat(true);
var focussed_grid: GridType = .image;
var text_box_focussed = false;
var frame_count: u64 = 0;
const min_sizes = [_]f32{ 10, 80, 30, 20, 60, 40, 10 };
var header_rects: [7]dvui.Rect = @splat(dvui.Rect.all(0)); // Used for column widths. Note is shared by both grids as used sequentially.
const row_height: f32 = 15.0;
const status_bar_height = 35 * 2; // TODO: Calculate?
const border_width = dvui.Rect.all(0);

var local_path_initialized = false;
var local_path_selection: ?[]const u8 = null;
fn setLocalPath(path: []const u8) !void {
    if (local_path_selection) |local_path| {
        gpa.free(local_path);
    }
    local_path_selection = try gpa.dupe(u8, path);
    local_path_initialized = false;
}

fn setImagePath(path: []const u8) !void {
    if (image_path_selection) |image_path| {
        gpa.free(image_path);
    }
    image_path_selection = try gpa.dupe(u8, path);
    image_path_initialized = false;
}
var image_path_initialized = false;
var image_path_selection: ?[]const u8 = null;
var copy_mode = CopyMode.AUTO;

const empty_directory_list: [0]DirectoryEntry = .{};

pub fn main() !void {
    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        _ = winapi.AttachConsole(0xFFFFFFFF);
    }
    std.log.info("SDL version: {}", .{Backend.getSDLVersion()});

    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");
    defer commands.deinit(gpa);
    defer CommandState.processed_files.clearAndFree(gpa);

    // init SDL backend (creates and owns OS window)
    var backend = try Backend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 900.0, .h = 600.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = vsync,
        .title = "Altair Disk Viewer",
        .icon = window_icon_png, // can also call setIconFromFileContent()
    });
    defer backend.deinit();

    try setImagePath(".");
    defer gpa.free(image_path_selection.?); // TODO: Either make thes undefined and free here or options nad check the optional.
    try setLocalPath(".\\disks");
    defer gpa.free(local_path_selection.?);

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer {
        std.debug.print("DEINITY\n", .{});
        win.deinit();
    }
    defer {
        if (theme_set)
            global_theme.deinit(gpa);
    }

    std.debug.print("Local path = {s}\n", .{local_path_selection.?});
    try commands.openLocalDirectory(local_path_selection.?);
    local_directories = try commands.localDirectoryListing(gpa);
    main_loop: while (true) {
        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(backend.hasEvent());

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        const quit = try backend.addAllEvents(&win);
        if (quit) break :main_loop;

        // if dvui widgets might not cover the whole window, then need to clear
        // the previous frame's render
        _ = Backend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 255);
        _ = Backend.c.SDL_RenderClear(backend.renderer);

        // The demos we pass in here show up under "Platform-specific demos"
        // TODO: This is where we need to catch unexpected errors
        if (!try gui_frame()) break :main_loop;

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

var theme_set = false;
var global_theme: dvui.Theme = undefined;

// TODO: There must be a better way to set the theme?
fn set_theme() !void {
    if (theme_set)
        return;

    // TODO: The Accent colour doesn't match the rest of the theme.
    // It is color_focus.
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
    const parsed = try dvui.Theme.QuickTheme.fromString(gpa, terminal_theme);
    defer parsed.deinit();

    const quick_theme = parsed.value;
    global_theme = try quick_theme.toTheme(gpa);
    // TODO: Is there a better colout to use for the grid selector than err?
    global_theme.color_err = try dvui.Color.fromHex("#08380e".*);
    //    global_theme.font_caption = .{ .size = global_theme.font_body.size, .name = global_theme.font_caption.name };
    global_theme.font_title_4 = .{ .size = 14, .name = global_theme.font_title_4.name };

    dvui.themeSet(&global_theme);
    theme_set = true;
}

fn gui_frame() !bool {
    if (!theme_set)
        try set_theme();
    frame_count += 1;
    text_box_focussed = false;

    if (!try createMenu()) return false;

    // This vbox contains all of the UI below the menu
    var vbox = try dvui.box(@src(), .vertical, .{
        .expand = .both,
        .border = Rect.all(0),
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
            .collapsed_size = paned_collapsed_width,
        }, .{
            .expand = .both,
            .background = true,
            .min_size_content = .{ .h = 100 },
        });
        defer paned.deinit();
        {

            // Top (or left) half of the pane contails the files from the Alrair disk image.
            var top_half = try dvui.box(@src(), .vertical, .{
                .expand = .both,
                .color_border = .{ .name = .text },
                .border = dvui.Rect.all(2),
                .corner_radius = dvui.Rect.all(5),
                .background = true, // remove
            });
            defer top_half.deinit();
            if (true) {
                try createFileSelector(.image);
                {
                    // Beneath the file selector is the file grid, with a fixed header
                    // and scroll area for the body. This vbox contains that grid.
                    var grid = try dvui.box(@src(), .vertical, .{
                        .background = true,
                        .expand = .both,
                    });
                    defer grid.deinit();

                    // TODO: What is this second vbox for?
                    var header = try dvui.box(@src(), .vertical, .{
                        .expand = .horizontal,
                        .border = border_width,
                    });
                    defer header.deinit();

                    try createGridHeader(.image);
                    try makeGridBody(.image);
                }
            }
        }
        blk: {
            // If paned is collapse, don't display the right/bottom pane.
            if (paned.collapsed()) {
                paned.animateSplit(1.0);
                break :blk;
            }

            var bottom_half = try dvui.box(@src(), .vertical, .{
                .expand = .both,
                .border = dvui.Rect.all(2),
                .corner_radius = dvui.Rect.all(5),
                .background = true, // remove
            });
            defer bottom_half.deinit();
            {
                if (true) {
                    try createFileSelector(.local);
                    {
                        var grid = try dvui.box(@src(), .vertical, .{
                            .background = true,
                            .expand = .horizontal,
                            .border = border_width,
                        });
                        defer grid.deinit();

                        // This box is just for padding purposes
                        var header = try dvui.box(@src(), .vertical, .{
                            .expand = .horizontal,
                            .background = true,
                            .border = border_width,
                        });
                        defer header.deinit();

                        try createGridHeader(.local);
                        try makeGridBody(.local);
                    }
                }
            }
        }
    }

    if (true) // DONT't remove braces
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
            .margin = Rect{},
        });
        defer menu_box.deinit();

        const reversed = dvui.Options{
            .color_text = .{ .name = .fill_window },
            .color_fill = .{ .name = .text },
            .expand = .horizontal,
            .margin = Rect{ .x = 2, .w = 2, .y = 2, .h = 0 },
            .corner_radius = Rect.all(0),
            .background = true,
        };

        const color_to_use = reversed;
        if (try statusBarButton(@src(), "GET", .{}, color_to_use, 0, .get, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try getButtonHandler();
            }
        }
        if (try statusBarButton(@src(), "PUT", .{}, color_to_use, 0, .put, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try putButtonHandler();
            }
        }
        if (try statusBarButton(@src(), "ERASE", .{}, color_to_use, 0, .erase, image_directories != null) or
            current_command == .erase)
        {
            if (CommandState.shouldProcessCommand()) {
                try eraseButtonHandler();
            }
        }
        if (try statusBarButton(@src(), "GET SYS", .{}, color_to_use, 4, .getsys, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try getSysButtonHandler();
            }
        }
        if (try statusBarButton(@src(), "PUT SYS", .{}, color_to_use, 5, .putsys, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try putSysButtonHandler();
            }
        }
        if (try statusBarButton(@src(), "CLOSE", .{}, color_to_use, 0, .close, image_directories != null)) {
            commands.closeImage(); // TODO: This makes some memory invalid?
            image_directories = null;
            CommandState.finishCommand();
        }

        if (try statusBarButton(@src(), "INFO", .{}, color_to_use, 2, .info, image_directories != null)) {
            if (CommandState.shouldProcessCommand()) {
                try infoButtonHandler();
            }
        }

        var buf: [20]u8 = undefined;
        var label = if (current_user == 16)
            try std.fmt.bufPrint(&buf, "USER *", .{})
        else
            try std.fmt.bufPrint(&buf, "USER {}", .{current_user});

        if (try statusBarButton(@src(), label, .{}, color_to_use, 0, .user, true)) {
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
        }
        if (try statusBarButton(@src(), "NEW", .{}, color_to_use, 0, .new, true)) {
            if (CommandState.shouldProcessCommand()) {
                try newButtonHandler();
            }
        }
        label = try std.fmt.bufPrint(&buf, "{s}", .{@tagName(copy_mode)});
        const underline_pos: usize = if (copy_mode == .BINARY) 3 else 0;
        if (try statusBarButton(@src(), label, .{}, color_to_use, underline_pos, .mode, true)) {
            copy_mode = nextCopyMode(copy_mode);
        }

        if (try statusBarButton(@src(), "ORIENT", .{}, color_to_use, 1, .orient, true)) {
            if (pane_orientation == .horizontal) {
                pane_orientation = .vertical;
            } else {
                pane_orientation = .horizontal;
                dvui.refresh(dvui.currentWindow(), @src(), null);
            }
        }
        if (try statusBarButton(@src(), "EXIT", .{}, color_to_use, 1, .exit, true)) {
            return false;
        }

        if (current_command != .get and current_command != .erase and current_command != .new and current_command != .put and current_command != .getsys) {
            current_command = .none;
        }
        // If there is an operation in progress, show the transfer dialog.
        try makeTransferDialog();
    }
    return true;
}

fn createMenu() !bool {
    if (true) {
        // TODO: Do we even really need a menu???
        var m = try dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
        defer m.deinit();

        if (try dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), .{ .from = r }, .{});
            //            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
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
            }
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
        .{ .category = .selection, .shortcut = "PG DN", .button = null, .help_text = "Scroll grid down." },
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

fn createFileSelector(id: GridType) !void {
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
    // So we don;t need to use is_initilized on the next loop to set the text?
    var entry = try dvui.textEntry(@src(), .{}, .{
        .id_extra = @intFromEnum(id),
        .expand = .horizontal,
    });
    errdefer entry.deinit();
    text_box_focussed = entry.wd.id == dvui.focusedWidgetId() or text_box_focussed;
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

    if (is_initialised.* == false) {
        is_initialised.* = true;
        entry.textLayout.selection.selectAll();
        entry.textTyped(path.*.?, false);
        dvui.refresh(null, @src(), null);
    }
    if (entry.enter_pressed) {
        // TODO: Repeated code from the icon click.
        image_directories = null;
        try commands.openExistingImage(entry.getText());
        image_directories = try commands.directoryListing(gpa);
        std.debug.print("Enter\n", .{});
        dvui.focusWidget(dvui.currentWindow().wd.id, null, null);
    }
    entry.deinit();

    if (try buttonIcon(@src(), "toggle", folder_icon, .{ .draw_focus = false }, .{ .id_extra = @intFromEnum(id) }, id)) {
        if (id == .image) {
            const filename = try dvui.dialogNativeFileOpen(dvui.currentWindow().arena(), .{ .title = "Select disk image", .filters = &.{ "*.dsk", "*.img" }, .filter_description = "images" });
            if (filename) |f| {
                std.debug.print("New file: {s}\n", .{f});
                image_directories = null;
                try commands.openExistingImage(f);
                image_directories = try commands.directoryListing(gpa);
                try setImagePath(f);
                is_initialised.* = false;
            }
        } else {
            // TODO: prob just init this to undefined. it's not really an optional.
            if (local_path_selection.?.len == 1 and local_path_selection.?[0] == '.') {
                var cwd = std.fs.cwd();
                const full_path = try cwd.realpathAlloc(gpa, ".");
                try setLocalPath(full_path);
            }

            const dirname =
                try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{ .title = "Select a Folder", .path = local_path_selection });
            if (dirname) |dir| {
                try commands.openLocalDirectory(dir);
                local_directories = try commands.localDirectoryListing(gpa);
                try setLocalPath(dir);
            }
        }
    }
}

fn createGridHeader(id: GridType) !void {
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

fn makeGridBody(id: GridType) !void {
    const directory_list = getDirectoryById(id);
    var should_display = true;

    const loaded = switch (id) {
        .image => if (image_directories == null) false else true,
        .local => if (local_directories == null) false else true,
    };
    if (!loaded) {
        try dvui.labelNoFmt(@src(), "Please open a disk image.", .{ .id_extra = @intFromEnum(id), .gravity_x = 0.5, .gravity_y = 0.5 });
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
        index: usize,
    };
    var to_display = try std.ArrayListUnmanaged(DisplayedFile).initCapacity(dvui.currentWindow().arena(), directory_list.len);
    defer to_display.deinit(dvui.currentWindow().arena());

    for (directory_list, 0..) |*entry, i| {
        if (entry.deleted) continue;
        if (id == .image and current_user != 16 and current_user != entry.user()) continue;
        to_display.appendAssumeCapacity(.{ .entry = entry, .index = i });
    }

    // TODO: Make this highlight part of the theme?
    //    const highlight_color: Options.ColorOrName = .{ .color = try dvui.Color.fromHex("#08380e".*) };
    var background: ?dvui.Options.ColorOrName = null;

    // TODO: Issue with this is that the row can be filtered :( So the index of the row on screen is no the same as
    // the index of a row in the grid.
    // So need to filter out the list to be displayed first in like an array of pointers to the underlying and then
    // run the routine... or something like that?ASD?
    // Work out which row is being highlighted.
    // previously this was within each individual row, but if the mouse went through multiple rows in a frame,
    // they would all end up getting highlighted on that frame and if the mouse was in an "inconvenient" location,
    // two rows could get highlighted at once.
    // Weird issues during scrolling etc. This way the highlighted row is calculated in adcance.
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
                    const offset_magic = -103; // Not sure why this magic is required?
                    const first_displayed: usize = @intFromFloat(getScrollInfo(id).viewport.y / 25);

                    rel_mouse_index = @intFromFloat(@max(me.p.y + offset_magic, 0) / 25);
                    rel_mouse_index += first_displayed;
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
        // TODO: Check if this *1000000 is really needed? If the create is called from
        // different parts of the source code.
        const id_extra = @intFromEnum(id) * 1000000 + abs_index;

        // TODO: I don;t think this is needed any more . USed ot be used for hover
        var row_box = try dvui.box(@src(), .horizontal, .{
            .id_extra = id_extra,
            .expand = .horizontal,
        });
        defer row_box.deinit();

        var row = try dvui.box(@src(), .horizontal, .{
            .id_extra = id_extra,
            .expand = .horizontal,
            .background = true,
            .color_fill = background,
        });

        defer row.deinit();
        var buf = std.mem.zeroes([256]u8);
        const checked_value = if (getDirectoryById(id)[abs_index].checked) "[X]" else "[ ]";
        try makeGridDataRow(0, id_extra, checked_value, false);
        try makeGridDataRow(1, id_extra, entry.entry.filename(), false);
        try makeGridDataRow(2, id_extra, entry.entry.extension(), false);
        try makeGridDataRow(3, id_extra, entry.entry.attribs(), false);

        var text = try formatNumber(&buf, "{}B", entry.entry.fileSizeInB());
        try makeGridDataRow(4, id_extra, text, true);

        text = try formatNumber(&buf, "{}K", entry.entry.fileUsedInKB());
        try makeGridDataRow(5, id_extra, text, true);

        text = try std.fmt.bufPrint(&buf, "{}", .{entry.entry.user()});
        try makeGridDataRow(6, id_extra, text, true);

        // TODO: Hardcoded 25's. should jsut be row height?

        if (true) {
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
            sortDirectories(id, label);
        }
    }
    try dvui.separator(@src(), .{ .id_extra = num, .expand = .vertical, .margin = Rect.all(1) });
    header_rects[num] = grp.data().rect;
}

/// Creates one row in the grid.
/// Note the use of the cols_rects array to make sure the scolling columns
/// are kept the same size as the header columns.
fn makeGridDataRow(col_num: u32, item_num: usize, value: []const u8, justify: bool) !void {

    // This hbox contains the row.
    var row = try dvui.box(@src(), .horizontal, .{
        .id_extra = col_num * 100 + item_num,
        .expand = .horizontal,
        .background = false,
        .margin = Rect.all(0),
        .padding = Rect.all(0),
        .min_size_content = .{ .w = header_rects[col_num].w, .h = row_height + 10.0 },
        .max_size_content = .{ .w = header_rects[col_num].w, .h = row_height + 10.0 },
    });
    defer row.deinit();

    // TODO: Why do we need 2 hboxes?
    var hbox = try dvui.box(@src(), .horizontal, .{
        .id_extra = col_num * 100 + item_num,
        .background = false,
        .min_size_content = .{ .w = header_rects[col_num].w, .h = row_height + 10.0 },
        .max_size_content = .{ .w = header_rects[col_num].w, .h = row_height + 10.0 },
    });
    defer hbox.deinit();
    if (col_num == 0 and false) {
        // TODO: Magic numbers.
        _ = try dvui.button(@src(), "[_]", .{}, .{
            .id_extra = col_num * 100 + item_num,
            .background = false,
        });
    } else {
        // TODO: Magic numbers.
        var name = try dvui.textLayout(@src(), .{}, .{
            .id_extra = col_num * 100 + item_num,
            .margin = Rect{ .x = 1, .w = 1 },
            .padding = Rect{ .x = 8, .w = 8 },
            .gravity_x = if (justify) 1.0 else 0.0,
            .gravity_y = 0.5,
            .background = false,
        });
        defer name.deinit();
        try name.addText(value, .{ .margin = dvui.Rect{ .w = 5, .h = 5 } });
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

fn sortDirectories(id: GridType, sort_by: []const u8) void {
    const idx = @intFromEnum(id);
    if (std.mem.eql(u8, sort_column[idx], sort_by)) {
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
fn formatNumber(buf: []u8, comptime fmt: []const u8, value: usize) ![]const u8 {
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
    const result_slice = buf[0..buf_idx];
    std.mem.reverse(u8, result_slice);
    return result_slice;
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

    const selected = current_command == cmd;
    var options2 = opts;
    if (selected) {
        options2 = options2.override(.{ .color_fill = .{ .color = opts.color(.fill_press) } });
    } else if (!enabled) {
        options2 = options2.override(.{ .color_fill = .{ .color = opts.color(.fill_hover) } });
    }
    var bw = dvui.ButtonWidget.init(src, init_opts, options2);

    bw.click = selected;

    // make ourselves the new parent
    try bw.install();

    // process events (mouse and keyboard) unless another operation is in progress.
    if (current_command == .none and !enter_pressed and enabled) {
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
            break :color opts.color(.fill_hover);
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
        dvui.refresh(null, @src(), 0);
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

    try dvui.icon(@src(), name, tvg_bytes, opts.strip().override(.{ .gravity_x = 0.5, .gravity_y = 0.0, .min_size_content = opts.min_size_content, .expand = .ratio }));

    if (alt_held) {
        // TODO: This needs a better font or something to make it stand out more.
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
                if (text_box_focussed) break;
                e.handled = true;
                switch (ke.action) {
                    .down => {
                        var dirs = getDirectoryById(focussed_grid);
                        const current_selection = getKbSelectionIndex(focussed_grid);
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
            .right_alt, .left_alt => {
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
                if (text_box_focussed) break;
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
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .get;
                }
            },
            .p => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .put;
                }
            },
            .a => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .mode;
                } else if (ke.action == .down and (ke.mod == .lcontrol or ke.mod == .rcontrol)) {
                    // select all TODO: Should really be in the grid.

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
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .user;
                }
            },
            .e => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .erase;
                }
            },
            .c => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .close;
                }
            },
            .r => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .orient;
                }
            },
            .x => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .exit;
                }
            },
            .s => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .getsys;
                }
            },
            .y => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .putsys;
                }
            },
            .n => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .new;
                }
            },
            .f => {
                if (ke.action == .up and alt_held) {
                    e.handled = true;
                    current_command = .info;
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
            // TODO: for pg up and down, need to also move the current kb index.
            // Currently will just scroll back.
            .page_down => {
                e.handled = true;
                if (ke.action == .down) {
                    pgdn_pressed = true;
                    selection_mode = .kb;
                    //                    getScrollInfo(focussed_grid).scrollPageDown(.vertical);
                    //   selection_mode = .mouse; // TODO: This is temp workaround
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

// TODO: Add some sort of Filename Type (local vs image) so that local file names can be displayed.
// Also need to work out how the Image Type will be returned . Maybe just cheat and make it an atrtibute of the command struct?
// In fact the buttons can move into Command right? They don't need to be set on the current file? Eve nthough the message does need ot be set per file.
// So move the button state to the CommandState and add a "context" to the command object so that can pass ocmmand-specific context between the button handler
// the the "transferDialog".
const FileStatus = struct {
    filename: []const u8,
    message: []const u8 = "",
    completed: bool = false,

    pub fn init(filename: []const u8, message: []const u8) FileStatus {
        return .{
            .filename = filename,
            .message = message,
        };
    }
};

// TODO: pull command state into here and any
// Help clean up state management like with a BeginCommand / EndCommand
// Prob add some more helpers so that users aren't always setting multiple raw CommandState fields.
const CommandState = struct {
    const State = enum { processing, waiting_for_input, confirm, cancel };

    pub const Buttons = struct {
        yes: bool = false,
        no: bool = false,
        yes_all: bool = false,
        no_all: bool = false,
        cancel: bool = false,
        image_selector: bool = false,
        save_file_selector: bool = false,
        open_file_selector: bool = false,
        type_selector: bool = false,

        const yes_no_all: Buttons = .{ .yes = true, .no = true, .yes_all = true, .no_all = true };
        const yes_no = .{ .yes = true, .no = true };
        const none: Buttons = .{};
    };
    pub const ConfirmAllState = enum { none, yes_to_all, no_to_all };
    // Remember the itr for next time!
    var state: State = .processing;
    var confirm_all: ConfirmAllState = .none;
    var itr: ?Commands.DirIterator = null;
    var processed_files: std.ArrayListUnmanaged(FileStatus) = .empty;
    var buttons: Buttons = .{};
    var file_selector_buffer: ?[]const u8 = null;
    var image_type: ?*const ad.DiskImageType = null;
    var prompt: ?[]const u8 = null;
    var err_message: ?[]const u8 = null;
    var initialized = false;
    var arena = std.heap.ArenaAllocator.init(gpa);

    pub fn currentFile() ?*FileStatus {
        if (processed_files.items.len > 0) {
            return &processed_files.items[processed_files.items.len - 1];
        } else {
            return null;
        }
    }

    pub fn setFileSelectorBuffer(buf: []const u8) !void {
        if (file_selector_buffer) |buffer| {
            gpa.free(buffer);
        }
        file_selector_buffer = try gpa.dupe(u8, buf);
    }

    pub fn shouldProcessCommand() bool {
        return state != .waiting_for_input;
    }

    pub fn finishCommand() void {
        itr = null;
        state = .processing;
        confirm_all = .none;
        current_command = .none;
    }

    pub fn freeResources() void {
        // TODO: Move this to using the arena?
        processed_files.clearRetainingCapacity();
        if (file_selector_buffer) |buffer| {
            gpa.free(buffer);
            file_selector_buffer = null;
        }
        image_type = null;
        prompt = null;
        err_message = null;
        initialized = false;
        _ = arena.reset(.free_all);
    }
};

pub fn makeTransferDialog() !void {
    const static = struct {
        var open_flag: bool = false;
        var scroll_info: dvui.ScrollInfo = .{};
        var last_nr_messages: usize = 0;
        var choice: usize = 0;
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
    //    if (current_command == .info) {
    //        dialog_win.autoSize();
    //  }

    try dvui.windowHeader("Altair to Local", "", &static.open_flag);
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
        //                if (!dvui.eventMatchSimple(e, dialog_win.data())) {
        //                    continue;
        //                }
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
            var vbox = try dvui.box(@src(), .vertical, .{ .expand = .horizontal });
            defer vbox.deinit();
            for (CommandState.processed_files.items, 0..) |*file, i| {
                const basename = std.fs.path.basename(file.filename);
                try dvui.label(@src(), "{s:<12} --> {s}", .{ basename, file.message }, .{ .id_extra = i });
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
                            const image_name = try findNewImageName(dir_path);
                            try CommandState.setFileSelectorBuffer(image_name);
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(image_name, false);
                            dvui.refresh(null, @src(), null);
                        }
                    } else {
                        const filename = "cpm.bin";
                        try CommandState.setFileSelectorBuffer(filename);
                        entry.textLayout.selection.selectAll();
                        entry.textTyped(filename, false);
                        dvui.refresh(null, @src(), null);
                    }
                }
                if (entry.enter_pressed or entry.text_changed) {
                    try CommandState.setFileSelectorBuffer(entry.getText());
                }
                empty_file_selector = entry.getText().len == 0;
                entry.deinit();
                if (try dvui.buttonIcon(@src(), "toggle", folder_icon, .{}, .{})) {
                    if (CommandState.buttons.image_selector) {
                        if (try dvui.dialogNativeFileSave(dvui.currentWindow().arena(), .{
                            .title = "Save image as",
                            .filters = &.{ "*.DSK", "*.IMG" },
                            .filter_description = "Altair Disk Images *.DSK;*.IMG",
                        })) |filename| {
                            try CommandState.setFileSelectorBuffer(filename);
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(filename, false);
                            dvui.refresh(null, @src(), null);
                        }
                    } else if (CommandState.buttons.save_file_selector) {
                        try CommandState.setFileSelectorBuffer("cpm.bin");
                        if (try dvui.dialogNativeFileSave(dvui.currentWindow().arena(), .{
                            .title = "Save file as",
                            .filters = &.{ "*.bin", "*.cpm" },
                            .filter_description = "System Images *.bin;*.cpm",
                        })) |filename| {
                            try CommandState.setFileSelectorBuffer(filename);
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(filename, false);
                            dvui.refresh(null, @src(), null);
                        }
                    } else {
                        try CommandState.setFileSelectorBuffer("cpm.bin");
                        if (try dvui.dialogNativeFileOpen(dvui.currentWindow().arena(), .{
                            .title = "Save file as",
                            .filters = &.{ "*.bin", "*.cpm" },
                            .filter_description = "System Images *.bin;*.cpm",
                        })) |filename| {
                            try CommandState.setFileSelectorBuffer(filename);
                            entry.textLayout.selection.selectAll();
                            entry.textTyped(filename, false);
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
        if (nr_messages > static.last_nr_messages) {
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

        if (current_command != .none) {
            _ = try dvui.button(@src(), "Working...", .{}, .{});
        } else {
            if (key_state == .enter or try buttonFocussed(@src(), "Close", .{}, .{})) {
                CommandState.finishCommand();
                CommandState.freeResources();
                // TODO: Need to clear the selection as well. prod add an EndCommand() that does the cleanup.
                dialog_win.close(); // can close the dialog this way
                // Refresh everything to the newset state.
                // TODO: This needs to be moved so it is always called on closeing of the window. i.e. by checking the closing variable?
                if (local_directories != null) {
                    local_directories = try commands.localDirectoryListing(gpa);
                }
                if (image_directories != null) {
                    image_directories = try commands.directoryListing(gpa);
                }
            }
        }
    }
}

/// Get selected files from image to local
/// Should be called each frame until current_command != .get
/// Handles at most 1 file per frame.
fn getButtonHandler() !void {
    if (image_directories == null) {
        // TODO: Potentially show a no files dialog box.
        current_command = .none;
        return;
    }
    current_command = .get;
    dvui.refresh(dvui.currentWindow(), @src(), null);
    if (local_path_selection) |local_path| {
        if (CommandState.itr == null) {
            // There shouldn't be any processed files when a new command is started.
            std.debug.assert(CommandState.processed_files.items.len == 0);
            // Create an iterator that returns the selected directories.
            CommandState.itr = Commands.DirectoryIterator(image_directories.?, DirectoryEntry.isSelected);
        }

        switch (CommandState.state) {
            .confirm, .processing => {
                CommandState.prompt = null; // TODO: fix all of this state handling stuff.
                const dir_entry = if (CommandState.state == .confirm) CommandState.itr.?.peek() else CommandState.itr.?.next();
                if (dir_entry) |file| {
                    if (CommandState.state != .confirm) {
                        try CommandState.processed_files.append(gpa, .init(file.filenameAndExtension(), "Copying..."));
                    }
                    var success: bool = true;
                    commands.getFile(file, local_path, copy_mode, CommandState.state == .confirm) catch |err| {
                        success = false;
                        var current = CommandState.currentFile().?;
                        if (CommandState.confirm_all == .yes_to_all) {
                            current.message = formatErrorMessage(err);
                        } else if (CommandState.confirm_all == .no_to_all) {
                            current.message = "Skipped.";
                        } else {
                            switch (err) {
                                error.PathAlreadyExists => {
                                    current.message = "Overwrite existing file?";
                                    CommandState.buttons = .yes_no_all;
                                    CommandState.state = .waiting_for_input;
                                },
                                else => {
                                    CommandState.prompt = "Retry?";
                                    current.message = formatErrorMessage(err);
                                    CommandState.buttons = .yes_no_all;
                                    CommandState.state = .waiting_for_input;
                                },
                            }
                        }
                    };
                    if (success) {
                        CommandState.state = .processing;
                        CommandState.currentFile().?.message = "Copied.";
                    }
                } else {
                    std.debug.print("setting current command = .none\n", .{});
                    CommandState.finishCommand();
                    // reload the directories when done so user can see.
                    //local_directories = try commands.localDirectoryListing(gpa);
                }
            },
            .cancel => {
                if (CommandState.currentFile()) |current| {
                    current.message = "Skipped.";
                    CommandState.state = .processing;
                } else {
                    CommandState.finishCommand();
                }
            },
            else => unreachable,
        }
    } else {
        // TODO: pop-up an error here.
    }
}

fn putButtonHandler() !void {
    if (local_directories == null) {
        // TODO: Potentially show a no files dialog box.
        current_command = .none;
        return;
    }
    current_command = .put;
    dvui.refresh(dvui.currentWindow(), @src(), null);
    //    if (local_path_selection) |local_path| {
    if (local_path_selection) |local_path| {
        if (CommandState.itr == null) {
            // There shouldn't be any processed files when a new command is started.
            std.debug.assert(CommandState.processed_files.items.len == 0);
            // Create an iterator that returns the selected directories.
            CommandState.itr = Commands.DirectoryIterator(local_directories.?, DirectoryEntry.isSelected);
        }

        switch (CommandState.state) {
            .confirm, .processing => {
                CommandState.prompt = null;
                const dir_entry = if (CommandState.state == .confirm) CommandState.itr.?.peek() else CommandState.itr.?.next();
                if (dir_entry) |file| {
                    if (CommandState.state != .confirm) {
                        try CommandState.processed_files.append(gpa, .init(file.filenameAndExtension(), "Copying..."));
                    }
                    var success: bool = true;
                    // TODO: Get user
                    commands.putFile(file.filenameAndExtension(), local_path, current_user, CommandState.state == .confirm or CommandState.confirm_all == .yes_to_all) catch |err| {
                        var current = CommandState.currentFile().?;
                        std.debug.print("error is {s}\n", .{@errorName(err)});
                        switch (err) {
                            // These are errors that need to be handled regardless of "confirm all"
                            error.OutOfAllocs => {
                                success = false;
                                current.message = "Disk Full";
                                CommandState.finishCommand();
                            },
                            else => {
                                if (CommandState.confirm_all == .yes_to_all) {
                                    current.message = formatErrorMessage(err);
                                } else if (CommandState.confirm_all == .no_to_all) {
                                    current.message = "Skipped";
                                    success = false;
                                } else {
                                    // These are errors which ignore "confirm all"
                                    success = false;
                                    switch (err) {
                                        error.PathAlreadyExists => {
                                            current.message = "Overwrite existing file?";
                                            CommandState.buttons = .yes_no_all;
                                            CommandState.state = .waiting_for_input;
                                        },
                                        else => {
                                            CommandState.prompt = "Retry?";
                                            current.message = formatErrorMessage(err);
                                            CommandState.buttons = .yes_no_all;
                                            CommandState.state = .waiting_for_input;
                                        },
                                    }
                                }
                            },
                        }
                    };
                    if (success) {
                        CommandState.state = .processing;
                        CommandState.currentFile().?.message = "OK";
                    }
                } else {
                    std.debug.print("setting current command = .none\n", .{});
                    CommandState.finishCommand();
                    // reload the directories when done so user can see.
                    //local_directories = try commands.localDirectoryListing(gpa);
                }
            },
            .cancel => {
                var current = CommandState.currentFile().?;
                current.message = "Skipped.";
                CommandState.state = .processing;
            },
            else => unreachable,
        }

        //        dvui.refresh(dvui.currentWindow(), @src(), null);
    } else {
        // TODO: pop-up an error here.
    }
}

fn eraseButtonHandler() !void {
    std.debug.print("Erase handler\n", .{});
    current_command = .erase;
    dvui.refresh(dvui.currentWindow(), @src(), null);

    // TODO:?? Is this local path selection needed?
    // And how do we know what we are doing and erase on? Only the image dir?
    if (local_path_selection) |local_path| {
        if (CommandState.itr == null) {
            // There shouldn't be any processed files when a new command is started.
            std.debug.assert(CommandState.processed_files.items.len == 0);
            // Create an iterator that returns the selected directories.
            CommandState.itr = Commands.DirectoryIterator(image_directories.?, DirectoryEntry.isSelected);
        }

        blk: switch (CommandState.state) {
            .processing => {
                if (CommandState.itr.?.next()) |file| {
                    std.debug.print("{s}.{s}\n", .{ file.filename(), file.extension() });
                    try CommandState.processed_files.append(gpa, .init(file.filenameAndExtension(), "Erase?"));
                    if (CommandState.confirm_all == .yes_to_all) {
                        CommandState.state = .confirm;
                        continue :blk .confirm; // Continue to the .confirm case.
                    } else if (CommandState.confirm_all == .no_to_all) {
                        CommandState.currentFile().?.message = "Skipped.";
                    } else {
                        CommandState.buttons = .yes_no_all;
                        CommandState.state = .waiting_for_input;
                    }
                } else {
                    CommandState.finishCommand();
                }
            },
            .confirm => {
                if (CommandState.itr.?.peek()) |file| {
                    std.debug.print(".confirm\n", .{});
                    var success: bool = true;
                    commands.eraseFile(file, local_path) catch |err| {
                        std.debug.print("err\n", .{});
                        var current = CommandState.currentFile().?;
                        if (CommandState.confirm_all == .yes_to_all) {
                            current.message = formatErrorMessage(err);
                        } else {
                            success = false;
                            switch (err) {
                                else => {
                                    current.message = formatErrorMessage(err);
                                    CommandState.state = .processing;
                                },
                            }
                        }
                    };
                    if (success) {
                        std.debug.print("success\n", .{});
                        CommandState.state = .processing;
                        CommandState.currentFile().?.message = "ERASED";
                        file.deleted = true;
                    }
                }
            },
            .cancel => {
                var current = CommandState.currentFile().?;
                current.message = "Skipped.";
                CommandState.state = .processing;
            },
            else => unreachable,
        }

        //        dvui.refresh(dvui.currentWindow(), @src(), null);
    } else {
        // TODO: pop-up an error here.
    }
}

fn newButtonHandler() !void {
    std.debug.print("New handler\n", .{});
    current_command = .new;
    dvui.refresh(dvui.currentWindow(), @src(), null);

    // TODO: Add a "begin command" to command state that basically makes sure the transfer window is shown.
    // Or something like that. Are there any commands that don't need to show that window?

    // TODO:?? Is this local path selection needed?
    // And how do we know what we are doing and erase on? Only the image dir?
    switch (CommandState.state) {
        .processing => {
            CommandState.prompt = "Create new image?";
            CommandState.state = .waiting_for_input;
            CommandState.buttons = .{ .image_selector = true, .type_selector = true, .yes = true, .no = true };
        },
        .confirm => {
            // TODO: Need the try / force option here.
            if (CommandState.file_selector_buffer) |image_path| {
                var current = FileStatus.init(image_path, "Creating...");
                try CommandState.processed_files.append(gpa, current);
                const image_type = CommandState.image_type orelse ad.all_disk_types.getPtrConst(.FDD_8IN);
                commands.createNewImage(image_path, image_type) catch |err| {
                    // TODO: Should be some way to set this to error.
                    current.message = formatErrorMessage(err);
                };
                current.message = "Created.";
                try setImagePath(image_path);
            }
            CommandState.finishCommand();
        },
        .cancel => {
            // TODO: We need to free resources here because the dialog closes immediately due to
            // there being no files in the process_files collection.
            // This is a wierd way to manage the state of whether the window is open or not. Needs a re-think
            CommandState.finishCommand();
            CommandState.freeResources();
        },
        else => unreachable,
    }
}

fn getSysButtonHandler() !void {
    std.debug.print("Get Sys handler\n", .{});
    current_command = .getsys;
    dvui.refresh(dvui.currentWindow(), @src(), null);

    // TODO: Add a "begin command" to command state that basically makes sure the transfer window is shown.
    // Or something like that. Are there any commands that don't need to show that window?

    // TODO:?? Is this local path selection needed?
    // And how do we know what we are doing and erase on? Only the image dir?
    switch (CommandState.state) {
        .processing => {
            CommandState.prompt = "Extract system image to?";
            CommandState.state = .waiting_for_input;
            CommandState.buttons = .{ .save_file_selector = true, .yes = true, .no = true };
        },
        .confirm => {
            // TODO: Need the try / force option here.
            if (CommandState.file_selector_buffer) |sys_path| {
                var current = FileStatus.init(sys_path, "Creating...");
                try CommandState.processed_files.append(gpa, current);
                commands.getSystem(sys_path) catch |err| {
                    current.message = formatErrorMessage(err);
                };
                CommandState.currentFile().?.message = "Done.";
                current.message = "Extracted.";
            }
            CommandState.finishCommand();
        },
        .cancel => {
            // TODO: We need to free resources here because the dialog closes immediately due to
            // there being no files in the process_files collection.
            // This is a wierd way to manage the state of whether the window is open or not. Needs a re-think
            CommandState.finishCommand();
            CommandState.freeResources();
        },
        else => unreachable,
    }
}

fn putSysButtonHandler() !void {
    std.debug.print("Get Sys handler\n", .{});
    current_command = .getsys;
    dvui.refresh(dvui.currentWindow(), @src(), null);

    // TODO: Add a "begin command" to command state that basically makes sure the transfer window is shown.
    // Or something like that. Are there any commands that don't need to show that window?

    // TODO:?? Is this local path selection needed?
    // And how do we know what we are doing and erase on? Only the image dir?
    switch (CommandState.state) {
        .processing => {
            CommandState.prompt = "Install system image from? ";
            CommandState.state = .waiting_for_input;
            CommandState.buttons = .{ .open_file_selector = true, .yes = true, .no = true };
        },
        .confirm => {
            // TODO: Need the try / force option here. ?? Not sure whta this comment means?
            if (CommandState.file_selector_buffer) |sys_path| {
                var current = FileStatus.init(sys_path, "Installing...");
                try CommandState.processed_files.append(gpa, current);
                commands.putSystem(sys_path) catch |err| {
                    current.message = formatErrorMessage(err);
                };
                CommandState.currentFile().?.message = "Done.";
                current.message = "Installed.";
            }
            CommandState.finishCommand();
        },
        .cancel => {
            // TODO: We need to free resources here because the dialog closes immediately due to
            // there being no files in the process_files collection.
            // This is a wierd way to manage the state of whether the window is open or not. Needs a re-think
            CommandState.finishCommand();
            CommandState.freeResources();
        },
        else => unreachable,
    }
}

fn infoButtonHandler() !void {
    std.debug.print("Info handler\n", .{});
    current_command = .info;
    dvui.refresh(dvui.currentWindow(), @src(), null);

    // TODO: Add a "begin command" to command state that basically makes sure the transfer window is shown.
    // Or something like that. Are there any commands that don't need to show that window?

    // TODO:?? Is this local path selection needed?
    // And how do we know what we are doing and erase on? Only the image dir?
    switch (CommandState.state) {
        .processing => {
            if (commands.disk_image) |disk_image| {
                const image_type = disk_image.image_type;
                const message_list = &CommandState.processed_files;
                const allocator = CommandState.arena.allocator();
                try message_list.append(gpa, .init("Tracks", try std.fmt.allocPrint(allocator, "{d}", .{image_type.tracks})));
                try message_list.append(gpa, .init("Track Len", try std.fmt.allocPrint(allocator, "{d}", .{image_type.track_size})));
                try message_list.append(gpa, .init("Res Tracks", try std.fmt.allocPrint(allocator, "{d}", .{image_type.reserved_tracks})));
                try message_list.append(gpa, .init("Sect/Track", try std.fmt.allocPrint(allocator, "{d}", .{image_type.sectors_per_track})));
                try message_list.append(gpa, .init("Sect Len", try std.fmt.allocPrint(allocator, "{d}", .{image_type.sector_size})));
                try message_list.append(gpa, .init("Block Size", try std.fmt.allocPrint(allocator, "{d}", .{image_type.block_size})));
                try message_list.append(gpa, .init("Directories", try std.fmt.allocPrint(allocator, "{d}", .{image_type.directories})));
                try message_list.append(gpa, .init("Allocations", try std.fmt.allocPrint(allocator, "{d}", .{image_type.total_allocs})));
                CommandState.state = .waiting_for_input;
            } else {
                CommandState.finishCommand();
                CommandState.freeResources();
            }
        },
        else => unreachable,
    }
}

/// finds the next available name in NEWnnn.DSK
pub fn findNewImageName(directory: []const u8) ![]const u8 {
    const static = struct {
        var filename: [10]u8 = undefined;
    };
    @memcpy(&static.filename, "IMG000.DSK");
    var num_part = static.filename[3..6];
    std.debug.print("opening {s}\n", .{directory});
    var cwd = try std.fs.cwd().openDir(directory, .{});
    for (0..999) |file_num| {
        num_part[2] = '0' + @as(u8, @intCast(file_num % 10));
        if (file_num % 10 == 0) {
            num_part[1] = '0' + @as(u8, @intCast((file_num / 10) % 10));
        }
        if (file_num % 100 == 0) {
            num_part[0] = '0' + @as(u8, @intCast((file_num / 100) % 10));
        }
        _ = cwd.statFile(&static.filename) catch |err| {
            switch (err) {
                error.FileNotFound => return &static.filename,
                else => continue,
            }
        };
    }
    return &static.filename;
}

fn formatErrorMessage(err: anyerror) []const u8 {
    const static = struct {
        var buffer: [1024]u8 = undefined;
    };

    return std.fmt.bufPrint(&static.buffer, "Error: {s}", .{@errorName(err)}) catch {
        return "";
    };
}

// Optional: windows os only
const winapi = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn AttachConsole(dwProcessId: std.os.windows.DWORD) std.os.windows.BOOL;
} else struct {};

pub const std_options: std.Options = .{
    // Set the log level to info
    .log_level = .err,
};
