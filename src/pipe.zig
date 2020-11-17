const std = @import("std");
const Flags = @import("flags.zig").Flags;
const windows = std.os.windows;

pub const Pipe = opaque {
    pub const OpenMode = Flags(extern enum(u32) {
        Inbound = 0x0001,
        Outbound = 0x0002,
        WriteDac = 0x00040000,
        WriteOwner = 0x00080000,
        AccessSystemSecurity = 0x01000000,
        FirstPipeInstance = 0x00080000,
        Overlapped = 0x40000000,
        WriteThrough = 0x80000000,
    });

    pub const PipeMode = Flags(extern enum {
        NoWait = 0x0001,
        ReadMessage = 0x0002,
        WriteMessage = 0x0004,
        RejectRemote = 0x0008,
    });

    extern "kernel32" fn CreateNamedPipeW(
        name: [*:0]const u16,
        open: OpenMode,
        pipe: PipeMode,
        maxInstance: i32,
        outbuffer: i32,
        inbuffer: i32,
        timeout: i32,
        security: ?*c_void,
    ) callconv(.Stdcall) ?*@This();

    extern "kernel32" fn ConnectNamedPipe(pipe: *@This(), overlapped: usize) callconv(.Stdcall) i32;
    extern "kernel32" fn FlushFileBuffers(pipe: *@This()) callconv(.Stdcall) i32;
    extern "kernel32" fn ReadFile(pipe: *@This(), buf: [*]u8, len: i32, readed: *i32, overlapped: usize) callconv(.Stdcall) i32;
    extern "kernel32" fn DisconnectNamedPipe(pipe: *@This()) callconv(.Stdcall) i32;
    extern "kernel32" fn PeekNamedPipe(
        pipe: *@This(),
        buffer: ?[*]u8,
        bufsize: i32,
        readed: ?*i32,
        total: ?*i32,
        msgsize: ?*i32,
    ) callconv(.Stdcall) i32;
    extern "kernel32" fn CallNamedPipeW(
        name: [*:0]const u16,
        in: [*]const u8,
        insize: i32,
        out: [*]u8,
        outsize: i32,
        readed: *i32,
        timeout: i32,
    ) callconv(.Stdcall) i32;

    pub const CreateFlags = struct {
        name: [*:0]const u16,
        open: OpenMode,
        pipe: PipeMode,
        maxInstance: i32 = 255,
        outbuffer: i32 = 8192,
        inbuffer: i32 = 8192,
        timeout: i32 = 1000,
        security: ?*c_void = null,
    };
    pub fn create(flags: CreateFlags) ?*@This() {
        return CreateNamedPipeW(flags.name, flags.open, flags.pipe, flags.maxInstance, flags.outbuffer, flags.inbuffer, flags.timeout, flags.security);
    }

    pub fn call(name: [:0]const u16, in: []const u8, out: []u8, timeout: i32) !void {
        var tmp: i32 = undefined;
        const res = CallNamedPipeW(name, in.ptr, @intCast(i32, in.len), out.ptr, @intCast(i32, out.len), &tmp, timeout);
        if (res == 0) {
            std.log.err("{}", .{windows.kernel32.GetLastError()});
            return error.FailedToCallNamedPipe;
        }
    }

    pub const Connection = struct {
        pipe: *Pipe,

        pub fn deconnect(self: @This()) void {
            std.log.info("disconnect", .{});
            _ = FlushFileBuffers(self.pipe);
            _ = DisconnectNamedPipe(self.pipe);
        }
    };

    pub fn connect(self: *@This()) ?Connection {
        const res = ConnectNamedPipe(self, 0);
        if (res == 0) return null;
        return Connection{ .pipe = self };
    }

    pub fn connectNoWait(self: *@This()) bool {
        const res = ConnectNamedPipe(self, 0);
        switch (windows.kernel32.GetLastError()) {
            .PIPE_LISTENING => return false,
            .PIPE_CONNECTED => return true,
            .NO_DATA => {
                _ = DisconnectNamedPipe(self);
                return false;
            },
            else => return false,
        }
    }

    pub fn read(self: *@This(), allocator: *std.mem.Allocator) !?[]align(8) const u8 {
        var size: i32 = undefined;
        if (PeekNamedPipe(self, null, 0, null, null, &size) == 0) return error.BrokenPipe;
        if (size <= 0) return null;
        const buf = try allocator.allocAdvanced(u8, 8, @intCast(usize, size), .exact);
        var len = try std.os.windows.ReadFile(self, buf, 0, .blocking);
        return buf[0..len];
    }

    pub fn write(self: *@This(), data: []const u8) !void {
        _ = try std.os.windows.WriteFile(self, data, 0, .blocking);
    }

    pub fn writeAny(self: *@This(), data: anytype) !void {
        const bytes = std.mem.toBytes(data);
        try self.write(bytes[0..]);
    }

    pub fn close(self: *@This()) void {
        windows.CloseHandle(self);
    }
};
