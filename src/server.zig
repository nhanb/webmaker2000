const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const print = std.debug.print;
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const djot = @import("djot.zig");
const sitefs = @import("sitefs.zig");
const constants = @import("constants.zig");

pub const SERVER_CMD = "server";

pub const Server = struct {
    process: std.process.Child,

    /// Spawns a child process that starts the http preview server.
    /// Assumes cwd() is already the site's dir, in other words, the same dir
    /// the contains `site.wm2k`.
    pub fn init(gpa: mem.Allocator, port: u16) !Server {
        var exe_path_buf: [1024 * 5]u8 = undefined;
        const exe_path = try std.fs.selfExePath(&exe_path_buf);

        var port_buf: [5]u8 = undefined;
        const port_str = std.fmt.bufPrintIntToSlice(&port_buf, port, 10, .upper, .{});

        const command: []const []const u8 = &.{
            exe_path,
            SERVER_CMD,
            port_str,
        };
        var proc = std.process.Child.init(command, gpa);
        try proc.spawn();

        return .{ .process = proc };
    }

    pub fn deinit(self: *Server) void {
        _ = self.process.kill() catch unreachable;
    }
};

/// Main entry point of the preview server subprocess:
pub fn serve(gpa: mem.Allocator, port_str: []const u8) !void {
    const port = try std.fmt.parseInt(u16, port_str, 10);

    try djot.init(gpa);
    defer djot.deinit();

    print("Server starting at http://localhost:{d}\n", .{port});

    const address = try net.Address.parseIp4("127.0.0.1", port);
    var net_server = try address.listen(.{ .reuse_address = true });

    while (true) {
        print("Waiting for new connection...\n", .{});
        const connection = net_server.accept() catch |err| {
            print("Connection to client interrupted: {}\n", .{err});
            continue;
        };
        var thread = try std.Thread.spawn(.{}, handle_request, .{connection});
        thread.detach();
    }
}

fn handle_request(connection: net.Server.Connection) !void {
    print("Incoming request\n", .{});
    defer connection.stream.close();

    var read_buffer: [1024 * 512]u8 = undefined;
    var http_server = http.Server.init(connection, &read_buffer);

    var request = http_server.receiveHead() catch |err| {
        print("Could not read head: {}\n", .{err});
        return;
    };

    print("Server serving {s}\n", .{request.head.target});

    var conn = try zqlite.Conn.init(
        constants.SITE_FILE,
        zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.ReadOnly,
    );
    defer conn.close();

    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    var arena_imp = std.heap.ArenaAllocator.init(gpa);
    defer arena_imp.deinit();
    const arena = arena_imp.allocator();

    const response = try sitefs.serve(arena, conn, request.head.target);
    switch (response) {
        .success => |body| {
            try request.respond(body, .{});
        },
        .not_found => {
            try request.respond("404 Not Found", .{ .status = .not_found });
        },
        .redirect => |path| {
            try request.respond("", .{
                .status = .moved_permanently,
                .extra_headers = &.{
                    .{
                        .name = "Location",
                        .value = path,
                    },
                },
            });
        },
    }
}
