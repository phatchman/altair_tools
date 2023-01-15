#Format of the Altair 8" floppy images

I've not found any really good documentation on how to read the MITS 8" floppy images and a lot of information had the be reverse-engineered from the CPM source code.

They are an unusual format as the MITS floppy controller hardware was relatively basic, leaving a lot to be done in software.

##Basic Information
Nr Tracks
Sector Size
...

##Sector layout

Information on the sector-layout is below. This is different for tracks 0-5 and 6-77.

###Tracks 0 - 5

| Byte #  | Description   | Notes                                 |
|---------|---------------|---------------------------------------|
| 0       | Track number  | High bit always set                   |
| 1-2     | Unused?       | 0x00 0x01                             |
| 3-130   | Data          | 128 bytes of data                     |
| 131     | Stop byte     | 0xff                                  |
| 132     | Checksum byte | Checksum by summing each byte in Data |
| 133-136 | Zero bytes     | filled with 0x00                      |

## Tracks 6 - 77

| Byte #  | Description   | Notes                                                                |
|---------|---------------|----------------------------------------------------------------------|
| 0       | Track number  | High bit always set                                                  |
| 1       | Sector number | Sector calculated as (sequential sector number * 17) % 32            |
| 2-3     | Unused        |                                                                      |
| 4       | Checksum      | Checksum by summing all bytes in Data as well as bytes 2, 3, 5 and 6 |
| 5-6     | Unused        |                                                                      |
| 7-134   | Data          | 128 bytes of data (Actually 129. What is byte 134 used for?)         |
| 135     | Stop byte     | 0xff                                                                 | 
| 136     | Zero byte     | 0x00                                                                 |

## Sector skew table
The following skew table is used in CPM. It is used to translate the logical sector into a physical 
disk sector. <br>
For tracks 0-5 the skew table translates the sector directly.<br>
For tracks 6-77, the sector is translated as (skew_table[logical_sector] - 1) * 17) % 32) + 1

```
	01 09 17 25 03 11 19 27 05 13 21 29 07 15 23 31
	02 10 18 26 04 12 20 28 06 14 22 30 08 16 24 32
```