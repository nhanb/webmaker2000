const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const zqlite = @import("zqlite");

const Database = @import("Database.zig");
const history = @import("history.zig");
const sql = @import("sql.zig");
const queries = @import("queries.zig");
const maths = @import("maths.zig");
const constants = @import("constants.zig");
const blobstore = @import("blobstore.zig");

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
            .update_post_slug => |data| {
                try sql.exec(conn, "update post set slug=? where id=?", .{ data.slug, data.id });
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
            .add_attachments => |payload| blk: {
                // First check if all files are eligible as attachments
                for (payload.file_paths) |path| {
                    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
                    defer file.close();
                    const stat = try file.stat();
                    if (stat.size > constants.MAX_ATTACHMENT_BYTES) {
                        // TODO show error dialog instead of just status text
                        try queries.setStatusText(arena, conn,
                            \\File {s} too big! ({s})
                        , .{
                            std.fs.path.basename(path),
                            try maths.humanReadableSize(arena, @intCast(stat.size)),
                        });
                        break :blk;
                    }
                }

                // Now actually add them:
                for (payload.file_paths) |path| {
                    const blob = try blobstore.store(arena, path);

                    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
                    defer file.close();
                    try sql.exec(
                        conn,
                        \\insert into attachment (post_id, name, hash, size_bytes) values (?,?,?,?)
                        \\on conflict (post_id, name) do update set hash=?
                    ,
                        .{
                            payload.post_id,
                            std.fs.path.basename(path),
                            &blob.hash,
                            blob.size,
                            &blob.hash,
                        },
                    );
                }
                try queries.setStatusText(
                    arena,
                    conn,
                    "Added {d} attachment{s}.",
                    .{
                        payload.file_paths.len,
                        if (payload.file_paths.len > 1) "s" else "",
                    },
                );
            },
            .delete_selected_attachments => |post_id| {
                try sql.exec(
                    conn,
                    \\delete from attachment
                    \\where post_id = ?
                    \\  and id in (select id from gui_attachment_selected)
                ,
                    .{post_id},
                );
                try queries.setStatusText(arena, conn, "Deleted selected attachment(s).", .{});
            },
            .select_attachment => |id| {
                try sql.exec(
                    conn,
                    "insert into gui_attachment_selected (id) values (?)",
                    .{id},
                );
            },
            .deselect_attachment => |id| {
                try sql.exec(
                    conn,
                    "delete from gui_attachment_selected where id=?",
                    .{id},
                );
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
    update_post_slug = 2,
    update_post_content = 3,
    edit_post = 4,
    list_posts = 5,
    delete_post = 6,
    delete_post_yes = 7,
    delete_post_no = 8,
    add_attachments = 9,
    delete_selected_attachments = 10,
    select_attachment = 11,
    deselect_attachment = 12,
};

pub const Action = union(ActionEnum) {
    create_post: void,
    update_post_title: struct { id: i64, title: []const u8 },
    update_post_slug: struct { id: i64, slug: []const u8 },
    update_post_content: struct { id: i64, content: []const u8 },
    edit_post: i64,
    list_posts: void,
    delete_post: i64,
    delete_post_yes: i64,
    delete_post_no: i64,
    add_attachments: struct { post_id: i64, file_paths: []const []const u8 },
    delete_selected_attachments: i64,
    select_attachment: i64,
    deselect_attachment: i64,
};

const Post = struct {
    id: i64,
    title: []u8,
    slug: []u8,
    content: []u8,
};

pub const Scene = enum(i64) {
    listing = 0,
    editing = 1,
};

pub const PostErrors = struct {
    empty_title: bool,
    empty_slug: bool,
    empty_content: bool,
    duplicate_slug: bool,

    pub fn hasErrors(self: PostErrors) bool {
        inline for (@typeInfo(PostErrors).@"struct".fields) |field| {
            if (@field(self, field.name)) return true;
        }
        return false;
    }
};

const Attachment = struct {
    id: i64,
    name: []const u8,
    size: []const u8,
    selected: bool,
};

const SceneState = union(Scene) {
    listing: struct {
        posts: []Post,
    },
    editing: struct {
        post: Post,
        post_errors: PostErrors,
        show_confirm_delete: bool,
        attachments: []Attachment,
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
                var rows = try sql.rows(conn, "select id, title, slug, content from post order by id desc", .{});
                defer rows.deinit();
                while (rows.next()) |row| {
                    const post = Post{
                        .id = row.int(0),
                        .title = try arena.dupe(u8, row.text(1)),
                        .slug = try arena.dupe(u8, row.text(2)),
                        .content = try arena.dupe(u8, row.text(3)),
                    };
                    try posts.append(post);
                }
                try sql.check(rows.err, conn);

                break :blk .{ .listing = .{ .posts = posts.items } };
            },

            .editing => blk: {
                var row = (try sql.selectRow(conn,
                    \\select p.id, p.title, p.slug, p.content
                    \\from post p
                    \\inner join gui_scene_editing e on e.post_id = p.id
                , .{})).?;
                defer row.deinit();

                const post = Post{
                    .id = row.int(0),
                    .title = try arena.dupe(u8, row.text(1)),
                    .slug = try arena.dupe(u8, row.text(2)),
                    .content = try arena.dupe(u8, row.text(3)),
                };

                var err_row = (try sql.selectRow(conn,
                    \\select
                    \\  empty_title,
                    \\  empty_slug,
                    \\  empty_content,
                    \\  duplicate_slug
                    \\from gui_current_post_err
                , .{})).?;
                defer err_row.deinit();

                const show_confirm_delete = (try sql.selectInt(
                    conn,
                    std.fmt.comptimePrint(
                        "select exists (select * from gui_modal where kind = {d})",
                        .{@intFromEnum(Modal.confirm_post_deletion)},
                    ),
                ) == 1);

                var attachment_rows = try sql.rows(
                    conn,
                    \\select a.id, a.name, s.id is not null, size_bytes
                    \\from attachment a
                    \\  left outer join gui_attachment_selected s on s.id = a.id
                    \\where post_id = ?
                    \\order by a.id
                ,
                    .{post.id},
                );
                var attachments: std.ArrayList(Attachment) = .init(arena);
                while (attachment_rows.next()) |arow| {
                    try attachments.append(Attachment{
                        .id = arow.int(0),
                        .name = try arena.dupe(u8, arow.text(1)),
                        .selected = arow.boolean(2),
                        .size = try maths.humanReadableSize(arena, arow.int(3)),
                    });
                }
                try sql.check(attachment_rows.err, conn);

                break :blk .{
                    .editing = .{
                        .post = post,
                        .post_errors = .{
                            .empty_title = err_row.boolean(0),
                            .empty_slug = err_row.boolean(1),
                            .empty_content = err_row.boolean(2),
                            .duplicate_slug = err_row.boolean(3),
                        },
                        .show_confirm_delete = show_confirm_delete,
                        .attachments = attachments.items,
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
