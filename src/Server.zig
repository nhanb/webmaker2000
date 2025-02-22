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
file_path: [:0]const u8 = undefined,

thread: std.Thread,
running: bool = true,
running_mut: std.Thread.Mutex = .{},

pub fn init(gpa: mem.Allocator, port: u16, file_path: [:0]const u8) !*Server {
    var server = try gpa.create(Server);
    server.* = .{
        .gpa = gpa,
        .address = try net.Address.parseIp4("127.0.0.1", port),
        .net_server = try server.address.listen(.{ .reuse_address = true }),
        .file_path = try gpa.dupeZ(u8, file_path),
        .running = true,
        .thread = try std.Thread.spawn(.{}, start_server, .{server}),
    };

    return server;
}

pub fn deinit(self: *Server) void {
    print("Server.deinit() starting\n", .{});
    self.running_mut.lock();
    self.running = false;
    self.running_mut.unlock();

    self.thread.join();
    self.gpa.free(self.file_path);
    self.net_server.deinit();
    self.gpa.destroy(self);
    print("Server.deinit() done.\n", .{});
}

fn start_server(self: *Server) void {
    print("Starting server\n", .{});

    var running = true;

    while (running) {
        self.running_mut.lock();
        running = self.running;
        self.running_mut.unlock();

        print("running = {}\n", .{running});

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

        var conn = zqlite.Conn.init(
            self.file_path,
            zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.ReadOnly,
        ) catch |err| {
            print("Could not open db: {}\n", .{err});
            continue;
        };
        defer conn.close();

        handle_request(&request, conn) catch |err| {
            print("Could not handle request: {}\n", .{err});
            continue;
        };
    }
}

fn handle_request(request: *http.Server.Request, conn: zqlite.Conn) !void {
    print("Handling request for {s}\n", .{request.head.target});

    // very dumb code just to confirm db connection works
    const id = try std.fmt.parseInt(i64, request.head.target["/".len..], 10);
    var row = try sql.selectRow(conn, "select title from post where id=?", .{id});
    defer row.?.deinit();
    try request.respond(row.?.text(0), .{});
}
