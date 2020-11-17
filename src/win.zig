const std = @import("std");
const Flags = @import("flags.zig").Flags;
const windows = std.os.windows;

pub const HWND = *opaque {};
pub const HICON = *opaque {};
const INSTANCE = opaque {};
pub const HINSTANCE = *const INSTANCE;
pub const PCWSTR = [*:0]align(1) const u16;
pub const HRESULT = u64;
pub const LRESULT = u32;

extern "comctl32" fn TaskDialogIndirect(
    config: *const TaskDialogConfig,
    btn: ?*c_uint,
    radio: ?*c_uint,
    verified: ?*bool,
) callconv(.Stdcall) HRESULT;
extern "comctl32" fn TaskDialog(
    hwnd: ?HWND,
    inst: HINSTANCE,
    title: PCWSTR,
    instrustion: PCWSTR,
    content: PCWSTR,
    combtns: c_uint,
    icns: ?PCWSTR, // -3
    btn: ?*c_uint,
) callconv(.Stdcall) HRESULT;

extern "comctl32" fn InitCommonControls() callconv(.Stdcall) void;
extern "user32" fn SetProcessDPIAware() callconv(.Stdcall) void;
extern "user32" fn LoadIconW(instance: ?HINSTANCE, name: PCWSTR) callconv(.Stdcall) ?HICON;
extern "user32" fn SetWindowTextW(hwnd: HWND, text: [*:0]const u16) callconv(.Stdcall) i32;
extern "user32" fn SendMessageW(hwnd: HWND, msg: c_uint, win: usize, user: usize) callconv(.Stdcall) LRESULT;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.Stdcall) windows.BOOL;

fn MAKEINTRESOURCE(id: i16) ?PCWSTR {
    return std.meta.cast(?PCWSTR, @intCast(usize, @bitCast(u16, id)));
}

extern const __ImageBase: INSTANCE;

pub fn Instance() HINSTANCE {
    return &__ImageBase;
}

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const isWindows = std.builtin.os.tag == .windows;

pub fn init() void {
    SetProcessDPIAware();
    InitCommonControls();
}

fn wecast(from: anytype) c_int {
    const mid = std.meta.Int(false, @bitSizeOf(@TypeOf(from)));
    return @intCast(c_int, @bitCast(mid, from));
}

const TaskDialogFlags = Flags(extern enum(c_uint) {
    EnableHyperlinks = 0x0001,
    UseHiconMain = 0x0002,
    UseHiconFooter = 0x0004,
    AllowDialogCancellation = 0x0008,
    UseCommandLinks = 0x0010,
    UseCommandLinksIcon = 0x0020,
    ExpandFooterArea = 0x0040,
    ExpandedByDefault = 0x0080,
    VerificationFlagChecked = 0x0100,
    ShowProgressBar = 0x0200,
    ShowMarqueeProgressBar = 0x0400,
    CallbackTimer = 0x0800,
    PositionRelativeToWindow = 0x1000,
    RtlLayout = 0x2000,
    NoDefaultRadioButton = 0x4000,
    CanBeMinimized = 0x8000,
    NoSetForeground = 0x00010000,
    SizeToContent = 0x01000000,
});

pub const CommonButtonFlags = Flags(extern enum(c_uint) {
    Ok = 0x0001,
    Yes = 0x0002,
    No = 0x0004,
    Cancel = 0x0008,
    Retry = 0x0010,
    Close = 0x0020,
});

pub const IconType = extern enum(i16) {
    None = 0,
    Warning = -1,
    Error = -2,
    Information = -3,
    Shield = -4,
};

const IconUnion = extern union {
    hicon: HICON,
    res: ?PCWSTR,
};

pub const TaskDialogButton = packed struct {
    id: c_int,
    text: PCWSTR,
};

pub const TaskDialogNotification = extern enum {
    Created = 0,
    Navigated = 1,
    ButtonClicked = 2,
    HyperlinkClicked = 3,
    Timer = 4,
    Destroyed = 5,
    RadioButtonClicked = 6,
    DialogConstructed = 7,
    VerificationClicked = 8,
    Help = 9,
    ExpandedButtonClicked = 10,
};

pub const TaskDialogNotificationData = union(TaskDialogNotification) {
    Created: void,
    Navigated: void,
    ButtonClicked: c_uint,
    HyperlinkClicked: [*:0]const u16,
    Timer: c_uint,
    Destroyed: void,
    RadioButtonClicked: c_uint,
    DialogConstructed: void,
    VerificationClicked: bool,
    Help: void,
    ExpandedButtonClicked: bool,
};

pub const TaskDialogMessage = extern enum(c_uint) {
    NavigatePage = 0x0400 + 101,
    ClickButton = 0x0400 + 102,
    SetMarqueeProgressBar = 0x0400 + 103,
    SetProgressBarState = 0x0400 + 104,
    SetProgressBarRange = 0x0400 + 105,
    SetProgressBarPos = 0x0400 + 106,
    SetProgressBarMarquee = 0x0400 + 107,
    SetElementText = 0x0400 + 108,
    ClickRadio = 0x0400 + 110,
    EnableButton = 0x0400 + 111,
    EnableRadioButton = 0x0400 + 112,
    ClickVerification = 0x0400 + 113,
    UpdateElementText = 0x0400 + 114,
    SetButtonElevationRequiredState = 0x0400 + 115,
    UpdateIcon = 0x0400 + 116,
};

pub const Dialog = struct {
    handle: HWND,

    pub const ProgressBarState = extern enum(usize) {
        Normal = 1,
        Error = 2,
        Paused = 3,
    };

    pub const ElementType = extern enum(usize) {
        Content,
        ExpandedInformation,
        Footer,
        MainInstruction,
    };

    pub fn send(self: @This(), msg: TaskDialogMessage, code: usize, user: usize) !void {
        const re = SendMessageW(self.handle, @enumToInt(msg), code, user);
        if (re != 0) return error.SendFailed;
    }

    pub fn close(self: @This()) !void {
        if (DestroyWindow(self.handle) == 0) {
            return error.CloseFailed;
        }
    }

    pub fn enableButton(self: @This(), id: usize, tog: bool) !void {
        return self.send(.EnableButton, id, if (tog) 1 else 0);
    }

    pub fn setWindowTitle(self: @This(), title: [*:0]const u16) !void {
        if (SetWindowTextW(self.handle, title) == 0) return error.SendFailed;
    }

    pub fn setElementText(self: @This(), ele: ElementType, text: [*:0]const u16) !void {
        return self.send(.SetElementText, @enumToInt(ele), @ptrToInt(text));
    }

    pub fn setProgressBarState(self: @This(), state: ProgressBarState) !void {
        return self.send(.SetProgressBarState, @enumToInt(state), 0);
    }

    pub fn setMarqueeProgressBar(self: @This(), opt: bool) !void {
        return self.send(.SetMarqueeProgressBar, if (opt) 1 else 0, 0);
    }

    pub fn setProgressBarMarquee(self: @This(), updateDelay: ?usize) !void {
        return self.send(.SetProgressBarMarquee, if (updateDelay != null) 1 else 0, updateDelay orelse 0);
    }

    pub fn setProgressBarRange(self: @This(), min: u16, max: u16) !void {
        return self.send(.SetProgressBarRange, 0, (@intCast(u32, max) << 16) + @intCast(u32, min));
    }

    pub fn setProgressBarPos(self: @This(), value: u16) !void {
        return self.send(.SetProgressBarPos, @intCast(usize, value), 0);
    }
};

fn callbackTrampoline(comptime Handler: type) TaskDialogCallback {
    const G = struct {
        fn callback(hwnd: HWND, msg: TaskDialogNotification, win: usize, user: usize, ref: *c_void) callconv(.Stdcall) HRESULT {
            const handler = std.meta.cast(*Handler, ref);
            const data: TaskDialogNotificationData = switch (msg) {
                .Created => .Created,
                .Navigated => .Navigated,
                .ButtonClicked => TaskDialogNotificationData{ .ButtonClicked = @intCast(c_uint, win) },
                .HyperlinkClicked => TaskDialogNotificationData{ .HyperlinkClicked = @intToPtr([*:0]const u16, win) },
                .Timer => TaskDialogNotificationData{ .Timer = @intCast(c_uint, win) },
                .Destroyed => .Destroyed,
                .RadioButtonClicked => TaskDialogNotificationData{ .RadioButtonClicked = @intCast(c_uint, win) },
                .DialogConstructed => .DialogConstructed,
                .VerificationClicked => TaskDialogNotificationData{ .VerificationClicked = win != 0 },
                .Help => .Help,
                .ExpandedButtonClicked => TaskDialogNotificationData{ .ExpandedButtonClicked = win != 0 },
            };
            return handler.invoke(Dialog{ .handle = hwnd }, data, user);
        }
    };
    return G.callback;
}

const TaskDialogCallback = fn (hwnd: HWND, msg: TaskDialogNotification, win: usize, user: usize, ref: *c_void) callconv(.Stdcall) HRESULT;

const TaskDialogConfig = packed struct {
    size: c_uint = @sizeOf(TaskDialogConfig),
    hwnd: ?HWND = null,
    inst: HINSTANCE,
    flags: TaskDialogFlags = .none,
    btnflags: CommonButtonFlags = .none,
    title: PCWSTR,
    mainIcon: IconUnion = .{ .res = MAKEINTRESOURCE(0) },
    instrustion: PCWSTR,
    content: PCWSTR,
    btnc: c_uint = 0,
    btns: ?[*]const TaskDialogButton = null,
    btnd: c_uint = 0,
    radioc: c_uint = 0,
    radios: ?[*]const TaskDialogButton = null,
    radiod: c_uint = 0,
    verification: ?PCWSTR = null,
    expandedInfo: ?PCWSTR = null,
    expandedCtl: ?PCWSTR = null,
    collapsedCtl: ?PCWSTR = null,
    footerIcon: IconUnion = .{ .res = MAKEINTRESOURCE(0) },
    footer: ?PCWSTR = null,
    callback: ?TaskDialogCallback = null,
    callbackData: ?*c_void = null,
    width: c_uint = 0,
};

pub const CommonOptions = struct {
    title: PCWSTR = L(""),
    instrustion: PCWSTR = L(""),
    content: [:0]const u16 = L(""),
    icon: IconType = .None,
};

pub fn showSimpleProgress(common: CommonOptions, btnType: CommonButtonFlags, handler: anytype) !c_uint {
    comptime const Handler = @TypeOf(handler.*);
    const cfg = TaskDialogConfig{
        .flags = TaskDialogFlags.create(.{ .ShowProgressBar, .CallbackTimer }),
        .inst = Instance(),
        .btnflags = btnType,
        .title = common.title,
        .instrustion = common.instrustion,
        .content = common.content,
        .callback = callbackTrampoline(Handler),
        .callbackData = handler,
        .mainIcon = .{ .res = MAKEINTRESOURCE(@enumToInt(common.icon)) },
    };
    var btn: c_uint = 0;
    const res = TaskDialogIndirect(&cfg, &btn, null, null);
    switch (res) {
        0 => return btn,
        0x8007000E => return error.OutOfMemory,
        0x80070057 => return error.InvalidArguments,
        0x80004005 => return error.UnspecifiedFailure,
        else => return error.UnexpectedError,
    }
}

pub fn showSelect(common: CommonOptions, cancellable: bool, btns: []const TaskDialogButton) !c_uint {
    var cfg = TaskDialogConfig{
        .flags = TaskDialogFlags.create(.{ .UseCommandLinks, .UseCommandLinksIcon }),
        .inst = Instance(),
        .title = common.title,
        .instrustion = common.instrustion,
        .content = common.content,
        .btnc = @intCast(c_uint, btns.len),
        .btns = btns.ptr,
        .mainIcon = .{ .res = MAKEINTRESOURCE(@enumToInt(common.icon)) },
    };
    if (cancellable) cfg.flags.add(.AllowDialogCancellation);
    var selected: c_uint = 0;
    const res = TaskDialogIndirect(&cfg, &selected, null, null);
    switch (res) {
        0 => return selected,
        0x8007000E => return error.OutOfMemory,
        0x80070057 => return error.InvalidArguments,
        0x80004005 => return error.UnspecifiedFailure,
        else => return error.UnexpectedError,
    }
}

pub fn showMessageBox(common: CommonOptions, btnType: CommonButtonFlags) !c_uint {
    var btn: c_uint = undefined;
    const res = TaskDialog(null, Instance(), common.title, common.instrustion, common.content, @enumToInt(btnType), MAKEINTRESOURCE(@enumToInt(common.icon)), &btn);
    switch (res) {
        0 => return btn,
        0x8007000E => return error.OutOfMemory,
        0x80070057 => return error.InvalidArguments,
        0x80004005 => return error.UnspecifiedFailure,
        else => return error.UnexpectedError,
    }
}
