;==============================================================
;          Copy/Repair Utility for Altair diskettes
;
; Supports both 88-DCDD 8" diskettes and 5.25" 88-MDS minidisks
; Runs under CP/M, but copies Altair Basic & DOS disks too
;==============================================================
;                           USAGE
;
; ACOPY <d>:=<s>: [/R] [/N] [/S] [/P]
;   <d> is the destination drive number and <s> is the source
;       drive number. <s> adn <d> are A-D for floppy disk
;       CP/M and C-F for hard disk CP/M.
;   /N copies only the actual non-system tracks
;   /R Repairs the diskette by rewriting all metadata
;   /P removes multiuser Basic directory passwords
;   /S copies only the actual system tracks
;==============================================================
;                       DESCRIPTION
; ACOPY copies an Altair diskette several tracks at a time, and
; (when no options are specified) does not check track data for
; validity.
;
; Each source diskette track is read repeatedly until two
; successive reads of the track are identical, or until the
; maximum number of retries has been reached. Subsequent tracks
; are read in the same manner until all available RAM is filled
; with track data.
;
; The tracks in the buffer are each then written to the
; destination diskette, and then read back and compared. This
; is repeated for each track until the read-back matches the
; written data, or until the maximum number of retries has been
; reached.
;
; This process is repeated until the entire diskette has been
; copied.
;
; An error message is printed on the Console whenever a track
; read or write is retried, and when the maximum number of
; retries was reached. When finished, the total number of
; unrecovered read and write failures is reported.
;
; The /R option causes much of the sector metadata (track
; numbers, sector numbers, Stop Bytes, and checksums) to be
; checked and repaired, before the track data is written to the
; destination diskette. A count and a log of the sectors that
; required repair is kept and reported when the copy is done.
;
; The /S option causes only the system tracks to be copied;
; the /N option causes only the non-system tracks to be copied.
; These commands refer to the actual use of the tracks, not how
; they are formatted: ACOPY figures out whether an 8" diskette
; is a CP/M diskette (with ony 2 actual system tracks) or not,
; by looking for the Digital Research copyright message in the
; first track on the disk. Acopy figures out how many system
; tracks exist on a minidisk by looking for valid sector
; numbers in the minidisk sector metadata.
;
; The /R, /N, and /S options are compatible with Altair Basic
; & DOS diskettes, as well as with Burcon and Mike Douglas CP/M
; diskettes. The /P option is compatible with Altair Basic &
; DOS diskettes only.
;==============================================================
;                      SYSTEM REQUIREMENTS
; 1) Written to assemble with Digital Research's ASM.
; 2) Requires MITS floppy disk controllers - either the
;    88-DCDD 8" disk controller or the 88-MDS minidisk
;    controller. The disk controller must be addressed at the
;    standard Altair disk controller address = 08H through 0Ah.
; 3) Only floppy drive numbers 0 through 3 are supported.
; 4) Runs on Floppy Disk CP/M (where floppy drives are disks
;    A: through D:) and on Hard Disk CP/M (where floppy drives
;    are disks C: through F:)
; 5) Uses all available RAM, including RAM used by CP/M's CCP
;    and BDOS, for buffering tracks, and requires all RAM to be
;    zero wait-state memory when copying 8" diskettes.
; 6) The minimum RAM required to copy an 8" diskette is 9.75K
;    plus the size of CP/M's BIOS. The minimum required to copy
;    a minidisk is 4.75K plus the size of the BIOS.
; 7) Messages display correctly on screens as small as 16X64.
;==============================================================
;                       REVISION HISTORY
;  1.00  22 June 2014  M. Eberhard
;     Created
;  1.01  13 July 2014  M. Eberhard
;     Don't stall after stepping- wait for MVHEAD bit before
;     changing disks. Detect system tracks for /S and /N on a
;     minidisk. change to CP/M-style drive letters. Mask ints.
;  1.02  15 July 2014  M. Eberhard
;     No "Insert CP/M disk" message if hard disk. Remove debug
;     code. Arrange subroutines in logical order.
;  1.03 16 July 2014  M. Eberhard
;     Support single-disk copies. Overwrite BDOS too.
;  1.04 17 July 2014  M. Eberhard
;     fix error-counting bug
;  1.05 18 July 2014  M. Eberhard
;     Automatically determine if an 8" disk is a CP/M disk. No
;     retries when reading minidisk track to determine if it is
;     a system track. Reorganize for INIT's temp track buffer.
;     Enhance comments.
;  1.06  5 August 2014 M. Eberhard
;     Check minidisk track 0 to determine if it is a CP/M disk.
;     Look for system tracks on the destination disk (rather
;     than on the source disk) if /N option. Log physical
;     sector numbers (rather than skewed sector numbers) for /R
;     errors. Tighten code.
;  1.07  11 December 2014  M. Eberhard
;     Bug fix
;  1.08  8 July 2015  M. Eberhard
;     Bug fix: reload head after calling CONIN. (The BIOS
;     unloads it.)
;
; To Do (maybe)
;   Allow user to specify tracks to copy
;   Repair broken directory & links
;   Don't let pacifier dots print past column 64
;==============================================================
;                       DISK FORMATS
;---------------------------
; Altair 8" Diskette Format
;---------------------------
;  Raw Bytes/sector: 137
;     Sectors/Track: 32, numbered 0-31
;   Tracks/Diskette: 77, numbered 0-76
;
; Tracks 0-5 are formatted as "System Tracks" (regardless of
; how they are actually used). Sectors on these tracks are
; formmatted as follows:
;
;     Byte    Value
;      0      Track number and 80h
;     1-2     Number of bytes in boot file
;    3-130    Data
;     131     0FFh (Stop Byte)
;     132     Checksum of 3-130
;    133-136  Not used
;
; Tracks 6-76 (except track 70) are "Data Tracks." Sectors
; on these tracks are formatted as follows:
;
;  Byte    Value
;     0      Track number and 80h
;     1      Skewed sector = (Sector number * 17) MOD 32
;     2      File number in directory
;     3      Data byte count
;     4      Checksum of 2-3 & 5-134
;    5-6     Pointer to next data group
;   7-134    Data
;    135     0FFh (Stop Byte)
;    136     Not used
;
; Track 70 is the Altair Basic/DOS directory track. It is
; formatted the same as the Data Tracks, except that each Data
; field is divided into 8 16-byte directory entries. The last 5
; of these 16 bytes are written as 0 by most versions of Altair
; Basic and DOS, but are used as a password by Multiuser Basic,
; where five 0's means "no password". Unfortunately, single-
; user Basic does not always clear these bytes. If these bytes
; are not all 0 For a given directory entry, then multiuser
; Basic will not be able to access the file. /P fixes this. The
; first directory entry that has FFh as its first byte is the
; end-of-directory marker. (This FFh is called "the directory
; stopper byte.")
;
;------------------------
; Altair Minidisk Format
;------------------------
;  Raw Bytes/sector: 137
;     Sectors/Track: 16, numbered 0-15
;   Tracks/Diskette: 35, numbered 0-34
;
; On a bootable Altair Basic minidisk, tracks 0-11 are System
; Tracks. On a CP/M minidisk, tracks 0-5 are System tracks.
; Sectors on these tracks are formatted the same as system
; tracks on an 8" diskette.
;
; The remaining tracks of a bootable minidisk, and on all
; tracks of a non-bootable data minidisk are formatted the
; same as sectors on Data Tracks on an 8" diskette, except
; that the sectors are not skewed.
;
; Track 34 is the Altair Minidisk Basic directory Track.
; Sectors on this track are formatted the same as the Directory
; Track on an 8" diskette.
;==============================================================
FALSE	equ	0
TRUE	equ	not FALSE

;******************
; ASCII Characters
;******************
CTRLC	equ	3	;Control-C for user-abort
LF	equ	0AH	;Linefeed
CR	equ	0DH	;Carriage return
QUOTE	equ	27h	;single quote

;*******************************
; Assembly Switches & variables
;*******************************
PACIFY	equ	TRUE	;enables printing of pacifiers
WPAC	equ	'.'	;printed whenever a track is written
RPAC	equ	'.'	;printed whenever a track is read,
			;..only in single-disk mode

RETRYS	equ	16	;max retries per track read & write
MAXDRV	equ	3	;drives 0-3 supported

ABTCHR	equ	CTRLC	;Console abort character

;---------------------
; Diskette Parameters
;---------------------
SECSIZ	equ	137	;Total bytes/sector

DTSECT	equ	1	;Logical sector number in Sys tracks
STDATA	equ	3	;System track sector data start
STCKSM	equ	132	;checksum byte, System tracks

DTCKSM	equ	4	;checksum byte, data tracks
DTDATA	equ	7	;Data track sector data start

SSTOPR	equ	0FFh	;sector data stop byte value
DSTOPR	equ	0FFh	;directory "stopper" value

; 8" diskette parameters

SPT8	equ	32	;8" diskette sectors/track
MAXTK8	equ	76	;8" diskette max track number
NSTK8	equ	6	;# of system tracks for 8" disk
BDTK8	equ	70	;Basic Directory Track, 8"
LCTRAK	equ	43	;low write current starting at this trk
CPMS8	equ	2	;number of tracks used by 8" CP/M boot

; Minidisk parameters

SPT5	equ	16	;Minidisk sectors/track
MAXTK5	equ	34	;minidisk max track number
BDTK5	equ	34	;Basic Directory Track, minidisk
CPMS5	equ	4	;number of minidisk CP/M system tracks

;---------------------------------------------------------
; Altair 8800 Disk Controller Equates (These are the same
; for the 88-DCDD controller and the 88-MDS controller.)
;---------------------------------------------------------
DENABL	equ	08H	;Drive Enable output
DDISBL	  equ	  0FFh	  ;disable disk controller

DSTAT	equ	08H	;Status input (active low)
ENWDAT	  equ	  01H	  ;-Enter Write Data
MVHEAD	  equ	  02H	  ;-Move Head OK
HDSTAT	  equ	  04H	  ;-Head Status
DRVRDY	  equ	  08H	  ;-Drive Ready
INTSTA	  equ	  20H	  ;-Interrupts Enabled
TRACK0	  equ	  40H	  ;-Track 0 detected
NRDA	  equ	  80H	  ;-New Read Data Available

DCTRL	equ	09H	  ;Drive Control output
STEPIN	  equ	  01H	  ;Step-In
STPOUT	  equ	  02H	  ;Step-Out
HDLOAD	  equ	  04H	  ;8" diskette: load head
			  ;Mini: restart 6.4 S timer
HDUNLD	  equ	  08h	  ;unload head (8" only)
IENABL	  equ	  10H	  ;Enable sector interrupt
IDSABL	  equ	  20H	  ;Disable interrupts
HCS	  equ	  40h	  ;Head Current Switch
			  ;..set for tracks>42
WENABL	  equ	  80H	  ;Enable drive write circuits

DSECTR	equ	09H	;Sector Position input
SVALID	  equ	  01h	  ;Sector Valid (1st 30 uS
			  ;..of sector pulse)
SECMSK	  equ	  3Eh	  ;Sector mask for MDSEC

DDATA	equ	0AH	;Disk Data (input/output)

;**************
; CP/M Equates
;**************
;--------------------------------------------
; CP/M Entry Points and low-memory locations
;--------------------------------------------
WBOOT	equ	0000H		;Jump to BIOS Warm Boot code
WBOOTA	equ	WBOOT+1		;Address of Warm Boot code

COMBUF	equ	WBOOT+80H	;command line buffer
USAREA	equ	WBOOT+100H	;User program area

;----------------------------------------------------------
; BIOS Entry Points, relative to the base address in WBOOT
;----------------------------------------------------------
CONST	equ	06h	;Console Status
CONIN	equ	09h	;Console Input
CONOUT	equ	0Ch	;Console output
SELDSK	equ	1Bh	;Select Disk. Returns hl=DPH address

;==============================================================
; Start of code
;==============================================================
	org	USAREA

;------------------------------------------------------
; Initialize, using code that gets wiped out by TRKBUF
;------------------------------------------------------
	lxi	SP,STACK	;create local stack
	call	INIT

;===Main Loop=================================================
; Copy/Repair all required tracks from the source disk to the
; destination disk, as specified during INIT
; On Entry:
;   e = 0 (meaning we start on track 0)
;   NOSYS = 1 if /N option (do only non-system tracks)
;   DOSYS = 1 if /S option (do only system tracks)
;   DOFIX = 1 if /R option (repair sector metadata)
;   SRCDSK = the source drive, which is selected,
;            and its head is on track 0 and loaded
;   DSTDSK = the destination drive, which is on track 0
;   MAXTRK = ending track number
;   BDTRAC = directory track for removing passwords, if /P
;           = FFh if no /P option
;   NSTRKS = CPMS8 if /N or /S on an 8" CP/M disk
;          = NSTK8 for any other 8" disk
;          = CPMS5 if /N or /S on a CP/M minidisk
;          = 0FFh for any other minidisk
;   TBMAX = high byte of the first address past the
;           end of the track buffer
;=============================================================
	lda	NOSYS		;/N option specifed?
	ora	a
	cnz	SKPSYS		;y: skip system tracks

COPLUP:	mvi	a,TRKBUF/256	;start with 1st buffer
	sta	TBCUR

	push	d		;save e=starting track number
				;..for the write loop

;---Read Loop-------------------------------------------------
; Read/verify/Repair as many tracks from the source disk
; as will fit in the track buffer.
;   e = current track
;   SRCDSK = the source drive, which is selected
;   MAXTRK = ending track number
;   BDTRAC = directory track for removing passwords
;          = FF if we shouldn't remove passwords
;   DOFIX = 1 to repair sector metadata
;   DOSYS = 1 to copy only the system tracks
;   NSTRKS = NSTK8 for 8" non-CP/M disk
;          = CPMS8 if /N or /S on an 8" CP/M disk
;          = CPMS5 if /N or /S on a CP/M minidisk
;          = 0FFh for any other minidisk
;   TBCUR = high byte of current track buffer address
;   TBMAX = High byte of the first address past the end of
;           the track buffer
;-------------------------------------------------------------
RDLOOP:	call	RVTRAC		;read & verify one track

; If /S and this is a data track, then flush the buffer
; (if needed), and quit.

	lda	DOSYS		;/S option specified?
	ora	a		;(clears carry too)
	cnz	CHKSYS		;y: sets carry if data track
				;..returns w/ hl=NSTRKS
	jnc	RDL1

; Found a data track during /S, so we are done reading.
; See if we need to flush any system tracks from the buffer.

	dcx	h		;point to STRACS
	mov	m,e		;remember for COPDON report

	mov	a,e
	pop	d		;recover starting track
	cmp	e		;any new sys tracks this pass?
	jz	COPDON		;n: all done, so exit

	mov	c,a		;current track, so GODST
				;..(within WRBUF) can back up
	dcx	h		;point to MAXTRK
	dcr	a		;don't write this data track
	mov	m,a		;set max for write loop
	jmp	WRBUF		;go write the last sys tracks
RDL1:

; Print pacifier only if single-disk mode

 if PACIFY
	call	TSINGL		;Z if single-drive mode
	mvi	a,RPAC		;read-track pacifier
	cz	PRINTA
 endif

; Step the source disk in, if there are more tracks
; e = current track
; MAXTRK = ending track number

	call	NEXTRK
	push	psw		;Z=done with all tracks

; Remove directory passwords if /P
; Note that BDTRAC = FFh if no /P option

	lda	BDTRAC		;basic directory track
	cmp	e		;are we on the dir track?
	cz	PWORDS		;y:go remove passwords

; Repair track metadata if /R

	lda	DOFIX		;should we fix this diskette?
	ora	a
	cnz	FIXTRK		;y:go fix this track

; Read another track, if there are more available track buffers

	pop	psw		;recover Z=done with all tracks
	cnz	NEXTTB		;next track buffer, next track
	jnz	RDLOOP		;Keep reading if still room

	mov	c,e		;c=track where the head is
	pop	d		;recover e=starting track #

;---Flush Track Buffer---------------------------------------
; Set up to Write/verify all tracks in the buffer to the
; destination disk
;   c = head position of the source disk
;   e = starting track for writing to the destination disk
;   SRCDSK = the source drive, which is still selected
;   DSTDSK = the destination drive
;   MAXTRK = ending track number for disk
;   TBMAX = High byte of the first address past the end of
;           the track buffer
;------------------------------------------------------------
WRBUF:	call	GODST		;switch to destination disk

; Loop to write all tracks in the buffer to the dest disk

;---Write Loop-------------------------------------------------
; Write/verify all tracks in the buffer to the destination
; disk. Exit program if e reaches MAXTRK.
;   e = current track
;   DSTDSK = the destination drive, which is selected
;   MAXTRK = ending track number for disk
;   TBMAX = High byte of the first address past the end of
;           the track buffer
;--------------------------------------------------------------
	mvi	a,TRKBUF/256	;start with 1st buffer
	sta	TBCUR

WRLOOP:	call	WVTRAC		;write & verify one track

 if PACIFY
	call	ILPRNT
	db	WPAC+80h	;pacifier
 endif

	call	NEXTRK		;destination step-in if we can
	jz	COPDON		;z: all done copying, so exit

	call	NEXTTB		;next track buffer, inr e
	jnz	WRLOOP		;keep writing if still more

;---Main Loop End--------------------------------------------
; The track buffer is flushed. Either ask the user to switch
; disks, and then back up the head (single-drive mode), or
; select the source drive (2-drive mode). Then do another
; pass through the main loop.
;   SRCDSK = source disk
;   DSTDSK = the destination drive, which is still selected
;------------------------------------------------------------
	call	GOSRC		;switch to source disk
	jmp	COPLUP		;go read more

;===Subroutine================================
; Read current track with verify and retries.
; On Entry:
;   TBCUR = high address of buffer start
; Trashes a,bc,d,hl
;=============================================
RVTRAC:	mvi	d,RETRYS+1

RRETRY:	call	RTRACK		;read a track
	call	VTRACK
	rz

	call	RETELL		;report retry, abort
				;..if too many retries
	jnz	RRETRY		;try again, unless too many
	ret			;give up on track

;===Subroutine================================
; Write current track with verify and retries
; On Entry:
;   TBCUR = high address of buffer start
;   e = track number
; Trashes a,bc,d,hl
;=============================================
WVTRAC:	mvi	d,RETRYS+1

WRETRY:	call	WTRACK		;write the track
	call	FNDSEC		;(29)must skip one sector
				;..for the end of trim-erase

	call	VTRACK		;(17)
	rz			;done if no error

	call	VETELL		;report retry, abort
				;..if too many retries
	jnz	WRETRY		;try again, unless too many
	ret			;give up on track

;===Subroutine===============================================
; Read all SPT sectors of the current track into the current
; track slot in the track buffer, starting with the first
; encountered sector. Use the physical sector number to
; write each sector into its appropriate sector slot in the
; buffer. Each sector is positioned in the buffer such that
; its last address is xxFFh.
; On Entry:
;   TBCUR = high address of buffer start
;   SPT = sectors per track for this drive
; Trashes a,c,hl
;============================================================

; Loop to read all SPT sectors from the disk

RTRACK:	lda	SPT		;sectors per track
	mov	c,a		;c counts sectors

TRLUP:	call	FNDSEC		;Find the next sector

; NRDA becomes true 140 uS after -SVALID becomes true, and
; occurs every 32 uS thereafter.  This loop takes 28 uS.

DRLUP:	in	DSTAT		;(10)Read the drive status
	rlc			;(4)New Read Data Available?
	jc	DRLUP		;(10)no: wait for data

	in	DDATA		;(10)Read data byte
	mov	m,a		;(7)Store it in sector buffer
	inr	l		;(5)Move to next buffer address
				;..and test for end
	jnz	DRLUP		;(10)Loop if more data

; Next sector, until all SPT sectors have been read

	dcr	c
	jnz	TRLUP

	ret

;===Subroutine================================================
; Write all SPT sectors to the current track from the current
; track slot in the track buffer, starting with the first
; encountered sector. Use the physical sector number to
; read each sector from its appropriate sector slot in the
; buffer. Each sector is positioned in the buffer such that
; its last address is xxFFh.
; On Entry:
;   e = track number
;   TBCUR=high address of buffer start
; Trashes a,bc,hl
;=============================================================

; Create write command, with reduced write current if needed

WTRACK:	mvi	b,WENABL	;compute correct write enable
	mov	a,e		;track number
	cpi	LCTRAK		;below track 43?
	jc	HICRNT		;y: high write current
	mvi	b,WENABL+HCS	;n: low current
HICRNT:

; Loop to write SPT sectors to the disk

	lda	SPT		;sectors per track
	mov	c,a		;c counts sectors

TWLUP:	call	FNDSEC		; Find the next sector

; ENWDAT becomes true 280 uS after -SVALID becomes true, and
; occurs every 32 uS thereafter. This loop takes 28 uS. 

	mov	a,b		;initiate write ASAP
	out	DCTRL		;with HCS set appropriately	

DWLUP:	in	DSTAT		;(10)Read the drive status
	rrc			;(4)test ENWDAT ready to write?
	jc	DWLUP		;(10)no: wait

	mov	a,m		;(7)write data
	out	DDATA		;(10)
	inr	l		;(5)Move to next buffer address
				;..and test for end
	jnz	DWLUP		;(10)Loop if more data

; Write the final 0 to end the write

DWLUP2:	in	DSTAT		;(10)Read the drive status
	rrc			;(4)ready to write?
	jc	DWLUP2		;(10)no: wait

	xra	a		;(4)write 0
	out	DDATA		;(10)Read data byte

; Next sector, until all SPT sectors are written

	dcr	c
	jnz	TWLUP

	ret

;===Subroutine==============================================
; Verify all SPT sectors of the current track by comparing
; the disk data to the data in the current track slot in
; the track buffer, starting with the first encountered
; sector. Use the physical sector number to find each
; sector's  slot in the buffer. Each sector is positioned
; in the buffer such that its last address is xxFFh.
; On Entry:
;  TBCUR=high address of buffer start
; On Exit:
;  Z set if track matches
;  Z clear if any mismatch
; Trashes a,c,hl
;===========================================================

; Loop to verify all SPT sectors on the current track

VTRACK:	lda	SPT		;(7)sectors per track
	mov	c,a		;(4)c counts sectors

TCLUP:	call	FNDSEC		;(17)find the next sector

; NRDA becomes true 140 uS after -SVALID becomes true, and
; occurs every 32 uS thereafter. This loop takes 30.5 uS.

DCLUP:	in	DSTAT		;(10)Read the drive status
	rlc			;(4)New Read Data Available?
	jc	DCLUP		;(10)no: wait for data

	in	DDATA		;(10)Read data byte
	cmp	m		;(7)Store it in sector buffer
	rnz			;(5)fail: ret with Z cleared
	
	inr	l		;(5)Move to next buffer address
	jnz	DCLUP		;(10)Loop if more data

; Next sector, until all SPT sectors have been verified.
 
	dcr	c		;next sector
	jnz	TCLUP		;until all sectors are verified

	ret			;success: ret with Z set

;===Subroutine======================================
; Find the next sector on the disk
; On Entry:
;  TBCUR = high address of current track buffer
; On Exit:
;  hl = buffer address for the sector we found
;     = buffer base address + (256 x sector number)
;  The sector is ready to read immediately
;===================================================
FNDSEC:	lhld	TBCUR-1		;h=current track buffer start
	mvi	l,(256-SECSIZ)	;page-aligned sector start

; -SVALID goes low for 30 uS.

WVALID:	in	DSECTR		;(10)Read the sector position
	rrc			;(4)put -SVALID in carry
	jc	WVALID		;(10)wait for sec to be valid

	ani	SECMSK/2	;(7)Mask sector bits
	add	h		;(4)point into sector buffer
	mov	h,a		;(4)hl=this sector start
	ret			;(10)

;===Subroutine==========================================
; Check sector metadata for all sectors from this track
; (which are in the track buffer), and repair as needed.
; Log every sector that had to be repaired, if room in
; the error buffer. For each sector, this checks/fixes:
;  Track number (byte 0)
;  Sector number (Byte 1 for data tracks only)
;  Stop Byte (1st byte after the data field)
;  Checksum (at STCKSM or DTCKSM)
; This also clears the (unused) last byte (byte 137)
;   of every sector, to make Burcon CP/M happy.
; On Entry:
;   e = track number
;   BSCNT = count of sector errors already in BSLIST
; Trashes a,bc,d,hl
;=======================================================

; Set up to check/fix either a system track or a data track

FIXTRK:	lxi	b,((256-SECSIZ)+STDATA)*256+(256-SECSIZ)+STCKSM

	call	CHKSYS		;is this a system track?
	jnc	FIXST		;y: b & c are correct

	lxi	b,((256-SECSIZ)+DTDATA)*256+(256-SECSIZ)+DTCKSM
FIXST:

	lhld	TBCUR-1		;h=TBCUR, start of buffer
	mvi	d,0		;init sector number

; Loop to fix every sector on this track
; b = low starting buffer address for sector data
; c = low buffer address for checksum
; d = physical sector number
; e = current track
; h = high address of current sector in the track buffer

FIXSEC:	push	d		;track & sector numbers

	mov	a,e		;correct track number
	ori	80h		;..with sync bit

	mvi	e,0		;e is error flag in this loop

; Burcon CP/M (oddly) expects the "unused" byte at the end of
; every Data-track sector to be 0. Set the last  byte of every
; sector to 0, without logging non-zero bytes here as errors.

	mvi	l,0FFh		;last sector byte location
	mov	m,e		;e=0

; Check track number in byte 0. Fix, remember error if
; necessary. (a=track number with msb set)

	mvi	l,(256-SECSIZ)	;track number goes here
	call	CHKFIX		;check byte, fix if needed

; If system track, then skip checking the sector number

	mov	a,c		;system track?
	sui	(256-SECSIZ)+STCKSM
	jz	FS1		;y: skip sector # check, a=0

; Compute skewed sector number, trashing d along the way
; Skewed sector = (Sector * 17) mod SPT. (Note that this
; produces non-skewed sectors for minidisks.)

	mov	a,d		;physical sector number
	add	a		;*2
	add	a		;*4
	add	a		;*8
	add	a		;*16
	add	d		;*17
	mov	d,a		;temp save

	lda	SPT
	dcr	a		;compute modula mask
	ana	d		;a = (Sector * 17) mod SPT

; Check skewed sector number in buffer byte 1
; Fix and remember error if necessary

	inr	l		;skewed sector number goes here
	call	CHKFIX		;check, fix if needed

; Initiate data-track sector checksum, computing the sum of
; the metadata bytes 2,3,5,& 6, which are to be included in
; the checksum

	inr	l		;initiate data track checksum
	mov	a,m
	inr	l
	add	m
	inr	l		;skip over actual cksum byte
	inr	l
	add	m
	inr	l
	add	m		;a=cksum of metadata

; Compute and check the checksum, and also check the stop byte
; at the end of the data. Fix, and remember error as necessary
; a = checksum so far
; b = low address of sector data
; c = low address of checksum in the buffer
; e = error flag
; h = high address of sector in buffer

FS1:	mov	l,b		;start of data field
	mvi	d,128		;data-field byte count

FSCSLP:	add	m		;compute checksum
	inr	l
	dcr	d
	jnz	FSCSLP

	mov	d,a		;temp save checksum

	mvi	a,SSTOPR	;is the stop byte right?
	call	CHKFIX		;check byte, fix if needed

	mov	a,d		;recover checksum
	mov	l,c		;checksum byte location
	call	CHKFIX		;check byte, fix if needed

; See if we got any errors in this sector, and log it if so

	dcr	e		;Z means error (if e was 1)
	pop	d		;recover track & sector

	push	h		;LOGERR Trashes hl
	cz	LOGERR		;d=sector, e=track
	pop	h

; Next sector, unless done

	inr	d		;next sector
	lda	SPT
	cmp	d		;all sectors done?
	rz			;done with track

	inr	h		;next sector buffer
	jmp	FIXSEC

;---Local Subroutine---------------------------
; Fix a sector byte, set error flag
; On Entry:
;   a = correct value
;  hl = address within sector buffer for value
; On Exit:
;   (hl) = a
;   e = 1 if a did not match (hl)
; Trashes a
;----------------------------------------------
CHKFIX:	cmp	m
	rz			;no error: done

	mov	m,a		; Fix value in buffer
	mvi	e,1		;flag error
	ret

;---Local Subroutine----------------------------
; Log a corrected metadata error
; Note that BSLIST is split. The sector numbers
; are saved in the next page after the page
; where the track numbers are saved.
; On Entry:
;   d = physycal sector number
;   e = track number
;   BSCNT=16-bit error count so far
; On Exit:
;   BSCNT = BSCNT+1
;   d & e stored in BSLIST, if room
; Trashes a,hl
;-----------------------------------------------
LOGERR:	lxi	h,BSCNT		;bad sector count
	mov	a,m
	cpi	MAXBSL		;Room in buffer?
	rz			;n: done

	inr	m		;bump count

	mvi	h,BSLIST/256	;index into list
	mov	l,a

	mov	m,e		;track number into list
	inr	h		;point to sector list
	mov	m,d		;physical sector number

	ret

;===Subroutine==============================================
; Remove Altair directory passwords from the current track,
; which is the directory track. (Set bytes 11-15 of each
; directory entry to 0)
; On Entry:
;   TBCUR = current track buffer
; Trashes a,bc,d,hl
;===========================================================
PWORDS:	lhld	TBCUR-1		;h=TBCUR, start of buffer
	lda	SPT
	mov	d,a		;sector counter

; Clear 8 directory entries on this sector

PWD0:	mvi	c,8		;8 directory entrys per sector

	mvi	l,(256-SECSIZ)+DTDATA+11

PWD1:	mvi	b,5		;5 bytes to write per dir entry

PWD2:	mvi	m,0		;clear the 5 password bytes
	inr	l
	dcr	b
	jnz	PWD2

	mov	a,l		;next directory entry
	adi	11		;skip to password position
	mov	l,a

	dcr	c		;more directory entries in
	jnz	PWD1		;..this sector?

; Recompute and replace this sector's checksum

	mvi	l,(256-SECSIZ)+DTDATA-5
	mvi	b,128+5		;data bytes + metadata
	xra	a		;initial checksum

RCSLUP:	add	m		;compute sector checksum
	inr	l
	dcr	b
	jnz	RCSLUP

	mvi	l,(256-SECSIZ)+DTCKSM
	sub	m		;remove old checksum from sum
	mov	m,a		;write new checksum

	inr	h		;Next sector on dir track
	dcr	d		;all sectors done?
	jnz	PWD0		;n: do another directory sector

	ret

;===Subroutine=================================================
; Determine if this track is a system track or a data track.
; Once we've found a data track, all subsequent tracks will be
; considered to be data tracks. For an 8" disk or a CP/M
; minidisk, all tracks below NSTRKS are system tracks. (NSTRKS
; was set during INIT and possibly modified in SKPSYS.) For a
; non-CP/M minidisk, this subroutine looks to see if the track
; has correct sector numbers in byte 1 of each sector for
; "most" (at least 14) sectors. if not, the track is assumed
; to be a system track.
; On Entry:
;   e = current track
;   NSTRKS = NSTRK8 or CPMS8 for 8" disks
;          = CPMS5 if /N or /S on a CP/M minidisk
;          = 0FFh for other minidisks, until a data track
;            is found
;          = first minidisk data track number, when found
; On Exit:
;   hl = NSTRKS
;   carry set if current track is a data track
;   carry cleared if it is a system track
;   NSTRKS = e if this is the 1st non-CP/M minidisk data track
; Trashes a,d
;==============================================================
CHKSYS:	lxi	h,NSTRKS

; If current track is >= NSTRKS, then this is a data track
; and we are done, and the carry flag set.

	mov	a,m
	dcr	a
	cmp	e		;already found a data track?
	rc			;y: all further tracks are data

; If NSTRKS is a positive number, then this is a system track
; on an 8" disk or a CP/M minidisk, and we are done (with the
; carry flag cleared), since INIT set NSTRKS to 0FFh for non-
; CP/M minidisks.

	rp			;carry is cleared

; We have an unknown track on a non-CP/M minidisk. Loop to
; count (in register d) the number of sectors that contain
; the correct sector number.

	push	h		;save NSTRKS

	lhld	TBCUR-1		;h=TBCUR, start of buffer
	mvi	l,(256-SECSIZ)+DTSECT

	xra	a		;start with sector 0
	mov	d,a		;no errors yet

SCMPLP:	cmp	m		;sector same as diskette?
	jz	SCMP1

	inr	d		;n:bump error count

SCMP1:	inr	a		;next sector
	inr	h		;next sector in buffer too
	cpi	SPT5		;looked at all sectors?
	jnz	SCMPLP		;n: do another sector

	pop	h		;recover NSTRKS

; Assume we have a minidisk data track if the sector number
; in byte 1 (DTSECT) is correct For at least 14 sectors.
; (This allow us to tolerate a damaged diskette.) Assume
; we have another system track otherwise.

	mov	a,d		;how many errors?
	cpi	3		;0-2 errors: it's a data disk
	rnc			;carry not set: system track

	mov	m,e		;we finally got a data track
				;..NSTRKS = # of sys tracks
	ret			;carry is still set for ret

;===Subroutine==========================================
; Compute next track buffer address   
; On Entry:
;   e = current track
;   TBCUR = address high byte of current track buffer
;   TBMAX = address high byte max+1
; On Exit:
;   e = e + 1
;   TBCUR = TBCUR + SPT
;   Z set if TBCUR=TBMAX
; Trashes a,hl
;=======================================================
NEXTTB:	inr	e		;next track, for return

	lda	SPT
	lxi	h,TBCUR
	add	m		;next track
	mov	m,a		;TBCUR:=TBCUR+SPT

	inx	h		;hl=TBMAX
	cmp	m		;buffer full?
	ret

;===Subroutine==============================================
; Step in one track, unless we are on the last track. Give
; the user a chance to abort. This routine does not check
; if stepping is allowed, nor does it wait for the step to
; complete, since it is always followed by a track read or
; write. The hardware will hold off on starting a read or
; write until the stepping has completed, and a track read/
; write takes longer than the minimum step time.
; On Entry:
;  e = current track
; On Exit:
;  Z set if already on last track
;  Z clear, head stepped in in otherwise
; Trashes a
;===========================================================
NEXTRK:	call	CHKABT		;give user a chance to quit

	lda	MAXTRK		;last track?
	cmp	e
	rz			;y: done, Z set

	mvi	a,STEPIN
	out	DCTRL		;n: step in, Z remains clear
	ret

;===Subroutine=================================================
; Skip actual system tracks on both disks
;
; For 8" Altair Basic/DOS disks, there are NSTK8 actual
; system tracks.
;    On entry and exit NSTRKS = NSTK8
;
; For 8" CP/M disks, there are CPMS8 actual system tracks,
; although NSTK8 tracks are formatted as system tracks.
;    On entry, NSTRKS = CPMS8
;    On exit, NSTRKS = NSTK8 (for FIXSYS)
;
; For Altair Basic minidisks, the number of system tracks is
; discovered by CHKSYS, which examines the format of each
; source disk track, looking for the first data track.
;    On entry, NSTRKS = 0FFh
;    On Exit, NSTRKS = the 1st non-system track number
;
; For CP/M minidisks:
;    On Entry and exit, NSTRKS = CPMS5
;
; On Entry:
;   e = current track
; On Exit:
;   e = current track = 1st non-system track
;   STRACS = number of tracks actually skipped
;   NSTRKS = number of tracks formatted as system tracks
;   The source disk head is on the first non-system track.
;   If 2-drive mode (SRC <> DST) then the destination disk
;     head is also on the first non-system track.
;   The source disk is selected
; Trashes a,b,d,hl
;==============================================================

; Loop to skip system tracks on the source disk

SKPSYS:	mvi	a,TRKBUF/256	;use 1st buffer
	sta	TBCUR

	lda	NSTRKS		;non-CP/M minidisk?
	inr	a		;FFh means yes
	cz	RTRACK		;y:read one track, no verify

	call	CHKSYS		;sets carry if data track
				;..on return, hl=NSTRKS
	cnc	SKIPT		;returns w/ no carry
	jnc	SKPSYS

; If this is an 8" CP/M disk then reset NSTRKS, so that it
; will be right for FIXTRK (The first NSTK8 tracks on an 8"
; disk are formatted like system tracks, even when there are
; fewer actual system tracks.)

	mov	a,m		;NSTRKS
	cpi	CPMS8
	jnz	SS1		;n: NSTRKS is ok

	mvi	m,NSTK8		;NSTRKS = number of system-
				;..formatted tracks

SS1:	dcx	h		;hl=STRACS. Remember number of
	mov	m,e		;..system tracks for COPDON

; Done if single-drive mode: the head is on the correct track
; and the source disk is already selected.

	call	TSINGL		;Z if single-drive, hl=DSTDSK
	rz			;y: single-drive mode, so done

; 2-drive mode: skip the same number of tracks on the
; destination disk, and then re-select the source disk.

	xra	a
	cmp	e		;did we actually skip any tracks?
	rz			;n: done

	mov	d,e		;remember number of tracks to skip
	mov	e,a		;start with track a=0

	call	SELECT		;select hl = DSTDSK

SKPDST:	call	SKIPT		;loop to skip dest tracks
	mov	a,e
	cmp	d
	jnz	SKPDST

	dcx	h		;re-select SRCDSK

; Fall into SELECT	

;===Subroutine======================================
; Select drive, when head movement is allowed
; On Entry: 
;   (hl) = drive to select
; On Exit:
;   Carry is clear
;   Z is set
; Trashes a
;===================================================
SELECT:	call	WHEAD		;wait for prior step to complete
				;..ret with Z set, carry clear
	mvi	a,DDISBL	;deselect first, as required
	out	DENABL

; Fall into ISELCT

;===Subroutine======================================
; Select drive immediately
; On Entry:
;   (hl) = drive to select
; Trashes a. Flags unaffected
;===================================================
ISELCT:	mov	a,m		;get specified disk
	out	DENABL		;select disk

;Fall into CHKABT to (mainly) load the head

;===Subroutine===========================
; Test to see if the user wants to abort
; and reload the head
; Trashes a
;========================================
CHKABT:	mvi	a,CONST		;console status
	call	GOBIOS		;via CP/M BIOS
	ora	a		;any chr waiting?
	cnz	GETCON		;y:get & test console chr

	mvi	a,HDLOAD	;Load 8" disk head, or enable
	out	DCTRL		;..minidisk for 6.4 Sec

	ret

;===Subroutine====================================
; Skip a track, and wait for the step to complete
; On Entry:
;   e = current track
; On Exit:
;   a = 0
;   e = e+1
;   carry is clear
;   Z is set
;   current disk is stepped in
;   error-exit if e > MAXTRK
; Trashes a
;=================================================
SKIPT:	call	NEXTRK
	jz	SKPERR

	inr	e		;next track

; Fall into WHEAD

;===Subroutine========================
; Wait for head movement to complete,
; with opportunity for user to abort
; On Exit:
;   a = 0
;   Carry clear
;   Z set
; Trashes a
;=====================================
WHEAD:	call	CHKABT		;user abort?

	in	DSTAT		;wait for step to complete
	ani	MVHEAD		;also clears carry
	jnz	WHEAD		;wait for servo to settle

	ret			;with carry clear

;===Subroutine==============================
;Report write retry
; On Entry:
;   d = remaining retries+1
;   e = track number
; On Exit:
;   d decremented
;   Z flag is cleared to retry the track
;   Z flag is set to give up on this track
; Trashes a,bc,hl
;===========================================
VETELL:	call	CILPRT
	db	'Writ','e'+80h

	jmp	ERTELL		;recycle some code

;===Subroutine=============================
;Report read retry
; On Entry:
;   d = remaining retries+1
;   e = track number
; On Exit:
;   d decremented
;   Z flag is cleared to retry the track
;   Z flag is set to give up on this track
; Trashes a,bc,hl
;===========================================
RETELL:	call	CILPRT
	db	'Rea','d'+80h

; Fall into ERTELL

;===Subroutine End===========================
;Report read or write retry,
; with opportunity for user to abort
; On Entry:
;   d = remaining retries+1
;   e = track number
; On Exit:
;   d decremented
;   Z  cleared to retry the track
;   Z  set to give up on this track
;   minidisk controller has been nudged
; Trashes a,bc,hl
;===========================================
ERTELL:	dcr	d		;too many retries?
	jz	BADTRK
	
	call	ILPRNT
	db	' retry track',' '+80h

	mov	a,e		;track number
	call	PADEC		;trashes bc
	
	call	CHKABT		;user abort?
				;..also reloads the head
	
	ora	d		;Z clear: retry this track
	ret

; Too many retries. Give up on this track.

BADTRK:	call	ILPRNT
	db	' FAI','L'+80h

	lxi	h,HERCNT	;hard error count
	inr	m		;bump error count
	xra	a		;set Z: give up on this track
	ret

;===subroutine==========================================
; Report all sector metadata errors in the error buffer
; On Entry:
;   BSCNT = number of corrected errors, >0
;   MAXBSL = max number of errors stored in buffer
;   BSLIST = list of stored errors
;=======================================================
SERPRT:	call	CILPRT
	db	'/R repairs:',' '+80h

	lda	BSCNT		;how many bad sectors?
	mov	e,a		;save error count
	cpi	MAXBSL

	mvi	a,'>'		;indicate overflow
	cnc	PRINTA		;..if BSLIST is full

	mov	a,e
	call	PADEC		;report number

; Print e track & sector number pairs, 4 to a line

	lxi	h,BSLIST	;the list of bad sectors

PSELUP:	mov	a,l		;error number
	cmp	e		;Printed all saved sectors?
	rz			;y: done
	
	ani	03h		;time for a new line?
	jnz	PSL1

	call	ILPRNT		;y: new line
	db	CR,LF+80h

PSL1:	call	ILPRNT		;track
	db	'  ','T'+80h
	call	PSVAL

	inr	h		;point to sector, in
				;..2nd buffer hole

	call	ILPRNT		;sector
	db	'/','S'+80h
	call	PSVAL

	call	CHKABT		;give user a chance to abort

	dcr	h		;point to 1st buffer hole
	inr	l		;next track number

	mov	a,l
	cpi	MAXBSL		;full buffer?	
	jnz	PSELUP		;n: look for more

; Note overflow, since the buffer is full

	call	ILPRNT
	db	'  =Full','='+80h
	ret

;--- Local subroutine-------------------------------
; Report an error component
; On Entry:
;  hl = address of value (a track or sector number)
; Trashes a,bc
;---------------------------------------------------
PSVAL:	mov	b,m		;get error value
	push	h
				;note: h<>0 here
	call	PBDEC2		;print error value
	pop	h
	ret

;===Subroutine============================
; Ask user to insert the destination disk
; On Entry:
;   hl = DSTDSK
;=========================================
PDSTIN:	call	CILPRT
	db	'Pu','t'+80h

; Fall into DSTIN

;===Subroutine============================
; Ask user to insert the destination disk
; On Entry:
;   hl = DSTDSK
;=========================================
DSTIN:	call	ILPRNT
	db	' destinatio','n'+80h

	jmp	PILETR

;===Subroutine==========================
; Ask user to insert the source disk
; On Entry:
;   hl = SRCDSK
;=======================================
PSRCIN:	call	CILPRT
	db	'Put sourc','e'+80h

; Fall into PILETR

;===subroutine======================================
; Print ' in ', disk letter at (hl) followed by ':'
; On Entry:
;   (HL) = disk number
; Trashes a
;===================================================
PILETR:	call	ILPRNT
	db	' in',' '+80h

; Fall into PDLETR

;===subroutine==============================
; Print disk letter at (hl) followed by ':'
; On Entry:
;   (HL) = disk number
; Trashes a
;===========================================
PDLETR:	lda	DOFFST		;get drive offset
	add	m		;add drive letter
	adi	'A'		;make it a drive letter
	call	PRINTA

	mvi	a,':'
	jmp	PRINTA

;===Subroutine====================
; Report hard-read/write failures
; On Entry:
;   a = error count
; Trashes a,bc,hl
;=================================
HFREP:	mov	b,a		;remember
	call	CILPRT
	db	'Errors:',' '+80h
	mov	a,b

; Fall into PADEC

;===Subroutine=========================
; Print a in decimal on the console
; with leading zeros suppressed
; Trashes a,bc,hl
;======================================
PADEC:	lxi	h,100		;h=0 (suppress leading 0s),
	call	DECDG1		;l=divisor=100 decimal

; Fall into PBDEC2, with h=0 to suppress leading 0s

;===Subroutine============================================
; Print b as 2 decimal digits on the console
; On Entry:
;  b = value, b < 100
;  h = 0 to suppress leading 0s, h<>0 to print leading 0s
; Trashes a,bc,hl
;=========================================================
PBDEC2:	mvi	l,10		;next digit - divide by 10
	call	DECDIG		;b=dividend

	lxi	h,1001h		;divide by 1, print if 0

; Fall into DECDIG

;-----Local Subroutine----------------------------
; Divide h by l (a power of 10) and print result,
; unless it's a leading 0.
; On Entry at DECDIG:
;   b = Dividend
; On Entry at DECDG1:
;   a = dividend
; On Entry:
;   l = divisor
;   h = 0 if all prior digits were 0
; On Exit:
;   Quotent is printed, unless it's a leading 0
;   b = remainder
;   h = 0 iff this and all prior digits are 0
;-------------------------------------------------
DECDIG:	mov	a,b		;dividend

DECDG1:	mvi	c,0FFh		;will go once to many

DIGLP:	inr	c
	sub	l
	jnc	DIGLP

	add	l		;went once 2 many
	mov	b,a		;remainder in b for ret
				;quotient in c
	mov	a,c
	ora	h		;suppress leading zero?
	mov	h,a		;remember for next digit
	rz		

	mov	a,c		;quotient

; Fall into PASCII

;===Subroutine==================
; Print character in a as ASCII
; Trashes a
;===============================
PASCII:	adi	'0'		;make digit ASCII

; Fall into PRINTA

;===Subroutine===============================
; Print character in a on console via BIOS.
; Strip msb first
; On Entry:
;   a = chr to print
; Trashes a
;==========================================
PRINTA:	push	b
	ani	7Fh		;strip end-of-string marker
	mov	c,a		;value to print
	mvi	a,CONOUT

	db	06h		;'mvi b' skips one instr.

; Fall into GOBIOS, skipping 'push b'

;===Subroutine=========================
; Go call a BIOS driver directly
; On Entry:
;   c = value for BIOS routine, if any
;   a = BIOS call address offset
; On Return:
;   psw is as BIOS left it
;   all other registers preserved
;======================================
GOBIOS:	push	b

	push	d
	push	h

	call	DOBIOS		;BIOS entry in a

	pop	h
	pop	d
	pop	b
	ret

;===Subroutine============================
; Go to a BIOS driver directly
; On Entry:
;   a = BIOS call address offset
;  all other registers as BIOS needs them
; On Return:
;   all registers as BIOS left them
;=========================================
DOBIOS:	lhld	WBOOTA		;get BIOS base address
	mov	l,a		;a has jump vector

	pchl			;go to BIOS routine

;===Subroutine=========================================
; Print CR, LF, then In-line Message
;  The call to ILPRNT is followed by a message string.
;  The last message character has its msb set.
; Trashes a
;======================================================
CILPRT:	CALL	ILPRNT
	DB	CR,LF+80H

; Fall into ILPRNT

;===Subroutine=========================================
; Print In-line Message
;  The call to ILPRNT is followed by a message string.
;  The last message string character has its msb set.
; On Exit:
;  Z cleared
; Trashes a
;======================================================
ILPRNT:	xthl			;Save hl, get msg addr

IPLOOP:	mov	a,m
	call	PRINTA		;print byte (strips msb)
	mov	a,m		;end?
	inx	h		;Next byte
	ora	a		;msb set?
	jp	IPLOOP		;Do all bytes of msg

	xthl			;Restore hl
				;..get return address
	ret

;===Subroutine=================
; Test for single-drive mode
; On Exit:
;   Z set if single-drive mode
;  hl = DSTDSK
; Trashes a
;==============================
TSINGL:	lxi	h,SRCDSK
	mov	a,m		;a=SRCDSK
	inx	h		;(hl)=DSTDSK

	cmp	m		;SRC=DST (single-drive mode)?
	ret

;===Subroutine==============================================
; Switch to the destination disk. If single-drive mode,
; then ask the user to switch disks, and then back up the
; head. If 2-drive mode, then select the destination disk.
; On Entry:
;   c = track that the head is currently on
;   e = track the head needs to be on, in single-drive mode
;   c >= e
; On Exit:
;   hl = DSTDSK
;   Z set
;   destination drive is selected, ready, and on track e
;   Abort if user didn't type 'Y'
; trashes a,c
;=========================================================== 
GODST:	call	TSINGL		;Z if single-drive, hl=DSTDSK
	jnz	SELECT		;2-drive: select dest disk

	call	PDSTIN		;'Put destination in <drive>'
	call	SWITCH

; Step back out from track c to track e

BACKUP:	mov	a,c
	cmp	e		;still need to step?
	rz			;n: done
	
	call	WHEAD		;wait for stepper to settle
	mvi	a,STPOUT
	out	DCTRL		;step out

	dcr	c		;next step
	jmp	BACKUP		;Z set when done

;===Subroutine===========================================
; Switch to the source disk. If single-drive mode, then
; ask the user to switch disks. if 2-drive mode, then
; select the source disk.
; On Exit:
;   hl = SRCDSK
;   drive is selected and ready
;   Abort if user didn't type 'Y'
; trashes a 
;========================================================
GOSRC:	call	TSINGL		;Z if single-drive, hl=DSTDSK
	dcx	h		;hl=SRCDSK
	jnz	SELECT		;2-drive: select source disk
	
	call	PSRCIN		;'Put source in <drive>'

; Fall into SWITCH

;===Subroutine====================================
; Wait for user to switch diskettes
; On Entry:
;  hl = SRCDSK or DSTDSK
; On Exit:
;   Z set
;   drive is selected and ready
;   Abort if user didn't type 'Y'
;=================================================
SWITCH:	call	ASKRDY		;Ready?
	jnz	CPMEXT		;n: abort

; Fall into WAITEN

;===Subroutine===========================================
; Wait for user to insert a diskette into the drive,
; and then load that drive's head.  Note that a minidisk
; will always report that it is ready. Minidisks will
; hang (later on) waiting for a sector, until a few
; seconds after the user inserts a disk.
; On Entry:
;   (hl) = disk to select
; On Exit:
;   Z set
;   drive is selected and ready
;========================================================
WAITEN:	call	ISELCT		;(re)select disk, load head
				;..and check for user abort

	in	DSTAT		;Read drive status
	ani	DRVRDY		;Diskette in drive?
	jnz	WAITEN		;no: wait for drive ready

	ret			;y: done, Z set

;===Subroutine=============
; Ask if the user is ready
; On Exit:
;   Z set if Y
;==========================
ASKRDY:	call	CILPRT
	db	'Read','y'+80h

; Fall into ASKYN

;===Subroutine========================================
; Ask user Y or N, accepting lowercase too. Spin here
; until Y or N typed, echoing only a Y or N.
; (GETCON will abort if ABTCHR is typed.) 
; On Exit:
;   Z set if Y, clear if N
;=====================================================
ASKYN:	call	ILPRNT
	db	' (Y/N)','?'+80h

ASKAGN:	call	GETCON		;get user input

	cpi	'Y'
	jz	ASKYN1
	
	cpi	'N'
	jnz	ASKAGN		;accept nothing else
	
	ora	a		;clear Z

;Y or N - echo, return with Z correctly set, chr in A

ASKYN1:	push	psw
	call	PRINTA		;echo
	pop	psw

	ret

;===Subroutine============================================
; Get one console chr, abort if it is the abort character.
; Otherwise, strip parity, convert to uppercase, and
; return with the console character.
; On Exit:
;  a = console character
;=========================================================
GETCON:	mvi	a,CONIN		;console input
	call	GOBIOS		;via CP/M BIOS

	ani	('a'-'A') xor 7Fh
				;strip parity, make uppercase
	cpi	ABTCHR		;abort?
	jz	REPEXT		;y: abort, report results

	ret

;===Exit=========================================
; Error: didn't find any data tracks
; On Entry:
;   e = current track = number of tracks skipped
;================================================
SKPERR:	call	CILPRT
	db	'FAI','L'+80h

	mov	a,e		;note how many system
	sta	STRACS		;..tracks were skipped

; Fall into COPDON

;===Exit=============================
; Disk copy is done
; Report particulars about this copy
;====================================

; Report number of system tracks for /N and /S

COPDON:	lhld	NOSYS		;h=DOSYS

	dcr	h		;/S?
	jnz	CD1

	call	CILPRT
	db	'Copied',' '+80h
	jmp	CD2

CD1:	dcr	l		;/N?
	jnz	CD3

	call	CILPRT
	db	'Skipped',' '+80h

CD2:	lda	STRACS		;actual system tracks
	call	PADEC

	call	ILPRNT
	db	' system track','s'+80h
CD3:

; Fall into REPEXT

;===Exit===========================================
; Report hard read/write errors & sectors repaired
;==================================================
REPEXT:	lda	HERCNT		;any hard read/write errors?
	ora	a
	cnz	HFREP		;y:report how many

	lda	DOFIX		;/R option?
	ora	a
	cnz	SERPRT		;y:report any sector errors

; Fall into CPMEXT

;===Exit==============================================
; Give the user a chance to replace the CP/M diskette
; if drive A: is a floppy disk (not a hard disk)
;=====================================================
CPMEXT:	lda	DOFFST		;hard disk CP/M?
	ora	a
	jnz	DISEXT		;y: no message

WAITY:	call	CILPRT
	db 'Put CP/M disk in A',':'+80h

	call	ASKRDY		;ready?
	jnz	WAITY

; Fall into DISEXT

;===Exit=========================================
; Disable the disk controller and return to CP/M
;================================================
DISEXT:	mvi	a,DDISBL	;disable disk controller
	out	DENABL

	jmp	WBOOT

;===Load-Initialized RAM Variables=====================
; Note that code assumes these variables are in order,
; as noted in the comments below.
;======================================================
; Drive variables

DOFFST:	db	0	;offset to floppy drives
SRCDSK:	db	0FFh	;source disk
DSTDSK:	db	0FFh	;destination disk (must follow SRCDSK)

; Command line options

VSTART:
NOSYS:	db	0	;(/S) 1: do only non-system tracks
DOSYS:	db	0	;(/N) 1: do only system tracks
			;(must follow NOSYS)
DOFIX:	db	0	;(/R) 1: repair sector metadata
DOPSWD:	db	0	;(/B) 1: remove directory passwords
			;(must follow DOFIX)

; Buffer Variables

TBCUR:	db	0	;current track buffer start high byte
			;(must follow DOPSWD)
TBMAX:	db	0	;high byte of end of track buffer+1
			;(must follow TBCUR)
; Disk parameters

SPT:	db	SPT8	;sectors per track
MAXTRK:	db	MAXTK8	;max track number (must follow SPT)
STRACS:	db	0	;number of actual system tracks found
			;(must follow MAXTRK)
NSTRKS:	db	NSTK8	;# of system-formatted tracks
			;(must follow STRACS)
BDTRAC:	db	BDTK8	;Basic directory track
			;(must follow NSTRKS)

; Counters

HERCNT:	db	0	;# of failed track reads/writes
BSCNT:	db	0	;count of errors in list

;==============================================================
; The track buffer occupies all available RAM from here, over-
; writing the INIT code as well as CP/M's CCP and BDOS. Each
; sector occupies the last SECSIZE (137) bytes of a 256-byte
; page. The address of TRKBUF also overlays the above code a
; bit, since its first (256-SECSIZE) bytes are not used. The
; first (256-SECSIZ) bytes of every TRKBUF page are not used
; for sector data. The first two of these "holes" are used for
; BSLIST. The first "hole" after the INIT code is used for the
; stack. Minidisks have 16 sectors per track, requiring 4K per
; track, 8" disks have 32 sectors per track, requiring 8K per
; track.
;==============================================================
TRKBUF:	equ	($-(256-SECSIZ)+255) and 0FF00h

;======================================================
; Bad Sector List, in the 1st and 2nd holes in TRKBUF.
; Each entry is 2 bytes: the track number goes in the
; first buffer hole, and the sector number goes in the
; second buffer hole.
;======================================================
BSLIST:	equ	TRKBUF+256	;address of 1st buffer hole
MAXBSL	equ	(256-SECSIZ)	;max /R sector errs in err log

;*************************************************************
; The following code, strings, and command table are used    *
; only during initialization and command line processing,    *
; and get overlayed by TRKBUF and BLIST, once initialization *
; is complete.                                               *
;*************************************************************

;***Subroutine**********************************************
; Initialization: parse command line, set up variables and
; disk parameters, based on user input and the type of disk
;  discovered.
; On Exit:
;   e = 0 (meaning we start on track 0)
;   NOSYS = 1 if /N option (do only non-system tracks)
;   DOSYS = 1 if /S option (do only system tracks)
;   DOFIX = 1 if /R option (repair sector metadata)
;   SRCDSK = the source drive, which is selected,
;            and its head is on track 0 and loaded
;   DSTDSK = the destination drive, which is on track 0
;   MAXTRK = ending track number
;   BDTRAC = directory track for removing passwords, if /P
;           = FFh if no /P option
;   NSTRKS = CPMS8 if /N or /S on an 8" CP/M disk
;          = NSTK8 for any other 8" disk
;          = CPMS5 if /N or /S on a CP/M minidisk
;          = 0FFh for any other minidisk
;   TBMAX = high byte of the first address past the
;           end of the track buffer
;***********************************************************
INIT:	di			;no interrupts ever

	call	FLPBAS		;check for hard disk CP/M
				;..to determine valid floppies

;--------------------------------
; Parse the command line options
;--------------------------------
	lxi	h,COMBUF	;CP/M put cmd line here
	mov	b,m		;1st byte is byte count
	inx	h		;point to the string

; Get and validate all command line options

	call	GDRIVS		;get source & destination
	call	GETOPS		;Get all "/" options

;Check for illegal /N /S option combo

	lhld	NOSYS		;both /N and /S?
	mov	a,h		;h got DOSYS
	ana	l		;l got NOSYS
	jnz	BADINP		;y: bogus

; Ask user to insert diskettes and restore them

	call	PUTDSK

;----------------------------------------------------
; Determine if this is an 8" disk or a minidisk, by
; seeing which physical sector number follows sector
; 0Fh. An 8" disk has 20h sectors, numbered 0-1Fh. A
; minidisk has 10h sectors, numbered 0-0Fh.
;----------------------------------------------------

; Wait for the highest minidisk sector, sector number 0Fh

CKDSK1:	in	DSECTR		;Read the sector position

	ani	SECMSK+SVALID	;Mask sector bits, and hunt
	cpi	(SPT5-1)*2	;..for minidisk last sector
	jnz	CKDSK1		;..only while SVALID is 0

; Wait for this sector to pass

CKDSK2:	in	DSECTR		;Read the sector position
	rrc			;wait for invalid sector
	jnc	CKDSK2

; Wait for and get the next sector number

CKDSK3:	in	DSECTR		;Read the sector position
	rrc			;put SVALID in carry
	jc	CKDSK3		;wait for sector to be valid

; The next sector after sector 0Fh will be 0 for a minidisk,
; and 10h for an 8" disk. set Z if we found a minidisk.

	ani	SPT8-1		;is this a minidisk?

; Set up the disk parameters based on what kind of disk
; was found, and print the next announcement portion.

	cz	SUMINI		;y: setup for minidisks
				;(returns with Z set)
	mvi	c,CPMS8		;in case of an 8" CP/M disk
	cnz	CHKCPM		;n: set up for an 8" disk

;--------------------------------------------------------------
; Announce exactly what we plan to copy and get confirmation.
; If either /N or /S option is selected, then we must look at
; one of the disks to see if it is a CP/M disk. For /S, we
; look at the source disk; for /N, we look at the destination
; disk.
;
; Example Complete Announcements:
;
;Copy a minidisk from A: to B:
;Copy an 8" disk's system tracks from CP/M disk A: to B:
;Copy a minidisk's non-system tracks from A: to CP/M disk B:
;Copy an 8" disk's non-system tracks from A: to non-CP/M disk B:
;--------------------------------------------------------------
	call	CILPRT
	db	'Copy ','a'+80h

	lda	SPT		;minidisk?
	cpi	SPT5
	jnz	ANNC1		;n: it's an 8"

	call	ILPRNT		;announce minidisk
	db	' min','i'+80h
	jmp	ANNC2

ANNC1:	call	ILPRNT		;announce 8" disk
	db	'n 8"',' '+80h

ANNC2:	call	ILPRNT
	db	'dis','k'+80h

	lhld	NOSYS		;and h=DOSYS
	push	h		;h=DOSYS, l=NOSYS

	mov	a,h
	ora	l		;either /N or /S?
	jz	ANNC3		;n: shorter message

	call	ILPRNT
	db	QUOTE,'s',' '+80h

	dcr	l		;/N?
	cz	PNON		;y: print 'non-'	

	call	ILPRNT
	db	'system track','s'+80h

ANNC3:	call	ILPRNT
	db	' from',' '+80h

	dcr	h		;we checked source if /S
	cz	PNCPM		;'[non-]CP/M disk '
	
	lxi	h,SRCDSK
	call	PDLETR		;print e.g. 'A:'

	call	ILPRNT
	db	' to',' '+80h
	
	pop	d		;d=DOSYS, e=NOSYS
	dcr	e		;/N?
	cz	PNCPM		;'[non-]CP/M disk '
	
	lxi	h,DSTDSK
	call	PDLETR		;print e.g. A:

; Announce /R and/or /P option, as appropriate

	lhld	DOFIX		;h=DOPSWD too
	dcr	l		;/R?
	jnz	ANNC4		;n: skip message

	call	CILPRT
	db	'repair as neede','d'+80h

ANNC4:	dcr	h		;/P:
	jnz	ANNC5		;n: skip message

	call	CILPRT
	db	'remove password','s'+80h
ANNC5:

; Ask the user to confirm the above-announced copy

	call	ASKRDY		;Ready (Y/N)?
	jnz	CPMEXT		;abort if 'N'

	lxi	h,SRCDSK	;(re)select source disk
	call	WAITEN		;..& wait for user

;----------------------------------------------------------
; Available track buffer memory starts at TRKBUF and goes
; up to CP/M's BIOS, overwriting both the CCP and BDOS.
; Within this available memory, compute the end address of
; the last complete track that fits, where each sector
; requires 256 buffer bytes. Remember the high byte of the
; first address past the track buffer in TBMAX.
;----------------------------------------------------------
	lda	SPT		;compute mask for modula SPT
	dcr	a
	cma
	mov	c,a

	lda	WBOOTA+1	;BIOS address high byte
	sui	TRKBUF/256	;number of available pages

	ana	c		;modula SPT
	adi	TRKBUF/256	;a=high byte of 1st address
				;..past the buffer end

	sta	TBMAX		;max track buffer addr + 1
				;..high byte

;--------------------------------------------------------
; Start copying with track 0 into TRKBUF. (Register e is
; used throughout ACOPY to remember the current track.)
;--------------------------------------------------------
	mvi	e,0		;track 0

;------------------------------------------------------
; If no /P then set directory track way out of bounds,
; overwriting the Basic directory track number that
; was installed by SUMINI or SUMAXI
; Return from call INIT.
;------------------------------------------------------
	lda	DOPSWD		;/P?
	ora	a
	rnz			;y: done with INIT

	dcr	a
	sta	BDTRAC		;n: BDTRAC=FFh

	ret			;done with INIT

;***Subroutine*********************************************
; We have a minidisk. Set up minidisk parameters, and then
; figure out whether or not we care if it is a CP/M disk.
; (We care only if /N or /S option was specified.) If we
; care, then read track 0 and search it for the Digital
; Research copyright message, to determine if this is a
; CP/M disk. Set up with appropriate minidisk parameters.
; On Exit:
;    Z set
;    MAXTRK = MAXTK5
;    SPT = SPT5
;    BDTRAC = BDTK5
;    if (/N or /S) and a CP/M disk was detected then
;       NSTRKS = CPMS5
;    otherwise
;       NSTRKS = 0FFh
;    Source disk is selected and loaded
; trashes a,bc,de,hl
;**********************************************************
SUMINI:	lxi	h,MAXTK5*256+SPT5
	shld	SPT		;saves also MAXTRK=MAXTK5

	lxi	h,BDTK5*256+0FFh
	shld	NSTRKS		;saves BDTRAC too

	mvi	c,CPMS5		;Set up for CP/M minidisk

; Fall into CHKCPM	

;***Subroutine******************************************
; If /S option, then check source disk for CP/M.
; If /N option, then check destination disk for CP/M.
; If neither, then just return.
; On Entry:
;   c = number of CP/M system tracks
;   Source disk is loaded and selected
;   SPT is valid
; On Exit:
;   Z is set
;   NSTRKS = c if CP/M found and (/N or /S)
;   Source disk is selected and loaded
; trashes a,de,hl
;******************************************************
CHKCPM:
;--------------------------------------------------------
; See if either /N or /S has been selected. If not, then
; we don't care if this is a CP/M disk or a Basic disk,
; and the current parameters are correct.
;--------------------------------------------------------
	lhld	NOSYS		;and h=DOSYS
	mov	a,l
	ora	h		;/S or /N?
	rz			;n: we don't care about CP/M	

;-----------------------------------------------------------
; /S or /N option is selected. Test to see if this is a
; CP/M disk by looking for the CP/M copyright message
; anywhere in the first disk track, except sector 0.
; This code will wipe out all INIT code past TTBUF.
;-----------------------------------------------------------
	push	b		;c = number of CP/M sys tracks
	mov	c,l		;c=NOSYS for next test
	
; If /N option then look for CP/M on the destination disk.
; If single-disk mode, then the correct disk is already loaded.

	call	TSINGL		;Single-drive mode?
	jz	CCPM1		;y: correct disk already in

	dcr	c		;/N?
	mov	c,e		;for GODST
	cz	GODST		;switch to dest disk
CCPM1:

; Read track 0 into the temporary track buffer

	mvi	a,TTBUF/256	;use temp track buffer
	sta	TBCUR
	call	RVTRAC		;read & verify track 0

; Search the track buffer for CP/M copyright string. Look in
; every sector except 0, which can only be a boot sector.

	mvi	h,TTBUF/256+1	;look in temp track buffer
				;and skip 1 (boot) sector
	lda	SPT		;number of sectors to check
	dcr	a		;..minus skipped sector 0
	mov	c,a		;..into reg c

	lxi	d,DRSTR		;"Digital Research" string

HUNT1:	mvi	l,(256-SECSIZ)+STDATA ;start of sector data
	mvi	b,128		;data bytes/sector

HUNT2:	ldax	d		;get a string chr
	ora	a		;end of string?
	stc			;carry set if CP/M disk
	jz	HUNT4		;y: we found a CP/M disk

	cmp	m		;another chr match?
	jz	HUNT3		;y: go look at next chr
	lxi	d,DRSTR-1	;n: start string over

HUNT3:	inx	d		;next string chr
	inr	l		;next byte in sector too
	dcr	b		;end of sector?
	jnz	HUNT2		;n: check next byte in sector

	inr	h		;y: next sector
	dcr	c		;looked at enough sectors?
	jnz	HUNT1		;n: beginning of next sector

	xra	a		;clear carry: no CP/M found

; The CP/M hunt is done. Re-select the source disk if necessary
; Z is set. Carry is set only if CP/M was found.

HUNT4:	push	psw		;remember return flags

	lda	NOSYS		;/N option?
	ora	a
	cnz	GOSRC		;y: switch back to source disk

	pop	psw		;recover return flags
	pop	b		;c = number of CP/M sys tracks

	rnc			;ret if no CP/M found

	mov	a,c
	sta	NSTRKS		;CP/M system tracks 
	
	ret			;with Z set

; Identifying portion of CP/M copyright message, null-terminated

DRSTR:	db	'Digital Research',0

;***Subroutine***********************************
; Print type of disk - CP/M or non-CP/M
; On Entry:
;   DOSYS or NOSYS is true
;   NSTRKS = CPMS5 or CPMS8
;         so print 'CP/M '
;   otherwise, NSTRKS > CPMS5
;         so print 'non-CP/M '
;************************************************
PNCPM:	lda	NSTRKS
	cpi	CPMS5+1		;CP/M disk found?

	cnc	PNON		;n: print 'non-'
	
	call	ILPRNT
	db	'CP/M disk',' '+80h

	ret

;***Subroutine******
; Print 'non-'
;*******************
PNON:	call	ILPRNT
	db	'non','-'+80h
	ret

;***Buffer************************************************
; Temp track buffer, used only to determine if a diskette
; is a CP/M disk. Placed beyond some INIT code, but
; overwrites all the below code.
;*********************************************************
TTBUF:	equ	($-(256-SECSIZ)+255) and 0FF00h

;***Subroutine***********************************************
; Look at CP/M drive A:'s sectors/track to determine the
; drive offset, which will be 0 for floppy disk CP/M, and
; 2 for hard disk CP/M (since hard disk CP/M drive A: and
; B: are the hard drive's 2 platters) This calls the BIOS
; SELDSK routine, which should not actually select the disk.
;************************************************************
FLPBAS:	mvi	c,0		;select disk 0 = A:
	mvi	a,SELDSK	;SELDSK returns hl=DPH
	call	DOBIOS		;BIOS call

	lxi	b,10		;offset to DPH address
	dad	b
	mov	e,m		;get address of DPB
	inx	h
	mov	d,m		;de=address of DPB
	xchg			;hl=address of DPB

	mvi	a,SPT8		;DPB first byte = SPT
	cmp	m		;greater than 8" SPT?
	rnc			;n: it's a floppy CP/M

	mvi	a,2		;y: hard disk offset = 2
	sta	DOFFST		;remember offset
	ret

;***Subroutine********************************************
; Ask user to put diskettes in the drives, wait for the
; diskettes, and restore them to track 0
; On Exit:
;   hl=DSTDSK
;   disk is inserted in destination drive
;    if /N and SRCDSK=DSTDSK (single drive mode) then
;       Destination disk is selected
;    else
;       Source disk is selected
;    both drives are on track 0
; trashes a
;*********************************************************
PUTDSK:	call	TSINGL		;single-drive mode? (hl=DSTDSK)
	push	psw		;remember Z=single-drive mode
	jz	PDSNGL		;y: 

	dcx	h		;hl=SRCDSK
	call	PSRCIN		;'Put source in <drive>'

	call	ILPRNT
	db	' an','d'+80h
	inx	h		;hl=DSTDSK
	call	DSTIN		;' destination in <drive>'

	jmp	CONSDM		;wait for confirmantion

; Single disk mode. Should we look at the source or dest disk?

PDSNGL:	lda	NOSYS		;need to look for CP/M on dest?
	ora	a
	jnz	PDSDST		;y:ask for dest disk

	dcx	h		;hl=SRCDSK
	call	PSRCIN		;'Put source in <drive>'
	jmp	CONSDM		;wait for confirmantion

; /N option selected - look at the destination disk (hl=DSTDSK)

PDSDST:	call	PDSTIN		;'Put destination in <drive>'

; Wait for user to confirm

CONSDM:	call	ASKRDY		;Ready (Y/N)?
	jnz	CPMEXT		;abort if 'N'

; Wait for destination disk to be ready. hl=DSTDRV here.

	call	WAITEN		;select destination, wait
				;..for disk ready

; Restore both drives to track 0

	call	RESTOR		;restore the dest (or only) disk

	pop	psw		;recall Z=single-drive mode
	rz			;single-drive mode: done

	dcx	h		;point to SRCDSK
	call	SELECT		;2-drive: select source disk

; Fall into RESTOR

;***Subroutine*****************************
; Restore current disk to track 0
; Step away from track 0 first, in case
; the head is jammed against the end-stop.
; On Entry:
;   disk to restore is already selected
; Trashes a
;******************************************
RESTOR:

; Step in until no longer on track 0

RSTIN:	mvi	a,STEPIN
	call	STEP
	jz	RSTIN

; step out to track 0

SKTRK0:	mvi	a,STPOUT
	call	STEP
	jnz	SKTRK0

	ret

;***Subroutine***********************
; Step once, and wait for completion
; On Entry:
;   a = STEPIN or STPOUT
; On Exit:
;   z set if on track 0
;************************************
STEP:	out	DCTRL		;step in/out

WSTEP:	in	DSTAT		;wait for step to complete
	rrc			;put MVHEAD bit in carry
	rrc			;is the servo stable?
	jc	WSTEP		;no: wait for servo to settle

	ani	TRACK0/4	;Are we at track 00?

	ret

;***Subroutine*****************************************
; Parse all command line options and set option
; variables appropriately.
; On Entry:
;   hl = address of next command line chr
;    b = remaining command line bytes
; On Exit:
;   SRCDSK = requested source disk number
;   DSTDSK = requested destination disk number
;   NOSYS = 1 if /N option (do only non-system tracks)
;   DOSYS = 1 if /S option (do only system tracks)
;   DOFIX = 1 if /R option (repair sector metadata)
;******************************************************
GETOPS:	call	SSKIP		;skip spaces
	rz			;end of input line: done

	cpi	'/'		;all start with /
	jnz	BADINP		;error:no slash

	call	CMDCHR		;Get an option chr, a=0 if none

;------------------------------------------------------------
; Got a command line option in a. Loop through the option
; table (which is in apphabetic order), looking for a match.
; Error-exit if not found in the table.
;  a=option character
;------------------------------------------------------------
	push	h		;Save COMBUF pointer
	lxi	h,OPTTAB

OPHUNT:	cmp	m		;Match? (alphabetic order)
	inx	h
	mov	e,m		;get var address offset
	inx	h

	jc	BADINP		;not in table
	jnz	OPHUNT		;No match: keep looking

;----------------------------------------------
; Option match. Set the specified command-line
;  variable to 1, and go look for more
;  e = address offset
;----------------------------------------------
	lxi	h,VSTART	;start of variable table
	mvi	d,0		;high byte

	dad	d		;offset to our variable
	mvi	m,1		;set variable true
	pop	h		;restore command line pointer

	jmp	GETOPS		;look for more
	
;***Subroutine*************************************
; Get and validate source and destination drives
; Abort to BADINP on bogus input. Abort to HLPEXT
; if no parameters specified.
; On Entry:
;   hl = address of next command line chr
;    b = remaining command line bytes
; On Exit:
;   b & hl updated
;   SRCDSK and DSTDSK are valid
;**************************************************
GDRIVS:	call	SSKIP		;skip initial spaces; get 1st
	jz	HLPEXT		;abort to help, if no drives

	lxi	d,DSTDSK	;get the destination first
	call	GETDRV		;get, validate, save drive

	call	CMDCHR
	cpi	'='		;mandatory equals sign?
	jnz	BADINP		;n: error

	call	CMDCHR		;get source

	dcx	d		;de=SRCDSK

; Fall into GETDRV to get the source drive number

;***Subroutine*************************************
; Get and validate a drive letter, followed by a :
; If valid, compute drive number, and save at de
; On Entry:
;   a = drive letter from command line
;   DOFFST = drive offset: 0 for floppy
;      disk CP/M, 2 for hard disk CP/M
;   de = address to save drive number
;   hl = address of next command line chr
;    b = remaining command line bytes
; On Exit:
;   b & hl updated
;   (de)=drive number between 0 and MAXDRV
;   jump to BADINP if invalid input
;*************************************************
GETDRV:	push	h
	lxi	h,DOFFST
	sui	'A'		;un-ASCII
	sub	m		;un-offset
	pop	h

	cpi	MAXDRV+1	;set c if okay
	jnc	BADINP		;bogus drive letter

	stax	d		;save drive number

	call	CMDCHR		;get mandatory colon
	cpi	':'
	rz			;good input

; Fall into BADINP

;***Subroutine***********************
; Print usage
; On Entry:
;   DOFFST = 0 for floppy disk CP/M
;          = 2 fpr hard disk CP/M
;************************************
BADINP:	call	CILPRT
	db	'Illegal option',CR,LF+80h
	
; Fall into HLPEXT

;***Exit***************************
; Print help, then return to CP/M.
; Pause after each page.
;**********************************
HLPEXT:	call	CILPRT

;    1234567890123456789012345678901234567890123456789012345678901234
 db 'Altair Disk Copy/Repair Utility   Vers. 1.08 by M. Eberhard'
 db CR,LF,CR,LF
 db 'USAGE'
 db CR,LF,CR,LF
 db ' ACOPY <d>:=<s>: [/N or /S] [/P] [/R]'
 db CR,LF
 db '  <d> is the destination, <s> is the source'
 db CR,LF
 db '  /N Copies only non-system tracks'
 db CR,LF
 db '  /S Copies only system tracks'
 db CR,LF
 db '  /P Removes Altair passwords'
 db CR,LF
 db '  /R Repairs sectors'
 db CR,LF,CR,LF
 db ' Valid <s> and <d> drives are',' '+80h

	lda	DOFFST		;min drive number
	adi	'A'
	mov	d,a		;save
	call	PRINTA

	call	ILPRNT
	db	'-'+80h

	mov	a,d
	adi	MAXDRV
	call	PRINTA

; Display help pages as requested

	lxi	d,HLPMSG

HLPLUP:	call	CILPRT
	db	CR,LF,'Mor','e'+80h

	call	ASKYN
	jnz	DISEXT

; Print one help page

PRINTF:	ldax	d
	call	PRINTA		;strips msb

	ldax	d		;test for end
	inx	d
	ora	a		;msb set?
	jp	PRINTF

	ldax	d		;is next chr the null term?
	ora	a
	jnz	HLPLUP		;n: do another help page

	jmp	DISEXT		;y: done


;***Subroutine**************************************
; Skip over spaces in command line buffer until
; a non-space character is found 
; On Entry:
;    b has remaining COMBUF byte count
;    hl points to the next chr in COMBUF
; On Exit:
;    a = chr from COMBUF
;    b has been decremented
;    hl has been advanced
;    Z = 1 means end of buffer (and a is not valid)
;***************************************************
SSKIP:	call	CMDCHR
	rz			;Z set for nothing left
	cpi	' '		;white space?
	jz	SSKIP
	ret			;chr in a, Z clear

;***Subroutine****************************
; Get next chr from command line buffer
; On Entry:
;    b has remaining COMBUF byte count
;    hl points to the next chr in COMBUF
; On Exit:
;    a = chr from COMBUF, parity stripped
;    b has been decremented
;    hl has been advanced
;    Z = 1, a = 0  means end of buffer
;*****************************************
CMDCHR:	mov	a,b		;End of buffer already?
	ora	a		;also clears carry
	rz			;and clears a

	mov	a,m		;get buffer chr
	inx	h		;bump buffer pointers
	dcr	b	
	ani	7FH		;Strip parity, clear Z
	ret			;with Z cleared

;***Help Strings****************************************
;* Each message terminated by msb set
;* Help message continues until final null termination
;********************************************************
HLPMSG:
;    1234567890123456789012345678901234567890123456789012345678901234
 db CR,LF,CR,LF
 db 'ACOPY copies and repairs Altair 8" disks and Altair minidisks,'
 db  CR,LF
 db 'verifying reads and writes, using all available RAM for speed.'

 db CR,LF,CR,LF
;    1234567890123456789012345678901234567890123456789012345678901234
 db 'USING ACOPY'
 db CR,LF,CR,LF
 db 'To copy C: to D:, type "ACOPY D:=C:". To repair while you copy,'
 db CR,LF
 db 'type "ACOPY D:=C: /R". Use /N to copy/repair only the non-system'
 db CR,LF
 db 'tracks, and use /S to copy/repair only the actual system tracks.'
 db CR,LF
 db '/N looks for CP/M on track 0 of the destination disk to decide'
 db CR,LF
 db 'how many system tracks to skip. /S looks for CP/M on track 0 of'
 db CR,LF
 db 'the source disk to decide how many system tracks to copy'
 db '.'+80h

 db CR,LF,CR,LF
;    1234567890123456789012345678901234567890123456789012345678901234
 db 'SYSTEM TRACKS'
 db CR,LF,CR,LF
 db 'System tracks on Altair disks are formatted differently than'
 db CR,LF
 db 'non-system tracks. Tracks 0-5 on 8" Basic/DOS disks are system'
 db CR,LF
 db 'tracks. Tracks 0-1 on 8" CP/M disks are system tracks, (although'
 db CR,LF
 db 'tracks 0-5 are all still formatted like system tracks). Tracks'
 db CR,LF
 db '6-76 on an 8" disk are always formatted as non-system tracks.'
 db CR,LF,CR,LF
 db 'On a minidisk, only the actual system tracks (0-11 for Basic,'
 db CR,LF
 db 'and 0-3 for CP/M) are formatted as system tracks. A non-bootable'
 db CR,LF
 db 'Basic minidisk has no system tracks'
 db '.'+80h

 db CR,LF,CR,LF
;    1234567890123456789012345678901234567890123456789012345678901234
 db 'REPAIRING A DISK'
 db CR,LF,CR,LF
 db 'Altair software checks the track & sector numbers, stop byte,'
 db CR,LF
 db 'checksum, and file links on every 8th sector when mounting'
 db CR,LF
 db 'a disk. Any error will cause the mount to fail. /R repairs the'
 db CR,LF
 db 'track & sector numbers, stop bytes and checksums, while copying'
 db '.'+80h

 db CR,LF,CR,LF
;    1234567890123456789012345678901234567890123456789012345678901234
 db 'ALTAIR PASSWORDS'
 db CR,LF,CR,LF
 db 'Altair Multiuser Basic treats 5 bytes in each directory entry as'
 db CR,LF
 db 'a file password, where all 0s means no password. Single-user'
 db CR,LF
 db 'Basic ignores these 5 bytes, and does not always clear them.'
 db CR,LF
 db 'Any file where these bytes are not cleared is unreadable by'
 db CR,LF
 db 'Multiuser Basic. Use /P to clear all directory passwords.'
 db CR,LF,CR,LF
 db 'Do not use /P on a CP/M disk.'
 db CR,LF+80h

 db 0		; Final termination of help message

;***Table*******************************************
; Command Line Options Table
;  Table entries must be in alphabetical order, and
;  terminated with 0FFh
;
; Each entry is 2 bytes long:
;  byte1 = uppercase legal option letter
;  byte2 = variable address offset
;***************************************************
OPTTAB:
;Non-System tracks only
	db	'N',NOSYS-VSTART

;Remove directory passwords
	db	'P',DOPSWD-VSTART

;Repair metadata
	db	'R',DOFIX-VSTART

;System tracks only
	db	'S',DOSYS-VSTART

;end-of-table marker
	db	0FFh

;===========================================
; System Stack
; Tucked between sectors in TRKBUF, leaving
; (256-SECSIZ)=119 bytes for the stack 
; (Grows downward from this address.)
;===========================================
STACK:	equ	(($+255) and 0FF00h)+(256-SECSIZ)

	END







