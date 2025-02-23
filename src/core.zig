const std = @import("std");
const history = @import("history.zig");
const Database = @import("Database.zig");
const sql = @import("sql.zig");

const Post = struct {
    id: i64,
    title: []u8,
    content: []u8,
};

pub const Scene = enum(i64) {
    listing = 0,
    editing = 1,
};

const SceneState = union(Scene) {
    listing: struct {
        posts: []Post,
    },
    editing: struct {
        post: Post,
        show_confirm_delete: bool,
    },
};

pub const Modal = enum(i64) {
    confirm_post_deletion = 0,
};

pub const GuiState = union(enum) {
    no_file_opened: void,
    opened: struct {
        scene: SceneState,
        status_text: []const u8,
        history: struct {
            undos: []history.Barrier,
            redos: []history.Barrier,
        },
    },

    pub fn read(maybe_db: ?Database, arena: std.mem.Allocator) !GuiState {
        const db = maybe_db orelse return .no_file_opened;
        const conn = db.conn;

        const current_scene: Scene = @enumFromInt(
            try sql.selectInt(conn, "select current_scene from gui_scene"),
        );

        const scene: SceneState = switch (current_scene) {
            .listing => blk: {
                var posts = std.ArrayList(Post).init(arena);
                var rows = try sql.rows(conn, "select id, title, content from post order by id desc", .{});
                defer rows.deinit();
                while (rows.next()) |row| {
                    const post = Post{
                        .id = row.int(0),
                        .title = try arena.dupe(u8, row.text(1)),
                        .content = try arena.dupe(u8, row.text(2)),
                    };
                    try posts.append(post);
                }
                try sql.check(rows.err, conn);

                break :blk .{ .listing = .{ .posts = posts.items } };
            },

            .editing => blk: {
                var row = (try sql.selectRow(conn,
                    \\select p.id, p.title, p.content
                    \\from post p
                    \\inner join gui_scene_editing e on e.post_id = p.id
                , .{})).?;
                defer row.deinit();

                const show_confirm_delete = (try sql.selectInt(
                    conn,
                    std.fmt.comptimePrint(
                        "select exists (select * from gui_modal where kind = {d})",
                        .{@intFromEnum(Modal.confirm_post_deletion)},
                    ),
                ) == 1);

                break :blk .{
                    .editing = .{
                        .post = Post{
                            .id = row.int(0),
                            .title = try arena.dupe(u8, row.text(1)),
                            .content = try arena.dupe(u8, row.text(2)),
                        },
                        .show_confirm_delete = show_confirm_delete,
                    },
                };
            },
        };

        const status_text_row = try sql.selectRow(
            conn,
            "select status_text from gui_status_text where expires_at > datetime('now')",
            .{},
        );
        const status_text = if (status_text_row) |row| blk: {
            defer row.deinit();
            break :blk try arena.dupe(u8, row.text(0));
        } else "";

        return .{
            .opened = .{
                .scene = scene,
                .status_text = status_text,
                .history = .{
                    .undos = try history.getBarriers(history.Undo, conn, arena),
                    .redos = try history.getBarriers(history.Redo, conn, arena),
                },
            },
        };
    }
};
