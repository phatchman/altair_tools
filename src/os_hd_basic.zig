pub const log = std.log.scoped(.altair_disk_lib);
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

pub const DiskImageType_HD_BASIC = struct {
    const skew_table = [48]u16{
        0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11,
        12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
        36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    };
    const directory_page = 192;
    const allocation_page = 1;
    const unusable_groups = 4;
    // These groups at end of disk are never allocated to a file.
    const never_allocated_groups = 29;

    pub fn init() DiskImageType {
        var result = DiskImageType{
            .type_id = .HD_BASIC,
            .type_name = "HD_BASIC",
            .description = "MITS 5MB Hark Disk (Altair HD BASIC)",
            .OS = .hd_basic,
            .tracks = 406,
            .reserved_tracks = 4,
            .sectors_per_track = 48,
            .sector_size_raw = 256,
            .sector_size_data = 256,
            .block_size = 2048,
            .directories = 512,
            .reserved_allocs = 56,
            .image_size = 4988928,
            .varying_sector_format = true,
            .skew_table = &skew_table,
            .detect_fn = isCorrectFormat,
        };
        result.init();
        // We can't really calc this. The disk has space for 33 more
        // allocations. They are "free" in the bitmap but are never used.
        result.total_allocs = 2403;
        return result;
    }

    pub fn isCorrectFormat(self: *const DiskImageType, io: std.Io, file: std.Io.File) bool {
        // Look for the "VOLUME TABLE" and "DIRECTORY TABLE" directory entries.
        if (DiskImageType.defaultDetectFn(self, io, file)) {
            var buf: [1024]u8 = undefined;
            var reader = file.reader(io, &buf);
            reader.seekTo(49152) catch return false;
            if (!std.mem.eql(u8, reader.interface.peek(DirEntry.volume_table.len) catch "", DirEntry.volume_table)) {
                return false;
            }
            reader.seekTo(49280) catch return false;
            if (!std.mem.eql(u8, reader.interface.peek(DirEntry.directory_table.len) catch "", DirEntry.directory_table)) {
                return false;
            }
            return true;
        }
        return false;
    }
};

pub const VolumeDescriptor = extern struct {
    label: [20]u8,
    dates_encoded: [6]u8,
    backup_set: u16 align(1),
    allocation_pages: [3]u16 align(1),
    directory_pages: [3]u16 align(1),
    os_start_page: u16 align(1),
    os_page_count: u16 align(1),
    mount_flag: u16 align(1),
    unused: [18]u8,
    allocation_page_current: u16 align(1),
    allocation_page_count: u16 align(1),
    directory_page_current: u16 align(1),
    directory_page_count: u16 align(1),
    unknown: [4]u8,
    last_page: u16 align(1),
    free_groups: u16 align(1),
    reserved_groups: u16 align(1),
    unusable_groups: u16 align(1),
    swap_area: [2]u16 align(1),
    swap_area2: [2]u16 align(1),
    unused3: [164]u8,

    pub fn format(self: *const VolumeDescriptor, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Label             : {s}\n", .{self.label});
        try writer.print("Date              : {x}\n", .{self.dates_encoded});
        try writer.print("Backup Set        : {}\n", .{self.backup_set});
        try writer.print("Allocation Pages  : {any}\n", .{self.allocation_pages});
        try writer.print("Directory Pages   : {any}\n", .{self.directory_pages});
        try writer.print("OS Start Page     : {d}\n", .{self.os_start_page});
        try writer.print("Mounted           : {d}\n", .{self.mount_flag});
        try writer.print("Alloc Page Current: {d}\n", .{self.allocation_page_current});
        try writer.print("Alloc Page Count  : {d}\n", .{self.allocation_page_count});
        try writer.print("Dir Entry Current : {d}\n", .{self.directory_page_current});
        try writer.print("Dir Entry Count   : {d}\n", .{self.directory_page_count});
        try writer.print("Last Page         : {d}\n", .{self.last_page});
        try writer.print("Free Groups       : {d}\n", .{self.free_groups});
        try writer.print("Reserved Groups   : {d}\n", .{self.reserved_groups});
        try writer.print("Unusable? Groups  : {d}\n", .{self.unusable_groups});
        try writer.print("Swap Area         : {any}\n", .{self.swap_area});
        try writer.print("Swap Area2        : {any}\n", .{self.swap_area2});
    }
};

pub const DirEntry = extern struct {
    pub const filename_len = 24;
    const volume_table = "VOLUME TABLE            ";
    const directory_table = "DIRECTORY TABLE         ";
    filename: [24]u8,
    creation_date: [3]u8,
    modification_date: [3]u8,
    read_only: u16 align(1),
    unused: [20]u8 = @splat(0xff),
    ref_count: u16 align(1),
    status: u8,
    unused2: u8 = 0,
    npages: u16 align(1),
    eof_byte: u16 align(1),
    ngroups: u16 align(1),
    last_group: u16 align(1),
    allocations: [32]u16 align(1),

    pub fn init(filename: []const u8, date: [3]u8) DirEntry {
        var result: DirEntry = .{
            .creation_date = date,
            .modification_date = date,
            .filename = @splat(' '),
            .status = 0x01,
            .read_only = 0x3, // read/write
            .ngroups = 0,
            .npages = 0,
            .ref_count = 0,
            .last_group = 0,
            .eof_byte = 0,
            .allocations = @splat(0xffff),
            .unused = @splat(0),
        };
        @memcpy(result.filename[0..filename.len], filename);
        return result;
    }

    pub fn validate(self: *const DirEntry, image_type: *const DiskImageType, entry_nr: u16) DirectoryTable.RawDirError!void {
        switch (self.status) {
            0x00, 0x01, 0x03, 0xff => {},
            else => {
                logerr(
                    "Invalid directory entry: {} [Invalid status: {x}. Must be one of 0x00, 0x01, 0x03 or 0xff]",
                    .{ entry_nr, self.status },
                );
                return DirectoryTable.RawDirError.InvalidDirectoryEntry;
            },
        }
        switch (self.read_only) {
            0x01, 0x03 => {},
            else => {
                logerr(
                    "Invalid directory entry: {} [Invalid readonly: {x}. Must be one of  0x01 or 0x03]",
                    .{ entry_nr, self.read_only },
                );
                return DirectoryTable.RawDirError.InvalidDirectoryEntry;
            },
        }
        if (self.ngroups > image_type.total_allocs) {
            logerr(
                "Invalid directory entry: {} [Invalid number of groups: {d}. Must be between 0 and {d}]",
                .{ entry_nr, self.ngroups, image_type.total_allocs },
            );
            return DirectoryTable.RawDirError.InvalidDirectoryEntry;
        }
        if (self.last_group > image_type.total_allocs) {
            logerr(
                "Invalid directory entry: {} [Invalid last group: {d}. Must be between 0 and {d}]",
                .{ entry_nr, self.last_group, image_type.total_allocs },
            );
            return DirectoryTable.RawDirError.InvalidDirectoryEntry;
        }
        if (self.npages > image_type.total_allocs * image_type.sectors_per_alloc) {
            logerr(
                "Invalid directory entry: {} [Invalid number of pages: {d}. Must be between 0 and {d}]",
                .{ entry_nr, self.npages, image_type.total_allocs * image_type.sectors_per_alloc },
            );
            return DirectoryTable.RawDirError.InvalidDirectoryEntry;
        }
        for (&self.allocations) |alloc| {
            if (alloc != 0xffff and alloc > image_type.total_allocs) {
                logerr(
                    "Invalid directory entry: {} [Invalid allocation: {d}. Must be between 0 and {d} or {d}]",
                    .{ entry_nr, alloc, image_type.total_allocs, 0xffff },
                );
                return DirectoryTable.RawDirError.InvalidDirectoryEntry;
            }
        }
    }

    pub fn isDeleted(self: *const DirEntry) bool {
        return self.status != 0x01 and self.status != 0x3;
    }

    pub fn setDeleted(self: *DirEntry) void {
        self.status = 0x00; // TODO: Confirm correct.
    }

    pub fn isLastEntry(self: *const DirEntry) bool {
        // TODO: Test this.. what actually happens for deleted files?
        return self.status == 0xff;
    }

    pub fn eql(self: *const DirEntry, cooked: *const CookedDirEntry) bool {
        return std.mem.eql(
            u8,
            std.mem.trimEnd(u8, &cooked.filename, " "),
            std.mem.trimEnd(u8, &self.filename, " "),
        );
    }

    pub fn lessThan(_: *const DiskImageType, lhs: *const DirEntry, rhs: *const DirEntry) bool {
        return std.mem.lessThan(u8, &lhs.filename, &rhs.filename);
    }

    pub fn format(self: *const DirEntry, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Filename         : {s}\n", .{self.filename});
        try writer.print("Creation         : {f}\n", .{fmtDate(self.creation_date)});
        try writer.print("Modification     : {f}\n", .{fmtDate(self.modification_date)});
        try writer.print("Read Only        : {}\n", .{self.read_only});
        try writer.print("Status           : {x}\n", .{self.status});
        try writer.print("Last Page        : {}\n", .{self.npages});
        try writer.print("Last Byte        : {}\n", .{self.eof_byte});
        try writer.print("Group Count      : {}\n", .{self.ngroups});
        try writer.print("Last Group       : {}\n", .{self.last_group});
        try writer.print("Allocations      : {any}\n", .{self.allocations});
    }

    pub fn cook(self: *const DirEntry, arena: std.mem.Allocator, image_type: *const DiskImageType, entry_nr: u16) !CookedDirEntry {
        try self.validate(image_type, entry_nr);
        var result: CookedDirEntry = .{
            .user = 0,
            .filename = @splat(' '),
            // 0x01 == RO and 0x03 == RW.
            .attribs = .{
                if (self.read_only == 0x01) 'R' else 'W',
                if (self.status == 0x01) 'S' else 'L',
            }, // Small vs Large file allocations
            .allocations = .empty,
            .os = .{
                .hd_basic = .{
                    .creation_date = self.creation_date,
                    .modification_date = self.modification_date,
                    .nbytes_last_page = self.eof_byte,
                    .ngroups = self.ngroups,
                    .last_group = self.last_group,
                    .npages = self.npages + 1, // raw dir only counts fully filled pages
                },
            },
            .size_in_bytes = @as(u32, self.npages) * image_type.sector_size_data + self.eof_byte,
            .used_in_kbytes = @as(u32, self.ngroups) * image_type.block_size / 1024,
            .has_extension = false,
        };
        try result.allocations.ensureTotalCapacity(arena, self.allocations.len);
        for (self.allocations) |alloc| {
            if (alloc == 0xffff) break;
            result.allocations.appendAssumeCapacity(alloc);
        }
        @memcpy(result.filename[0..24], &self.filename); // TODO: Support larger filenames
        return result;
    }
};

comptime {
    std.debug.assert(@sizeOf(VolumeDescriptor) == 256);
    std.debug.assert(@sizeOf(DirEntry) == 128);
    std.debug.assert(@alignOf(VolumeDescriptor) == 1);
    std.debug.assert(@alignOf(DirEntry) == 1);
}

fn unsupported(label: *VolumeDescriptor) error{InvalidImageFile}!void {
    logerr("Unsupported volume label. [Allocation page is {d}, required is 1. Directory page is {d}, required is 192]", .{ label.allocation_pages[0], label.directory_pages[0] });
    return error.InvalidImageFile;
}

pub fn loadDirectory(arena: std.mem.Allocator, dir: *DirectoryTable, image: *DiskImage, option: LoadOption) DirectoryTable.DirectoryLoadError!void {
    {
        var label_sector: DiskSector = undefined;
        const label = try loadVolumeLabel(image, &label_sector);
        if (label.directory_pages[0] != DiskImageType_HD_BASIC.directory_page) {
            return unsupported(label);
        } else if (label.allocation_pages[0] != DiskImageType_HD_BASIC.allocation_page) {
            return unsupported(label);
        }

        var dir_page: u16 = DiskImageType_HD_BASIC.directory_page;
        var dir_location = toPhysicalAddress(image.image_type, dir_page);
        var dir_sector: DiskSector = .initUnformatted(image.image_type, dir_location.track);
        var dir_count: u16 = 0;
        while (dir_count < image.image_type.directories) {
            try image.readSector(dir_location, &dir_sector);
            // Each 256B sector contains 2 x 128B diectory entries
            const entries = std.mem.bytesAsSlice(DirEntry, dir_sector.dataBytes());
            dir.raw_directories.hd_basic.appendSliceAssumeCapacity(entries);
            dir_count += @intCast(entries.len);
            dir_page += 1;
            dir_location = toPhysicalAddress(image.image_type, dir_page);
        }
        for (0..image.image_type.reserved_allocs) |alloc| {
            dir.free_allocations.unset(alloc);
        }

        for (dir.raw_directories.hd_basic.items, 0..) |entry, entry_nr| {
            for (entry.allocations) |alloc| {
                if (alloc == 0xffff) break;
                if (!entry.isDeleted()) {
                    try entry.validate(image.image_type, @intCast(entry_nr));
                    dir.free_allocations.unset(alloc);
                    // Large files use an indirect allocation scheme.
                    if (entry.status == 0x03) { // Large file
                        sub_allocs: for (0..image.image_type.sectors_per_alloc) |offset| {
                            const alloc_location = toPhysicalAddress(image.image_type, @intCast(alloc * 8 + offset));
                            var alloc_sector: DiskSector = .initUnformatted(image.image_type, alloc_location.track);
                            try image.readSector(alloc_location, &alloc_sector);
                            const allocations: []align(1) u16 = @ptrCast(alloc_sector.dataBytes());
                            for (allocations) |ind_alloc| {
                                if (ind_alloc == 0xffff) break :sub_allocs;
                                dir.free_allocations.unset(ind_alloc);
                            }
                        }
                    }
                }
            }
        }
    }
    // Check the free allocations vs the allocation bitmap from page 1 and 2.
    {
        var allocation_bitmap: [512]u8 = undefined;
        var location: PhysicalAddress = toPhysicalAddress(image.image_type, 1);
        var sector: DiskSector = .initUnformatted(image.image_type, location.track);
        try image.readSector(location, &sector);
        @memcpy(allocation_bitmap[0..256], sector.dataBytes());
        location = toPhysicalAddress(image.image_type, 2);
        sector = .initUnformatted(image.image_type, location.track);
        try image.readSector(location, &sector);
        @memcpy(allocation_bitmap[256..], sector.dataBytes());
        var alloc_nr: u16 = 0;
        for (&allocation_bitmap) |byte| {
            var to_shift: u8 = byte;
            for (0..8) |_| {
                if (alloc_nr == dir.free_allocations.capacity()) break;
                if (dir.free_allocations.isSet(alloc_nr) == if (to_shift & 0x01 == 1) true else false) {
                    // TODO: Make this a log message
                    std.debug.print(
                        "Allocation validation for {}. disk map is {} directory map is {}\n",
                        .{ alloc_nr, to_shift & 0x01, 1 - (to_shift & 0x01) },
                    );
                }
                to_shift = to_shift >> 1;
                alloc_nr += 1;
            }
        }
    }
    if (option == .full) {
        if (dir.raw_directories.hd_basic.items.len <= 2) {
            logerr("Directory table is missing mandatory 'VOLUME TABLE' and/or 'DIRECTORY TABLE' entries. Cannot load directory.", .{});
            return error.InvalidDirectoryEntry;
        }

        var raw_dir_sorted: std.ArrayList(*DirEntry) = try .initCapacity(dir.allocator(), dir.raw_directories.hd_basic.items.len);
        defer raw_dir_sorted.deinit(dir.allocator());
        // Don't show first 2 entries.
        dir.rawDirsSorted(DirEntry, dir.raw_directories.hd_basic.items[2..], &raw_dir_sorted);
        // TODO: Get a sorted set of raw dirs before creating the cooked ones.
        for (raw_dir_sorted.items) |entry| {
            if (entry.isLastEntry()) break;
            if (!entry.isDeleted()) {
                const entry_nr = (@intFromPtr(entry) - @intFromPtr(&dir.raw_directories.hd_basic.items[0])) / @bitSizeOf(DirEntry);
                try entry.validate(image.image_type, @intCast(entry_nr));
                const cooked = try entry.cook(arena, image.image_type, @intCast(entry_nr));
                dir.cooked_directories.appendAssumeCapacity(cooked);
            }
        }
    } else {
        for (dir.raw_directories.hd_basic.items, 0..) |raw_dir, entry_nr| {
            raw_dir.validate(image.image_type, @intCast(entry_nr)) catch {};
        }
    }
}

// TODO: Errorset
// TODO: hd basic decoding. Maybe we should do that encoing / decoding as a seprate step
// common  to both?

pub fn copyFromImage(image: *DiskImage, entry: *const directory_table.CookedDirEntry, out_writer: *std.Io.Writer, _: DiskImage.TextMode) !void {
    const sectors_per_alloc = image.image_type.sectors_per_alloc; // 8
    var page_count: usize = 0;
    copy: for (entry.allocations.items) |alloc| {
        if (alloc == 0xffff) break :copy;

        const start_page = alloc * sectors_per_alloc;
        for (0..sectors_per_alloc) |offset| {
            const location = toPhysicalAddress(image.image_type, @intCast(start_page + offset));
            var sector: DiskSector = .initUnformatted(image.image_type, location.track);
            try image.readSector(location, &sector);
            if (entry.attribs[1] == 'S') { // Small
                if (page_count + 1 == entry.os.hd_basic.npages) {
                    try out_writer.writeAll(sector.dataBytes()[0..entry.os.hd_basic.nbytes_last_page]);
                    break :copy;
                } else {
                    try out_writer.writeAll(sector.dataBytes());
                }
                page_count += 1;
            } else if (entry.attribs[1] == 'L') { // Larger
                const sub_allocations: []align(1) u16 = @ptrCast(sector.dataBytes());
                // Large files use indirect allocations
                for (sub_allocations) |sub_alloc| {
                    if (sub_alloc == 0xffff) break :copy;
                    for (0..sectors_per_alloc) |sub| {
                        const sub_location = toPhysicalAddress(image.image_type, @intCast(sub_alloc * sectors_per_alloc + sub));
                        var sub_sector: DiskSector = .initUnformatted(image.image_type, sub_location.track);
                        try image.readSector(sub_location, &sub_sector);
                        if (page_count == entry.os.hd_basic.npages) {
                            try out_writer.writeAll(sub_sector.dataBytes()[0..entry.os.hd_basic.nbytes_last_page]);
                            break :copy;
                        } else {
                            try out_writer.writeAll(sub_sector.dataBytes());
                        }
                        page_count += 1;
                    }
                }
            }
        }
        if (alloc == entry.os.hd_basic.last_group) break :copy;
    }
}

pub fn copyToImage(image: *DiskImage, file_reader: *std.Io.Reader, to_filename: []const u8, force: bool, text_mode: DiskImage.TextMode) !void {
    _ = text_mode; // TODO: Incorporate basic decoding.
    const CopyToImage = struct {
        const CopyToImage = @This();
        img: *DiskImage,
        entry: *DirEntry,
        indirect_location: ?PhysicalAddress,
        indirect_group_idx: u16,
        indirect_alloc_idx: u8,
        indirect_groups: [128]u16 align(1),

        pub fn init(img: *DiskImage, _: *VolumeDescriptor, entry: *DirEntry) CopyToImage {
            return .{
                //.vol = vol,
                .img = img,
                .entry = entry,
                .indirect_location = null,
                .indirect_group_idx = 0,
                .indirect_alloc_idx = 0,
                .indirect_groups = @splat(0xffff),
            };
        }

        pub fn newAllocation(self: *CopyToImage) !void { //error{OutOfAllocs}!void {
            // This should be impossible to trigger on 5MB hd_basic disks.
            if (self.indirect_alloc_idx >= self.entry.allocations.len) return error.OutOfAllocs;

            self.entry.last_group = try allocationGetFree(&self.img.directory);
            if (self.entry.ngroups < self.entry.allocations.len) {
                self.entry.allocations[self.entry.ngroups] = self.entry.last_group;
                self.entry.ngroups += 1;
            } else if (self.entry.status == 0x01 and self.entry.ngroups == self.entry.allocations.len) {
                // convert to large file format and get a new allocation for that file.
                self.convertToLargeFile();
                // Now get a new allocation for the actual file data.
                return self.newAllocation();
            } else {
                // groups are u16 = 128 per sector. 8 sectors per group
                // = 1024 groups per indirect block.
                if (self.indirect_group_idx % 128 == 0 and self.indirect_group_idx != 0) {
                    try self.writeIndirectGroupPage();
                    if (self.indirect_group_idx % 1024 == 0) {
                        // new indirect allocation page required.
                        self.indirect_location = toPhysicalAddress(self.img.image_type, self.entry.last_group * self.img.image_type.sectors_per_alloc);
                        try self.initIndirectGroupPages();
                        self.entry.allocations[self.indirect_alloc_idx] = self.entry.last_group;
                        self.indirect_alloc_idx += 1;
                        self.indirect_group_idx = 0;
                        self.entry.ngroups += 1;
                        return self.newAllocation();
                    }
                }
                self.indirect_groups[self.indirect_group_idx % 128] = self.entry.last_group;
                self.indirect_group_idx += 1;
                self.entry.ngroups += 1;
            }
        }

        fn initIndirectGroupPages(self: *CopyToImage) !void {
            const location = self.indirect_location.?;
            for (0..self.img.image_type.sectors_per_alloc) |offset| {
                var sector: DiskSector = .initUnformatted(self.img.image_type, location.track);
                @memset(sector.dataBytes(), 0xff);
                try self.img.writeSector(.{ .track = location.track, .sector = @intCast(location.sector + offset) }, &sector);
            }
        }

        fn writeIndirectGroupPage(self: *CopyToImage) !void {
            var sector: DiskSector = .initUnformatted(self.img.image_type, self.indirect_location.?.track);
            @memcpy(sector.dataBytes(), @as([]u8, @ptrCast(&self.indirect_groups)));
            try self.img.writeSector(self.indirect_location.?, &sector);
            self.indirect_location.?.sector += 1;
            @memset(&self.indirect_groups, 0xffff);
        }

        fn convertToLargeFile(self: *CopyToImage) void {
            const image_type = self.img.image_type;
            const sectors_per_alloc = image_type.block_size / image_type.sector_size_data;

            self.entry.status = 0x03;
            self.indirect_location = toPhysicalAddress(image_type, self.entry.last_group * sectors_per_alloc);

            for (self.indirect_groups[0..self.entry.allocations.len], 0..) |*group, i| {
                group.* = self.entry.allocations[i];
            }
            @memset(&self.entry.allocations, 0xffff);
            self.entry.allocations[0] = self.entry.last_group;
            self.entry.ngroups += 1;
            self.indirect_alloc_idx = 1;
            self.indirect_group_idx = self.entry.allocations.len;
        }

        // TODO: errorsets.
        pub fn writePage(self: *CopyToImage, data: []const u8) !void {
            if (data.len == 0) return;
            const image_type = self.img.image_type;
            const sectors_per_alloc = image_type.sectors_per_alloc;
            const write_page = self.entry.last_group * sectors_per_alloc + (self.entry.npages % sectors_per_alloc);
            const write_location = toPhysicalAddress(image_type, write_page);

            var write_sector: DiskSector = .initFormatted(image_type, write_location);
            @memcpy(write_sector.dataBytes()[0..data.len], data);
            try self.img.writeSector(write_location, &write_sector);
            if (data.len == self.img.image_type.sector_size_data) {
                self.entry.npages += 1;
            } else {
                self.entry.eof_byte = @intCast(data.len);
            }
        }

        // TODO: Error sets
        pub fn copyFile(self: *CopyToImage, reader: *std.Io.Reader) !void {
            var read_buffer: [256]u8 = undefined;
            const sectors_per_alloc = self.img.image_type.block_size / self.img.image_type.sector_size_data;
            var nbytes = try reader.readSliceShort(&read_buffer);
            while (nbytes != 0) {
                try self.newAllocation();
                for (0..sectors_per_alloc) |_| {
                    try self.writePage(read_buffer[0..nbytes]);
                    nbytes = try reader.readSliceShort(&read_buffer);
                    if (nbytes == 0) break;
                }
            }
        }

        pub fn flush(self: *CopyToImage) !void {
            if (self.indirect_location != null) {
                try self.writeIndirectGroupPage();
            }
        }
    };

    // TODO: This is common to all copy routines.
    const basename = std.fs.path.basename(to_filename);
    var conversion_buf: [@typeInfo(@FieldType(DirEntry, "filename")).array.len]u8 = undefined;
    const filename = translateFilename(basename, &conversion_buf);

    if (image.directory.findByFilename(filename, null)) |existing_entry| {
        if (force) {
            try image.erase(existing_entry);
        } else {
            return std.Io.File.OpenError.PathAlreadyExists;
        }
    }
    // TODO: end common.

    var label_sector: DiskSector = .initUnformatted(image.image_type, 0);
    const label: *VolumeDescriptor = try loadVolumeLabel(image, &label_sector);

    var entry_nr: u16 = undefined;
    const free_entry = try rawEntryGetFree(&image.directory, &entry_nr);
    _, const modification_date = decodeDates(label.dates_encoded) catch .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    free_entry.* = .init(filename, modification_date);

    var copy: CopyToImage = .init(image, label, free_entry);
    const copy_err = copy.copyFile(file_reader);
    try copy.flush();
    try writeAllocationBitmap(image);
    try hd_basic.rawEntryWrite(image, entry_nr);
    // TODO: Think about allocators.. And should we just pass them everywhere instead of storing them??
    // well actualyl we should jsut pull the init of the cooked out of the cooked entry itself.
    // Then this need to pass an allocator goes away.
    const cooked: CookedDirEntry = try free_entry.cook(
        image.directory.arena.allocator(),
        image.image_type,
        entry_nr,
    );
    image.directory.cooked_directories.appendAssumeCapacity(cooked);
    // If everything else succeeds, return any copy error.
    return copy_err;
}

/// Get a free allocation (group) and unmark it from the free groups in memory
/// This needs to be committed to disk in the volume label to make it a permanent allocation
/// only pub for tests
pub fn allocationGetFree(dir: *DirectoryTable) error{OutOfAllocs}!u16 {
    const free = dir.free_allocations.findFirstSet() orelse return error.OutOfAllocs;
    dir.free_allocations.unset(free);
    return @intCast(free);
}

// TODO: Remove initialized from the other ones and add an init to the Raw Entries
fn rawEntryGetFree(dir: *const DirectoryTable, entry_nr: *u16) error{OutOfExtents}!*DirEntry {
    for (dir.raw_directories.hd_basic.items, 0..) |*entry, nr| {
        if (entry.isDeleted()) {
            entry_nr.* = @intCast(nr);
            return entry;
        }
    }
    return error.OutOfExtents;
}

// TODO: Doesn;t need to be pub after we fix up the init stuff
pub fn toPhysicalAddress(image_type: *const DiskImageType, page_nr: u16) PhysicalAddress {
    // TODO: Add validation
    // Pages are sequentially numbered sectors starting from track 0
    return .{
        .track = page_nr / image_type.sectors_per_track,
        .sector = page_nr % image_type.sectors_per_track,
    };
}

// TODO: Support get / set volume label for user.
fn loadVolumeLabel(image: *DiskImage, sector: *DiskSector) !*VolumeDescriptor {
    const location: PhysicalAddress = .{ .track = 0, .sector = 0 };
    sector.* = .initUnformatted(image.image_type, location.track);
    try image.readSector(location, sector);
    const result: *VolumeDescriptor = @ptrCast(sector.dataBytes());
    return result;
}

// TODO: Needs to pass disk image type here.
pub fn initVolumeLabel(image_type: *const DiskImageType, sector: *DiskSector) void {
    const label: *VolumeDescriptor = std.mem.bytesAsValue(VolumeDescriptor, sector.dataBytes());
    label.* = .{
        .label = @splat(' '),
        .dates_encoded = @splat(0),
        .backup_set = 0,
        .allocation_pages = @splat(DiskImageType_HD_BASIC.allocation_page),
        .directory_pages = @splat(DiskImageType_HD_BASIC.directory_page),
        .os_start_page = 24, // This is set even for a freshly formatted disk with no OS
        .os_page_count = 168,
        .mount_flag = 0,
        .unused = @splat(0),
        .allocation_page_current = DiskImageType_HD_BASIC.allocation_page,
        .allocation_page_count = 305, // I don't know why this is 305. It doesn't use all 305.
        .directory_page_current = DiskImageType_HD_BASIC.directory_page,
        .directory_page_count = image_type.directories / 2, // 2 dirs per page
        .unknown = @splat(0),
        .last_page = @intCast(image_type.tracks * image_type.sectors_per_track - 1),
        .reserved_groups = image_type.reserved_allocs + 1,
        .unusable_groups = DiskImageType_HD_BASIC.unusable_groups,
        .free_groups = @intCast(image_type.total_allocs - image_type.reserved_allocs + 32),
        .swap_area = .{ 0xffff, 0xffff },
        .swap_area2 = .{ 0x0000, 0x0000 },
        .unused3 = @splat(0),
    };
}

// TODO: error sets
pub fn volumeLabelSet(image: *DiskImage, label: DiskLabel) !void {
    var sector: DiskSector = .initUnformatted(image.image_type, 0);
    try image.readSector(.{ .track = 0, .sector = 0 }, &sector);
    const vd: *VolumeDescriptor = std.mem.bytesAsValue(VolumeDescriptor, sector.dataBytes());
    vd.label = label.hd_basic.user_label;
    const encoded_date = encodeDates(label.hd_basic.created_yymmdd, label.hd_basic.modified_yymmdd);
    vd.dates_encoded = encoded_date;
    try image.writeSector(.{ .track = 0, .sector = 0 }, &sector);
    // There is a copy on the last sector
    try image.writeSector(.{ .track = image.image_type.tracks - 1, .sector = image.image_type.sectors_per_track - 1 }, &sector);
    // Update the VOLUME_LABEL and DIRECTORY_LABEL dates
    const dir_location = toPhysicalAddress(image.image_type, DiskImageType_HD_BASIC.directory_page);
    try image.readSector(dir_location, &sector);
    const vol_table: *DirEntry = std.mem.bytesAsValue(DirEntry, sector.dataBytes()[0..128]);
    const dir_table: *DirEntry = std.mem.bytesAsValue(DirEntry, sector.dataBytes()[128..]);
    vol_table.creation_date = encoded_date[0..3].*;
    dir_table.creation_date = encoded_date[0..3].*;
    vol_table.modification_date = encoded_date[3..].*;
    dir_table.modification_date = encoded_date[3..].*;
    try image.writeSector(dir_location, &sector);
}

pub fn volumeLabelGet(image: *DiskImage, label: *DiskLabel) !void {
    label.* = .{ .hd_basic = undefined };
    var sector: DiskSector = .initUnformatted(image.image_type, 0);
    const vol = loadVolumeLabel(image, &sector) catch |err| {
        logerr("Unabled to read volume label: {t}", .{err});
        return error.LabelNotFound;
    };
    @memcpy(&label.hd_basic.user_label, &vol.label);
    label.hd_basic.created_yymmdd, label.hd_basic.modified_yymmdd = decodeDates(vol.dates_encoded) catch |err| blk: {
        logerr("Unable to decode dates in volume label: {t}", .{err});
        break :blk .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    };
}

// TODO: Be consistent about what namespace the errors live in.
pub fn rawEntryWrite(img: *DiskImage, entry_nr: u16) (DiskImage.WriteSectorError || DirectoryTable.RawDirError)!void {
    const image_type = img.image_type;

    const this_entry = &img.directory.raw_directories.hd_basic.items[entry_nr];
    if (!this_entry.isDeleted()) {
        try this_entry.validate(img.image_type, entry_nr);
    }
    const entry_page = DiskImageType_HD_BASIC.directory_page + entry_nr / image_type.dirs_per_sector;
    const location = toPhysicalAddress(image_type, entry_page);
    var sector: DiskSector = .initFormatted(img.image_type, location);
    // start_index is the index of the directory entry that is first in the sector.
    const start_index = entry_nr / image_type.dirs_per_sector * image_type.dirs_per_sector;
    // Copy 1 full sector worth of extents/raw entries i.e. 2. TODO: This is genric, but small.
    @memcpy(sector.dataBytes(), std.mem.sliceAsBytes(img.directory.raw_directories.hd_basic.items[start_index..][0..image_type.dirs_per_sector]));
    try img.writeSector(location, &sector);
}

pub fn initAllocationMap(sector: *DiskSector, which: enum { first, second }) void {
    switch (which) {
        .first => @memset(sector.dataBytes()[0..7], 0xff),
        .second => sector.dataBytes()[49] = 0xF8, // TODO: Allocations 2440 - 2440 are marked as unsed / unsable??
    }
}

pub fn writeAllocationBitmap(image: *DiskImage) !void {
    var allocation_bitmap: [512]u8 = @splat(0);
    for (&allocation_bitmap, 0..) |*byte, idx| {
        const capacity = image.directory.free_allocations.capacity();
        for (0..8) |bit| {
            const group = idx * 8 + bit;
            if (group >= capacity) break;
            if (!image.directory.free_allocations.isSet(group)) {
                byte.* |= @as(u8, 1) << @intCast(bit);
            }
        }
    }
    allocation_bitmap[305] = 0xF8; // Some fixed guard byte?
    var alloc_location = toPhysicalAddress(image.image_type, 1);
    var alloc_sector: DiskSector = .initFormatted(image.image_type, alloc_location);
    @memcpy(alloc_sector.rawBytes(), allocation_bitmap[0..256]);
    try image.writeSector(alloc_location, &alloc_sector);
    alloc_location = toPhysicalAddress(image.image_type, 2);
    @memcpy(alloc_sector.rawBytes(), allocation_bitmap[256..]);
    try image.writeSector(alloc_location, &alloc_sector);

    var vol_sector: DiskSector = .initUnformatted(image.image_type, 0);
    const vol = try loadVolumeLabel(image, &vol_sector);
    vol.free_groups = @intCast(image.directory.free_allocations.count() + 32); // TODO: Constant somewhere?
    try image.writeSector(.{ .track = 0, .sector = 0 }, &vol_sector);
    try image.writeSector(.{
        .track = image.image_type.tracks - 1,
        .sector = image.image_type.sectors_per_track - 1,
    }, &vol_sector);
}

// The first 3 directory entries are "VOLUME TABLE" and "DIRECTORY TABLE"
pub fn initDirectoryEntries(image_type: *const DiskImageType, sector: *DiskSector) void {
    const vol_table: *DirEntry = std.mem.bytesAsValue(DirEntry, sector.dataBytes()[0..128]);
    const dir_table: *DirEntry = std.mem.bytesAsValue(DirEntry, sector.dataBytes()[128..]);
    vol_table.* = .{
        .filename = DirEntry.volume_table.*,
        .creation_date = @splat(0),
        .modification_date = @splat(0),
        .read_only = 0x01,
        .ref_count = 0,
        .status = 0x01,
        .npages = 3,
        .eof_byte = 0x00,
        .ngroups = 1,
        .last_group = 0x00,
        .allocations = @splat(0xffff),
    };
    vol_table.allocations[0] = 0x000;
    const sectors_per_alloc = image_type.sectors_per_alloc;
    const ngroups = image_type.directories / 2 / sectors_per_alloc;
    const dir_alloc = DiskImageType_HD_BASIC.directory_page / sectors_per_alloc;
    dir_table.* = .{
        .filename = DirEntry.directory_table.*,
        .creation_date = @splat(0),
        .modification_date = @splat(0),
        .read_only = 0x01,
        .ref_count = 0,
        .status = 0x01,
        .npages = image_type.directories / 2,
        .eof_byte = 0,
        .ngroups = ngroups,
        .last_group = dir_alloc + ngroups - 1,
        .allocations = undefined,
    };
    for (&dir_table.allocations, dir_alloc..image_type.reserved_allocs) |*alloc, idx| {
        alloc.* = @intCast(idx);
    }
}

pub fn translateFilename(basename: []const u8, to_filename: []u8) []u8 {
    var idx: usize = 0;
    for (basename) |ch| {
        if (idx == to_filename.len) break;
        if (std.ascii.isPrint(ch)) {
            to_filename[idx] = ch;
            idx += 1;
        }
    }
    log.info("Translated filename {s} to {s}", .{ basename, to_filename[0..idx] });
    return to_filename[0..idx];
}

pub fn fmtDate(date: [3]u8) std.fmt.Alt([3]u8, formatDate) {
    return .{ .data = date };
}
fn formatDate(date: [3]u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d:02}/{d:02}/{d:02}", .{ date[1], date[2], date[0] });
}

// 0 - created month, BCD +0x30
// 1 - created year, BCD
// 2 - modified year, BCD +0x30
// 3 - created day, BCD
// 4 - modified day, BCD +0x30
// 5 - modified month, BCD
fn encodeDates(created_yymmdd: [3]u8, modified_yymmdd: [3]u8) [6]u8 {
    var result: [6]u8 = undefined;
    result[0] = ((created_yymmdd[1] / 10 << 4) | (created_yymmdd[1] % 10)) +| 0x30;
    result[1] = (created_yymmdd[0] / 10 << 4) | (created_yymmdd[0] % 10);
    result[2] = ((modified_yymmdd[0] / 10 << 4) | (modified_yymmdd[0] % 10)) +| 0x30;
    result[3] = (created_yymmdd[2] / 10 << 4) | (modified_yymmdd[2] % 10);
    result[4] = ((modified_yymmdd[2] / 10 << 4) | (modified_yymmdd[2] % 10)) +| 0x30;
    result[5] = (modified_yymmdd[1] / 10 << 4) | (modified_yymmdd[1] % 10);
    return result;
}

fn plausibleDate(date: [3]u8) bool {
    return date[0] < 99 and date[1] <= 12 and date[2] <= 31;
}

// Some programs write the volume label with pseudo BCD encoding, which interleaves
// the created and modified dates, while others use raw date formats.
// Sometimes the date is all 0xff or all 0x00.
// So just try and make some sensible date out of what we are given.
fn decodeDates(encoded: [6]u8) !struct { [3]u8, [3]u8 } {
    var created_yymmdd: [3]u8 = undefined;
    var modified_yymmdd: [3]u8 = undefined;
    created_yymmdd[0] = encoded[0];
    created_yymmdd[1] = encoded[1];
    created_yymmdd[2] = encoded[2];

    modified_yymmdd[0] = encoded[3];
    modified_yymmdd[1] = encoded[4];
    modified_yymmdd[2] = encoded[5];

    if (!plausibleDate(created_yymmdd) or !plausibleDate(modified_yymmdd)) {
        created_yymmdd[0] = (encoded[1] >> 4) * 10 + (encoded[1] & 0x0f);
        created_yymmdd[1] = ((encoded[0] -% 0x30) >> 4) * 10 + ((encoded[0] -% 0x30) & 0x0f);
        created_yymmdd[2] = (encoded[3] >> 4) * 10 + (encoded[3] & 0x0f);

        modified_yymmdd[0] = ((encoded[2] -% 0x30) >> 4) * 10 + ((encoded[2] -% 0x30) & 0x0f);
        modified_yymmdd[1] = (encoded[5] >> 4) * 10 + (encoded[5] & 0x0f);
        modified_yymmdd[2] = ((encoded[4] -% 0x30) >> 4) * 10 + ((encoded[4] -% 0x30) & 0x0f);
    }
    if (!plausibleDate(created_yymmdd) or !plausibleDate(modified_yymmdd)) {
        if (std.mem.allEqual(u8, &encoded, 0xff)) {
            created_yymmdd = @splat(0);
            modified_yymmdd = @splat(0);
        } else {
            return error.InvalidDate;
        }
    }
    return .{ created_yymmdd, modified_yymmdd };
}

test "encode dates" {
    const l = struct {
        fn enc(year: u8, month: u8, day: u8) [2][3]u8 {
            return .{ .{ year, month, day }, .{ year, month, day } };
        }
    };
    var created: [3]u8 = undefined;
    var modified: [3]u8 = undefined;
    // - 01/01/70 = 31 70 A0 01 31 01
    created, modified = l.enc(70, 1, 1);
    try std.testing.expectEqual(.{ 0x31, 0x70, 0xA0, 0x01, 0x31, 0x01 }, encodeDates(created, modified));
    try std.testing.expectEqual(.{ created, modified }, decodeDates(.{ 0x31, 0x70, 0xA0, 0x01, 0x31, 0x01 }));
    // - 06/15/85 = 36 85 B5 15 45 06
    created, modified = l.enc(85, 6, 15);
    try std.testing.expectEqual(.{ 0x36, 0x85, 0xB5, 0x15, 0x45, 0x06 }, encodeDates(created, modified));
    try std.testing.expectEqual(.{ created, modified }, decodeDates(.{ 0x36, 0x85, 0xB5, 0x15, 0x45, 0x06 }));
    // - 11/23/91 = 41 91 C1 23 53 11
    created, modified = l.enc(91, 11, 23);
    try std.testing.expectEqual(.{ 0x41, 0x91, 0xC1, 0x23, 0x53, 0x11 }, encodeDates(created, modified));
    try std.testing.expectEqual(.{ created, modified }, decodeDates(.{ 0x41, 0x91, 0xC1, 0x23, 0x53, 0x11 }));
}

const std = @import("std");
const disk_types = @import("disk_types.zig");
const DiskSector = disk_types.DiskSector;
const DiskImageType = disk_types.DiskImageType;
const directory_table = @import("directory_table.zig");
const DirectoryTable = directory_table.DirectoryTable;
const LoadOption = DirectoryTable.LoadOption;
const hd_basic = @import("os_hd_basic.zig");
const DiskImage = @import("disk_image.zig").DiskImage;
const PhysicalAddress = disk_types.PhysicalAddress;
const DiskLabel = disk_types.DiskLabel;
const CookedDirEntry = directory_table.CookedDirEntry;
