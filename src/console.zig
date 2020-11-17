const std = @import("std");

extern "kernel32" fn GetConsoleWindow() callconv(.Stdcall) *Window;
extern "kernel32" fn SetConsoleTitleW(title: [*:0]const u16) callconv(.Stdcall) bool;
extern "kernel32" fn GetConsoleTitleW(buffer: [*]u16, len: u32) callconv(.Stdcall) u32;
extern "kernel32" fn WriteConsoleW(handle: *c_void, buffer: [*]const u16, len: u32, written: ?*u32, reserved: usize) callconv(.Stdcall) bool;
extern "user32" fn ShowWindow(win: *Window, cmd: ShowOptions) callconv(.Stdcall) bool;

pub const ShowOptions = extern enum(i32) {
    Hide = 0,
    ShowNormal = 1,
    ShowMinimized = 2,
    ShowMaximized = 3,
    ShowNoActivate = 4,
    Show = 5,
    Minimize = 6,
    ShowMinimizedNoActivate = 7,
    ShowNa = 8,
    Restore = 9,
    ShowDefault = 10,
};

pub const Window = opaque {
    pub fn current() *@This() {
        return GetConsoleWindow();
    }

    pub fn show(self: *@This(), cmd: ShowOptions) void {
        _ = ShowWindow(self, cmd);
    }
};

pub fn setTitle(title: [*:0]const u16) bool {
    return SetConsoleTitleW(title);
}

pub fn getTitle(buffer: []u16) []const u16 {
    const len = GetConsoleTitleW(buffer.ptr, @intCast(u32, buffer.len));
    return buffer[0..len];
}

pub fn write(data: []const u16) void {
    const out = std.io.getStdOut();
    if (out.isTty()) {
        _ = WriteConsoleW(out.handle, data.ptr, @intCast(u32, data.len), null, 0);
    } else {
        out.writer().writeAll(std.mem.sliceAsBytes(data)) catch {};
    }
}