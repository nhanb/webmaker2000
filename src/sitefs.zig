const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const allocPrint = std.fmt.allocPrint;
const mem = std.mem;
const fs = std.fs;
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const djot = @import("djot.zig");
const html = @import("html.zig");

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
    dir: []const []const u8,
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
    const arena = args.arena;
    const conn = args.conn;
    const list_children = args.list_children;

    print("stat: {s}\n", .{path});

    const prefix = if (path.len == 0)
        ""
    else
        try allocPrint(arena, "{s}/", .{path});

    // Root dir:
    if (path.len == 0) {
        if (!list_children) return .{ .dir = &.{} };

        var children = std.ArrayList([]const u8).init(arena);

        // index.html
        try children.append(try allocPrint(arena, "{s}index.html", .{prefix}));

        // a dir for each post
        // TODO: right now it's id but it should be slug in the future.
        var rows = try sql.rows(conn, "select id from post order by id", .{});
        defer rows.deinit();
        while (rows.next()) |row| {
            const slug = try arena.dupe(u8, row.text(0));
            try children.append(
                try allocPrint(arena, "{s}{s}", .{ prefix, slug }),
            );
        }

        return .{ .dir = children.items };
    }

    assert(path[0] != '/');
    assert(path[path.len - 1] != '/');

    // Home page
    if (mem.eql(u8, path, "index.html")) {
        var h = html.Builder{ .allocator = arena };

        var posts = std.ArrayList(html.Element).init(arena);

        var rows = try sql.rows(conn, "select id, title from post order by id desc", .{});
        defer rows.deinit();
        while (rows.next()) |row| {
            const slug = try arena.dupe(u8, row.text(0));
            const title = try arena.dupe(u8, row.text(1));
            try posts.append(
                h.li(null, .{
                    h.a(
                        .{ .href = try allocPrint(arena, "{s}/", .{slug}) },
                        .{title},
                    ),
                }),
            );
        }

        var content = h.html(
            .{ .lang = "en" },
            .{
                h.head(null, .{
                    h.meta(.{ .charset = "utf-8" }),
                    h.meta(.{ .name = "viewport", .content = "width=device-width, initial-scale=1.0" }),
                    h.title(null, .{"Home | WebMaker2000 Preview"}),
                    //h.link(.{ .rel = "stylesheet", .href = static.style_css.url_path }),
                    //h.link(.{ .rel = "icon", .type = "image/png", .href = static.developers_png.url_path }),
                }),
                h.body(null, .{
                    h.h1(null, .{"Home"}),
                    h.ul(null, .{posts.items}),
                }),
            },
        );

        return .{ .file = try content.toHtml(arena) };
    }

    var parts = mem.splitScalar(u8, path, '/');
    const post_slug = parts.next().?;

    const maybe_row = try sql.selectRow(
        conn,
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
        // Post dir only has index.html as child for now.
        // Later post assets will also end up here.
        const child = try allocPrint(arena, "{s}index.html", .{prefix});
        var children = try std.ArrayList([]const u8).initCapacity(arena, 1);
        try children.append(child);
        return .{ .dir = children.items };
    }

    // At this point we're sure our caller is requesting /<slug>/index.html

    const title = row.text(0);
    const content = row.text(1);
    const content_html = try djot.toHtml(arena, content);

    const full_html = try std.fmt.allocPrint(arena,
        \\<head><title>{s}</title></head>
        \\<h1>{s}</h1>
        \\{s}
    , .{ title, title, content_html });

    return .{ .file = full_html };
}

pub fn generate(
    arena: mem.Allocator,
    conn: zqlite.Conn,
    in_path: []const u8,
    out_dir: fs.Dir,
) !void {
    switch (try read(.{
        .conn = conn,
        .path = in_path,
        .arena = arena,
        .list_children = true,
    })) {
        .file => |data| {
            try out_dir.writeFile(.{
                .sub_path = in_path,
                .data = data,
            });
        },
        .dir => |children| {
            if (in_path.len > 0) try out_dir.makeDir(in_path);
            for (children) |child_path| {
                try generate(arena, conn, child_path, out_dir);
            }
        },
        .not_found => unreachable,
    }
}
