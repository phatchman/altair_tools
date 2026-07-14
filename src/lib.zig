//! Export all library namespaces.

pub const disk_image = @import("disk_image.zig");
pub const disk_types = @import("disk_types.zig");
pub const directory_table = @import("directory_table.zig");

pub const DiskImage = disk_image.DiskImage;
pub const DiskImageType = disk_types.DiskImageType;
pub const DiskImageTypes = disk_types.DiskImageTypes;
pub const DiskLabel = disk_types.DiskLabel;
pub const CookedDirEntry = directory_table.CookedDirEntry;
pub const DirectoryTable = directory_table.DirectoryTable;
pub const OperatingSystem = disk_types.OperatingSystem;
pub const all_disk_types = disk_types.all_disk_types;
pub const all_disk_type_names = disk_types.all_disk_type_names;
// pub const os_cpm = @import("os_cpm.zig");
// pub const os_ados = @import("os_altair_dos.zig");
// pub const os_hd_basic = @import("os_hd_basic.zig");
