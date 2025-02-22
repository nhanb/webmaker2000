const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const print = std.debug.print;

const Server = @This();

gpa: mem.Allocator = undefined,
address: net.Address = undefined,
net_server: net.Server = undefined,

pub fn init(gpa: mem.Allocator, port: u16, file_path: [:0]const u8) !*Server {
    _ = file_path;

    var server = try gpa.create(Server);
    server.gpa = gpa;
    server.address = try net.Address.parseIp4("127.0.0.1", port);
    server.net_server = try server.address.listen(.{ .reuse_address = true });

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
        handle_request(&request) catch |err| {
            std.debug.print("Could not handle request: {}", .{err});
            continue;
        };
    }
}

fn handle_request(request: *http.Server.Request) !void {
    std.debug.print("Handling request for {s}\n", .{request.head.target});
    try request.respond("Hello http!\n", .{});
}

pub fn deinit(self: *Server) void {
    self.net_server.deinit();
    self.gpa.destroy(self);
    print("Server.deinit() done.\n", .{});
}
