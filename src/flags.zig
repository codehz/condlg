const std = @import("std");

pub fn Flags(comptime T: type) type {
    const Storage = @TagType(T);
    return packed enum(Storage) {
        none = 0,
        all = comptime blk: {
            comptime var ret = 0;
            inline for (std.meta.fields(T)) |field| ret |= field.value;
            break :blk ret;
        },
        _,

        const Self = @This();
        pub const FlagTag = T;

        pub fn from(comptime val: comptime_int) Self {
            return @intToEnum(Self, val);
        }

        pub fn create(comptime list: anytype) Self {
            var ret = Self.none;
            inline for (list) |item| {
                ret.add(item);
            }
            return ret;
        }

        pub fn add(self: *align(1) Self, x: T) void {
            self.* = self.incl(x);
        }

        pub fn del(self: *align(1) Self, x: T) void {
            self.* = self.excl(x);
        }

        pub fn incl(self: Self, x: T) Self {
            return @intToEnum(Self, @enumToInt(self) | @enumToInt(x));
        }

        pub fn excl(self: Self, x: T) Self {
            return @intToEnum(Self, @enumToInt(self) & ~@enumToInt(x));
        }

        pub fn merge(self: Self, rhs: Self) Self {
            return @intToEnum(Self, @enumToInt(self) | @enumToInt(rhs));
        }

        pub fn mergeFrom(self: *Self, rhs: Self) void {
            self.* = self.merge(x);
        }

        pub fn format(value: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            var val = @enumToInt(value);
            try writer.writeAll(@typeName(T));
            inline for (std.meta.fields(T)) |field| {
                if (field.value & val != 0) {
                    try writer.writeAll(" | " ++ @tagName(@field(T, field.name)));
                }
            }
        }
    };
}