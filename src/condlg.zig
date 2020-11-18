const std = @import("std");
const cli = @import("cli.zig");
const win = @import("win.zig");
const console = @import("console.zig");
const Pipe = @import("pipe.zig").Pipe;
const checkppid = @import("checkppid.zig");
const shellexec = @import("shellexec.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

fn readContents(path: ?[:0]const u16, allocator: *std.mem.Allocator, first: ?cli.ArgIteratorW.DataWithIndex, iter: *cli.ArgIteratorW) ![:0]const u16 {
    if (path) |f| {
        const file = try std.fs.cwd().openFileW(f, .{});
        defer file.close();
        const size = @intCast(usize, try std.os.windows.GetFileSizeEx(file.handle));
        const buffer = try allocator.alloc(u16, @divExact(size, 2) + 1);
        errdefer allocator.free(buffer);
        _ = try std.os.windows.ReadFile(file.handle, std.mem.sliceAsBytes(buffer[0..]), null, .blocking);
        buffer[@divExact(size, 2)] = 0;
        return translateContent(buffer[0..@divExact(size, 2) :0], allocator);
    } else {
        const orig = try readRest(@intCast(u16, '\n'), allocator, first, iter);
        errdefer allocator.free(orig);
        return translateContent(orig, allocator);
    }
}

fn readRest(sep: u16, allocator: *std.mem.Allocator, first: ?cli.ArgIteratorW.DataWithIndex, iter: *cli.ArgIteratorW) ![:0]const u16 {
    if (first) |f| {
        var buffer = try std.ArrayListSentineled(u16, 0).init(allocator, f.data);
        errdefer buffer.deinit();
        while (iter.next()) |tok| {
            try buffer.append(sep);
            try buffer.appendSlice(tok.data);
        }
        return buffer.toOwnedSlice();
    } else {
        return error.NoFile;
    }
}

fn translateContent(pdata: [:0]const u16, allocator: *std.mem.Allocator) ![:0]const u16 {
    const State = enum {
        Normal,
        StartText,
        EndText,
        StartHref,
    };
    var ret = try std.ArrayListSentineled(u16, 0).initSize(allocator, 0);
    defer ret.deinit();
    var sync: usize = 0;
    var start: usize = 0;
    var text: []const u16 = undefined;
    var state: State = .Normal;
    for (pdata) |ch, i| switch (state) {
        .Normal => switch (ch) {
            '[' => {
                start = i;
                state = .StartText;
            },
            else => {},
        },
        .StartText => switch (ch) {
            '[' => start = i,
            ']' => if (i == start + 1) {
                state = .Normal;
            } else {
                text = pdata[start + 1 .. i];
                state = .EndText;
            },
            else => {},
        },
        .EndText => switch (ch) {
            '(' => state = .StartHref,
            else => state = .Normal,
        },
        .StartHref => switch (ch) {
            ')' => if (i == start + text.len + 4) {
                state = .Normal;
            } else {
                try ret.appendSlice(pdata[sync..start]);
                try ret.appendSlice(L("<A HREF=\""));
                try ret.appendSlice(pdata[start + text.len + 3 .. i]);
                try ret.appendSlice(L("\">"));
                try ret.appendSlice(text);
                try ret.appendSlice(L("</A>"));
                sync = i + 1;

                state = .Normal;
            },
            else => {},
        },
    };
    if (sync == 0) return pdata;
    try ret.appendSlice(pdata[sync..]);
    const owned = ret.toOwnedSlice();
    allocator.free(pdata);
    return owned;
}

fn testTranslateContent(comptime expected: []const u8, comptime input: []const u8) !void {
    const dest = blk: {
        const orig = try std.testing.allocator.dupeZ(u16, L(input));
        errdefer std.testing.allocator.free(orig);
        break :blk try translateContent(orig, std.testing.allocator);
    };
    defer std.testing.allocator.free(dest);
    var ret: [expected.len * 2]u8 = undefined;
    const u8len = try std.unicode.utf16leToUtf8(&ret, dest);
    std.testing.expectEqualStrings(expected, ret[0..u8len]);
}

test "translateContent - no change" {
    try testTranslateContent("123", "123");
}

test "translateContent - translate link" {
    try testTranslateContent("123<A HREF=\"https://www.google.com\">456</A>789", "123[456](https://www.google.com)789");
}

test "translateContent - translate copmplex link" {
    try testTranslateContent("123[<A HREF=\"https://www.google.com\">456</A>]789", "123[[456](https://www.google.com)]789");
}

const RequestType = extern enum(u64) {
    Ping,
    Close,
    SetWinTitle,
    SetTitle,
    SetContent,
    SetProgress,
    SetRange,
    SetMarquee,
    WaitButton,
    _,
};

const ResponseType = extern enum(u64) {
    Ok = 0,
    Failed = 1,
    Unknown = 2,
    Incorrect = 4,
    _,
};

const RpcCommand = struct {
    pub const Error = cli.ParseError || std.fs.File.OpenError || std.os.ReadError || std.os.windows.GetFileSizeError || error{
        NoPipe,
        NoFile,
        FailedToCallNamedPipe,
        InvalidLink,
    };
    pub const Result = u8;

    pipe: ?[:0]const u16 = null,
    timeout: u32 = 0,
    content: ?[:0]const u16 = null,

    fn encodeCommand(allocator: *std.mem.Allocator, cmd: RequestType, data: []const u8) ![]const u8 {
        const size = 8 + data.len;
        const ret = try allocator.alloc(u8, size);
        std.mem.copy(u8, ret[0..8], std.mem.asBytes(&cmd));
        std.mem.copy(u8, ret[8..], data);
        return ret;
    }

    fn getPipe(self: *@This(), allocator: *std.mem.Allocator) Error![:0]const u16 {
        const prefix: []const u16 = L("\\\\.\\Pipe\\");
        const pipe = self.pipe orelse return error.NoPipe;
        if (pipe.len == 0) return error.NoPipe;
        if (pipe[0] == '\\') return pipe;
        var newpipe = try allocator.allocSentinel(u16, pipe.len + prefix.len, 0);
        errdefer allocator.free(newpipe);
        std.mem.copy(u16, newpipe[0..prefix.len], prefix);
        std.mem.copy(u16, newpipe[prefix.len..], pipe);
        allocator.free(pipe);
        self.pipe = newpipe;
        return newpipe;
    }

    fn sendCommand(self: *@This(), rt: RequestType, allocator: *std.mem.Allocator, data: []const u8) Error!u8 {
        const pipe = try self.getPipe(allocator);
        const encoded = try encodeCommand(allocator, rt, data);
        defer allocator.free(encoded);
        var resp: ResponseType = undefined;
        try Pipe.call(pipe, encoded, std.mem.asBytes(&resp), @bitCast(i32, self.timeout));
        return @intCast(u8, @enumToInt(resp));
    }

    fn setText(self: *@This(), rt: RequestType, allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const content = try readContents(self.content, allocator, iter.next(), iter);
        defer allocator.free(content);
        return sendCommand(self, rt, allocator, std.mem.sliceAsBytes(content));
    }

    fn simple(self: *@This(), rt: RequestType, allocator: *std.mem.Allocator) Error!u8 {
        const pipe = try self.getPipe(allocator);
        const cmd = std.mem.toBytes(rt);
        var resp: ResponseType = undefined;
        try Pipe.call(pipe, cmd[0..], std.mem.asBytes(&resp), @bitCast(i32, self.timeout));
        return @intCast(u8, @enumToInt(resp));
    }

    pub fn Ping(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        return self.simple(.Ping, allocator);
    }

    pub fn Close(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        return self.simple(.Close, allocator);
    }

    pub fn SetWinTitle(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        return self.setText(.SetWinTitle, allocator, iter);
    }

    pub fn SetTitle(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        return self.setText(.SetTitle, allocator, iter);
    }

    pub fn SetContent(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        return self.setText(.SetContent, allocator, iter);
    }

    pub fn SetProgress(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const next = try iter.nextUint(u16);
        return self.sendCommand(.SetProgress, allocator, std.mem.asBytes(&next));
    }

    pub fn SetRange(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        var range: [2]u16 = undefined;
        range[0] = try iter.nextUint(u16);
        range[1] = try iter.nextUint(u16);
        return self.sendCommand(.SetRange, allocator, std.mem.asBytes(&range));
    }

    pub fn SetMarquee(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        return self.simple(.SetMarquee, allocator);
    }

    pub fn WaitButton(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        return self.simple(.WaitButton, allocator);
    }

    fn deinit(self: *@This(), allocator: *std.mem.Allocator) void {
        if (self.pipe) |str| allocator.free(str);
        if (self.content) |str| allocator.free(str);
    }
};

const Module = struct {
    pub const Error = cli.ParseError || RpcCommand.Error || std.fs.File.OpenError || std.os.ReadError || std.os.windows.GetFileSizeError || error{
        InvalidArguments,
        UnspecifiedFailure,
        UnexpectedError,
        NoFile,
        FailedToCreatePipe,
    };

    pub const Result = u8;

    wintitle: ?[:0]const u16 = null,
    title: ?[:0]const u16 = null,
    content: ?[:0]const u16 = null,
    icon: win.IconType = .None,

    fn buildCommon(self: *@This(), allocator: *std.mem.Allocator, first: ?cli.ArgIteratorW.DataWithIndex, iter: *cli.ArgIteratorW) !win.CommonOptions {
        return win.CommonOptions{
            .title = self.wintitle orelse L("title"),
            .instrustion = self.title orelse L("message"),
            .content = try readContents(self.content, allocator, first, iter),
            .icon = self.icon,
        };
    }

    fn freeCommon(opt: win.CommonOptions, allocator: *std.mem.Allocator) void {
        allocator.free(opt.content);
    }

    pub fn msgbox(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const MsgBoxOptions = struct {
            button: win.CommonButtonFlags = .none,
        };
        var opt = MsgBoxOptions{};
        const first = try cli.parseArguments(&opt, allocator, iter);
        const common = try self.buildCommon(allocator, first, iter);
        defer freeCommon(common, allocator);
        const ret = try win.showMessageBox(common, opt.button);
        return @intCast(u8, ret);
    }

    pub fn select(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const SelectBoxOptions = struct {
            option: std.ArrayListUnmanaged([:0]const u16) = .{},
            cancellable: bool = false,

            pub fn deinit(sself: *@This(), sallocator: *std.mem.Allocator) void {
                for (sself.option.items) |item| sallocator.free(item);
                sself.option.deinit(sallocator);
            }
        };
        var opt = SelectBoxOptions{};
        defer opt.deinit(allocator);
        const first = try cli.parseArguments(&opt, allocator, iter);
        const common = try self.buildCommon(allocator, first, iter);
        defer freeCommon(common, allocator);
        var buttons = try std.ArrayListUnmanaged(win.TaskDialogButton).initCapacity(allocator, opt.option.items.len);
        defer buttons.deinit(allocator);
        for (opt.option.items) |item, i| try buttons.append(allocator, win.TaskDialogButton{
            .id = @intCast(c_int, i + 0x1000),
            .text = item,
        });
        const ret = try win.showSelect(common, opt.cancellable, buttons.items);
        if (ret < 0x1000) return 0;
        return @intCast(u8, ret - 0x1000 + 1);
    }

    pub fn wait(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const WaitOptions = struct {
            timeout: u32 = 10 * 1000,
            button: win.CommonButtonFlags = .none,

            pub fn invoke(this: *@This(), dlg: win.Dialog, data: win.TaskDialogNotificationData, user: usize) win.HRESULT {
                switch (data) {
                    .Created => dlg.setProgressBarRange(0, 65535) catch {},
                    .HyperlinkClicked => |file| _ = shellexec.exec(file, null, false),
                    .Timer => |val| {
                        const ret = if (val >= this.timeout)
                            dlg.close()
                        else
                            dlg.setProgressBarPos(@floatToInt(u16, 65536 * @intToFloat(f32, val) / @intToFloat(f32, this.timeout)));
                        ret catch {};
                    },
                    else => {},
                }
                return 0;
            }
        };
        var opt = WaitOptions{};
        const first = try cli.parseArguments(&opt, allocator, iter);
        const common = try self.buildCommon(allocator, first, iter);
        defer freeCommon(common, allocator);
        const ret = try win.showSimpleProgress(common, opt.button, &opt);
        return @intCast(u8, ret);
    }

    pub fn marquee(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const Context = struct {
            w32pipe: ?*Pipe = null,
            waitClose: bool = false,
            allocator: *std.mem.Allocator,
            parent: std.os.windows.HANDLE = undefined,
        };
        const MarqueeOptions = struct {
            ctx: Context,
            pipe: ?[:0]const u16 = null,
            fps: u8 = 30,
            cascade: bool = false,
            onexit: ?[:0]const u16 = null,

            fn setTitle(alloc: *std.mem.Allocator, pipe: *Pipe, dlg: win.Dialog, msg: []align(8) const u8) !void {
                const text = std.mem.bytesAsSlice(u16, msg[8..]);
                const sent = try alloc.allocSentinel(u16, text.len, 0);
                defer alloc.free(sent);
                std.mem.copy(u16, sent, text);
                try dlg.setWindowTitle(sent);
                pipe.writeAny(ResponseType.Ok) catch {};
            }

            fn setText(alloc: *std.mem.Allocator, et: win.Dialog.ElementType, pipe: *Pipe, dlg: win.Dialog, msg: []align(8) const u8) !void {
                const text = std.mem.bytesAsSlice(u16, msg[8..]);
                const sent = try alloc.allocSentinel(u16, text.len, 0);
                defer alloc.free(sent);
                std.mem.copy(u16, sent, text);
                try dlg.setElementText(et, sent);
                pipe.writeAny(ResponseType.Ok) catch {};
            }

            fn handle(this: *@This(), pipe: *Pipe, dlg: win.Dialog) !void {
                if (pipe.read(this.ctx.allocator) catch return) |msg| {
                    if (msg.len < 8) {
                        pipe.writeAny(ResponseType.Incorrect) catch {};
                        return;
                    }
                    const msghdr = std.mem.bytesToValue(RequestType, msg[0..8]);
                    switch (msghdr) {
                        .Ping => {
                            pipe.writeAny(ResponseType.Ok) catch {};
                        },
                        .Close => {
                            try dlg.close();
                            pipe.writeAny(ResponseType.Ok) catch {};
                        },
                        .SetWinTitle => {
                            try setTitle(this.ctx.allocator, pipe, dlg, msg);
                        },
                        .SetTitle => {
                            try setText(this.ctx.allocator, .MainInstruction, pipe, dlg, msg);
                        },
                        .SetContent => {
                            try setText(this.ctx.allocator, .Content, pipe, dlg, msg);
                        },
                        .SetProgress => {
                            var value: u16 = undefined;
                            std.mem.copy(u8, std.mem.asBytes(&value), msg[8..10]);
                            try dlg.setProgressBarPos(value);
                            pipe.writeAny(ResponseType.Ok) catch {};
                        },
                        .SetRange => {
                            var value: [2]u16 = undefined;
                            std.mem.copy(u8, std.mem.asBytes(&value), msg[8..12]);
                            try dlg.setMarqueeProgressBar(false);
                            try dlg.setProgressBarRange(value[0], value[1]);
                            pipe.writeAny(ResponseType.Ok) catch {};
                        },
                        .SetMarquee => {
                            try dlg.setMarqueeProgressBar(true);
                            pipe.writeAny(ResponseType.Ok) catch {};
                        },
                        .WaitButton => {
                            dlg.enableButton(1, true) catch {};
                            this.ctx.waitClose = true;
                        },
                        else => pipe.writeAny(ResponseType.Unknown) catch {},
                    }
                }
            }

            pub fn invoke(this: *@This(), dlg: win.Dialog, data: win.TaskDialogNotificationData, user: usize) win.HRESULT {
                switch (data) {
                    .Created => {
                        dlg.setMarqueeProgressBar(true) catch {};
                        dlg.setProgressBarMarquee(this.fps) catch {};
                        dlg.enableButton(1, false) catch {};
                    },
                    .HyperlinkClicked => |file| _ = shellexec.exec(file, null, false),
                    .Timer => |val| {
                        if (this.ctx.w32pipe) |pipe| {
                            if (pipe.connectNoWait()) {
                                this.handle(pipe, dlg) catch {
                                    pipe.writeAny(ResponseType.Failed) catch {};
                                };
                            }
                        }
                        if (this.cascade and !checkppid.stillAlive(this.ctx.parent)) {
                            this.cascade = false;

                            if (this.onexit) |prog| {
                                _ = shellexec.exec(prog, if (this.pipe) |p| p.ptr else null, true);
                            } else {
                                dlg.enableButton(1, true) catch {};
                                dlg.setMarqueeProgressBar(false) catch {};
                            }
                        }
                    },
                    else => {},
                }
                return 0;
            }

            pub fn deinit(this: *@This(), sallocator: *std.mem.Allocator) void {
                if (this.pipe) |str| sallocator.free(str);
                if (this.onexit) |str| sallocator.free(str);
                if (this.ctx.w32pipe) |pipe| pipe.close();
            }

            fn getPipe(this: *@This(), alloc: *std.mem.Allocator) Error![:0]const u16 {
                const prefix: []const u16 = L("\\\\.\\Pipe\\");
                const pipe = this.pipe orelse unreachable;
                if (pipe.len == 0) return error.NoPipe;
                if (pipe[0] == '\\') return pipe;
                var newpipe = try alloc.allocSentinel(u16, pipe.len + prefix.len, 0);
                errdefer alloc.free(newpipe);
                std.mem.copy(u16, newpipe[0..prefix.len], prefix);
                std.mem.copy(u16, newpipe[prefix.len..], pipe);
                alloc.free(pipe);
                this.pipe = newpipe;
                return newpipe;
            }
        };
        var opt = MarqueeOptions{ .ctx = .{ .allocator = allocator } };
        defer opt.deinit(allocator);
        opt.ctx.parent = checkppid.getParent();
        const first = try cli.parseArguments(&opt, allocator, iter);
        if (opt.pipe) |_| {
            opt.ctx.w32pipe = Pipe.create(.{
                .name = try opt.getPipe(allocator),
                .open = Pipe.OpenMode.create(.{ .Inbound, .Outbound }),
                .pipe = Pipe.PipeMode.create(.{ .ReadMessage, .WriteMessage, .NoWait }),
            }) orelse return error.FailedToCreatePipe;
        }
        const common = try self.buildCommon(allocator, first, iter);
        defer freeCommon(common, allocator);
        _ = try win.showSimpleProgress(common, win.CommonButtonFlags.none, &opt);
        if (opt.ctx.waitClose) {
            opt.ctx.w32pipe.?.writeAny(ResponseType.Ok) catch {};
        }
        return 0;
    }

    pub fn rpc(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        var cmds = RpcCommand{};
        defer cmds.deinit(allocator);
        return cli.evalModule(&cmds, allocator, iter);
    }

    pub fn help(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        @setEvalBranchQuota(1048576);
        const msg: [:0]const u16 = L(
            \\dialog - Windows dialog toolkit
            \\  Created by CodeHz
            \\
            \\Global options:
            \\  [/wintitle TILTE] [/title TILTE] [/content file] [/icon None|Warning|Error|Information|Shield]
            \\
            \\Sub commands:
            \\  msgbox [/button Ok|Yes|No|Cancel|Retry|Close]
            \\    Display an information box, will return the code of the clicked button
            \\
            \\  select /option A /option B [/cancellable]
            \\    Show a list of options, the errorlevel will be set after selection
            \\
            \\  wait [/timeout time]
            \\    Display a progress bar, which will be destroyed after the specified time
            \\
            \\  marquee [/pipe namedpipe] [/cascade] [/onexit prog]
            \\    Create a persistent marquee style progress bar, controlled by named pipes
            \\
            \\  rpc [/pipe namedpipe] [/timeout time]
            \\    Ping|Close|SetWinTitle|SetTitle|SetContent|SetProgress|SetRange|SetMarquee|WaitButton
        );
        _ = win.showMessageBox(.{
            .title = L("ConDlg Help"),
            .instrustion = L("Friendly Dialog Builder For Commandline user"),
            .content = msg,
            .icon = .Information,
        }, win.CommonButtonFlags.create(.{.Ok})) catch {};
        return 0;
    }

    fn deinit(self: *@This(), allocator: *std.mem.Allocator) void {
        if (self.wintitle) |str| allocator.free(str);
        if (self.title) |str| allocator.free(str);
        if (self.content) |str| allocator.free(str);
    }
};

pub const enable_segfault_handler = false;

pub fn panic(name: []const u8, bt: ?*std.builtin.StackTrace) noreturn {
    const G = struct {
        var buffer = [1]u16{0} ** 1024;
    };
    const len = std.unicode.utf8ToUtf16Le(&G.buffer, name) catch unreachable;
    _ = win.showMessageBox(.{
        .title = L("ConDlg Error"),
        .instrustion = L("Unfortunately, the program crashed"),
        .content = G.buffer[0..len :0],
    }, win.CommonButtonFlags.create(.{.Close})) catch {};
    std.os.exit(255);
}

pub fn main() anyerror!u8 {
    var heap = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = heap.deinit();
    const allocator = &heap.allocator;
    var mod: Module = .{};
    defer mod.deinit(allocator);
    var iter = cli.ArgIteratorW.init();
    _ = iter.next();
    return cli.evalModule(&mod, allocator, &iter) catch |e| switch (e) {
        error.NoCommand => return mod.help(allocator, &iter),
        else => return e,
    };
}
