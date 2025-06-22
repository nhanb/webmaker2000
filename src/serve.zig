const std = @import("std");
const mem = std.mem;
const server = @import("server.zig");

pub fn main() !u8 {
    var dba_impl = std.heap.DebugAllocator(.{}){};
    const global_dba = dba_impl.allocator();
    defer _ = dba_impl.deinit();

    const argv = try std.process.argsAlloc(global_dba);
    defer std.process.argsFree(global_dba, argv);

    // wm2k <SERVER_CMD> <PORT>
    // to start a web server.
    // This is to be run as a subprocess called by the main program.
    // It assumes the current working directory is the same dir that contains
    // the site.wm2k file.

    if (argv.len != 2) {
        std.debug.print("Usage: wm2k <PORT>\n", .{});
        return 1;
    }

    try server.serve(global_dba, argv[1]);
    return 0;
}
