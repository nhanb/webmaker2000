const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const zqlite = @import("zqlite");

const Database = @import("Database.zig");
const history = @import("history.zig");
const sql = @import("sql.zig");
const queries = @import("queries.zig");

pub const Core = struct {
    state: GuiState = undefined,
    maybe_db: ?Database = null,

    pub fn deinit(self: *Core) void {
        if (self.maybe_db) |db| {
            db.deinit();
        }
    }

    pub fn handleAction(self: *Core, conn: zqlite.Conn, arena: Allocator, action: Action) !void {
        if (self.state == .no_file_opened) {
            return error.ActionNotImplemented;
        }

        try sql.execNoArgs(conn, "begin immediate");
        errdefer conn.rollback();

        try queries.clearStatusText(conn);

        const skip_history = history.shouldSkip(action);
        if (!skip_history) {
            try history.foldRedos(conn, self.state.opened.history.redos);
        }

        switch (action) {
            .create_post => {
                try sql.execNoArgs(conn, "insert into post default values");
                const new_post_id = conn.lastInsertedRowId();
                try sql.exec(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                try sql.exec(conn, "update gui_scene_editing set post_id = ?", .{new_post_id});

                try queries.setStatusText(arena, conn, "Created post #{d}.", .{new_post_id});
            },
            .update_post_title => |data| {
                try sql.exec(conn, "update post set title=? where id=?", .{ data.title, data.id });
            },
            .update_post_content => |data| {
                try sql.exec(conn, "update post set content=? where id=?", .{ data.content, data.id });
            },
            .edit_post => |post_id| {
                try sql.exec(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                try sql.exec(conn, "update gui_scene_editing set post_id = ?", .{post_id});
            },
            .list_posts => {
                try conn.exec("update gui_scene set current_scene=?", .{@intFromEnum(Scene.listing)});
            },
            .delete_post => {
                try sql.execNoArgs(conn, std.fmt.comptimePrint(
                    "insert into gui_modal(kind) values({d})",
                    .{@intFromEnum(Modal.confirm_post_deletion)},
                ));
            },
            .delete_post_yes => |post_id| {
                try sql.exec(conn, "delete from post where id=?", .{post_id});
                try sql.exec(conn, "update gui_scene set current_scene=?", .{@intFromEnum(Scene.listing)});
                try sql.execNoArgs(conn, std.fmt.comptimePrint(
                    "delete from gui_modal where kind={d}",
                    .{@intFromEnum(Modal.confirm_post_deletion)},
                ));
                try queries.setStatusText(
                    arena,
                    conn,
                    "Deleted post #{d}.",
                    .{post_id},
                );
            },
            .delete_post_no => {
                try sql.execNoArgs(conn, std.fmt.comptimePrint(
                    "delete from gui_modal where kind={d}",
                    .{@intFromEnum(Modal.confirm_post_deletion)},
                ));
            },
        }

        if (!skip_history) {
            try history.addUndoBarrier(action, conn);
        }

        try conn.commit();
    }
};

pub const ActionEnum = enum(i64) {
    create_post = 0,
    update_post_title = 1,
    update_post_content = 2,
    edit_post = 3,
    list_posts = 4,
    delete_post = 5,
    delete_post_yes = 6,
    delete_post_no = 7,
};

pub const Action = union(ActionEnum) {
    create_post: void,
    update_post_title: struct { id: i64, title: []const u8 },
    update_post_content: struct { id: i64, content: []const u8 },
    edit_post: i64,
    list_posts: void,
    delete_post: i64,
    delete_post_yes: i64,
    delete_post_no: i64,
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
