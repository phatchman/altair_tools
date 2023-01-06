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
altairdsk: <disk_image> -[d|r|F]v
altairdsk: <disk_image> -[g|p|e][t|b]v  <src_filename> [dst_filename]
altairdsk: <disk_image> -[G|P][t|b]v    <filename ...>
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
* On windows the option processing is different. The command needs to come before the disk image e.g. altairdsk -g cpm.dsk asm.com
* altairdsk will do it's best to detect whether a binary or text file is being transferred, but you can force that with the -t and -b options.
This is only needed when copying a file from the altair disk.<br>
* If an invalid CP/M filename is supplied, for example ABC.COMMMMMM, it will be converted to a similar valid CP/M filename.

## Examples

### Get a directory listing
./altairdsk -d cpm.dsk<br>
./altairdsk cpm.dsk

### Format a disk
./altairdsk -F new.dsk

### Copy a file from the disk (get)
./altairdsk cpm.dsk -g LADDER.COM

### Copy a file to the disk (put)
./altairdsk cpm.dsk -p LADDER.COM

### Copy multiple files from the disk (get multiple)
This command allows wildcards of * or ?. <br>
./altairdsk cpm.dsk -G load.com dump.com 'asm.*' 'p?p.com'<br>

To get all files from the disk<br>
./altairdsk cpm.dsk -G '*'

### Copy multiple files to the disk image (get multiple)
./altairdsk cpm.dsk -P load.com dump.com asm.com pip.com

### Erase a file
./altairdsk cpm.dsk -E asm.com

