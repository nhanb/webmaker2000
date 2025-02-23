const std = @import("std");
const print = std.debug.print;

const zqlite = @import("zqlite");

const Database = @import("Database.zig");
const history = @import("history.zig");
const sql = @import("sql.zig");

pub const Core = struct {
    state: GuiState,

    pub fn handleAction(self: *Core, conn: zqlite.Conn, action: Action) !void {
        try conn.transaction();
        errdefer conn.rollback();

        switch (action) {
            .edit_post => |post_id| {
                try history.foldRedos(conn, self.state.opened.history.redos);
                try sql.exec(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                try sql.exec(conn, "update gui_scene_editing set post_id = ?", .{post_id});
            },
            else => {
                print("TODO action: {}\n", .{action});
            },
        }

        try history.addUndoBarrier(.change_scene, conn);
        try conn.commit();
    }
};

pub const ActionEnum = enum(i64) {
    create_post = 0,
    update_post_title = 1,
    update_post_content = 2,
    delete_post = 3,
    edit_post = 4,
    list_posts = 5,
};

pub const Action = union(ActionEnum) {
    create_post: void,
    update_post_title: struct { id: i64, title: []const u8 },
    update_post_content: struct { id: i64, content: []const u8 },
    delete_post: i64,
    edit_post: i64,
    list_posts: void,
};

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
