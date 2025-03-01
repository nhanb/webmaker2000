const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const allocPrint = std.fmt.allocPrint;
const mem = std.mem;
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const djot = @import("djot.zig");

const MAX_URL_LEN = 2048; // https://stackoverflow.com/a/417184

pub const Response = union(enum) {
    not_found: void,
    redirect: []const u8,
    success: []const u8,
};

pub fn serve(arena: mem.Allocator, conn: zqlite.Conn, path: []const u8) !Response {
    assert(path.len >= 1); // even root must be "/", not ""

    if (path[path.len - 1] == '/') {
        return serve(arena, conn, try allocPrint(arena, "{s}index.html", .{path}));
    }

    const read_result =
        try read(.{
            .arena = arena,
            .conn = conn,
            .path = path["/".len..],
        });
    return switch (read_result) {
        .file => |content| .{ .success = content },
        .dir => .{ .redirect = try allocPrint(arena, "{s}/", .{path}) },
        .not_found => .not_found,
    };
}

pub const ReadResult = union(enum) {
    file: []const u8,
    dir: [][]const u8,
    not_found: void,
};

const ReadArgs = struct {
    arena: mem.Allocator,
    conn: zqlite.Conn,
    path: []const u8,
    list_children: bool = false,
};

pub fn read(args: ReadArgs) !ReadResult {
    const path = args.path;
    print("stat: {s}\n", .{path});

    if (path.len == 0) {
        // TODO: list root dir's children
        return .{ .dir = &.{} };
    }

    assert(path[0] != '/');
    assert(path[path.len - 1] != '/');

    var parts = mem.splitScalar(u8, path, '/');
    const post_slug = parts.next().?;

    const maybe_row = try sql.selectRow(
        args.conn,
        "select title, content from post where id=?",
        .{post_slug},
    );
    var row = if (maybe_row) |r| r else return .not_found;
    defer row.deinit();

    // Now that we're sure the url points to a post that exists, we can examine
    // the later parts if any:
    if (parts.next()) |second_part| {
        // TODO In the future we'll support uploading assets to a post, in which
        // case we'll serve them here, but for now, only "index.html" is valid.
        if (!mem.eql(u8, second_part, "index.html")) {
            return .not_found;
        }
    } else {
        // TODO: list post dir's children (only index.html for now)
        return .{ .dir = &.{} };
    }

    // At this point we're sure our caller is requesting /<slug>/index.html

    const title = row.text(0);
    const content = row.text(1);
    const content_html = try djot.toHtml(args.arena, content);

    const full_html = try std.fmt.allocPrint(args.arena,
        \\<head><title>{s}</title></head>
        \\<h1>{s}</h1>
        \\{s}
    , .{ title, title, content_html });

    return .{ .file = full_html };
}

// TODO: children(), walk() to generate static site
