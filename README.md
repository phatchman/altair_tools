# Altair Tools 

A collection of utilities for the Altair 8800

* Altairdsk allows the reading and writing of CP/M formatted Altair 8800 floppy disk disk images.

If you are looking for a utility similar to cpmtools, but for the Altair 8800 floppy disk images, then this repository is for you. 
It has been tested under Windows and Linux, but would probably work on MacOS as well.

altairdks allows you to:
  1. Perform a directory listing
  2. Copy files to and from the disk
  3. Erase files
  4. Format and existing disk or create a newly formatted disk.

PLEASE make sure you make a backup of any disk images before writing to them with this utility.

## Command Line
```
altairdsk: -[d|r|F]v       <disk_image> 
altairdsk: -[g|p|e][t|b]v  <disk_image> <src_filename> [dst_filename]
altairdsk: -[G|P][t|b]v    <disk_image> <filename ...>
altairdsk: -h
        -d      Directory listing (default)
        -r      Raw directory listing    
        -F      Format existing or create new disk image
        -g      Get - Copy file from Altair disk image to host
        -p      Put - Copy file from host to Altair disk image
        -G      Get Multiple - Copy multiple files from Altair disk image to host
                               wildcards * and ? are supported e.g '*.COM'                            
        -P      Put Multiple - Copy multiple files from host to Altair disk image
        -e      Erase a file
        -t      Put/Get a file in text mode
        -b      Put/Get a file in binary mode
        -v      Verbose - Prints sector read/write information
        -h      Help
```
        
## Some things to note:
* On linux you have the option of putting the disk image before the option. For example: altairdsk cpm.dsk -g ASM.COM. I find this more convenient.
* altairdsk will do it's best to detect whether a binary or text file is being transferred, but you can force that with the -t and -b options.
This is only needed when copying a file from the altair disk.<br>
* If an invalid CP/M filename is supplied, for example ABC.COMMMMMM, it will be converted to a similar valid CP/M filename; ABC.COM in this example.
* Wildcards don't work the same as on CP/M. ./altairdsk xxx.dsk -G '\*' will match everything, including the extension, and get all files. On CP/M you would use '*.*'. You can still use '*.TXT' and 'ABC.*' and that will work as expected.

## Examples

### Get a directory listing
`./altairdsk cpm.dsk -d`<br>
`./altairdsk cpm.dsk`
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
Used is the amount of space actually used on the disk (in 2K blocks)<br>
U is the user number<br>
At is the file attributes. R - Read only, W - Read/write. S - System

### Format a disk
`./altairdsk new.dsk -F`

### Copy a file from the disk (get)
`./altairdsk cpm.dsk -g LADDER.COM`

### Copy a file to the disk (put)
`./altairdsk -p cpm.dsk LADDER.COM`

### Copy multiple files from the disk (get multiple)
This command allows wildcards of * or ?. Note on Windows you shouldn't use the quotes around the wildcarded filenames. They are only needed on linux/unix.<br>
`./altairdsk -G cpm.dsk load.com dump.com 'asm.*' 'p?p.com'`

To get all files from the disk<br>
`./altairdsk -G cpm.dsk '*'`

### Copy multiple files to the disk image (get multiple)
`./altairdsk -P cpm.dsk load.com dump.com asm.com pip.com`

### Erase a file
`./altairdsk -E cpm.dsk asm.com`

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
