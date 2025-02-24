const std = @import("std");
const zqlite = @import("zqlite");
const sql = @import("sql.zig");

pub fn setStatusText(
    gpa: std.mem.Allocator,
    conn: zqlite.Conn,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(text);

    return sql.exec(conn,
        \\update gui_status_text
        \\set status_text=?, expires_at = datetime('now', '+5 seconds')
    , .{text});
}

pub fn setStatusTextNoAlloc(conn: zqlite.Conn, text: []const u8) !void {
    return sql.exec(conn,
        \\update gui_status_text
        \\set status_text=?, expires_at = datetime('now', '+5 seconds')
    , .{text});
}

pub fn clearStatusText(conn: zqlite.Conn) !void {
    return sql.execNoArgs(conn, "update gui_status_text set status_text=''");
}
