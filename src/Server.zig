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

pub fn init(gpa: mem.Allocator, port: u16, file_path: [:0]const u8) !*Server {
    print("Server starting at http://localhost:{d}\n", .{port});

    var server = try gpa.create(Server);
    server.* = .{
        .gpa = gpa,
        .address = try net.Address.parseIp4("127.0.0.1", port),
        .net_server = try server.address.listen(.{ .reuse_address = true }),
        .file_path = try gpa.dupeZ(u8, file_path),
    };

    // Run server in separate thread, then detach() so it doesn't block the
    // whole program from exiting. Worst case scenario, the thread gets killed
    // before its sqlite connection is properly closed, but since this is a
    // read-only sqlite connection, it's Probably Okay (tm).
    //
    // I previously tried to conditionally break the loop in start_server by
    // sending a special http request to the server itself, but Chrome on
    // Windows would automatically open a connection without sending anything:
    // <https://stackoverflow.com/questions/47336535/why-does-chrome-open-a-connection-but-not-send-anything>
    // , presumably to appear more speedy. This unfortunately deadlocked
    // the loop before our special "shutdown" request could be received.
    //
    // So here we are, detach()-ing the thread into the ether and trying not to
    // worry too much about it...
    var thread = try std.Thread.spawn(.{}, start_server, .{server});
    thread.detach();

    return server;
}

pub fn deinit(self: *Server) void {
    self.net_server.deinit();
    self.gpa.free(self.file_path);
    self.gpa.destroy(self);
    print("Server shut down.\n", .{});
}

fn start_server(self: *Server) !void {
    while (true) {
        print("Waiting for new connection...\n", .{});
        const connection = self.net_server.accept() catch |err| {
            print("Connection to client interrupted: {}\n", .{err});
            continue;
        };
        var thread = try std.Thread.spawn(.{}, handle_request, .{ connection, self.file_path });
        thread.detach();
    }
}

fn handle_request(connection: net.Server.Connection, file_path: [:0]const u8) !void {
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
        file_path,
        zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.ReadOnly,
    );
    defer conn.close();

    // very dumb code just to confirm db connection works
    const id = request.head.target["/".len..];
    const row = try sql.selectRow(conn, "select title from post where id=?", .{id});
    if (row) |r| {
        defer r.deinit();
        try request.respond(r.text(0), .{});
    } else {
        try request.respond("nope", .{});
    }
}
