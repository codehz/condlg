const std = @import("std");

extern "shell32" fn ShellExecuteExW(info: *ShellExecuteInfo) callconv(.Stdcall) bool;
extern "ole32" fn CoInitializeEx(reserved: ?*c_void, flags: u32) callconv(.Stdcall) u32;

const ShellExecuteInfo = extern struct {
    cbSize: u32 = @sizeOf(@This()),
    fmask: u32 = 0,
    hwnd: usize = 0,
    verb: ?[*:0]const u16 = null,
    file: ?[*:0]const u16 = null,
    parameters: ?[*:0]const u16 = null,
    directory: ?[*:0]const u16 = null,
    show: c_int = 0,
    app: usize = 0,
    idlist: ?*c_void = null,
    class: ?[*:0]const u16 = null,
    hkey: usize = 0,
    hotkey: u32 = 0,
    moniter: usize = 0,
    process: usize = 0,
};

const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub fn exec(file: [:0]const u16, parameters: ?[:0]const u16, hide: bool) bool {
    _ = CoInitializeEx(null, 0x6);
    var info = ShellExecuteInfo{
        .file = file.ptr,
        .parameters = if (parameters) |p| p.ptr else null,
        .show = if (hide) 0 else 5,
    };
    return ShellExecuteExW(&info);
}