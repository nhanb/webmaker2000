// Thin wrappers around zqlite, mostly to print the actual sql errors to make
// debugging less painful.

const std = @import("std");
const zqlite = @import("zqlite");

pub fn openWithSaneDefaults(path: [:0]const u8, flags: c_int) !zqlite.Conn {
    const conn = try zqlite.open(path, flags);
    try execNoArgs(conn,
        \\PRAGMA foreign_keys = 1;
        \\PRAGMA busy_timeout = 3000;
    );
    return conn;
}

pub fn exec(conn: zqlite.Conn, sql: []const u8, args: anytype) !void {
    conn.exec(sql, args) catch |err| {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err;
    };
}

pub fn execNoArgs(conn: zqlite.Conn, sql: [*:0]const u8) !void {
    conn.execNoArgs(sql) catch |err| {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err;
    };
}

pub fn rows(conn: zqlite.Conn, sql: []const u8, args: anytype) !zqlite.Rows {
    return conn.rows(sql, args) catch |err| {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err;
    };
}

pub fn check(err: ?zqlite.Error, conn: zqlite.Conn) !void {
    if (err != null) {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err.?;
    }
}

pub fn selectRow(conn: zqlite.Conn, sql: []const u8, args: anytype) !?zqlite.Row {
    return (conn.row(sql, args) catch |err| {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err;
    });
}

/// Assumes the result is only 1 row with 1 column, which is an int.
pub fn selectInt(conn: zqlite.Conn, sql: []const u8) !i64 {
    var row = (conn.row(sql, .{}) catch |err| {
        std.debug.print(">> sql error: {s}\n", .{conn.lastError()});
        return err;
    }).?;
    defer row.deinit();
    return row.int(0);
}
