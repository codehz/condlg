const std = @import("std");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

fn l(ch: u8) u16 {
    return @intCast(u16, ch);
}

extern "kernel32" fn GetCommandLineW() callconv(.Stdcall) [*:0]const u16;

fn lower16(ch: u16, cvt: bool) u16 {
    return if (cvt and ch > l('A') and ch < l('Z')) ch ^ 0x20 else ch;
}
pub const ArgIteratorW = struct {
    const Buffer16 = struct {
        const BUFFER_SIZE = 16384;
        const BufferRaw = [BUFFER_SIZE]u16;
        var buffer: BufferRaw = undefined;
        idx: usize = 0,

        fn init() @This() {
            return .{};
        }

        fn push(self: *@This(), ch: u16) void {
            buffer[self.idx] = ch;
            self.idx += 1;
        }

        fn dump(self: *@This()) [:0]const u16 {
            buffer[self.idx] = 0;
            return buffer[0..self.idx :0];
        }
    };

    index: usize,
    cmd_line: [*:0]const u16,

    pub fn init() @This() {
        return @This(){
            .index = 0,
            .cmd_line = GetCommandLineW(),
        };
    }

    pub const DataWithIndex = struct {
        index: usize,
        data: [:0]const u16,
        cvt: bool,
    };

    pub fn next(self: *@This()) ?DataWithIndex {
        var cvt = false;
        while (true) : (self.index += 1) {
            const byte = self.cmd_line[self.index];
            switch (byte) {
                0 => return null,
                l(' '), l('\t') => continue,
                l('/') => {
                    cvt = true;
                    continue;
                },
                else => break,
            }
        }
        const cache = self.index;
        return DataWithIndex{
            .index = cache,
            .data = self.internalNext(cvt),
            .cvt = cvt,
        };
    }

    pub fn nextUint(self: *@This(), comptime T: type) error{InvalidNumber}!T {
        const tmp = self.next() orelse return error.InvalidNumber;
        if (tmp.cvt) return error.InvalidNumber;
        return parseUintU16(u16, tmp.data) orelse return error.InvalidNumber;
    }

    fn internalNext(self: *@This(), cvt: bool) [:0]const u16 {
        var buf = Buffer16.init();
        var backslash_count: usize = 0;
        var in_quote = false;
        while (true) : (self.index += 1) {
            const byte = self.cmd_line[self.index];
            switch (byte) {
                0 => return buf.dump(),
                l('"') => {
                    const quote_is_real = backslash_count % 2 == 0;
                    self.emitBackslashes(&buf, backslash_count / 2);
                    backslash_count = 0;

                    if (quote_is_real) {
                        in_quote = !in_quote;
                    } else {
                        buf.push(l('"'));
                    }
                },
                l('\\') => {
                    backslash_count += 1;
                },
                l(' '), l('\t') => {
                    self.emitBackslashes(&buf, backslash_count);
                    backslash_count = 0;
                    if (in_quote) {
                        buf.push(byte);
                    } else {
                        return buf.dump();
                    }
                },
                else => {
                    self.emitBackslashes(&buf, backslash_count);
                    backslash_count = 0;
                    buf.push(lower16(byte, cvt));
                },
            }
        }
    }

    fn emitBackslashes(self: *@This(), buf: *Buffer16, emit_count: usize) void {
        var i: usize = 0;
        while (i < emit_count) : (i += 1) {
            buf.push(l('\\'));
        }
    }
};

pub fn parseUintU16(comptime T: type, input: []const u16) ?T {
    var ret: T = 0;
    for (input) |ch| {
        if (ch >= l('0') and ch <= l('9')) {
            var v = @intCast(T, ch - l('0'));
            ret = ret * 10 + v;
        } else return null;
    }
    return ret;
}

fn transform(comptime origin: []const u16) ?[]const u16 {
    comptime {
        if (origin[0] == lower16(origin[0], true)) return null;
        var ret: []const u16 = &[1]u16{lower16(origin[0], true)};
        for (origin[1..]) |ch| {
            const lch = lower16(ch, true);
            if (lch == ch) {
                ret = ret ++ [1]u16{ch};
            } else {
                ret = ret ++ L("_") ++ [1]u16{lch};
            }
        }
        return ret;
    }
}

fn eq(comptime precompiled: []const u8, text: []const u16) bool {
    if (comptime transform(comptime L(precompiled))) |lvar| {
        return std.mem.eql(u16, text, L(precompiled)) or std.mem.eql(u16, text, lvar);
    } else {
        return std.mem.eql(u16, text, L(precompiled));
    }
}

pub const ParseError = error{
    UnknownArgument,
    UnknownEnumValue,
    InvalidArgument,
    InvalidNumber,
    InvalidCommand,
    NoCommand,
    OutOfMemory,
    DanglingSurrogateHalf,
    ExpectedSecondSurrogateHalf,
    UnexpectedSecondSurrogateHalf,
};

fn assignArguments(mod: anytype, allocator: *std.mem.Allocator, data: ArgIteratorW.DataWithIndex, iter: *ArgIteratorW) ParseError!void {
    comptime const fields: []const std.builtin.TypeInfo.StructField = std.meta.fields(@TypeOf(mod.*));
    inline for (fields) |field| {
        if (eq(field.name, data.data)) {
            switch (field.field_type) {
                ?[:0]const u16, [:0]const u16 => {
                    const val = iter.next() orelse return error.InvalidArgument;
                    @field(mod, field.name) = try allocator.dupeZ(u16, val.data);
                },
                ?[]const u8, []const u8 => {
                    const val = iter.next() orelse return error.InvalidArgument;
                    @field(mod, field.name) = try std.unicode.utf16leToUtf8Alloc(allocator, val.data);
                },
                std.ArrayListUnmanaged([:0]const u16) => {
                    const val = iter.next() orelse return error.InvalidArgument;
                    try @field(mod, field.name).append(allocator, try allocator.dupeZ(u16, val.data));
                },
                u8, u16, u32, u64 => {
                    const val = iter.next() orelse return error.InvalidArgument;
                    @field(mod, field.name) = parseUintU16(field.field_type, val.data) orelse return error.InvalidNumber;
                },
                bool => @field(mod, field.name) = true,
                else => {
                    switch (@typeInfo(field.field_type)) {
                        .Enum => |e| {
                            const val = iter.next() orelse return error.InvalidArgument;
                            if (comptime @hasDecl(field.field_type, "FlagTag")) {
                                const FlagTag = field.field_type.FlagTag;
                                inline for (@typeInfo(FlagTag).Enum.fields) |tagField| {
                                    if (eq(tagField.name, val.data) or eq("+" ++ tagField.name, val.data)) {
                                        @field(mod, field.name).add(@field(FlagTag, tagField.name));
                                        return;
                                    } else if (eq("-" ++ tagField.name, val.data)) {
                                        @field(mod, field.name).del(@field(FlagTag, tagField.name));
                                        return;
                                    }
                                }
                            } else {
                                inline for (e.fields) |enumField| {
                                    if (eq(enumField.name, val.data)) {
                                        @field(mod, field.name) = @field(field.field_type, enumField.name);
                                        return;
                                    }
                                }
                            }
                            return error.UnknownEnumValue;
                        },
                        else => return error.UnknownArgument,
                    }
                },
            }
            return;
        }
    }
    return error.UnknownArgument;
}

pub fn parseArguments(module: anytype, allocator: *std.mem.Allocator, iter: *ArgIteratorW) ParseError!?ArgIteratorW.DataWithIndex {
    const Module = @TypeOf(module.*);
    while (iter.next()) |opt| {
        if (opt.cvt) {
            try assignArguments(module, allocator, opt, iter);
        } else {
            return opt;
        }
    }
    return null;
}

pub fn evalModule(module: anytype, allocator: *std.mem.Allocator, iter: *ArgIteratorW) @TypeOf(module.*).Error!@TypeOf(module.*).Result {
    const Module = @TypeOf(module.*);
    const commands: []const std.builtin.TypeInfo.Declaration = std.meta.declarations(Module);
    while (iter.next()) |opt| {
        if (opt.cvt) {
            try assignArguments(module, allocator, opt, iter);
        } else {
            inline for (commands) |command| {
                if (comptime !command.is_pub or comptime command.data != .Fn) continue;
                if (eq(command.name, opt.data))
                    return @field(module, command.name)(allocator, iter);
            }
            return error.InvalidCommand;
        }
    }
    return error.NoCommand;
}
