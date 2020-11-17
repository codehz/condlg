const std = @import("std");
const Flags = @import("flags.zig").Flags;
const windows = std.os.windows;

const ProcessBasicInformation = extern struct {
    ExitStatus: u32,
    PebBaseAddress: usize,
    AffinityMask: usize,
    BasePriority: u32,
    UniqueProcessId: usize,
    InheritedFromUniqueProcessId: usize,
};

extern "ntdll" fn NtQueryInformationProcess(
    fake: isize, // -1
    class: u32,
    info: *ProcessBasicInformation,
    len: u32,
    retlen: ?*u32,
) callconv(.Stdcall) windows.NTSTATUS;
extern "kernel32" fn OpenProcess(access: u32, inherit: bool, pid: usize) callconv(.Stdcall) ?windows.HANDLE;

pub fn getParent() windows.HANDLE {
    var info: ProcessBasicInformation = undefined;
    const status = NtQueryInformationProcess(-1, 0, &info, @sizeOf(ProcessBasicInformation), null);
    if (status != .SUCCESS) {
        std.log.err("err: {}", .{status});
        unreachable;
    }
    return OpenProcess(0x00100000, false, info.InheritedFromUniqueProcessId).?;
}

pub fn stillAlive(handle: windows.HANDLE) bool {
    std.os.windows.WaitForSingleObject(handle, 0) catch |e| return e == error.WaitTimeOut;
    return false;
}