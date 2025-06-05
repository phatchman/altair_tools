//! Help in managing the state of each command and their interactions with the
//! transferDialog()

/// List of available commands.
pub const CommandList = enum { none, get, put, mode, close, erase, user, new, info, getsys, putsys, orient, exit };

/// As each file is processed, it's FileStatus is added to the
/// CommandState's processed_files collection.
/// Some commands just use message if there is no filename to display.
pub const FileStatus = struct {
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

/// State of the current command
pub const State = enum {
    /// Ready to process the next file
    processing,
    /// Waiting for user response to question
    waiting_for_input,
    /// User has confirmed
    confirm,
    /// USer has cancelled
    cancel,
};

pub const Buttons = struct {
    /// Standard buttons for yes, no, etc.
    yes: bool = false,
    no: bool = false,
    yes_all: bool = false,
    no_all: bool = false,
    cancel: bool = false,

    /// Request user to supply an image filename
    image_selector: bool = false,
    /// Request user to supply a filename ot save to
    save_file_selector: bool = false,
    /// Request user to supply a filename to open from.
    open_file_selector: bool = false,
    /// Request user to supplly the image type.
    type_selector: bool = false,

    pub const yes_no_all: Buttons = .{ .yes = true, .no = true, .yes_all = true, .no_all = true };
    pub const yes_no = .{ .yes = true, .no = true };
    pub const none: Buttons = .{};

    pub fn isNone(self: Buttons) bool {
        return std.meta.eql(self, .none);
    }
};
// TODO: What should be pub or not?
pub const ConfirmAllState = enum { none, yes_to_all, no_to_all };
// Remember the itr for next time!
pub var state: State = .processing;
pub var current_command: CommandList = .none;
pub var prev_command: CommandList = .none;
pub var confirm_all: ConfirmAllState = .none;
var itr: ?Commands.DirIterator = null;
pub var processed_files: std.ArrayListUnmanaged(FileStatus) = .empty;
pub var buttons: Buttons = .{};
pub var file_selector_buffer: ?[]const u8 = null;
pub var image_type: ?*const ad.DiskImageType = null;
pub var prompt: ?[]const u8 = null;
pub var err_message: ?[]const u8 = null;
pub var initialized = false;
pub var arena: std.heap.ArenaAllocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    arena = .init(allocator);
}

pub fn directoryEntryIterator(entries: []DirectoryEntry) *Commands.DirIterator {
    if (itr == null) {
        itr = Commands.DirectoryIterator(entries, DirectoryEntry.isSelected);
    }
    return &itr.?;
}

pub fn addProcessedFile(status: FileStatus) !void {
    try processed_files.append(arena.allocator(), status);
}

pub fn currentFile() ?*FileStatus {
    if (processed_files.items.len > 0) {
        return &processed_files.items[processed_files.items.len - 1];
    } else {
        return null;
    }
}

pub fn setFileSelectorBuffer(buf: []const u8) !void {
    if (file_selector_buffer) |buffer| {
        arena.allocator().free(buffer);
    }
    file_selector_buffer = try arena.allocator().dupe(u8, buf);
}

pub fn shouldProcessCommand() bool {
    return state != .waiting_for_input;
}

pub fn finishCommand() void {
    itr = null;
    state = .processing;
    confirm_all = .none;
    buttons = .none;
    prev_command = current_command;
    current_command = .none;
}

pub fn freeResources() void {
    // TODO: Why is this shrink required over just setting capacity to 0?
    processed_files.clearAndFree(arena.allocator());
    if (file_selector_buffer) |buffer| {
        arena.allocator().free(buffer);
        file_selector_buffer = null;
    }
    image_type = null;
    prompt = null;
    err_message = null;
    initialized = false;
    _ = arena.reset(.free_all);
}

const std = @import("std");
const Commands = @import("commands.zig");
const ad = @import("altair_disk");
const DirectoryEntry = Commands.DirectoryEntry;
