const std = @import("std");
const zqlite = @import("zqlite");

pub fn selectInt(conn: *zqlite.Conn, sql: []const u8) !i64 {
    var row = (conn.row(sql, .{}) catch |err| {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err;
    }).?;
    defer row.deinit();
    return row.int(0);
}

pub fn execPrintErr(conn: *zqlite.Conn, sql: []const u8, args: anytype) !void {
    conn.exec(sql, args) catch |err| {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err;
    };
}
