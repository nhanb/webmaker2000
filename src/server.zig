const std = @import("std");
const Database = @import("Database.zig");
const zqlite = @import("zqlite");
const httpz = @import("httpz");

pub fn run(port: u16, file_path: [:0]const u8) !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_impl.allocator();

    const conn = try zqlite.open(file_path, zqlite.OpenFlags.EXResCode);

    var db = try Database.init(gpa, conn, file_path);
    defer db.deinit();

    var app = App{
        .db = db,
    };

    var server = try httpz.Server(*App).init(gpa, .{ .port = port }, &app);
    defer {
        // clean shutdown, finishes serving any live request
        server.stop();
        server.deinit();
    }

    var router = server.router(.{});
    router.get("/*", serve, .{});

    std.debug.print("Preview server up: http://localhost:{d}\n", .{port});
    try server.listen();
}

const App = struct {
    db: Database,
};

fn serve(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;
    try std.fmt.format(res.writer(), "Hello!", .{});
}
