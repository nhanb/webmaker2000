const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const zqlite = @import("zqlite");
const ziglua = @import("ziglua");
const sql = @import("sql.zig");
const djot_lua = @embedFile("djot.lua");

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

pub fn all(conn: zqlite.Conn, arena: std.mem.Allocator, out_dir: fs.Dir) !void {
    var timer = try std.time.Timer.start();
    defer print("** generate.all() took {}ms\n", .{timer.read() / 1_000_000});

    var rows = try sql.rows(conn, "select id, title, content from post order by id", .{});
    defer rows.deinit();
    while (rows.next()) |row| {
        const id = row.text(0);
        const title = row.text(1);
        const content = try djotToHtml(arena, row.text(2));
        try post(out_dir, id, title, content);
    }
    try sql.check(rows.err, conn);
}

// TODO: don't recreate the lua vm every time
pub fn djotToHtml(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var lua = try ziglua.Lua.init(arena);
    defer lua.deinit();

    lua.openLibs(); // load lua standard libraries

    lua.doString(djot_lua) catch |err| {
        print("lua error: {s}\n", .{try lua.toString(-1)});
        return err;
    };

    lua.doString(
        \\djot = require("djot")
        \\function djotToHtml(input)
        \\  return djot.render_html(djot.parse(input))
        \\end
    ) catch |err| {
        print("lua error: {s}\n", .{try lua.toString(-1)});
        return err;
    };

    _ = try lua.getGlobal("djotToHtml");
    _ = lua.pushString(input);
    lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
        print("lua error: {s}\n", .{try lua.toString(-1)});
        return err;
    };

    const result = arena.dupeZ(u8, try lua.toString(1));

    // All done. Pop previous result from stack.
    lua.pop(1);

    return result;
}
