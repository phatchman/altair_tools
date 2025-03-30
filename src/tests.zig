const std = @import("std");
const testing = std.testing;
const FileNameIterator = @import("disk_image.zig").FileNameIterator;

const DiskImageType8IN = @import("disk_types.zig").DiskImageType_MITS_8IN;
const DiskImageTYpe = @import("disk_types.zig").DiskImageType;
const CookedDirEntry = @import("disk_image.zig").CookedDirEntry;

test "filename pattern match" {
    var directories: [1]CookedDirEntry = undefined;
    @memcpy(directories[0]._filename[0..7], "ABC.COM");
    const image_type = DiskImageType8IN.init();

    directories[0].image_type = &image_type;

    var itr: FileNameIterator = .init(&directories, "*.COM", true);
    if (itr.next()) |cooked| {
        try testing.expectEqualStrings(cooked.filenameAndExtension(), "ABC.COM");
    } else {
        try testing.expect(false);
    }
}
