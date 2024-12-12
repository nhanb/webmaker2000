const std = @import("std");
const dvui = @import("dvui");
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const history = @import("history.zig");
comptime {
    std.debug.assert(dvui.backend_kind == .sdl);
}
const Backend = dvui.backend;

// TODO: read path from argv instead
const DB_PATH = "Site1.wm2k";

const Post = struct {
    id: i64,
    title: []u8,
    content: []u8,
};

const Scene = enum {
    listing,
    editing,
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

const Modal = enum {
    confirm_post_deletion,
};

const GuiState = struct {
    scene: SceneState,
    history: struct {
        undos: []history.Barrier,
        redos: []history.Barrier,
    },

    fn read(conn: zqlite.Conn, arena: std.mem.Allocator) !GuiState {
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

        return GuiState{
            .scene = scene,
            .history = .{
                .undos = try history.getBarriers(history.Undo, conn, arena),
                .redos = try history.getBarriers(history.Redo, conn, arena),
            },
        };
    }
};

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // init SDL backend (creates and owns OS window)
    var backend = try Backend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = true,
        .title = "WebMaker2000",
    });
    defer backend.deinit();

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer win.deinit();

    // Attempt to open db file at `path`.
    // If it doesn't exist, create and initialize its schema.

    var is_new_db = false;
    const conn = zqlite.open(DB_PATH, zqlite.OpenFlags.EXResCode) catch |err| blk: {
        if (err == error.CantOpen) {
            is_new_db = true;
            break :blk try zqlite.open(
                DB_PATH,
                zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.Create,
            );
        }
        return err;
    };

    try sql.execNoArgs(conn, "pragma foreign_keys = on");

    if (is_new_db) {
        try sql.execNoArgs(conn, "begin exclusive");
        try sql.execNoArgs(conn, @embedFile("db_schema.sql"));
        try history.createTriggers(history.Undo, conn, gpa);
        try sql.execNoArgs(conn, "commit");
    } else {
        // TODO: read user_version pragma to check if the db was initialized
        // correctly. If not, abort with error message somehow.
    }

    defer conn.close();

    // Create arena that is reset every frame:
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // In each frame:
    // - make sure arena is reset
    // - read gui_state fresh from database
    // - (the is are dvui boilerplate)
    main_loop: while (true) {
        defer _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 * 100 });

        const gui_state = try GuiState.read(conn, arena.allocator());

        for (gui_state.history.undos) |undo| {
            std.debug.print("Undo: {d}: {s}\n", .{ undo.id, undo.description });
        }
        for (gui_state.history.redos) |redo| {
            std.debug.print("Redo: {d}: {s}\n", .{ redo.id, redo.description });
        }
        std.debug.print("---\n", .{});

        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(backend.hasEvent());

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        const quit = try backend.addAllEvents(&win);
        if (quit) break :main_loop;

        // if dvui widgets might not cover the whole window, then need to clear
        // the previous frame's render
        _ = Backend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 255);
        _ = Backend.c.SDL_RenderClear(backend.renderer);

        try gui_frame(&gui_state, arena.allocator(), conn);

        // marks end of dvui frame, don't call dvui functions after this
        // - sends all dvui stuff to backend for rendering, must be called before renderPresent()
        const end_micros = try win.end(.{});

        // cursor management
        backend.setCursor(win.cursorRequested());
        backend.textInputRect(win.textInputRequested());

        // render frame to OS
        backend.renderPresent();

        // waitTime and beginWait combine to achieve variable framerates
        const wait_event_micros = win.waitTime(end_micros, null);
        backend.waitEventTimeout(wait_event_micros);
    }
}

fn gui_frame(
    gui_state: *const GuiState,
    arena: std.mem.Allocator,
    conn: zqlite.Conn,
) !void {
    var scroll = try dvui.scrollArea(
        @src(),
        .{},
        .{
            .expand = .both,
            .color_fill = .{ .name = .fill_window },
        },
    );
    defer scroll.deinit();

    {
        var toolbar = try dvui.box(
            @src(),
            .horizontal,
            .{ .expand = .horizontal },
        );
        defer toolbar.deinit();

        if (try dvui.button(@src(), "Undo", .{}, .{})) {
            if (gui_state.history.undos.len > 0) {
                try history.undo(arena, conn, gui_state.history.undos);
            }
        }

        if (try dvui.button(@src(), "Redo", .{}, .{})) {
            if (gui_state.history.redos.len > 0) {
                try history.redo(arena, conn, gui_state.history.redos);
            }
        }
    }

    switch (gui_state.scene) {
        .listing => |state| {
            try dvui.label(@src(), "Posts", .{}, .{ .font_style = .title_1 });

            if (try dvui.button(@src(), "New post", .{}, .{})) {
                try conn.transaction();
                errdefer conn.rollback();
                try sql.execNoArgs(conn, "insert into post default values");
                const new_post_id = conn.lastInsertedRowId();
                try sql.exec(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                try sql.exec(conn, "update gui_scene_editing set post_id = ?", .{new_post_id});
                try conn.commit();
            }

            for (state.posts, 0..) |post, i| {
                var hbox = try dvui.box(@src(), .horizontal, .{ .id_extra = i });
                defer hbox.deinit();

                if (try dvui.button(@src(), "Edit", .{}, .{})) {
                    try conn.transaction();
                    errdefer conn.rollback();
                    try sql.exec(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                    try sql.exec(conn, "update gui_scene_editing set post_id = ?", .{post.id});
                    try conn.commit();
                }

                try dvui.label(
                    @src(),
                    "{d}. {s}",
                    .{ post.id, post.title },
                    .{ .id_extra = i, .gravity_y = 0.5 },
                );
            }
        },

        .editing => |state| {
            var vbox = try dvui.box(
                @src(),
                .vertical,
                .{ .expand = .both },
            );
            defer vbox.deinit();

            try dvui.label(@src(), "Editing post #{d}", .{state.post.id}, .{ .font_style = .title_1 });

            var title_buf: []u8 = state.post.title;
            var content_buf: []u8 = state.post.content;

            try dvui.label(@src(), "Title:", .{}, .{});
            var title_entry = try dvui.textEntry(
                @src(),
                .{
                    .text = .{
                        .buffer_dynamic = .{
                            .backing = &title_buf,
                            .allocator = arena,
                        },
                    },
                },
                .{ .expand = .horizontal },
            );
            if (title_entry.text_changed) {
                try sql.exec(conn, "update post set title=? where id=?", .{ title_entry.getText(), state.post.id });
                try history.addBarrier(history.Undo, conn, "Update post title");
            }
            title_entry.deinit();

            try dvui.label(@src(), "Content:", .{}, .{});
            var content_entry = try dvui.textEntry(
                @src(),
                .{
                    .multiline = true,
                    .text = .{
                        .buffer_dynamic = .{
                            .backing = &content_buf,
                            .allocator = arena,
                        },
                    },
                },
                .{
                    .expand = .both,
                    .min_size_content = .{ .h = 80 },
                },
            );
            if (content_entry.text_changed) {
                try sql.exec(conn, "update post set content=? where id=?", .{ content_entry.getText(), state.post.id });
            }
            content_entry.deinit();

            {
                var hbox = try dvui.box(@src(), .horizontal, .{});
                defer hbox.deinit();

                if (try dvui.button(@src(), "Back", .{}, .{})) {
                    try conn.exec("update gui_scene set current_scene=?", .{@intFromEnum(Scene.listing)});
                }

                if (try dvui.button(@src(), "Delete", .{}, .{})) {
                    try sql.execNoArgs(conn, std.fmt.comptimePrint(
                        "insert into gui_modal(kind) values({d})",
                        .{@intFromEnum(Modal.confirm_post_deletion)},
                    ));
                }
            }

            // Post deletion confirmation modal:
            if (state.show_confirm_delete) {
                var modal = try dvui.floatingWindow(
                    @src(),
                    .{ .modal = true },
                    .{ .max_size_content = .{ .w = 500 } },
                );
                defer modal.deinit();

                try dvui.windowHeader("Confirm deletion", "", null);
                try dvui.label(@src(), "Are you sure you want to delete this post?", .{}, .{});

                {
                    _ = try dvui.spacer(@src(), .{}, .{ .expand = .vertical });
                    var hbox = try dvui.box(@src(), .horizontal, .{ .gravity_x = 1.0 });
                    defer hbox.deinit();

                    if (try dvui.button(@src(), "Yes", .{}, .{})) {
                        try conn.transaction();
                        errdefer conn.rollback();
                        try sql.exec(conn, "delete from post where id=?", .{state.post.id});
                        try sql.exec(conn, "update gui_scene set current_scene=?", .{@intFromEnum(Scene.listing)});
                        try sql.execNoArgs(conn, std.fmt.comptimePrint(
                            "delete from gui_modal where kind={d}",
                            .{@intFromEnum(Modal.confirm_post_deletion)},
                        ));
                        try conn.commit();
                    }

                    if (try dvui.button(@src(), "No", .{}, .{})) {
                        try sql.execNoArgs(conn, std.fmt.comptimePrint(
                            "delete from gui_modal where kind={d}",
                            .{@intFromEnum(Modal.confirm_post_deletion)},
                        ));
                    }
                }
            }
        },
    }
}
