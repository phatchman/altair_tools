;**************************************************************
;*
;*             C P / M   version   2 . 2
;*
;*   Reconstructed from memory image on February 27, 1981
;*
;*                by Clark A. Calkins
;*
;*   (Edited by MWD to provide a capitalized prompt
;*    instead of lower case, e.g., "A>" vs "a>" and to
;*    compute the program ORG from the macro CPMSIZE)
;*
;*
;**************************************************************

IOBYTE	EQU	3	;i/o definition byte.
TDRIVE	EQU	4	;current drive name and user number.
ENTRY	EQU	5	;entry point for the cp/m bdos.
TFCB	EQU	5CH	;default file control block.
TBUFF	EQU	80H	;i/o buffer and command line storage.
TBASE	EQU	100H	;transiant program storage area.
;
;   Set control character equates.
;
CNTRLC	EQU	3	;control-c
CNTRLE	EQU	05H	;control-e
BS	EQU	08H	;backspace
TAB	EQU	09H	;tab
LF	EQU	0AH	;line feed
FF	EQU	0CH	;form feed
CR	EQU	0DH	;carriage return
CNTRLP	EQU	10H	;control-p
CNTRLR	EQU	12H	;control-r
CNTRLS	EQU	13H	;control-s
CNTRLU	EQU	15H	;control-u
CNTRLX	EQU	18H	;control-x
CNTRLZ	EQU	1AH	;control-z (end-of-file mark)
DEL	EQU	7FH	;rubout
;
;   Set origin for CP/M
;
	maclib	cpmsize		;bring in memory and bios size

	ORG	ccpBase
;
CBASE	JMP	COMMAND	;execute command processor (ccp).
	JMP	CLEARBUF	;entry to empty input buffer before starting ccp.

;
;   Standard cp/m ccp input buffer. Format is (max length),
; (actual length), (char #1), (char #2), (char #3), etc.
;
INBUFF	DB	127	;length of input buffer.
	DB	0	;current length of contents.
	DB	'Copyright'
	DB	' 1979 (c) by Digital Research      '
	DB	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
	DB	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
	DB	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
	DB	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
INPOINT	DW	INBUFF+2;input line pointer
NAMEPNT	DW	0	;input line pointer used for error message. Points to
;			;start of name in error.
;
;   Routine to print (A) on the console. All registers used.
;
PRINT	MOV	E,A	;setup bdos call.
	MVI	C,2
	JMP	ENTRY
;
;   Routine to print (A) on the console and to save (BC).
;
PRINTB	PUSH	B
	CALL	PRINT
	POP	B
	RET
;
;   Routine to send a carriage return, line feed combination
; to the console.
;
CRLF	MVI	A,CR
	CALL	PRINTB
	MVI	A,LF
	JMP	PRINTB
;
;   Routine to send one space to the console and save (BC).
;
SPACE	MVI	A,' '
	JMP	PRINTB
;
;   Routine to print character string pointed to be (BC) on the
; console. It must terminate with a null byte.
;
PLINE	PUSH	B
	CALL	CRLF
	POP	H
PLINE2	MOV	A,M
	ORA	A
	RZ
	INX	H
	PUSH	H
	CALL	PRINT
	POP	H
	JMP	PLINE2
;
;   Routine to reset the disk system.
;
RESDSK	MVI	C,13
	JMP	ENTRY
;
;   Routine to select disk (A).
;
DSKSEL	MOV	E,A
	MVI	C,14
	JMP	ENTRY
;
;   Routine to call bdos and save the return code. The zero
; flag is set on a return of 0ffh.
;
ENTRY1	CALL	ENTRY
	STA	RTNCODE	;save return code.
	INR	A	;set zero if 0ffh returned.
	RET
;
;   Routine to open a file. (DE) must point to the FCB.
;
OPEN	MVI	C,15
	JMP	ENTRY1
;
;   Routine to open file at (FCB).
;
OPENFCB	XRA	A	;clear the record number byte at fcb+32
	STA	FCB+32
	LXI	D,FCB
	JMP	OPEN
;
;   Routine to close a file. (DE) points to FCB.
;
CLOSE	MVI	C,16
	JMP	ENTRY1
;
;   Routine to search for the first file with ambigueous name
; (DE).
;
SRCHFST	MVI	C,17
	JMP	ENTRY1
;
;   Search for the next ambigeous file name.
;
SRCHNXT	MVI	C,18
	JMP	ENTRY1
;
;   Search for file at (FCB).
;
SRCHFCB	LXI	D,FCB
	JMP	SRCHFST
;
;   Routine to delete a file pointed to by (DE).
;
DELETE	MVI	C,19
	JMP	ENTRY
;
;   Routine to call the bdos and set the zero flag if a zero
; status is returned.
;
ENTRY2	CALL	ENTRY
	ORA	A	;set zero flag if appropriate.
	RET
;
;   Routine to read the next record from a sequential file.
; (DE) points to the FCB.
;
RDREC	MVI	C,20
	JMP	ENTRY2
;
;   Routine to read file at (FCB).
;
READFCB	LXI	D,FCB
	JMP	RDREC
;
;   Routine to write the next record of a sequential file.
; (DE) points to the FCB.
;
WRTREC	MVI	C,21
	JMP	ENTRY2
;
;   Routine to create the file pointed to by (DE).
;
CREATE	MVI	C,22
	JMP	ENTRY1
;
;   Routine to rename the file pointed to by (DE). Note that
; the new name starts at (DE+16).
;
RENAM	MVI	C,23
	JMP	ENTRY
;
;   Get the current user code.
;
GETUSR	MVI	E,0FFH
;
;   Routne to get or set the current user code.
; If (E) is FF then this is a GET, else it is a SET.
;
GETSETUC:MVI	C,32
	JMP	ENTRY
;
;   Routine to set the current drive byte at (TDRIVE).
;
SETCDRV	CALL	GETUSR	;get user number
	ADD	A	;and shift into the upper 4 bits.
	ADD	A
	ADD	A
	ADD	A
	LXI	H,CDRIVE;now add in the current drive number.
	ORA	M
	STA	TDRIVE	;and save.
	RET
;
;   Move currently active drive down to (TDRIVE).
;
MOVECD	LDA	CDRIVE
	STA	TDRIVE
	RET
;
;   Routine to convert (A) into upper case ascii. Only letters
; are affected.
;
UPPER	CPI	'a'	;check for letters in the range of 'a' to 'z'.
	RC
	CPI	'{'
	RNC
	ANI	5FH	;convert it if found.
	RET
;
;   Routine to get a line of input. We must check to see if the
; user is in (BATCH) mode. If so, then read the input from file
; ($$$.SUB). At the end, reset to console input.
;
GETINP	LDA	BATCH	;if =0, then use console input.
	ORA	A
	JZ	GETINP1
;
;   Use the submit file ($$$.sub) which is prepared by a
; SUBMIT run. It must be on drive (A) and it will be deleted
; if and error occures (like eof).
;
	LDA	CDRIVE	;select drive 0 if need be.
	ORA	A
	MVI	A,0	;always use drive A for submit.
	CNZ	DSKSEL	;select it if required.
	LXI	D,BATCHFCB
	CALL	OPEN	;look for it.
	JZ	GETINP1	;if not there, use normal input.
	LDA	BATCHFCB+15;get last record number+1.
	DCR	A
	STA	BATCHFCB+32
	LXI	D,BATCHFCB
	CALL	RDREC	;read last record.
	JNZ	GETINP1	;quit on end of file.
;
;   Move this record into input buffer.
;
	LXI	D,INBUFF+1
	LXI	H,TBUFF	;data was read into buffer here.
	MVI	B,128	;all 128 characters may be used.
	CALL	HL2DE	;(HL) to (DE), (B) bytes.
	LXI	H,BATCHFCB+14
	MVI	M,0	;zero out the 's2' byte.
	INX	H	;and decrement the record count.
	DCR	M
	LXI	D,BATCHFCB;close the batch file now.
	CALL	CLOSE
	JZ	GETINP1	;quit on an error.
	LDA	CDRIVE	;re-select previous drive if need be.
	ORA	A
	CNZ	DSKSEL	;don't do needless selects.
;
;   Print line just read on console.
;
	LXI	H,INBUFF+2
	CALL	PLINE2
	CALL	CHKCON	;check console, quit on a key.
	JZ	GETINP2	;jump if no key is pressed.
;
;   Terminate the submit job on any keyboard input. Delete this
; file such that it is not re-started and jump to normal keyboard
; input section.
;
	CALL	DELBATCH;delete the batch file.
	JMP	CMMND1	;and restart command input.
;
;   Get here for normal keyboard input. Delete the submit file
; incase there was one.
;
GETINP1	CALL	DELBATCH;delete file ($$$.sub).
	CALL	SETCDRV	;reset active disk.
	MVI	C,10	;get line from console device.
	LXI	D,INBUFF
	CALL	ENTRY
	CALL	MOVECD	;reset current drive (again).
;
;   Convert input line to upper case.
;
GETINP2	LXI	H,INBUFF+1
	MOV	B,M	;(B)=character counter.
GETINP3	INX	H
	MOV	A,B	;end of the line?
	ORA	A
	JZ	GETINP4
	MOV	A,M	;convert to upper case.
	CALL	UPPER
	MOV	M,A
	DCR	B	;adjust character count.
	JMP	GETINP3
GETINP4	MOV	M,A	;add trailing null.
	LXI	H,INBUFF+2
	SHLD	INPOINT	;reset input line pointer.
	RET
;
;   Routine to check the console for a key pressed. The zero
; flag is set is none, else the character is returned in (A).
;
CHKCON	MVI	C,11	;check console.
	CALL	ENTRY
	ORA	A
	RZ		;return if nothing.
	MVI	C,1	;else get character.
	CALL	ENTRY
	ORA	A	;clear zero flag and return.
	RET
;
;   Routine to get the currently active drive number.
;
GETDSK	MVI	C,25
	JMP	ENTRY
;
;   Set the stabdard dma address.
;
STDDMA	LXI	D,TBUFF
;
;   Routine to set the dma address to (DE).
;
DMASET	MVI	C,26
	JMP	ENTRY
;
;  Delete the batch file created by SUBMIT.
;
DELBATCH:LXI	H,BATCH	;is batch active?
	MOV	A,M
	ORA	A
	RZ
	MVI	M,0	;yes, de-activate it.
	XRA	A
	CALL	DSKSEL	;select drive 0 for sure.
	LXI	D,BATCHFCB;and delete this file.
	CALL	DELETE
	LDA	CDRIVE	;reset current drive.
	JMP	DSKSEL
;
;   Check to two strings at (PATTRN1) and (PATTRN2). They must be
; the same or we halt....
;
VERIFY	LXI	D,PATTRN1;these are the serial number bytes.
	LXI	H,PATTRN2;ditto, but how could they be different?
	MVI	B,6	;6 bytes each.
VERIFY1	LDAX	D
	CMP	M
	JNZ	HALT	;jump to halt routine.
	INX	D
	INX	H
	DCR	B
	JNZ	VERIFY1
	RET
;
;   Print back file name with a '?' to indicate a syntax error.
;
SYNERR	CALL	CRLF	;end current line.
	LHLD	NAMEPNT	;this points to name in error.
SYNERR1	MOV	A,M	;print it until a space or null is found.
	CPI	' '
	JZ	SYNERR2
	ORA	A
	JZ	SYNERR2
	PUSH	H
	CALL	PRINT
	POP	H
	INX	H
	JMP	SYNERR1
SYNERR2	MVI	A,'?'	;add trailing '?'.
	CALL	PRINT
	CALL	CRLF
	CALL	DELBATCH;delete any batch file.
	JMP	CMMND1	;and restart from console input.
;
;   Check character at (DE) for legal command input. Note that the
; zero flag is set if the character is a delimiter.
;
CHECK	LDAX	D
	ORA	A
	RZ
	CPI	' '	;control characters are not legal here.
	JC	SYNERR
	RZ		;check for valid delimiter.
	CPI	'='
	RZ
	CPI	'_'
	RZ
	CPI	'.'
	RZ
	CPI	':'
	RZ
	CPI	';'
	RZ
	CPI	'<'
	RZ
	CPI	'>'
	RZ
	RET
;
;   Get the next non-blank character from (DE).
;
NONBLANK:LDAX	D
	ORA	A	;string ends with a null.
	RZ
	CPI	' '
	RNZ
	INX	D
	JMP	NONBLANK
;
;   Add (HL)=(HL)+(A)
;
ADDHL	ADD	L
	MOV	L,A
	RNC	;take care of any carry.
	INR	H
	RET
;
;   Convert the first name in (FCB).
;
CONVFST	MVI	A,0
;
;   Format a file name (convert * to '?', etc.). On return,
; (A)=0 is an unambigeous name was specified. Enter with (A) equal to
; the position within the fcb for the name (either 0 or 16).
;
CONVERT	LXI	H,FCB
	CALL	ADDHL
	PUSH	H
	PUSH	H
	XRA	A
	STA	CHGDRV	;initialize drive change flag.
	LHLD	INPOINT	;set (HL) as pointer into input line.
	XCHG
	CALL	NONBLANK;get next non-blank character.
	XCHG
	SHLD	NAMEPNT	;save pointer here for any error message.
	XCHG
	POP	H
	LDAX	D	;get first character.
	ORA	A
	JZ	CONVRT1
	SBI	'A'-1	;might be a drive name, convert to binary.
	MOV	B,A	;and save.
	INX	D	;check next character for a ':'.
	LDAX	D
	CPI	':'
	JZ	CONVRT2
	DCX	D	;nope, move pointer back to the start of the line.
CONVRT1	LDA	CDRIVE
	MOV	M,A
	JMP	CONVRT3
CONVRT2	MOV	A,B
	STA	CHGDRV	;set change in drives flag.
	MOV	M,B
	INX	D
;
;   Convert the basic file name.
;
CONVRT3	MVI	B,08H
CONVRT4	CALL	CHECK
	JZ	CONVRT8
	INX	H
	CPI	'*'	;note that an '*' will fill the remaining
	JNZ	CONVRT5	;field with '?'.
	MVI	M,'?'
	JMP	CONVRT6
CONVRT5	MOV	M,A
	INX	D
CONVRT6	DCR	B
	JNZ	CONVRT4
CONVRT7	CALL	CHECK	;get next delimiter.
	JZ	GETEXT
	INX	D
	JMP	CONVRT7
CONVRT8	INX	H	;blank fill the file name.
	MVI	M,' '
	DCR	B
	JNZ	CONVRT8
;
;   Get the extension and convert it.
;
GETEXT	MVI	B,03H
	CPI	'.'
	JNZ	GETEXT5
	INX	D
GETEXT1	CALL	CHECK
	JZ	GETEXT5
	INX	H
	CPI	'*'
	JNZ	GETEXT2
	MVI	M,'?'
	JMP	GETEXT3
GETEXT2	MOV	M,A
	INX	D
GETEXT3	DCR	B
	JNZ	GETEXT1
GETEXT4	CALL	CHECK
	JZ	GETEXT6
	INX	D
	JMP	GETEXT4
GETEXT5	INX	H
	MVI	M,' '
	DCR	B
	JNZ	GETEXT5
GETEXT6	MVI	B,3
GETEXT7	INX	H
	MVI	M,0
	DCR	B
	JNZ	GETEXT7
	XCHG
	SHLD	INPOINT	;save input line pointer.
	POP	H
;
;   Check to see if this is an ambigeous file name specification.
; Set the (A) register to non zero if it is.
;
	LXI	B,11	;set name length.
GETEXT8	INX	H
	MOV	A,M
	CPI	'?'	;any question marks?
	JNZ	GETEXT9
	INR	B	;count them.
GETEXT9	DCR	C
	JNZ	GETEXT8
	MOV	A,B
	ORA	A
	RET
;
;   CP/M command table. Note commands can be either 3 or 4 characters long.
;
NUMCMDS	EQU	6	;number of commands
CMDTBL	DB	'DIR '
	DB	'ERA '
	DB	'TYPE'
	DB	'SAVE'
	DB	'REN '
	DB	'USER'
;
;   The following six bytes must agree with those at (PATTRN2)
; or cp/m will HALT. Why?
;
PATTRN1	DB	0,22,0,0,0,0;(* serial number bytes *).
;
;   Search the command table for a match with what has just
; been entered. If a match is found, then we jump to the
; proper section. Else jump to (UNKNOWN).
; On return, the (C) register is set to the command number
; that matched (or NUMCMDS+1 if no match).
;
SEARCH	LXI	H,CMDTBL
	MVI	C,0
SEARCH1	MOV	A,C
	CPI	NUMCMDS	;this commands exists.
	RNC
	LXI	D,FCB+1	;check this one.
	MVI	B,4	;max command length.
SEARCH2	LDAX	D
	CMP	M
	JNZ	SEARCH3	;not a match.
	INX	D
	INX	H
	DCR	B
	JNZ	SEARCH2
	LDAX	D	;allow a 3 character command to match.
	CPI	' '
	JNZ	SEARCH4
	MOV	A,C	;set return register for this command.
	RET
SEARCH3	INX	H
	DCR	B
	JNZ	SEARCH3
SEARCH4	INR	C
	JMP	SEARCH1
;
;   Set the input buffer to empty and then start the command
; processor (ccp).
;
CLEARBUF:XRA	A
	STA	INBUFF+1;second byte is actual length.
;
;**************************************************************
;*
;*
;* C C P  -   C o n s o l e   C o m m a n d   P r o c e s s o r
;*
;**************************************************************
;*
COMMAND	LXI	SP,CCPSTACK;setup stack area.
	PUSH	B	;note that (C) should be equal to:
	MOV	A,C	;(uuuudddd) where 'uuuu' is the user number
	RAR		;and 'dddd' is the drive number.
	RAR
	RAR
	RAR
	ANI	0FH	;isolate the user number.
	MOV	E,A
	CALL	GETSETUC;and set it.
	CALL	RESDSK	;reset the disk system.
	STA	BATCH	;clear batch mode flag.
	POP	B
	MOV	A,C
	ANI	0FH	;isolate the drive number.
	STA	CDRIVE	;and save.
	CALL	DSKSEL	;...and select.
	LDA	INBUFF+1
	ORA	A	;anything in input buffer already?
	JNZ	CMMND2	;yes, we just process it.
;
;   Entry point to get a command line from the console.
;
CMMND1	LXI	SP,CCPSTACK;set stack straight.
	CALL	CRLF	;start a new line on the screen.
	CALL	GETDSK	;get current drive.
	ADI	'A'	;changed from 'a' (mwd)
	CALL	PRINT	;print current drive.
	MVI	A,'>'
	CALL	PRINT	;and add prompt.
	CALL	GETINP	;get line from user.
;
;   Process command line here.
;
CMMND2	LXI	D,TBUFF
	CALL	DMASET	;set standard dma address.
	CALL	GETDSK
	STA	CDRIVE	;set current drive.
	CALL	CONVFST	;convert name typed in.
	CNZ	SYNERR	;wild cards are not allowed.
	LDA	CHGDRV	;if a change in drives was indicated,
	ORA	A	;then treat this as an unknown command
	JNZ	UNKNOWN	;which gets executed.
	CALL	SEARCH	;else search command table for a match.
;
;   Note that an unknown command returns
; with (A) pointing to the last address
; in our table which is (UNKNOWN).
;
	LXI	H,CMDADR;now, look thru our address table for command (A).
	MOV	E,A	;set (DE) to command number.
	MVI	D,0
	DAD	D
	DAD	D	;(HL)=(CMDADR)+2*(command number).
	MOV	A,M	;now pick out this address.
	INX	H
	MOV	H,M
	MOV	L,A
	PCHL		;now execute it.
;
;   CP/M command address table.
;
CMDADR	DW	DIRECT,ERASE,TYPE,SAVE
	DW	RENAME,USER,UNKNOWN
;
;   Halt the system. Reason for this is unknown at present.
;
HALT	LXI	H,76F3H	;'DI HLT' instructions.
	SHLD	CBASE
	LXI	H,CBASE
	PCHL
;
;   Read error while TYPEing a file.
;
RDERROR	LXI	B,RDERR
	JMP	PLINE
RDERR	DB	'Read error',0
;
;   Required file was not located.
;
NONE	LXI	B,NOFILE
	JMP	PLINE
NOFILE	DB	'No file',0
;
;   Decode a command of the form 'A>filename number{ filename}.
; Note that a drive specifier is not allowed on the first file
; name. On return, the number is in register (A). Any error
; causes 'filename?' to be printed and the command is aborted.
;
DECODE	CALL	CONVFST	;convert filename.
	LDA	CHGDRV	;do not allow a drive to be specified.
	ORA	A
	JNZ	SYNERR
	LXI	H,FCB+1	;convert number now.
	LXI	B,11	;(B)=sum register, (C)=max digit count.
DECODE1	MOV	A,M
	CPI	' '	;a space terminates the numeral.
	JZ	DECODE3
	INX	H
	SUI	'0'	;make binary from ascii.
	CPI	10	;legal digit?
	JNC	SYNERR
	MOV	D,A	;yes, save it in (D).
	MOV	A,B	;compute (B)=(B)*10 and check for overflow.
	ANI	0E0H
	JNZ	SYNERR
	MOV	A,B
	RLC
	RLC
	RLC	;(A)=(B)*8
	ADD	B	;.......*9
	JC	SYNERR
	ADD	B	;.......*10
	JC	SYNERR
	ADD	D	;add in new digit now.
DECODE2	JC	SYNERR
	MOV	B,A	;and save result.
	DCR	C	;only look at 11 digits.
	JNZ	DECODE1
	RET
DECODE3	MOV	A,M	;spaces must follow (why?).
	CPI	' '
	JNZ	SYNERR
	INX	H
DECODE4	DCR	C
	JNZ	DECODE3
	MOV	A,B	;set (A)=the numeric value entered.
	RET
;
;   Move 3 bytes from (HL) to (DE). Note that there is only
; one reference to this at (A2D5h).
;
MOVE3	MVI	B,3
;
;   Move (B) bytes from (HL) to (DE).
;
HL2DE	MOV	A,M
	STAX	D
	INX	H
	INX	D
	DCR	B
	JNZ	HL2DE
	RET
;
;   Compute (HL)=(TBUFF)+(A)+(C) and get the byte that's here.
;
EXTRACT	LXI	H,TBUFF
	ADD	C
	CALL	ADDHL
	MOV	A,M
	RET
;
;  Check drive specified. If it means a change, then the new
; drive will be selected. In any case, the drive byte of the
; fcb will be set to null (means use current drive).
;
DSELECT	XRA	A	;null out first byte of fcb.
	STA	FCB
	LDA	CHGDRV	;a drive change indicated?
	ORA	A
	RZ
	DCR	A	;yes, is it the same as the current drive?
	LXI	H,CDRIVE
	CMP	M
	RZ
	JMP	DSKSEL	;no. Select it then.
;
;   Check the drive selection and reset it to the previous
; drive if it was changed for the preceeding command.
;
RESETDR	LDA	CHGDRV	;drive change indicated?
	ORA	A
	RZ
	DCR	A	;yes, was it a different drive?
	LXI	H,CDRIVE
	CMP	M
	RZ
	LDA	CDRIVE	;yes, re-select our old drive.
	JMP	DSKSEL
;
;**************************************************************
;*
;*           D I R E C T O R Y   C O M M A N D
;*
;**************************************************************
;
DIRECT	CALL	CONVFST	;convert file name.
	CALL	DSELECT	;select indicated drive.
	LXI	H,FCB+1	;was any file indicated?
	MOV	A,M
	CPI	' '
	JNZ	DIRECT2
	MVI	B,11	;no. Fill field with '?' - same as *.*.
DIRECT1	MVI	M,'?'
	INX	H
	DCR	B
	JNZ	DIRECT1
DIRECT2	MVI	E,0	;set initial cursor position.
	PUSH	D
	CALL	SRCHFCB	;get first file name.
	CZ	NONE	;none found at all?
DIRECT3	JZ	DIRECT9	;terminate if no more names.
	LDA	RTNCODE	;get file's position in segment (0-3).
	RRC
	RRC
	RRC
	ANI	60H	;(A)=position*32
	MOV	C,A
	MVI	A,10
	CALL	EXTRACT	;extract the tenth entry in fcb.
	RAL		;check system file status bit.
	JC	DIRECT8	;we don't list them.
	POP	D
	MOV	A,E	;bump name count.
	INR	E
	PUSH	D
	ANI	03H	;at end of line?
	PUSH	PSW
	JNZ	DIRECT4
	CALL	CRLF	;yes, end this line and start another.
	PUSH	B
	CALL	GETDSK	;start line with ('A:').
	POP	B
	ADI	'A'
	CALL	PRINTB
	MVI	A,':'
	CALL	PRINTB
	JMP	DIRECT5
DIRECT4	CALL	SPACE	;add seperator between file names.
	MVI	A,':'
	CALL	PRINTB
DIRECT5	CALL	SPACE
	MVI	B,1	;'extract' each file name character at a time.
DIRECT6	MOV	A,B
	CALL	EXTRACT
	ANI	7FH	;strip bit 7 (status bit).
	CPI	' '	;are we at the end of the name?
	JNZ	DRECT65
	POP	PSW	;yes, don't print spaces at the end of a line.
	PUSH	PSW
	CPI	3
	JNZ	DRECT63
	MVI	A,9	;first check for no extension.
	CALL	EXTRACT
	ANI	7FH
	CPI	' '
	JZ	DIRECT7	;don't print spaces.
DRECT63	MVI	A,' '	;else print them.
DRECT65	CALL	PRINTB
	INR	B	;bump to next character psoition.
	MOV	A,B
	CPI	12	;end of the name?
	JNC	DIRECT7
	CPI	9	;nope, starting extension?
	JNZ	DIRECT6
	CALL	SPACE	;yes, add seperating space.
	JMP	DIRECT6
DIRECT7	POP	PSW	;get the next file name.
DIRECT8	CALL	CHKCON	;first check console, quit on anything.
	JNZ	DIRECT9
	CALL	SRCHNXT	;get next name.
	JMP	DIRECT3	;and continue with our list.
DIRECT9	POP	D	;restore the stack and return to command level.
	JMP	GETBACK
;
;**************************************************************
;*
;*                E R A S E   C O M M A N D
;*
;**************************************************************
;
ERASE	CALL	CONVFST	;convert file name.
	CPI	11	;was '*.*' entered?
	JNZ	ERASE1
	LXI	B,YESNO	;yes, ask for confirmation.
	CALL	PLINE
	CALL	GETINP
	LXI	H,INBUFF+1
	DCR	M	;must be exactly 'y'.
	JNZ	CMMND1
	INX	H
	MOV	A,M
	CPI	'Y'
	JNZ	CMMND1
	INX	H
	SHLD	INPOINT	;save input line pointer.
ERASE1	CALL	DSELECT	;select desired disk.
	LXI	D,FCB
	CALL	DELETE	;delete the file.
	INR	A
	CZ	NONE	;not there?
	JMP	GETBACK	;return to command level now.
YESNO	DB	'All (y/n)?',0
;
;**************************************************************
;*
;*            T Y P E   C O M M A N D
;*
;**************************************************************
;
TYPE	CALL	CONVFST	;convert file name.
	JNZ	SYNERR	;wild cards not allowed.
	CALL	DSELECT	;select indicated drive.
	CALL	OPENFCB	;open the file.
	JZ	TYPE5	;not there?
	CALL	CRLF	;ok, start a new line on the screen.
	LXI	H,NBYTES;initialize byte counter.
	MVI	M,0FFH	;set to read first sector.
TYPE1	LXI	H,NBYTES
TYPE2	MOV	A,M	;have we written the entire sector?
	CPI	128
	JC	TYPE3
	PUSH	H	;yes, read in the next one.
	CALL	READFCB
	POP	H
	JNZ	TYPE4	;end or error?
	XRA	A	;ok, clear byte counter.
	MOV	M,A
TYPE3	INR	M	;count this byte.
	LXI	H,TBUFF	;and get the (A)th one from the buffer (TBUFF).
	CALL	ADDHL
	MOV	A,M
	CPI	CNTRLZ	;end of file mark?
	JZ	GETBACK
	CALL	PRINT	;no, print it.
	CALL	CHKCON	;check console, quit if anything ready.
	JNZ	GETBACK
	JMP	TYPE1
;
;   Get here on an end of file or read error.
;
TYPE4	DCR	A	;read error?
	JZ	GETBACK
	CALL	RDERROR	;yes, print message.
TYPE5	CALL	RESETDR	;and reset proper drive
	JMP	SYNERR	;now print file name with problem.
;
;**************************************************************
;*
;*            S A V E   C O M M A N D
;*
;**************************************************************
;
SAVE	CALL	DECODE	;get numeric number that follows SAVE.
	PUSH	PSW	;save number of pages to write.
	CALL	CONVFST	;convert file name.
	JNZ	SYNERR	;wild cards not allowed.
	CALL	DSELECT	;select specified drive.
	LXI	D,FCB	;now delete this file.
	PUSH	D
	CALL	DELETE
	POP	D
	CALL	CREATE	;and create it again.
	JZ	SAVE3	;can't create?
	XRA	A	;clear record number byte.
	STA	FCB+32
	POP	PSW	;convert pages to sectors.
	MOV	L,A
	MVI	H,0
	DAD	H	;(HL)=number of sectors to write.
	LXI	D,TBASE	;and we start from here.
SAVE1	MOV	A,H	;done yet?
	ORA	L
	JZ	SAVE2
	DCX	H	;nope, count this and compute the start
	PUSH	H	;of the next 128 byte sector.
	LXI	H,128
	DAD	D
	PUSH	H	;save it and set the transfer address.
	CALL	DMASET
	LXI	D,FCB	;write out this sector now.
	CALL	WRTREC
	POP	D	;reset (DE) to the start of the last sector.
	POP	H	;restore sector count.
	JNZ	SAVE3	;write error?
	JMP	SAVE1
;
;   Get here after writing all of the file.
;
SAVE2	LXI	D,FCB	;now close the file.
	CALL	CLOSE
	INR	A	;did it close ok?
	JNZ	SAVE4
;
;   Print out error message (no space).
;
SAVE3	LXI	B,NOSPACE
	CALL	PLINE
SAVE4	CALL	STDDMA	;reset the standard dma address.
	JMP	GETBACK
NOSPACE	DB	'No space',0
;
;**************************************************************
;*
;*           R E N A M E   C O M M A N D
;*
;**************************************************************
;
RENAME	CALL	CONVFST	;convert first file name.
	JNZ	SYNERR	;wild cards not allowed.
	LDA	CHGDRV	;remember any change in drives specified.
	PUSH	PSW
	CALL	DSELECT	;and select this drive.
	CALL	SRCHFCB	;is this file present?
	JNZ	RENAME6	;yes, print error message.
	LXI	H,FCB	;yes, move this name into second slot.
	LXI	D,FCB+16
	MVI	B,16
	CALL	HL2DE
	LHLD	INPOINT	;get input pointer.
	XCHG
	CALL	NONBLANK;get next non blank character.
	CPI	'='	;only allow an '=' or '_' seperator.
	JZ	RENAME1
	CPI	'_'
	JNZ	RENAME5
RENAME1	XCHG
	INX	H	;ok, skip seperator.
	SHLD	INPOINT	;save input line pointer.
	CALL	CONVFST	;convert this second file name now.
	JNZ	RENAME5	;again, no wild cards.
	POP	PSW	;if a drive was specified, then it
	MOV	B,A	;must be the same as before.
	LXI	H,CHGDRV
	MOV	A,M
	ORA	A
	JZ	RENAME2
	CMP	B
	MOV	M,B
	JNZ	RENAME5	;they were different, error.
RENAME2	MOV	M,B;	reset as per the first file specification.
	XRA	A
	STA	FCB	;clear the drive byte of the fcb.
RENAME3	CALL	SRCHFCB	;and go look for second file.
	JZ	RENAME4	;doesn't exist?
	LXI	D,FCB
	CALL	RENAM	;ok, rename the file.
	JMP	GETBACK
;
;   Process rename errors here.
;
RENAME4	CALL	NONE	;file not there.
	JMP	GETBACK
RENAME5	CALL	RESETDR	;bad command format.
	JMP	SYNERR
RENAME6	LXI	B,EXISTS;destination file already exists.
	CALL	PLINE
	JMP	GETBACK
EXISTS	DB	'File exists',0
;
;**************************************************************
;*
;*             U S E R   C O M M A N D
;*
;**************************************************************
;
USER	CALL	DECODE	;get numeric value following command.
	CPI	16	;legal user number?
	JNC	SYNERR
	MOV	E,A	;yes but is there anything else?
	LDA	FCB+1
	CPI	' '
	JZ	SYNERR	;yes, that is not allowed.
	CALL	GETSETUC;ok, set user code.
	JMP	GETBACK1
;
;**************************************************************
;*
;*        T R A N S I A N T   P R O G R A M   C O M M A N D
;*
;**************************************************************
;
UNKNOWN	CALL	VERIFY	;check for valid system (why?).
	LDA	FCB+1	;anything to execute?
	CPI	' '
	JNZ	UNKWN1
	LDA	CHGDRV	;nope, only a drive change?
	ORA	A
	JZ	GETBACK1;neither???
	DCR	A
	STA	CDRIVE	;ok, store new drive.
	CALL	MOVECD	;set (TDRIVE) also.
	CALL	DSKSEL	;and select this drive.
	JMP	GETBACK1;then return.
;
;   Here a file name was typed. Prepare to execute it.
;
UNKWN1	LXI	D,FCB+9	;an extension specified?
	LDAX	D
	CPI	' '
	JNZ	SYNERR	;yes, not allowed.
UNKWN2	PUSH	D
	CALL	DSELECT	;select specified drive.
	POP	D
	LXI	H,COMFILE	;set the extension to 'COM'.
	CALL	MOVE3
	CALL	OPENFCB	;and open this file.
	JZ	UNKWN9	;not present?
;
;   Load in the program.
;
	LXI	H,TBASE	;store the program starting here.
UNKWN3	PUSH	H
	XCHG
	CALL	DMASET	;set transfer address.
	LXI	D,FCB	;and read the next record.
	CALL	RDREC
	JNZ	UNKWN4	;end of file or read error?
	POP	H	;nope, bump pointer for next sector.
	LXI	D,128
	DAD	D
	LXI	D,CBASE	;enough room for the whole file?
	MOV	A,L
	SUB	E
	MOV	A,H
	SBB	D
	JNC	UNKWN0	;no, it can't fit.
	JMP	UNKWN3
;
;   Get here after finished reading.
;
UNKWN4	POP	H
	DCR	A	;normal end of file?
	JNZ	UNKWN0
	CALL	RESETDR	;yes, reset previous drive.
	CALL	CONVFST	;convert the first file name that follows
	LXI	H,CHGDRV;command name.
	PUSH	H
	MOV	A,M	;set drive code in default fcb.
	STA	FCB
	MVI	A,16	;put second name 16 bytes later.
	CALL	CONVERT	;convert second file name.
	POP	H
	MOV	A,M	;and set the drive for this second file.
	STA	FCB+16
	XRA	A	;clear record byte in fcb.
	STA	FCB+32
	LXI	D,TFCB	;move it into place at(005Ch).
	LXI	H,FCB
	MVI	B,33
	CALL	HL2DE
	LXI	H,INBUFF+2;now move the remainder of the input
UNKWN5	MOV	A,M	;line down to (0080h). Look for a non blank.
	ORA	A	;or a null.
	JZ	UNKWN6
	CPI	' '
	JZ	UNKWN6
	INX	H
	JMP	UNKWN5
;
;   Do the line move now. It ends in a null byte.
;
UNKWN6	MVI	B,0	;keep a character count.
	LXI	D,TBUFF+1;data gets put here.
UNKWN7	MOV	A,M	;move it now.
	STAX	D
	ORA	A
	JZ	UNKWN8
	INR	B
	INX	H
	INX	D
	JMP	UNKWN7
UNKWN8	MOV	A,B	;now store the character count.
	STA	TBUFF
	CALL	CRLF	;clean up the screen.
	CALL	STDDMA	;set standard transfer address.
	CALL	SETCDRV	;reset current drive.
	CALL	TBASE	;and execute the program.
;
;   Transiant programs return here (or reboot).
;
	LXI	SP,BATCH	;set stack first off.
	CALL	MOVECD	;move current drive into place (TDRIVE).
	CALL	DSKSEL	;and reselect it.
	JMP	CMMND1	;back to comand mode.
;
;   Get here if some error occured.
;
UNKWN9	CALL	RESETDR	;inproper format.
	JMP	SYNERR
UNKWN0	LXI	B,BADLOAD;read error or won't fit.
	CALL	PLINE
	JMP	GETBACK
BADLOAD	DB	'Bad load',0
COMFILE	DB	'COM'	;command file extension.
;
;   Get here to return to command level. We will reset the
; previous active drive and then either return to command
; level directly or print error message and then return.
;
GETBACK	CALL	RESETDR	;reset previous drive.
GETBACK1:CALL	CONVFST	;convert first name in (FCB).
	LDA	FCB+1	;if this was just a drive change request,
	SUI	' '	;make sure it was valid.
	LXI	H,CHGDRV
	ORA	M
	JNZ	SYNERR
	JMP	CMMND1	;ok, return to command level.
;
;   ccp stack area.
;
	DB	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
CCPSTACK:EQU	$	;end of ccp stack area.
;
;   Batch (or SUBMIT) processing information storage.
;
BATCH	DB	0	;batch mode flag (0=not active).
BATCHFCB:DB	0,'$$$     SUB',0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
;
;   File control block setup by the CCP.
;
FCB	DB	0,'           ',0,0,0,0,0,'           ',0,0,0,0,0
RTNCODE	DB	0	;status returned from bdos call.
CDRIVE	DB	0	;currently active drive.
CHGDRV	DB	0	;change in drives flag (0=no change).
NBYTES	DW	0	;byte counter used by TYPE.
;
;   Room for expansion?
;
	DB	0,0,0,0,0,0,0,0,0,0,0,0,0
;
;   Note that the following six bytes must match those at
; (PATTRN1) or cp/m will HALT. Why?
;
PATTRN2	DB	0,22,0,0,0,0;(* serial number bytes *).
;
;**************************************************************
;*
;*                    B D O S   E N T R Y
;*
;**************************************************************
;
FBASE	JMP	FBASE1
;
;   Bdos error table.
;
BADSCTR	DW	ERROR1	;bad sector on read or write.
BADSLCT	DW	ERROR2	;bad disk select.
RODISK	DW	ERROR3	;disk is read only.
ROFILE	DW	ERROR4	;file is read only.
;
;   Entry into bdos. (DE) or (E) are the parameters passed. The
; function number desired is in register (C).
;
FBASE1	XCHG		;save the (DE) parameters.
	SHLD	PARAMS
	XCHG
	MOV	A,E	;and save register (E) in particular.
	STA	EPARAM
	LXI	H,0
	SHLD	STATUS	;clear return status.
	DAD	SP
	SHLD	USRSTACK;save users stack pointer.
	LXI	SP,STKAREA;and set our own.
	XRA	A	;clear auto select storage space.
	STA	AUTOFLAG
	STA	AUTO
	LXI	H,GOBACK;set return address.
	PUSH	H
	MOV	A,C	;get function number.
	CPI	NFUNCTS	;valid function number?
	RNC
	MOV	C,E	;keep single register function here.
	LXI	H,FUNCTNS;now look thru the function table.
	MOV	E,A
	MVI	D,0	;(DE)=function number.
	DAD	D
	DAD	D	;(HL)=(start of table)+2*(function number).
	MOV	E,M
	INX	H
	MOV	D,M	;now (DE)=address for this function.
	LHLD	PARAMS	;retrieve parameters.
	XCHG		;now (DE) has the original parameters.
	PCHL		;execute desired function.
;
;   BDOS function jump table.
;
NFUNCTS	EQU	41	;number of functions in followin table.
;
FUNCTNS	DW	WBOOT,GETCON,OUTCON,GETRDR,PUNCH,LIST,DIRCIO,GETIOB
	DW	SETIOB,PRTSTR,RDBUFF,GETCSTS,GETVER,RSTDSK,SETDSK,OPENFIL
	DW	CLOSEFIL,GETFST,GETNXT,DELFILE,READSEQ,WRTSEQ,FCREATE
	DW	RENFILE,GETLOG,GETCRNT,PUTDMA,GETALOC,WRTPRTD,GETROV,SETATTR
	DW	GETPARM,GETUSER,RDRANDOM,WTRANDOM,FILESIZE,SETRAN,LOGOFF,RTN
	DW	RTN,WTSPECL
;
;   Bdos error message section.
;
ERROR1	LXI	H,BADSEC	;bad sector message.
	CALL	PRTERR	;print it and get a 1 char responce.
	CPI	CNTRLC	;re-boot request (control-c)?
	JZ	0	;yes.
	RET		;no, return to retry i/o function.
;
ERROR2	LXI	H,BADSEL	;bad drive selected.
	JMP	ERROR5
;
ERROR3	LXI	H,DISKRO	;disk is read only.
	JMP	ERROR5
;
ERROR4	LXI	H,FILERO	;file is read only.
;
ERROR5	CALL	PRTERR
	JMP	0	;always reboot on these errors.
;
BDOSERR	DB	'Bdos Err On '
BDOSDRV	DB	' : $'
BADSEC	DB	'Bad Sector$'
BADSEL	DB	'Select$'
FILERO	DB	'File '
DISKRO	DB	'R/O$'
;
;   Print bdos error message.
;
PRTERR	PUSH	H	;save second message pointer.
	CALL	OUTCRLF	;send (cr)(lf).
	LDA	ACTIVE	;get active drive.
	ADI	'A'	;make ascii.
	STA	BDOSDRV	;and put in message.
	LXI	B,BDOSERR;and print it.
	CALL	PRTMESG
	POP	B	;print second message line now.
	CALL	PRTMESG
;
;   Get an input character. We will check our 1 character
; buffer first. This may be set by the console status routine.
;
GETCHAR	LXI	H,CHARBUF;check character buffer.
	MOV	A,M	;anything present already?
	MVI	M,0	;...either case clear it.
	ORA	A
	RNZ		;yes, use it.
	JMP	CONIN	;nope, go get a character responce.
;
;   Input and echo a character.
;
GETECHO	CALL	GETCHAR	;input a character.
	CALL	CHKCHAR	;carriage control?
	RC		;no, a regular control char so don't echo.
	PUSH	PSW	;ok, save character now.
	MOV	C,A
	CALL	OUTCON	;and echo it.
	POP	PSW	;get character and return.
	RET
;
;   Check character in (A). Set the zero flag on a carriage
; control character and the carry flag on any other control
; character.
;
CHKCHAR	CPI	CR	;check for carriage return, line feed, backspace,
	RZ		;or a tab.
	CPI	LF
	RZ
	CPI	TAB
	RZ
