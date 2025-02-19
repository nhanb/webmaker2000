const std = @import("std");
const print = std.debug.print;
const dvui = @import("dvui");
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const history = @import("history.zig");
const theme = @import("theme.zig");
const generate = @import("generate.zig");
const djot = @import("djot.zig");
const queries = @import("queries.zig");

comptime {
    std.debug.assert(dvui.backend_kind == .sdl);
}
const Backend = dvui.backend;

const EXTENSION = "wm2k";

const Post = struct {
    id: i64,
    title: []u8,
    content: []u8,
};

const Scene = enum(i64) {
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

const Modal = enum(i64) {
    confirm_post_deletion = 0,
};

const Database = struct {
    gpa: std.mem.Allocator,
    conn: zqlite.Conn,
    file_path: []const u8,

    fn output_path(self: Database) []const u8 {
        return self.file_path[0 .. self.file_path.len - 1 - EXTENSION.len];
    }

    fn init(gpa: std.mem.Allocator, conn: zqlite.Conn, file_path: []const u8) !Database {
        return .{
            .gpa = gpa,
            .conn = conn,
            .file_path = try gpa.dupe(u8, file_path),
        };
    }

    fn deinit(self: Database) void {
        self.conn.close();
        self.gpa.free(self.file_path);
    }
};

const GuiState = union(enum) {
    no_file_opened: void,
    opened: struct {
        scene: SceneState,
        status_text: []const u8,
        history: struct {
            undos: []history.Barrier,
            redos: []history.Barrier,
        },
    },

    fn read(maybe_db: ?Database, arena: std.mem.Allocator) !GuiState {
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

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    // init SDL backend (creates and owns OS window)
    var backend = try Backend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .min_size = .{ .w = 500.0, .h = 350.0 },
        .vsync = true,
        .title = "WebMaker2000",
        .icon = @embedFile("favicon.png"),
    });
    defer backend.deinit();

    // init dvui Window (maps onto a single OS window)
    var default_theme = theme.default();
    var win = try dvui.Window.init(
        @src(),
        gpa,
        backend.backend(),
        .{ .theme = &default_theme },
    );
    defer win.deinit();

    // Add Noto Sans font which supports Vietnamese
    try win.font_bytes.put(
        "Noto",
        dvui.FontBytesEntry{
            .ttf_bytes = @embedFile("fonts/NotoSans-Regular.ttf"),
            .allocator = null,
        },
    );
    try win.font_bytes.put(
        "NotoBd",
        dvui.FontBytesEntry{
            .ttf_bytes = @embedFile("fonts/NotoSans-Bold.ttf"),
            .allocator = null,
        },
    );

    // Extra keybinds
    try win.keybinds.putNoClobber("wm2k_undo", .{ .control = true, .shift = false, .key = .z });
    try win.keybinds.putNoClobber("wm2k_redo", .{ .control = true, .shift = true, .key = .z });

    var maybe_db: ?Database = null;
    defer if (maybe_db) |db| db.deinit();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);
    if (argv.len == 2 and std.mem.endsWith(u8, argv[1], "." ++ EXTENSION)) {
        // TODO: how to handle errors (e.g. file not found) here? We can't draw
        // anything at this stage.

        const existing_file_path = argv[1];
        const conn = try zqlite.open(existing_file_path, zqlite.OpenFlags.EXResCode);
        maybe_db = try Database.init(gpa, conn, existing_file_path);

        try sql.execNoArgs(conn, "pragma foreign_keys = on");

        // TODO: read user_version pragma to check if the db was initialized
        // correctly. If not, abort with error message somehow.

        const filename = std.fs.path.basename(existing_file_path);
        try queries.setStatusText(gpa, conn, "Opened {s}", .{existing_file_path});
        const window_title = try std.fmt.allocPrintZ(gpa, "{s} - WebMaker2000", .{filename});
        defer gpa.free(window_title);
        _ = Backend.c.SDL_SetWindowTitle(backend.window, window_title);
    }

    try djot.init(gpa);
    defer djot.deinit();

    // Create arena that is reset every frame:
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // In each frame:
    // - make sure arena is reset
    // - read gui_state fresh from database
    // - (the is are dvui boilerplate)
    main_loop: while (true) {
        defer _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 * 100 });

        const gui_state = try GuiState.read(maybe_db, arena.allocator());

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

        try gui_frame(&gui_state, &maybe_db, &backend, arena.allocator(), gpa);

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
    maybe_db: *?Database,
    backend: *dvui.backend,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator, // for data that needs to survive to next frame
) !void {
    var background = try dvui.overlay(@src(), .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .name = .fill_window },
    });
    defer background.deinit();

    switch (gui_state.*) {

        // Let user either create new or open existing wm2k file:
        .no_file_opened => {
            var vbox = try dvui.box(@src(), .vertical, .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
            defer vbox.deinit();

            try dvui.label(@src(), "Would you like to create a new site or open an existing one?", .{}, .{});

            {
                var hbox = try dvui.box(@src(), .horizontal, .{
                    .expand = .both,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                });
                defer hbox.deinit();

                if (try dvui.button(@src(), "New...", .{}, .{})) {
                    if (try dvui.dialogNativeFileSave(arena, .{
                        .title = "Create new site",
                        .filters = &.{"*." ++ EXTENSION},
                    })) |new_file_path| {
                        // Assuming the native "save file" dialog has
                        // already asked for user confirmation if the chosen
                        // file already exists, we can safely delete it now:
                        std.fs.deleteFileAbsolute(new_file_path) catch |err| {
                            if (err != error.FileNotFound) {
                                return err;
                            }
                        };

                        const conn = try zqlite.open(
                            new_file_path,
                            zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.Create,
                        );
                        maybe_db.* = try Database.init(gpa, conn, new_file_path);

                        try sql.execNoArgs(conn, "pragma foreign_keys = on");

                        try sql.execNoArgs(conn, "begin exclusive");
                        try sql.execNoArgs(conn, @embedFile("db_schema.sql"));
                        try history.createTriggers(history.Undo, conn, arena);
                        try history.createTriggers(history.Redo, conn, arena);
                        try sql.execNoArgs(conn, "commit");

                        const filename = std.fs.path.basename(new_file_path);
                        try queries.setStatusText(arena, conn, "Created {s}", .{filename});
                        _ = Backend.c.SDL_SetWindowTitle(
                            backend.window,
                            try std.fmt.allocPrintZ(arena, "{s} - WebMaker2000", .{filename}),
                        );
                    }
                }

                if (try dvui.button(@src(), "Open...", .{}, .{})) {
                    if (try dvui.dialogNativeFileOpen(arena, .{
                        .title = "Open site",
                        .filters = &.{"*." ++ EXTENSION},
                    })) |existing_file_path| {
                        const conn = try zqlite.open(existing_file_path, zqlite.OpenFlags.EXResCode);
                        maybe_db.* = try Database.init(gpa, conn, existing_file_path);

                        try sql.execNoArgs(conn, "pragma foreign_keys = on");

                        // TODO: read user_version pragma to check if the db was initialized
                        // correctly. If not, abort with error message somehow.

                        const filename = std.fs.path.basename(existing_file_path);
                        try queries.setStatusText(arena, conn, "Opened {s}", .{filename});
                        _ = Backend.c.SDL_SetWindowTitle(
                            backend.window,
                            try std.fmt.allocPrintZ(arena, "{s} - WebMaker2000", .{filename}),
                        );
                    }
                }
            }
        },

        // User has actually opened a file => show main UI:
        .opened => |state| {
            const db = maybe_db.*.?;
            const conn = db.conn;

            // Handle keyboard shortcuts
            const evts = dvui.events();
            for (evts) |*e| {
                switch (e.evt) {
                    .key => |key| {
                        if (key.action == .down) {
                            if (key.matchBind("wm2k_undo")) {
                                try history.undo(conn, state.history.undos);
                            } else if (key.matchBind("wm2k_redo")) {
                                try history.redo(conn, state.history.redos);
                            }
                        }
                    },
                    else => {},
                }
            }

            // Actual GUI starts here

            var scroll = try dvui.scrollArea(
                @src(),
                .{},
                .{
                    .expand = .both,
                    .color_fill = .{ .name = .fill_window },
                    .corner_radius = dvui.Rect.all(0),
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

                const undo_opts: dvui.Options = if (state.history.undos.len == 0) .{
                    .color_text = .{ .name = .fill_press },
                    .color_text_press = .{ .name = .fill_press },
                    .color_fill_hover = .{ .name = .fill_control },
                    .color_fill_press = .{ .name = .fill_control },
                    .color_accent = .{ .name = .fill_control },
                } else .{};

                if (try theme.button(@src(), "Undo", .{}, undo_opts)) {
                    try history.undo(conn, state.history.undos);
                }

                const redo_opts: dvui.Options = if (state.history.redos.len == 0) .{
                    .color_text = .{ .name = .fill_press },
                    .color_text_press = .{ .name = .fill_press },
                    .color_fill_hover = .{ .name = .fill_control },
                    .color_fill_press = .{ .name = .fill_control },
                    .color_accent = .{ .color = dvui.Color{ .a = 0x00 } },
                } else .{};

                if (try theme.button(@src(), "Redo", .{}, redo_opts)) {
                    try history.redo(conn, state.history.redos);
                }

                if (try theme.button(@src(), "Generate", .{}, .{})) {
                    var timer = try std.time.Timer.start();

                    const output_path = db.output_path();

                    var cwd = std.fs.cwd();
                    try cwd.deleteTree(output_path);

                    var out_dir = try cwd.makeOpenPath(output_path, .{});
                    defer out_dir.close();
                    try generate.all(conn, arena, out_dir);

                    const miliseconds = timer.read() / 1_000_000;
                    try queries.setStatusText(
                        arena,
                        conn,
                        "Generated static site in {d}ms.",
                        .{miliseconds},
                    );
                }
            }

            switch (state.scene) {
                .listing => |scene| {
                    try dvui.label(@src(), "Posts", .{}, .{ .font_style = .title_1 });

                    if (try theme.button(@src(), "New post", .{}, .{})) {
                        try conn.transaction();
                        errdefer conn.rollback();

                        try history.foldRedos(conn, state.history.redos);

                        try sql.execNoArgs(conn, "insert into post default values");
                        const new_post_id = conn.lastInsertedRowId();
                        try sql.exec(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                        try sql.exec(conn, "update gui_scene_editing set post_id = ?", .{new_post_id});

                        try queries.setStatusText(arena, conn, "Created post #{d}.", .{new_post_id});

                        try history.addUndoBarrier(.create_post, conn);

                        try conn.commit();
                    }

                    for (scene.posts, 0..) |post, i| {
                        var hbox = try dvui.box(@src(), .horizontal, .{ .id_extra = i });
                        defer hbox.deinit();

                        if (try theme.button(@src(), "Edit", .{}, .{})) {
                            try conn.transaction();
                            errdefer conn.rollback();
                            try history.foldRedos(conn, state.history.redos);
                            try sql.exec(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                            try sql.exec(conn, "update gui_scene_editing set post_id = ?", .{post.id});
                            try history.addUndoBarrier(.change_scene, conn);
                            try conn.commit();
                        }

                        try dvui.label(
                            @src(),
                            "{d}. {s}",
                            .{ post.id, post.title },
                            .{ .id_extra = i, .gravity_y = 0.5 },
                        );
                    }

                    try dvui.label(@src(), "{s}", .{state.status_text}, .{
                        .gravity_x = 1,
                        .gravity_y = 1,
                    });
                },

                .editing => |scene| {
                    var vbox = try dvui.box(
                        @src(),
                        .vertical,
                        .{ .expand = .both },
                    );
                    defer vbox.deinit();

                    try dvui.label(@src(), "Editing post #{d}", .{scene.post.id}, .{ .font_style = .title_1 });

                    var title_buf: []u8 = scene.post.title;
                    var content_buf: []u8 = scene.post.content;

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
                        try conn.transaction();
                        errdefer conn.rollback();
                        defer conn.commit() catch unreachable;
                        try history.foldRedos(conn, state.history.redos);
                        try sql.exec(conn, "update post set title=? where id=?", .{ title_entry.getText(), scene.post.id });
                        try history.addUndoBarrier(.update_post_title, conn);
                    }
                    title_entry.deinit();

                    try dvui.label(@src(), "Content:", .{}, .{});
                    var content_entry = try dvui.textEntry(
                        @src(),
                        .{
                            .multiline = true,
                            .break_lines = true,
                            .scroll_horizontal = false,
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
                        try conn.transaction();
                        errdefer conn.rollback();
                        try history.foldRedos(conn, state.history.redos);
                        try sql.exec(conn, "update post set content=? where id=?", .{ content_entry.getText(), scene.post.id });
                        try history.addUndoBarrier(.update_post_content, conn);
                        try conn.commit();
                    }
                    content_entry.deinit();

                    {
                        var hbox = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal });
                        defer hbox.deinit();

                        // Only show "Back" button if post is not empty
                        // TODO there might be a more elegant way to implement "discard
                        // newly created post if empty".
                        if ((scene.post.title.len > 0 or scene.post.content.len > 0) and
                            try theme.button(@src(), "Back", .{}, .{}))
                        {
                            try conn.transaction();
                            errdefer conn.rollback();
                            try history.foldRedos(conn, state.history.redos);
                            try conn.exec("update gui_scene set current_scene=?", .{@intFromEnum(Scene.listing)});
                            try history.addUndoBarrier(.change_scene, conn);
                            try conn.commit();
                        }

                        if (try theme.button(@src(), "Delete", .{}, .{})) {
                            try sql.execNoArgs(conn, std.fmt.comptimePrint(
                                "insert into gui_modal(kind) values({d})",
                                .{@intFromEnum(Modal.confirm_post_deletion)},
                            ));
                        }

                        try dvui.label(@src(), "{s}", .{state.status_text}, .{
                            .gravity_x = 1,
                            .gravity_y = 1,
                        });
                    }

                    // Post deletion confirmation modal:
                    if (scene.show_confirm_delete) {
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

                            if (try theme.button(@src(), "Yes", .{}, .{})) {
                                try conn.transaction();
                                errdefer conn.rollback();
                                try history.foldRedos(conn, state.history.redos);

                                try sql.exec(conn, "delete from post where id=?", .{scene.post.id});
                                try sql.exec(conn, "update gui_scene set current_scene=?", .{@intFromEnum(Scene.listing)});
                                try sql.execNoArgs(conn, std.fmt.comptimePrint(
                                    "delete from gui_modal where kind={d}",
                                    .{@intFromEnum(Modal.confirm_post_deletion)},
                                ));
                                try queries.setStatusText(
                                    arena,
                                    conn,
                                    "Deleted post #{d}.",
                                    .{scene.post.id},
                                );

                                try history.addUndoBarrier(.delete_post, conn);
                                try conn.commit();
                            }

                            if (try theme.button(@src(), "No", .{}, .{})) {
                                try sql.execNoArgs(conn, std.fmt.comptimePrint(
                                    "delete from gui_modal where kind={d}",
                                    .{@intFromEnum(Modal.confirm_post_deletion)},
                                ));
                            }
                        }
                    }
                },
            }
        },
    }
}
