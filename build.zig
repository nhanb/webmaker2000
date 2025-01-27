const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "wm2k",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // dvui
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl"));

    // zqlite
    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");
    exe.root_module.addImport("zqlite", zqlite.module("zqlite"));

    // ziglua
    const ziglua = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ziglua", ziglua.module("ziglua"));

    const compile_step = b.step("compile-wm2k", "Compile wm2k");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(compile_step);

    const run_step = b.step("run", "Run wm2k");
    run_step.dependOn(&run_cmd.step);
}
