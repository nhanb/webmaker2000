const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const print = std.debug.print;
const zqlite = @import("zqlite");
const sql = @import("sql.zig");

const Server = @This();

gpa: mem.Allocator,
address: net.Address,
net_server: net.Server,
file_path: [:0]const u8,
thread: std.Thread,

pub fn init(gpa: mem.Allocator, port: u16, file_path: [:0]const u8) !*Server {
    print("Server starting at port {d}\n", .{port});

    var server = try gpa.create(Server);
    server.* = .{
        .gpa = gpa,
        .address = try net.Address.parseIp4("127.0.0.1", port),
        .net_server = try server.address.listen(.{ .reuse_address = true }),
        .file_path = try gpa.dupeZ(u8, file_path),
        .thread = try std.Thread.spawn(.{}, start_server, .{server}),
    };

    return server;
}

pub fn deinit(self: *Server) void {
    {
        // Send shutdown request
        var client = std.http.Client{ .allocator = self.gpa };
        defer client.deinit();
        _ = client.fetch(.{
            .method = .POST,
            .location = .{
                .uri = .{
                    .scheme = "http",
                    .host = .{ .raw = "127.0.0.1" },
                    .path = .{ .raw = SHUTDOWN_PATH },
                    .port = self.net_server.listen_address.getPort(),
                },
            },
        }) catch |err| {
            print("Failed to send shutdown request: {}\n", .{err});
            unreachable;
        };
    }

    self.thread.join();
    self.gpa.free(self.file_path);
    self.net_server.deinit();
    self.gpa.destroy(self);
    print("Server shut down cleanly.\n", .{});
}

/// When server receives a POST to this path, it will stop waiting for
/// connections, letting the server thread end.
const SHUTDOWN_PATH = "/_wm2k_shutdown";

fn start_server(self: *Server) !void {
    var conn = try zqlite.Conn.init(
        self.file_path,
        zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.ReadOnly,
    );
    defer conn.close();

    while (true) {
        var connection = self.net_server.accept() catch |err| {
            print("Connection to client interrupted: {}\n", .{err});
            continue;
        };
        defer connection.stream.close();

        var read_buffer: [1024]u8 = undefined;
        var http_server = http.Server.init(connection, &read_buffer);

        var request = http_server.receiveHead() catch |err| {
            print("Could not read head: {}\n", .{err});
            continue;
        };

        if (request.head.method == .POST and
            std.mem.eql(u8, request.head.target, SHUTDOWN_PATH))
        {
            request.respond("bye", .{}) catch unreachable;
            break;
        }

        handle_request(&request, conn) catch |err| {
            print("Could not handle request: {}\n", .{err});
            continue;
        };
    }
}

fn handle_request(request: *http.Server.Request, conn: zqlite.Conn) !void {
    print("Server serving {s}\n", .{request.head.target});

    // very dumb code just to confirm db connection works
    const id = try std.fmt.parseInt(i64, request.head.target["/".len..], 10);
    const row = try sql.selectRow(conn, "select title from post where id=?", .{id});
    if (row) |r| {
        defer r.deinit();
        try request.respond(r.text(0), .{});
    } else {
        try request.respond("nope", .{});
    }
}
