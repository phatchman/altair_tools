# This branch is considered beta-quality software. 
# There are no known critical issues, however more testing is required before I can recommend regular use.

# Altair Tools 

A collection of utilities for the Altair 8800

* Altairdsk allows the reading and writing of CP/M formatted Altair 8800 floppy disk disk images.
* *NEW:* adgui provides a graphical user interface for most altairdsk operations.

If you are looking for a utility similar to cpmtools, but for the Altair 8800 floppy disk images, then this repository is for you. 
It has been tested under Windows and Linux, but would probably work on MacOS as well.

altairdsk allows you to:
  1. Perform a directory listing
  2. Copy files to and from the disk
  3. Erase files
  4. Format an existing disk or create a newly formatted disk.
  5. Create bootable CP/M disk images
  6. Recoverr disk images with directory entry corruption.

## Supported Disk Image Types

| Type              | Description   |
|-------------------|---------------|
| FDD_8IN (default) | The MITS 8" hard-sectored floppy disk images |
| FDD_TAR           | Tarbell disk images |
| HDD_5MB           | The MITS 5MB hard disk disk images |
| HDD_5MB_1024      | The MITS 5MB hard disk, but modified for 1024 directory entries. Note you need the modified CP/M image to use this format. See https://github.com/ratboy666/hd1024 |
| FDD_1.5MB         | FDC+ 1.5MB images |
| FDD_8IN_8MB       | FDC+ 8MB "floppy" images |

While every care has been taken to ensure this utility will not corrupt you disk images, _PLEASE_ make sure you make a backup of any disk images before writing to them.

## Build Instructions

This version of altair tools is built using Zig. If you are interested in why or my general thoughts after my first real Zig project, take a look kat WhyZig.MD
The C version can be found in the legacy directory and should still build using cmake. However the C version will no longer be developed or supported by me.
One of the nice things about Zig is that the build system is part of the language.
One of the not-so-nice things about Zig is that it's not a standard part of O/S distributions yet. but it is very easy to install.

1. Install Zig version 0.14.0 from https://ziglang.org/ or from your package manager if available.
2. zig build --release=safe
Optionally build the GUI.
1. cd adgui
2. zig buld --release=safe

The executables are placed in the respective zig-out\bin directories.
There is no install target provided. So copy the executable to your desired install location if you need.

## Command Line
```
USAGE:
  altairdsk [OPTIONS] <disk_image> [<filename>...]

Altair Disk Image Utility

ARGUMENTS:
  disk_image   Filename of Altair disk image
  filename     List of filesnames. Wildcards * and ? are supported e.g. '*.COM'

OPTIONS:
  -d, --dir                          Directory listing (default)
  -r, --raw                          Raw directory listing
  -i, --info                         Prints disk format information
  -F, --format                       Format existing or create new disk image. Defaults to FDD_8IN
  -g, --get                          Copy file from Altair disk image to host
  -o, --out <outdir>                 Out directory for get and get multiple
  -G, --get-multiple                 Copy multiple files from Altair disk image to host. Wildcards * and ? are supported e.g '*.COM'
  -p, --put                          Copy file from host to Altair disk image
  -P, --put-multiple                 Copy multiple files from host to Altair disk image
  -e, --erase                        Erase a file
  -E, --erase-multiple               Erase multiple files - wildcards supported
  -t, --text                         Put or get a file in text mode
  -b, --bin                          Put or get a file in binary mode
  -u, --user <user>                  Restrict operation to this CP/M user
  -x, --extract-cpm <system_image>   Extract CP/M system (from a bootable disk image) to a file
  -s, --write-cpm <system_image>     Write saved CP/M system image to disk image (make disk bootable)
  -R, --recover <new_disk_image>     Try to recover a corrupt image
  -T, --type <type>                  Disk image type. Auto-detected if possible. Supported types are:
                                           * FDD_8IN - MITS 8" Floppy Disk  (Default)
                                           * HDD_5MB - MITS 5MB Hard Disk
                                           * HDD_5MB_1024 - MITS 5MB, with 1024 directories
                                           * FDD_TAR - Tarbell Floppy Disk
                                           * FDD_1.5MB - FDC+ 1.5MB Floppy Disk
                                           * FDD_8IN_8MB - FDC+ 8MB "Floppy" Disk
                                     !!! The HDD_5MB_1024 type cannot be auto-detected. Always use -T with this format.
  -v, --verbose                      Verbose - Prints information about operations being performed
  -V, --very-verbose                 Very verbose - Additionally prints sector read/write information
  -h, --help                         Show this help output.
      --color <VALUE>                When to use colors (*auto*, never, always).
```

## Some things to note:
* The 5MB HDD images that come with the Altair-Duino have an invalid directory table. altairdsk will print an error and refuse to open these images. Use the -R / --recover option to create a clean version of these disk images.
* There is no expansion of wildcards in windows. But there is a work-around for powershell. See below.
* altairdsk will do it's best to detect whether a binary or text file is being transferred, but you can force that with the -t and -b options.
This is only needed when copying a file from the altair disk.<br>
* If an invalid CP/M filename is supplied, for example ABC.COMMMMMM, it will be converted to a similar valid CP/M filename; ABC.COM in this example.
* Wildcards don't work the same as on CP/M. ./altairdsk xxx.dsk -G '\*' will match everything, including the extension, and get all files. On CP/M you would use '\*.\*'. You can still use '\*.TXT' and 'ABC.\*' and that will work as expected.
* As mentioned in the usage, if using the HDD_5MB_1024 format with 1024 directory entries, make sure you always use the -T option. You *will* corrupt the image if you don't specify the format.

## Examples

### Get a directory listing
`./altairdsk -d cpm.dsk`<br>
`./altairdsk cpm.dsk`<br>
Restrict the directory listing to a particular user with the -u option<br>
`./altairdsk -u 0 cpm.dsk`

```
Name     Ext  Length Used U At
ASM      COM   8768B   8K 0 W
DDT      COM   5206B   6K 0 W
DO       COM   2329B   4K 0 W
DUMP     COM    411B   2K 0 W
ED       COM   6576B   6K 0 W
FORMAT   COM   1918B   2K 0 W
L80      COM  11508B  12K 0 W
LADDER   COM  43155B  40K 0 W
LOAD     COM   2192B   2K 0 W
LS       COM   3288B   4K 0 W
M80      COM  21509B  20K 0 W
MAC      COM  12604B  12K 0 W
NSWP     COM  12056B  12K 0 W
PIP      COM   7946B   8K 0 W
R        COM   4384B   4K 0 W
STAT     COM   5754B   6K 0 W
TEST     COM    137B   2K 0 W
W        COM   4247B   4K 0 W
WM       COM  11371B  12K 0 W
XDIR     COM  11782B  12K 0 W
20 file(s), occupying 178K of 296K total capacity
41 directory entries and 118K bytes remain
```
Length is length of the file to nearest 128 byte sector<br>
Used is the amount of space actually used on the disk (in multiples of 1 block)<br>
U is the user number<br>
At is the file attributes. R - Read only, W - Read/write. S - System

### Format a disk
`./altairdsk -F new.dsk`<br>
To format for a specific type<br>
`./altairdsk -F -T HDD_5MB new.dsk`

You can generally put options in any order<br>
`./altairdsk new.dsk -F -T HDD_5MB`<br>
`./altairdsk -F new.dsk -T FDD_TAR`

### Copy a file from the disk (get)
`./altairdsk -g cpm.dsk LADDER.COM`

get files for a single user<br>
`./altairdsk -g -u1 cpm.dsk LADDER.COM`

### Copy a file to the disk (put)<br>
`./altairdsk -p cpm.dsk LADDER.COM`

### Copy multiple files from the disk (get multiple)
This command allows wildcards of * or ?. Note the use of single quotes to stop the shell/command prompt expanding wildcards<br>
`./altairdsk -G cpm.dsk load.com dump.com 'asm.*' 'p?p.com'`

To get all files from the disk<br>
`./altairdsk -G cpm.dsk '*'`

If the same file exists for multiple users, the user number is appended to the filename e.g. ASM.TXT_1.

### Copy multiple files to the disk image (put multiple)
`./altairdsk -P cpm.dsk load.com dump.com asm.com pip.com`

Copy multiple files to user 1<br>
`./altairdsk -P -u1 cpm.dsk *.com`

Wildcard expansion is not performed on windows. However you can use the following powershell trick instead:
`altairdsk cpm.dsk - P $(dir *)`

### Erase a file
`./altairdsk -e cpm.dsk asm.com`

If the same file exists for multiple users, only the first copy of the file will be erased. Use the -E option to erase the file for all users.

### Erase a multiple files
`./altairdsk -E cpm.dsk 'asm.*'`

If the same file exists for multiple users, the -E option will remove the file from all users, unless the -u option is specified.<br>
To remove all files from user 2<br>
`./altairdsk -E -u 2 cpm.dsk '*'`

### Save CP/M system tracks from bootable disk
`./altairdsk -x cpm.dsk boot.img`

### Make a bootable disk from previously saved system tracks
`./altairdsk -s cpm.dsk boot.img`

### Fixup Altair Duino 5MB HDSK images
The CP/M HDSK03.DSK and HDSK04.DSK images that come with the Altair Duino have some directory entry corruption. This version of altairdsk includes a -R / --recovery option to create a new version of the image. Please be careful with the order you specify the options or you can accidentally overwrite the original image. The new image name must be specified immediately after the -R option. *Always keep a backup before doing any write operations*<br>
`altairdsk -R HDSDK04_NEW.DSK HDSK04.DSK`

You will see a list of errors while running this command. These are expected.

### Image Informatio
Displays track and sector information.
`./altairdsk -i cpm.dsk`
```
Type:         HDD_5MB
Sector Len:   128
Data Len:     128
Num Tracks:   406
Res Tracks:   1
Secs / Track: 96
Block Size:   4096
Track Len:    12288
Recs / Ext:   256
Recs / Alloc: 32
Dirs / Sect   4
Dirs / Alloc: 16
Dir Allocs:   2
Num Dirs:     256
```

### Raw directory listing
Dumps the CP/M extent information<br>
`./altairdsk -r cpm.dsk`
```
IDX:U:FILENAME:TYP:AT:EXT:REC:[ALLOCATIONS]
000:0:ASM     :COM:W :000:064:[2,3,4,5,0,0,0,0,0,0,0,0,0,0,0,0]
001:0:DDT     :COM:W :000:038:[6,7,8,0,0,0,0,0,0,0,0,0,0,0,0,0]
002:0:DO      :COM:W :000:017:[9,10,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
003:0:DUMP    :COM:W :000:003:[11,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
004:0:ED      :COM:W :000:048:[12,13,14,0,0,0,0,0,0,0,0,0,0,0,0,0]
005:0:FORMAT  :COM:W :000:014:[15,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
006:0:L80     :COM:W :000:084:[16,17,18,19,20,21,0,0,0,0,0,0,0,0,0,0]
007:0:LADDER  :COM:W :000:128:[22,23,24,25,26,27,28,29,0,0,0,0,0,0,0,0]
008:0:LADDER  :COM:W :001:128:[30,31,32,33,34,35,36,37,0,0,0,0,0,0,0,0]
009:0:LADDER  :COM:W :002:059:[38,39,40,41,0,0,0,0,0,0,0,0,0,0,0,0]
010:0:LOAD    :COM:W :000:016:[42,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
011:0:LS      :COM:W :000:024:[43,44,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
012:0:M80     :COM:W :000:128:[45,46,47,48,49,50,51,52,0,0,0,0,0,0,0,0]
013:0:M80     :COM:W :001:029:[53,54,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
014:0:MAC     :COM:W :000:092:[55,56,57,58,59,60,0,0,0,0,0,0,0,0,0,0]
015:0:NSWP    :COM:W :000:088:[61,62,63,64,65,66,0,0,0,0,0,0,0,0,0,0]
016:0:PIP     :COM:W :000:058:[67,68,69,70,0,0,0,0,0,0,0,0,0,0,0,0]
017:0:R       :COM:W :000:032:[71,72,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
018:0:STAT    :COM:W :000:042:[73,74,75,0,0,0,0,0,0,0,0,0,0,0,0,0]
019:0:TEST    :COM:W :000:001:[76,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
020:0:W       :COM:W :000:031:[77,78,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
021:0:WM      :COM:W :000:083:[79,80,81,82,83,84,0,0,0,0,0,0,0,0,0,0]
022:0:XDIR    :COM:W :000:086:[85,86,87,88,89,90,0,0,0,0,0,0,0,0,0,0]
FREE ALLOCATIONS:
091 092 093 094 095 096 097 098 099 100 101 102 103 104 105 106
107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122
123 124 125 126 127 128 129 130 131 132 133 134 135 136 137 138
139 140 141 142 143 144 145 146 147 148 149
```
IDX is the order of the extent on disk<br>
U is the user number<br>
AT are the attributes (R - Read only, W - Read/Write, S - System)<br>
EXT is the extent number for the file<br>
REC is the number of records controlled by this extent<br>
ALLOCATIONS is the list of allocations controlled by this extent
