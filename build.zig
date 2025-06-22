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
    switch (target.result.os.tag) {
        .windows => {
            const dvui_dep = b.dependency("dvui", .{
                .target = target,
                .optimize = optimize,
                .backend = .dx11,
            });
            exe.root_module.addImport("dvui", dvui_dep.module("dvui_dx11"));
        },
        else => {
            const dvui_dep = b.dependency("dvui", .{
                .target = target,
                .optimize = optimize,
                .backend = .sdl3,
            });
            exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
        },
    }

    // zqlite
    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    if (b.systemIntegrationOption("sqlite3", .{})) {
        exe.linkSystemLibrary("sqlite3");
    } else {
        exe.addCSourceFile(.{
            .file = b.path("lib/sqlite3.c"),
            .flags = &[_][]const u8{
                "-DSQLITE_DQS=0",
                "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
                "-DSQLITE_USE_ALLOCA=1",
                "-DSQLITE_THREADSAFE=1",
                "-DSQLITE_TEMP_STORE=3",
                "-DSQLITE_ENABLE_API_ARMOR=1",
                "-DSQLITE_ENABLE_UNLOCK_NOTIFY",
                "-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1",
                "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600",
                "-DSQLITE_OMIT_DECLTYPE=1",
                "-DSQLITE_OMIT_DEPRECATED=1",
                "-DSQLITE_OMIT_LOAD_EXTENSION=1",
                "-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
                "-DSQLITE_OMIT_SHARED_CACHE",
                "-DSQLITE_OMIT_TRACE=1",
                "-DSQLITE_OMIT_UTF16=1",
                "-DHAVE_USLEEP=0",
            },
        });
    }
    exe.root_module.addImport("zqlite", zqlite.module("zqlite"));

    // ziglua is now called lua_wrapper for some reason
    const use_system_lua = b.systemIntegrationOption("lua", .{});
    if (use_system_lua) {
        exe.linkSystemLibrary("lua");
    }
    const lua_wrapper = b.dependency("lua_wrapper", .{
        .target = target,
        .optimize = optimize,
        .shared = use_system_lua,
    });
    exe.root_module.addImport("lua_wrapper", lua_wrapper.module("lua_wrapper"));

    exe.addWin32ResourceFile(.{ .file = b.path("res/resource.rc") });

    const compile_step = b.step("compile-wm2k", "Compile wm2k");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(compile_step);

    const run_step = b.step("run", "Run wm2k");
    run_step.dependOn(&run_cmd.step);
}
