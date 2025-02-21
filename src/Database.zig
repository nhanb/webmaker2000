const std = @import("std");
const zqlite = @import("zqlite");
const EXTENSION = @import("constants.zig").EXTENSION;

const Database = @This();

gpa: std.mem.Allocator,
conn: zqlite.Conn,
file_path: []const u8,

pub fn output_path(self: Database) []const u8 {
    return self.file_path[0 .. self.file_path.len - 1 - EXTENSION.len];
}

pub fn init(gpa: std.mem.Allocator, conn: zqlite.Conn, file_path: []const u8) !Database {
    return .{
        .gpa = gpa,
        .conn = conn,
        .file_path = try gpa.dupe(u8, file_path),
    };
}

pub fn deinit(self: Database) void {
    self.conn.close();
    self.gpa.free(self.file_path);
}
