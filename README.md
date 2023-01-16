# Altair Tools 

A collection of utilities for the Altair 8800

* Altairdsk allows the reading and writing of CP/M formatted Altair 8800 floppy disk disk images.

If you are looking for a utility similar to cpmtools, but for the Altair 8800 floppy disk images, then this repository is for you. 
It has been tested under Windows and Linux, but would probably work on MacOS as well.

altairdsk allows you to:
  1. Perform a directory listing
  2. Copy files to and from the disk
  3. Erase files
  4. Format an existing disk or create a newly formatted disk.
  5. Create bootable CP/M disk images

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

For windows you can get the pre-compiled binary from the windows directory<br>
For linux and other unix-ish platforms:
```
% cmake .
% make
```
There is no install target provided. So copy the executable to your desired install location if you need.

## Command Line
```
altairdsk: -[d|r|F]v  [-T <type>] [-u <user>] <disk_image>
altairdsk: -[g|p|e][t|b]v [-T <type>] [-u <user>] <disk_image> <src_filename> [dst_filename]
altairdsk: -[G|P|E][t|b]v [-T <type>] [-u <user>] <disk_image> <filename ...>
altairdsk: -[x|s]v        [-T <type>] <disk_image> <system_image>
altairdsk: -h
        -d      Directory listing (default)
        -r      Raw directory listing
        -F      Format existing or create new disk image. Defaults to FDD_8IN
        -g      Get - Copy file from Altair disk image to host
        -G      Get Multiple - Copy multiple files from Altair disk image to host
                               wildcards * and ? are supported e.g '*.COM'
        -P      Put Multiple - Copy multiple files from host to Altair disk image
        -e      Erase a file
        -E      Erase multiple files - wildcards supported
        -t      Put/Get a file in text mode
        -b      Put/Get a file in binary mode
        -u      User - Restrict operation to CP/M user
        -x      Extract CP/M system (from a bootable disk image) to a file
        -s      Write saved CP/M system image to disk image (make disk bootable)
        -T      Disk image type. Auto-detected if possible. Supported types are:
                        * FDD_8IN - MITS 8" Floppy Disk (Default)
                        * HDD_5MB - MITS 5MB Hard Disk
                        * HDD_5MB_1024 - MITS 5MB, with 1024 directories (!!!)
                        * FDD_TAR - Tarbell Floppy Disk
                        * FDD_1.5MB - FDC+ 1.5MB Floppy Disk
                        * FDD_8IN_8MB - FDC+ 8MB "Floppy" Disk
        -v      Verbose - Prints image type and sector read/write information
        -h      Help

!!! The HDD_5MB_1024 type cannot be auto-detected. Always use -T with this format,
otherwise your disk image will auto-detect as the standard 5MB type and could be corrupted.
```

## Some things to note:
* The 5MB HDD images that come with the Altair-Duino have an invalid directory table. If you do a directory listing on these images, you will see some strange directory entries. See the examples below for details on how to create new, valid disk images with this utility.
* On linux you have the option of putting the disk image before the options. For example: altairdsk cpm.dsk -g ASM.COM. I find this syntax more convenient.
* altairdsk will do it's best to detect whether a binary or text file is being transferred, but you can force that with the -t and -b options.
This is only needed when copying a file from the altair disk.<br>
* If an invalid CP/M filename is supplied, for example ABC.COMMMMMM, it will be converted to a similar valid CP/M filename; ABC.COM in this example.
* Wildcards don't work the same as on CP/M. ./altairdsk xxx.dsk -G '\*' will match everything, including the extension, and get all files. On CP/M you would use '\*.\*'. You can still use '\*.TXT' and 'ABC.\*' and that will work as expected.
* As mentioned in the usage, if using the HDD_5MB_1024 format with 1024 directory entries, make sure you always use the -T option.

## Examples

### Get a directory listing
`./altairdsk -d cpm.dsk`<br>
`./altairdsk cpm.dsk`<br>
Restrict the directory listing to a particular user with the -u option<br>
`./altairdsk -u0 cpm.dsk`

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
Length is length of the file to nearest 128k sector<br>
Used is the amount of space actually used on the disk (in multiples of 1 block)<br>
U is the user number<br>
At is the file attributes. R - Read only, W - Read/write. S - System

### Format a disk
`./altairdsk -F new.dsk`<br>
To format for a specific type<br>
`./altairdsk -F -T HDD_5MB new.dsk`

Or on linux/unix you can put options in any order<br>
`./altairdsk new.dsk -FT HDD_5MB`<br>
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
`./altairdsk -Pu1 cpm.dsk *.com`

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
The CP/M HDSK03.DSK and HDSK04.DSK images that come with the Altair Duino have some directory entry corruption. You can fix this by creating a new image with a copy of the files. Example below.<br>
Note that you will receive the error message below multiple times during this operation. The error is caused by the invalid directory entries and are expected.
_Invalid allocation number found in directory table.
Possible incorrect image type. Use -v to check image type detected or selected._<br>

Create a new directory named _files_ below where you keep the HDSK03.DSK<br>
`mkdir files`<br>
Create a new disk image<br>
`altairdsk -FT HDD_5MB HDSK03_NEW.DSK`<br>
Copy the CP/M system tracks<br>
`altairdsk -x HDSK03.DSK hdsk_cpm.bin`<br>
`altairdsk -s HDSK03_NEW.DSK hdsk_cpm.bin`<br>
Copy the files from user 0. The directory entries for user 0 are all valid.<br>
`cd files`<br>
`altairdsk ../HDSK03.DSK -Gu0 '*'`<br>
`altairdsk ../HDSK03_NEW.DSK -P *`<br>
Note that quotes around '*' are used for the Get, but not on the Put.<br>
You should now have a new bootable image _HDSK03_NEW.DSK_ with all of the files copied.

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
