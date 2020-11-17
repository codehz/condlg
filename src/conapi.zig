const std = @import("std");
const cli = @import("cli.zig");
const console = @import("console.zig");

const Module = struct {
    pub const Error = cli.ParseError;

    pub const Result = u8;

    pub fn show(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const MsgBoxOptions = struct {
            mode: console.ShowOptions = .Hide,
        };
        var opt: MsgBoxOptions = .{};
        _ = try cli.parseArguments(&opt, allocator, iter);
        console.Window.current().show(opt.mode);
        return 0;
    }

    pub fn title(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const TitleOptions = struct {
            value: ?[:0]const u16 = null,

            pub fn deinit(this: *@This(), alloc: *std.mem.Allocator) void {
                if (this.value) |str| alloc.free(str);
            }
        };
        var opt: TitleOptions = .{};
        defer opt.deinit(allocator);
        _ = try cli.parseArguments(&opt, allocator, iter);
        if (opt.value) |newtitle| {
            return if (console.setTitle(newtitle)) 0 else 1;
        } else {
            var buffer: [4096]u16 = undefined;
            const str = console.getTitle(&buffer);
            console.write(str);
            return 0;
        }
    }

    pub fn help(self: *@This(), allocator: *std.mem.Allocator, iter: *cli.ArgIteratorW) Error!u8 {
        const writer = std.io.getStdOut().writer();
        writer.writeAll(
            \\conapi - Console API (with some gui stuff)
            \\  Created by CodeHz
            \\
            \\sub commands:
            \\  show [/mode Hide|ShowNormal|ShowMinimized|ShowMaximized|ShowNoActivate|Show|Minimize|ShowMinimizedNoActivate|ShowNa|Restore|ShowDefault]
            \\    Manipulate current the console window
            \\
            \\  title [newtitle]
            \\    Set or get console title
        ) catch unreachable;
        return 1;
    }
};

pub const enable_segfault_handler = false;

pub fn main() anyerror!u8 {
    var heap = std.heap.HeapAllocator.init();
    defer heap.deinit();
    const allocator = &heap.allocator;
    var mod: Module = .{};
    var iter = cli.ArgIteratorW.init();
    _ = iter.next();
    return cli.evalModule(&mod, allocator, &iter) catch |e| switch (e) {
        error.NoCommand => return mod.help(allocator, &iter),
        else => return e,
    };
}
