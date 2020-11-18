const std = @import("std");
const Builder = std.build.Builder;

const FileDesc = struct {
    Comments: ?[]const u8 = null,
    CompanyName: ?[]const u8 = null,
    FileDescription: ?[]const u8 = null,
    FileVersion: ?[]const u8 = null,
    InternalName: ?[]const u8 = null,
    LegalCopyright: ?[]const u8 = null,
    LegalTrademarks: ?[]const u8 = null,
    OriginalFilename: ?[]const u8 = null,
    ProductName: ?[]const u8 = null,
    ProductVersion: ?[]const u8 = null,
};

const RcInfo = struct {
    manifest: ?[]const u8 = null,
    descriptions: FileDesc = .{},
};

fn editrc(b: *Builder, target: *std.build.InstallArtifactStep, comptime info: RcInfo) void {
    const rcedit = b.addSystemCommand(&[_][]const u8{"rcedit"});
    rcedit.addArtifactArg(target.artifact);
    if (info.manifest) |manifest| {
        rcedit.addArgs(&[_][]const u8{
            "--application-manifest",
            manifest,
        });
    }
    inline for (std.meta.fields(@TypeOf(info.descriptions))) |field| {
        if (@field(info.descriptions, field.name)) |value| {
            rcedit.addArgs(&[_][]const u8{
                "--set-version-string",
                field.name,
                value,
            });
        }
    }
    target.step.dependOn(&rcedit.step);
}

pub fn build(b: *Builder) void {
    b.setPreferredReleaseMode(.ReleaseSmall);
    const m32 = b.option(bool, "32", "build 32bit") orelse false;
    const target = std.zig.CrossTarget.parse(.{ .arch_os_abi = if (m32) "i386-windows-gnu" else "x86_64-windows-gnu" }) catch unreachable;
    const mode = b.standardReleaseOptions();

    const conapi_exe = b.addExecutable(if (m32) "conapi32" else "conapi", "src/conapi.zig");
    if (mode == .ReleaseSmall) {
        conapi_exe.strip = true;
    }
    conapi_exe.single_threaded = true;
    conapi_exe.setTarget(target);
    conapi_exe.setBuildMode(mode);
    conapi_exe.install();

    editrc(b, conapi_exe.install_step.?, .{
        .descriptions = .{
            .ProductName = "Windows Console Helper",
            .FileDescription = "Manipulate console window",
            .InternalName = "conapi",
            .OriginalFilename = "conapi",
            .CompanyName = "CodeHz",
            .LegalCopyright = "Copyright 2020 CodeHz"
        },
    });

    const condlg_exe = b.addExecutable(if (m32) "condlg32" else "condlg", "src/condlg.zig");
    if (mode == .ReleaseSmall) {
        condlg_exe.strip = true;
    }
    condlg_exe.subsystem = .Windows;
    condlg_exe.single_threaded = true;
    condlg_exe.setTarget(target);
    condlg_exe.setBuildMode(mode);
    condlg_exe.install();

    editrc(b, condlg_exe.install_step.?, .{
        .manifest = "src/app.manifest",
        .descriptions = .{
            .ProductName = "Friendly Dialog Builder For Commandline user",
            .FileDescription = "Console ❤ Dialog",
            .InternalName = "condlg",
            .OriginalFilename = "condlg",
            .CompanyName = "CodeHz",
            .LegalCopyright = "Copyright 2020 CodeHz"
        },
    });

    const testStep = b.step("test", "Do alg test");
    const condlg_test = b.addTest("src/condlg.zig");
    condlg_test.setTarget(target);
    testStep.dependOn(&condlg_test.step);
}
