const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const zqlite = @import("zqlite");
const sql = @import("sql.zig");

pub fn post(
    out_dir: fs.Dir,
    path: []const u8,
    title: []const u8,
    content: []const u8,
) !void {
    var post_dir = try out_dir.makeOpenPath(path, .{});
    defer post_dir.close();

    var index_file = try post_dir.createFile("index.html", .{ .truncate = true });
    defer index_file.close();

    // TODO: proper html template
    try index_file.writeAll("<h1>");
    try index_file.writeAll(title);
    try index_file.writeAll("</h1>\n");
    try index_file.writeAll("<p>");
    try index_file.writeAll(content);
    try index_file.writeAll("</p>\n");

    print("Generated {s}/{s}: {s}\n", .{ path, "index.html", title });
}

pub fn all(conn: zqlite.Conn, out_dir: fs.Dir) !void {
    var timer = try std.time.Timer.start();
    defer print("** generate.all() took {}us\n", .{timer.read() / 1_000});

    var rows = try sql.rows(conn, "select id, title, content from post order by id", .{});
    defer rows.deinit();
    while (rows.next()) |row| {
        const id = row.text(0);
        const title = row.text(1);
        const content = row.text(2);
        try post(out_dir, id, title, content);
    }
    try sql.check(rows.err, conn);
}
