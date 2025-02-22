const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const print = std.debug.print;
const zqlite = @import("zqlite");
const sql = @import("sql.zig");

const Server = @This();

gpa: mem.Allocator = undefined,
address: net.Address = undefined,
net_server: net.Server = undefined,
conn: zqlite.Conn = undefined,

pub fn init(gpa: mem.Allocator, port: u16, file_path: [:0]const u8) !*Server {
    var server = try gpa.create(Server);
    server.gpa = gpa;
    server.address = try net.Address.parseIp4("127.0.0.1", port);
    server.net_server = try server.address.listen(.{ .reuse_address = true });
    server.conn = try zqlite.Conn.init(file_path, zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.ReadOnly);

    // TODO: creating an sqlite connection in one thread then using it in
    // another is probably bad. Is there a better way?
    var thread = try std.Thread.spawn(.{}, start_server, .{server});
    thread.detach();

    return server;
}

fn start_server(self: *Server) void {
    var net_server = self.net_server;

    while (true) {
        var connection = net_server.accept() catch |err| {
            std.debug.print("Connection to client interrupted: {}\n", .{err});
            continue;
        };
        defer connection.stream.close();

        var read_buffer: [1024]u8 = undefined;
        var http_server = http.Server.init(connection, &read_buffer);

        var request = http_server.receiveHead() catch |err| {
            std.debug.print("Could not read head: {}\n", .{err});
            continue;
        };
        self.handle_request(&request) catch |err| {
            std.debug.print("Could not handle request: {}", .{err});
            continue;
        };
    }
}

fn handle_request(self: *Server, request: *http.Server.Request) !void {
    std.debug.print("Handling request for {s}\n", .{request.head.target});

    // very dumb code just to confirm db connection works
    const id = try std.fmt.parseInt(i64, request.head.target["/".len..], 10);
    var row = try sql.selectRow(self.conn, "select title from post where id=?", .{id});
    defer row.?.deinit();
    try request.respond(row.?.text(0), .{});
}

pub fn deinit(self: *Server) void {
    self.conn.close();
    self.net_server.deinit();
    self.gpa.destroy(self);
    print("Server.deinit() done.\n", .{});
}
