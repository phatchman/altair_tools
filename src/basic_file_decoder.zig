//! Decodes encoded Altair Disk Basic files to plain text files.
//! The file has a header of 0xff
//! Then next 2 bytes are the line number or 0x0000 for EOF
//! The file is then read character by character and processed until 0x00 which indicated end of line.

const log = std.log.scoped(.altair_disk_lib);
// Don't log errors during fuzz testing.
const logerr = if (@import("builtin").fuzz) log.info else log.err;

// Convert ascii basic files into a form that the basic interpreter can read.
// does not encode into altair / ms basic format. it keeps the file as ascii.
pub const BasicTextFileReader = struct {
    const State = enum { start, line, end_line, done };
    const ReadError = error{ ReadFailed, StreamTooLong };

    source: *std.Io.Reader,
    state: State = .start,
    cr_ending: bool = false,
    pending: []const u8 = &.{},
    eol_buf: [2]u8 = .{ '\r', '\n' },
    err: ?ReadError = null,
    interface: std.Io.Reader,

    pub fn init(source: *std.Io.Reader, buffer: []u8) BasicTextFileReader {
        return .{
            .source = source,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn fillIfEmpty(self: *BasicTextFileReader) error{ReadFailed}!void {
        self.err = null;
        if (self.pending.len != 0 or self.state == .done) return;
        switch (self.state) {
            .start => {
                // BASIC steals the first char of the file
                self.pending = " ";
                self.state = .line;
            },
            .line => {
                const slice = self.source.takeDelimiter('\n') catch |e| {
                    self.err = e;
                    return error.ReadFailed;
                } orelse {
                    self.state = .done;
                    return;
                };
                if (slice.len == 0) {
                    self.state = .done;
                    return;
                }
                self.cr_ending = slice[slice.len - 1] == '\r';
                self.pending = slice;
                self.state = .end_line;
            },
            .end_line => {
                if (self.cr_ending) {
                    // add the \n
                    self.pending = self.eol_buf[1..2];
                } else {
                    // add the \r\n
                    self.pending = self.eol_buf[0..2];
                }
                self.state = .line;
            },
            .done => unreachable,
        }
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *BasicTextFileReader = @fieldParentPtr("interface", r);
        try self.fillIfEmpty();
        if (self.pending.len == 0) return error.EndOfStream;
        const n = limit.minInt(self.pending.len);
        try w.writeAll(self.pending[0..n]);
        self.pending = self.pending[n..];
        return n;
    }
};

pub fn decode(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const header = try reader.takeByte();
    if (header != 0xff) {
        return error.InvalidFormat;
    }

    const eof: bool = false;
    while (!eof) {
        const link_bytes = try reader.takeInt(u16, .little);
        // link to next line is 0x0000 for EOF.
        if (link_bytes == 0) break;

        const line_nr: u16 = try reader.takeInt(u16, .little);
        try writer.print("{} ", .{line_nr});
        while (true) {
            try writer.flush();
            try switch (try reader.takeByte()) {
                0x00 => {
                    const end_file = try reader.peekInt(u16, .little) == 0;
                    if (!end_file)
                        try writer.print("\n", .{});
                    break;
                },
                0x0E => {
                    const reference: u16 = try reader.takeInt(u16, .little);
                    try writer.print("{d}", .{reference});
                },
                0x0B => {
                    const val = try reader.takeInt(u16, .little);
                    try writer.print("&O{o}", .{val});
                },
                0x0C => {
                    const val = try reader.takeInt(u16, .little);
                    try writer.print("&H{X}", .{val});
                },
                0x0F => {
                    const val = try reader.takeByte();
                    try writer.print("{d}", .{val});
                },
                0x1C => {
                    const val = try reader.takeInt(u16, .little);
                    try writer.print("{d}", .{val});
                },
                0x1D => {
                    const raw: u32 = try reader.takeInt(u32, .little);
                    try writer.print("{f}", .{floatSingle(raw)});
                },
                0x1F => {
                    const raw = try reader.takeInt(u64, .little);
                    try writer.print("{f}", .{floatDouble(raw)});
                },
                0x11...0x1A => |val| try writer.print("{d}", .{val - 0x11}), // small integer: value = byte - 0x11
                0x80 => |tok| return unhandledToken(tok),
                0x81 => writer.print("END", .{}),
                0x82 => writer.print("FOR", .{}),
                0x83 => writer.print("NEXT", .{}),
                0x84 => writer.print("DATA", .{}),
                0x85 => writer.print("INPUT", .{}),
                0x86 => writer.print("DIM", .{}),
                0x87 => writer.print("READ", .{}),
                0x88 => writer.print("LET", .{}),
                0x89 => writer.print("GOTO", .{}),
                0x8A => writer.print("RUN", .{}),
                0x8B => writer.print("IF", .{}),
                0x8C => writer.print("RESTORE", .{}),
                0x8D => writer.print("GOSUB", .{}),
                0x8E => writer.print("RETURN", .{}),
                0x8F => writer.print("REM", .{}),
                0x90 => writer.print("STOP", .{}),
                0x91 => writer.print("PRINT", .{}),
                0x92 => writer.print("CLEAR", .{}),
                0x93 => writer.print("LIST", .{}),
                0x94 => writer.print("NEW", .{}),
                0x95 => writer.print("ON", .{}),
                0x96 => writer.print("NULL", .{}),
                0x97 => writer.print("WAIT", .{}),
                0x98 => writer.print("DEF", .{}),
                0x99 => writer.print("POKE", .{}),
                0x9A => writer.print("CONT", .{}),
                0x9B => |tok| return unhandledToken(tok),
                0x9C => |tok| return unhandledToken(tok),
                0x9D => writer.print("OUT", .{}),
                0x9E => writer.print("LPRINT", .{}),
                0x9F => writer.print("LLIST", .{}),
                0xA0 => writer.print("CONSOLE", .{}),
                0xA1 => writer.print("WIDTH", .{}),
                0xA2 => writer.print("ELSE", .{}),
                0xA3 => writer.print("TRON", .{}),
                0xA4 => writer.print("TROFF", .{}),
                0xA5 => writer.print("SWAP", .{}),
                0xA6 => writer.print("ERASE", .{}),
                0xA7 => writer.print("EDIT", .{}),
                0xA8 => writer.print("ERROR", .{}),
                0xA9 => writer.print("RESUME", .{}),
                0xAA => writer.print("DELETE", .{}),
                0xAB => writer.print("AUTO", .{}),
                0xAC => writer.print("RENUM", .{}),
                0xAD => writer.print("DEFSTR", .{}),
                0xAE => writer.print("DEFINT", .{}),
                0xAF => writer.print("DEFSNG", .{}),
                0xB0 => writer.print("DEFDBL", .{}),
                0xB1 => writer.print("LINE", .{}),
                0xB2...0xBB => |tok| return unhandledToken(tok),
                0xBC => writer.print("DSKO$", .{}),
                0xBD => writer.print("UNLOAD", .{}),
                0xBE => writer.print("MOUNT", .{}),
                0xBF => writer.print("OPEN", .{}),
                0xC0 => writer.print("FIELD", .{}),
                0xC1 => writer.print("GET", .{}),
                0xC2 => writer.print("PUT", .{}),
                0xC3 => writer.print("CLOSE", .{}),
                0xC4 => writer.print("LOAD", .{}),
                0xC5 => writer.print("MERGE", .{}),
                0xC6 => writer.print("FILES", .{}),
                0xC7 => writer.print("NAME", .{}),
                0xC8 => writer.print("KILL", .{}),
                0xC9 => writer.print("LSET", .{}),
                0xCA => writer.print("RSET", .{}),
                0xCB => writer.print("SAVE", .{}),
                0xCC => |tok| return unhandledToken(tok),
                0xCD => |tok| return unhandledToken(tok),
                0xCE => writer.print("TO", .{}),
                0xCF => writer.print("THEN", .{}),
                0xD0 => writer.print("TAB(", .{}),
                0xD1 => writer.print("STEP", .{}),
                0xD2 => writer.print("USR", .{}),
                0xD3 => writer.print("FN", .{}),
                0xD4 => writer.print("SPC(", .{}),
                0xD5 => writer.print("NOT", .{}),
                0xD6 => writer.print("ERL", .{}),
                0xD7 => writer.print("ERR", .{}),
                0xD8 => writer.print("STRING$", .{}),
                0xD9 => writer.print("USING", .{}),
                0xDA => writer.print("INSTR", .{}),
                0xDB => writer.print("'", .{}),
                0xDC => writer.print("VARPTR", .{}),
                0xDD...0xEE => |tok| return unhandledToken(tok),
                0xEF => writer.print(">", .{}),
                0xF0 => writer.print("=", .{}),
                0xF1 => writer.print("<", .{}),
                0xF2 => writer.print("+", .{}),
                0xF3 => writer.print("-", .{}),
                0xF4 => writer.print("*", .{}),
                0xF5 => writer.print("/", .{}),
                0xF6 => writer.print("^", .{}),
                0xF7 => writer.print("AND", .{}),
                0xF8 => writer.print("OR", .{}),
                0xF9 => writer.print("XOR", .{}),
                0xFA => writer.print("EQV", .{}),
                0xFB => writer.print("IMP", .{}),
                0xFC => writer.print("MOD", .{}),
                0xFD => writer.print("\\", .{}),
                0xFE => |tok| return unhandledToken(tok),
                0xFF => {
                    try switch (try reader.takeByte()) {
                        0x81 => writer.print("LEFT$", .{}),
                        0x82 => writer.print("RIGHT$", .{}),
                        0x83 => writer.print("MID$", .{}),
                        0x84 => writer.print("SGN", .{}),
                        0x85 => writer.print("INT", .{}),
                        0x86 => writer.print("ABS", .{}),
                        0x87 => writer.print("SQR", .{}),
                        0x88 => writer.print("RND", .{}),
                        0x89 => writer.print("SIN", .{}),
                        0x8A => writer.print("LOG", .{}),
                        0x8B => writer.print("EXP", .{}),
                        0x8C => writer.print("COS", .{}),
                        0x8D => writer.print("TAN", .{}),
                        0x8E => writer.print("ATN", .{}),
                        0x8F => writer.print("FRE", .{}),
                        0x90 => writer.print("INP", .{}),
                        0x91 => writer.print("POS", .{}),
                        0x92 => writer.print("LEN", .{}),
                        0x93 => writer.print("STR$", .{}),
                        0x94 => writer.print("VAL", .{}),
                        0x95 => writer.print("ASC", .{}),
                        0x96 => writer.print("CHR$", .{}),
                        0x97 => writer.print("PEEK", .{}),
                        0x98 => writer.print("SPACE$", .{}),
                        0x99 => writer.print("OCT$", .{}),
                        0x9A => writer.print("HEX$", .{}),
                        0x9B => writer.print("LPOS", .{}),
                        0x9C => writer.print("CINT", .{}),
                        0x9D => writer.print("CSNG", .{}),
                        0x9E => writer.print("CDBL", .{}),
                        0x9F => writer.print("FIX", .{}),
                        0xAA => writer.print("DSKI$", .{}),
                        0xAB => writer.print("CVI", .{}),
                        0xAC => writer.print("CVS", .{}),
                        0xAD => writer.print("CVD", .{}),
                        0xAF => writer.print("EOF", .{}),
                        0xB0 => writer.print("LOC", .{}),
                        0xB2 => writer.print("MKI$", .{}),
                        0xB3 => writer.print("MKS$", .{}),
                        0xB4 => writer.print("MKD$", .{}),
                        else => |tok| return unhandledToken(tok),
                    };
                },
                ':' => {
                    switch (try reader.peekByte()) {
                        0xA2 => {}, // suppress printing ":" on ELSE
                        0x8F => { // REM
                            const next: u16 = try reader.peekInt(u16, .little);
                            if (next >> 8 == 0xDB) {
                                // collapse `:REM'` into `'`
                                _ = try reader.discardAll(2);
                                try writer.print("'", .{});
                            } else {
                                try writer.print(":", .{});
                            }
                        },
                        else => try writer.print(":", .{}),
                    }
                },
                else => |ch| writer.print("{c}", .{ch}),
            };
        }
    }
}

fn unhandledToken(token: u8) error{InvalidToken}!void {
    logerr("Unknown token encountered while decoding BASIC file: {x}", .{token});
    return error.InvalidToken;
}

test "decoder" {
    const input_program = @embedFile("test_disks/test.bin");
    var output_program =
        \\10 REM *** DECODER TOKEN COVERAGE ***
        \\20 A=0:B=1:C=2:D=3:E=4:F=5:G=6:H=7:I=8:J=9
        \\30 K=100:L=255:M=256:N=30000
        \\40 O=&O17:P=&H1F:Q=&HABCD
        \\50 R=1.5:S=1.5#
        \\60 T=1+2-3*4/5^6\7
        \\70 U=8 MOD 9:V=1 AND 2:W=3 OR 4:X=5 XOR 6
        \\80 Y=A EQV B:Z=9 IMP 1:AA=NOT 2
        \\90 IF A<B THEN 110 ELSE 100
        \\100 IF A>B THEN PRINT"GT"
        \\110 IF A=B THEN STOP
        \\112 END
        \\113 IF A<=B THEN PRINT"LE"
        \\114 IF A>=B THEN PRINT"GE"
        \\115 IF A<>B THEN PRINT"NE"
        \\116 LLIST
        \\120 FOR I=1 TO 10 STEP 2:NEXT I
        \\130 DIM AR(5):AR(1)=1:ERASE AR
        \\140 DATA 1,2,3:READ DA,DB,DC:RESTORE
        \\150 LET LV=5:GOTO 170
        \\160 GOSUB 600
        \\170 ON A GOTO 100,110,120
        \\180 ON A GOSUB 600,600
        \\190 DEFINT W:DEFSNG X:DEFDBL Y:DEFSTR Z
        \\200 INPUT IV:LPRINT IV
        \\210 POKE 1,2:OUT 3,4:WAIT 5,6,7
        \\220 GX=PEEK(8):WIDTH 80:NULL 1
        \\230 CONSOLE 0,23,0,1:TRON:TROFF
        \\240 SWAP A,B:CLEAR
        \\245 XR=1:REM MID-LINE REM TEST
        \\246 YR=2::ZR=3
        \\247 NV=-5:RL!=2.5:IX%=7
        \\248 WA=&H8F91:WB=&O77777:WC=32655
        \\249 NF=-1.5
        \\250 DEF FNX(NV)=NV*2:FX=FNX(3)
        \\260 HX=USR(0):POKE VARPTR(A),0
        \\270 ON ERROR GOTO 290:ERROR 5
        \\280 RESUME 300
        \\290 PRINT ERL;ERR
        \\300 PRINT TAB(5);"A";SPC(3);"B"
        \\310 PRINT USING"##.#";R
        \\320 PRINT NOT A;A MOD B
        \\330 PRINT SGN(1);INT(1.5);ABS(-2);SQR(4);RND(1);FIX(2.5)
        \\340 PRINT SIN(0);COS(0);TAN(0);ATN(1);LOG(2);EXP(1)
        \\350 PRINT FRE(0);POS(0);LPOS(0);INP(1)
        \\360 PRINT LEN("AB");STR$(5);VAL("12");ASC("A");CHR$(65)
        \\370 PRINT LEFT$("AB",1);RIGHT$("AB",1);MID$("ABC",2,1)
        \\380 PRINT SPACE$(2);STRING$(3,"*");INSTR("ABC","B")
        \\390 PRINT OCT$(8);HEX$(255)
        \\400 PRINT CINT(1.5);CSNG(1.5#);CDBL(1.5)
        \\410 OPEN"R",1,"DATA",128:FIELD#1,10 AS FA$
        \\420 LSET FA$="X":RSET FA$="Y":PUT#1,1:GET#1,1
        \\430 PRINT LOC(1);EOF(1)
        \\440 CI=CVI("AB"):CS=CVS("ABCD"):CD=CVD("ABCDEFGH")
        \\450 MA$=MKI$(1):MB$=MKS$(1.5):MC$=MKD$(1.5#)
        \\455 DATA PRINT,GOTO,FOR
        \\460 CLOSE#1:NAME"A"AS"B":KILL"B"
        \\470 LINE INPUT LI$
        \\480 'LEADING APOSTROPHE COMMENT
        \\490 ZZ=1 'TRAILING APOSTROPHE
        \\500 PRINT"TAB`HERE"
        \\510 RUN 600
        \\520 CONT
        \\530 NEW
        \\540 SAVE"X"
        \\550 LOAD"X"
        \\560 MERGE"X"
        \\570 FILES"*.*"
        \\580 MOUNT 0
        \\590 UNLOAD 0
        \\595 DK$=DSKI$(0,0,1)
        \\596 DSKO$ A$,1
        \\600 RETURN
        \\700 LIST
        \\710 EDIT 10
        \\720 AUTO 100,10
        \\730 RENUM 1000,10,10
        \\740 DELETE 700
        \\800 PRINT"BEL@END"
        \\860 X=1: 
        \\970 PRINT "a
        \\b"
    .*;
    // NOTE: The characters ` and @ are replaced with control chars.
    std.mem.replaceScalar(u8, &output_program, '`', '\t');
    std.mem.replaceScalar(u8, &output_program, '@', 0x07);

    var in: std.Io.Reader = .fixed(input_program);
    var out_buf: [output_program.len * 2]u8 = undefined; // Only * 2 in case the decoder output fails by outputting too many chars.
    var out: std.Io.Writer = .fixed(&out_buf);

    try decode(&in, &out);
    try std.testing.expectEqualStrings(&output_program, out.buffered());
}

const crash = @embedFile("crash");

test "fuzz decoder" {
    try std.testing.fuzz({}, randomData, .{});
    //    try std.testing.fuzz({}, randomData, .{ .corpus = &.{crash} });
}

fn randomData(_: void, smith: *std.testing.Smith) !void {
    var program: [512]u8 = undefined;
    var out_buf: [512 * 4]u8 = undefined;
    const len = smith.slice(&program);
    var reader: std.Io.Reader = .fixed(program[0..len]);
    var writer: std.Io.Writer = .fixed(&out_buf);
    decode(&reader, &writer) catch |err| switch (err) {
        error.WriteFailed, error.ReadFailed => return err,
        error.EndOfStream, error.InvalidToken, error.InvalidFormat => {},
    };
}

// Microsoft Binary Format (MBF) floating point
//
// Single precision  — token 0x1D, 4 bytes
//   bits 31..24  exponent+128; 0 here means the whole number is 0.0
//   bit  23      sign; 1 = negative
//   bits 22..0   mantissa fraction, 23 bits; actually 24 bit, but high bit is alwasy 1 so not stored
//   value = mantissa * 2^(exp - 128 - 24)
fn formatFloatSingle(raw: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const exp: u8 = @intCast(raw >> 24);
    const negative: bool = (raw & 0x00800000) != 0;
    const neg_sign = if (negative) "-" else "";

    if (exp == 0) {
        try w.print("{s}0!", .{neg_sign});
        return;
    }

    const mantissa: u32 = (raw | 0x00800000) & 0x00FFFFFF;
    const value: f64 = std.math.ldexp(@as(f64, @floatFromInt(mantissa)), @as(i32, exp) - 128 - 24);
    const log_scale = 5.0 - @floor(std.math.log10(value));
    const scale = std.math.pow(f64, 10.0, log_scale);

    var sci_exp: i32 = 5 - @as(i32, @intFromFloat(log_scale));
    var six_sig_figures: u32 = @intFromFloat(@abs(@round(value * scale)));
    if (six_sig_figures >= 1_000_000) {
        six_sig_figures /= 10;
        sci_exp += 1;
    }

    const pad_buf: [7]u8 = @splat('0');

    if (sci_exp >= 6 or sci_exp <= -3) {
        const mantissa_int = six_sig_figures / 100_000;
        var mantissa_dec = six_sig_figures % 100_000;
        var mantissa_dec_places: u32 = 5;
        while (mantissa_dec_places != 0 and mantissa_dec % 10 == 0 and mantissa_dec != 0) {
            mantissa_dec /= 10;
            mantissa_dec_places -= 1;
        }
        const exp_sign: []const u8 = if (sci_exp >= 0) "+" else "-";
        const exp_abs: u32 = @intCast(@abs(sci_exp));
        if (mantissa_dec == 0) {
            try w.print("{s}{d}E{s}{d:0>2}", .{ neg_sign, mantissa_int, exp_sign, exp_abs });
        } else {
            const dec_pad_len = mantissa_dec_places -| std.fmt.count("{d}", .{mantissa_dec});
            try w.print("{s}{d}.{s}{d}E{s}{d:0>2}", .{ neg_sign, mantissa_int, pad_buf[0..dec_pad_len], mantissa_dec, exp_sign, exp_abs });
        }
    } else {
        const int_part: f64 = @trunc(value);
        var dec_part: f64 = @round((value - int_part) * scale);
        var decimal_places: u32 = @intFromFloat(@max(log_scale, 0));
        while (decimal_places != 0 and @mod(dec_part, 10) == 0 and dec_part != 0) {
            dec_part /= 10;
            decimal_places -= 1;
        }
        const pad_len = decimal_places -| std.fmt.count("{d}", .{dec_part});
        if (int_part == 0 and dec_part == 0) {
            try w.print("{s}0", .{neg_sign});
        } else if (int_part == 0) {
            try w.print("{s}.{s}{d}", .{ neg_sign, pad_buf[0..pad_len], dec_part });
        } else if (dec_part == 0) {
            try w.print("{s}{d}!", .{ neg_sign, int_part });
        } else {
            try w.print("{s}{d}.{s}{d}", .{ neg_sign, int_part, pad_buf[0..pad_len], dec_part });
        }
    }
}

pub fn floatSingle(raw: u32) std.fmt.Alt(u32, formatFloatSingle) {
    return .{ .data = raw };
}

test "single precision format" {
    var buf: [32]u8 = undefined;
    for (sng_cases) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{f}", .{floatSingle(case.val)});
        try std.testing.expectEqualStrings(case.expected, w.buffered());
    }
}

// Microsoft Binary Format (MBF) floating point
//
// Double precision  — token 0x1F, 8 byte
//   bits 63..56  exponent + 128; 0 here means the whole number is 0.0
//   bit  55      sign; 1 = negative
//   bits 54..0   mantissa fraction, 55 bits; where 56th bit always assumed to be 1
//   value = mantissa * 2^(exp - 128 - 56)
fn formatFloatDouble(raw: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const exp: u8 = @intCast(raw >> 56);
    const negative: bool = (raw & 0x0080000000000000) != 0;
    const neg_sign = if (negative) "-" else "";

    if (exp == 0) {
        try w.print("{s}0#", .{neg_sign});
        return;
    }

    const mantissa: u64 = (raw | 0x0080000000000000) & 0x00FFFFFFFFFFFFFF;
    const value: f128 = std.math.ldexp(@as(f128, @floatFromInt(mantissa)), @as(i32, exp) - 128 - 56);
    const log_scale: f128 = 15.0 - @floor(std.math.log10(value));
    const scale: f64 = std.math.pow(f64, 10.0, @floatCast(log_scale));

    var sci_exp: i32 = 15 - @as(i32, @intFromFloat(log_scale));
    var sixteen_sig: u64 = @intFromFloat(@abs(@round(value * scale)));

    if (sixteen_sig >= 10_000_000_000_000_000) {
        sixteen_sig /= 10;
        sci_exp += 1;
    }
    // This works around a boundary issue where log10(9999999999999996) gives 16, rather than 15.999999....
    // The precision is fine for 14 and below. At 15 and above the sci_exp will be 1 too large.
    // pow10 isn't implemented for f128, so we need to loop instead
    if (sci_exp >= 16) {
        var threshold: f128 = 1;
        for (0..@intCast(sci_exp)) |_| threshold *= 10;
        if (value < threshold) {
            sci_exp -= 1;
            sixteen_sig *= 10;
        }
    }

    const pad_buf: [16]u8 = @splat('0');

    if (sci_exp >= 16 or sci_exp <= -3) {
        const mantissa_int = sixteen_sig / 1_000_000_000_000_000;
        var mantissa_dec = sixteen_sig % 1_000_000_000_000_000;
        var mantissa_dec_places: u32 = 15;
        while (mantissa_dec_places != 0 and mantissa_dec % 10 == 0 and mantissa_dec != 0) {
            mantissa_dec /= 10;
            mantissa_dec_places -= 1;
        }
        const exp_sign: []const u8 = if (sci_exp >= 0) "+" else "-";
        const exp_abs: u32 = @intCast(@abs(sci_exp));
        if (mantissa_dec == 0) {
            try w.print("{s}{d}D{s}{d:0>2}", .{ neg_sign, mantissa_int, exp_sign, exp_abs });
        } else {
            const dec_pad_len = mantissa_dec_places -| std.fmt.count("{d}", .{mantissa_dec});
            try w.print("{s}{d}.{s}{d}D{s}{d:0>2}", .{ neg_sign, mantissa_int, pad_buf[0..dec_pad_len], mantissa_dec, exp_sign, exp_abs });
        }
    } else {
        const int_part: f128 = @trunc(value);
        var dec_part: f128 = @round((value - int_part) * @as(f128, scale));
        var decimal_places: u32 = @intFromFloat(@max(log_scale, 0));
        while (decimal_places != 0 and @mod(dec_part, 10) == 0 and dec_part != 0) {
            dec_part /= 10;
            decimal_places -= 1;
        }
        const pad_len = decimal_places -| std.fmt.count("{d}", .{dec_part});
        if (int_part == 0 and dec_part == 0) {
            try w.print("{s}0#", .{neg_sign});
        } else if (int_part == 0) {
            try w.print("{s}.{s}{d}#", .{ neg_sign, pad_buf[0..pad_len], dec_part });
        } else if (dec_part == 0) {
            try w.print("{s}{d}#", .{ neg_sign, int_part });
        } else {
            try w.print("{s}{d}.{s}{d}#", .{ neg_sign, int_part, pad_buf[0..pad_len], dec_part });
        }
    }
}

pub fn floatDouble(raw: u64) std.fmt.Alt(u64, formatFloatDouble) {
    return .{ .data = raw };
}

test "double precision format" {
    var buf: [32]u8 = undefined;
    for (dbl_cases) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{f}", .{floatDouble(case.val)});
        try std.testing.expectEqualStrings(case.expected, w.buffered());
    }
}

const SngCase = struct { val: u32, expected: []const u8 };
const sng_cases = [_]SngCase{
    .{ .val = 0x00000000, .expected = "0!" }, //            0.0
    .{ .val = 0x00200000, .expected = "0!" }, //            underflow → 0
    .{ .val = 0x00800000, .expected = "-0!" }, //           negative zero
    .{ .val = 0xFF7FFFF1, .expected = "1.70141E+38" }, //   max SNG
    .{ .val = 0xFFFFFFF1, .expected = "-1.70141E+38" }, //  -max SNG
    .{ .val = 0x5F5BE6FD, .expected = "1E-10" }, //         "short" E notation
    .{ .val = 0x70FBA882, .expected = "-1.5E-05" }, //      negative "short" E notation
    .{ .val = 0x7721D14D, .expected = "1.23457E-03" }, //   E notation with decimal mantissa
    .{ .val = 0x7A23D700, .expected = "9.99999E-03" }, //   just below 0.01 boundary
    .{ .val = 0x7A23D70A, .expected = ".01" }, //           lower fixed to E boundary
    .{ .val = 0x7A23D775, .expected = ".0100001" }, //      just above 0.01
    .{ .val = 0x7D4CCCC0, .expected = ".0999999" }, //      just below 0.1
    .{ .val = 0x80000000, .expected = ".5" }, //            0.5 - suppress leading zero
    .{ .val = 0x80800000, .expected = "-.5" }, //           -0.5 suppress leadign 0 for negative
    .{ .val = 0x811E060F, .expected = "1.23456" }, //       6 sig figs with decimal
    .{ .val = 0x91434FF3, .expected = "99999.9" }, //       near upper E boundary
    .{ .val = 0x91435000, .expected = "100000!" }, //       integer at upper fixed range
    .{ .val = 0x9143500D, .expected = "100000!" }, //       100000.1 rounds to 100000
    .{ .val = 0x947423E0, .expected = "999998!" }, //       near upper boundary
    .{ .val = 0x947423F0, .expected = "999999!" }, //       upper fixed boundary
    .{ .val = 0x947423F6, .expected = "999999!" }, //       999999.4 -> 999999
    .{ .val = 0x947423F8, .expected = "1E+06" }, //         999999.5 -> 1E+06
    .{ .val = 0x94742400, .expected = "1E+06" }, //         exact 1000000 E boundary
    .{ .val = 0x9516B450, .expected = "1.23457E+06" }, //   E notation high with decimal
    .{ .val = 0x94F423F0, .expected = "-999999!" }, //      -999999 negative near e boundary
    .{ .val = 0x94F42400, .expected = "-1E+06" }, //        -1000000, negative E boundary
    .{ .val = 0x7AA3D70A, .expected = "-.01" }, //          -0.01
    .{ .val = 0x707BA882, .expected = "1.5E-05" }, //       1.5e-5 short E
    .{ .val = 0x947424A0, .expected = "1.00001E+06" }, //   mantissa with leading zeros in decimal
    .{ .val = 0x6A210FB0, .expected = "1.5E-07" }, //       short form negative exponent
};

const DblCase = struct { val: u64, expected: []const u8 };
const dbl_cases = [_]DblCase{
    .{ .val = 0x000E000000000000, .expected = "0#" },
    .{ .val = 0x5F5BE6FECEBDEDD6, .expected = "1D-10" },
    .{ .val = 0x6A210FAFA06C1BB2, .expected = "1.5D-07" },
    .{ .val = 0x707BA8826AA8EB46, .expected = "1.5D-05" },
    .{ .val = 0x7A22339C0EBEDFA4, .expected = "9.9D-03" },
    .{ .val = 0x7A23D70A3D70A3D7, .expected = ".01#" },
    .{ .val = 0x7A23D7759D3B0ECA, .expected = ".0100001#" },
    .{ .val = 0x7D4CCCBF60D37F6E, .expected = ".0999999#" },
    .{ .val = 0x8000000000000000, .expected = ".5#" },
    .{ .val = 0x811E06521462D050, .expected = "1.23456789012346#" },
    .{ .val = 0x91434FF333333333, .expected = "99999.9#" },
    .{ .val = 0x9143500000000000, .expected = "100000#" },
    .{ .val = 0x9143500CCCCCCCCD, .expected = "100000.1#" },
    .{ .val = 0x947423E000000000, .expected = "999998#" },
    .{ .val = 0x947423F000000000, .expected = "999999#" },
    .{ .val = 0xB60E1BC9BF03FFF0, .expected = "9999999999999996#" },
    .{ .val = 0xB60E1BC9BF03FFFC, .expected = "9999999999999999#" },
    .{ .val = 0xB60E1BC9BF040000, .expected = "1D+16" },
    .{ .val = 0xB60E1C26E0DFA000, .expected = "1.00001D+16" },
    .{ .val = 0xB62F71651C03A000, .expected = "1.23457D+16" },
    .{ .val = 0xB95B4DA5D3187A48, .expected = "1.23456789012346D+17" },
    .{ .val = 0x4863BCD1FBFFF078, .expected = "1.23456789012346D-17" },
    .{ .val = 0xFF39C1D34AC02C87, .expected = "1.23456789012346D+38" },
    .{ .val = 0xB931A2BC2EC4FFCE, .expected = "9.99999999999999D+16" },
    .{ .val = 0xBC5E0B6B3A763FC2, .expected = "9.99999999999999D+17" },
    .{ .val = 0xC00AC7230489E7D9, .expected = "9.99999999999999D+18" },
    .{ .val = 0xC32D78EBC5AC61CF, .expected = "9.99999999999999D+19" },
};

const std = @import("std");
const Io = std.Io;
