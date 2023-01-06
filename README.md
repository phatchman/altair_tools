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

## Examples

### Get a directory listing
`./altairdsk cpm.dsk -d`<br>
`./altairdsk cpm.dsk`

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

