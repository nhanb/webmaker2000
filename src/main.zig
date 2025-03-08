const std = @import("std");
const print = std.debug.print;
const allocPrint = std.fmt.allocPrint;
const dvui = @import("dvui");
const zqlite = @import("zqlite");

const sql = @import("sql.zig");
const history = @import("history.zig");
const theme = @import("theme.zig");
const djot = @import("djot.zig");
const queries = @import("queries.zig");
const Database = @import("Database.zig");
const server = @import("server.zig");
const constants = @import("constants.zig");
const PORT = constants.PORT;
const EXTENSION = constants.EXTENSION;
const core_ = @import("core.zig");
const GuiState = core_.GuiState;
const Modal = core_.Modal;
const Core = core_.Core;
const sitefs = @import("sitefs.zig");

comptime {
    std.debug.assert(dvui.backend_kind == .sdl);
}
const Backend = dvui.backend;

var maybe_server: ?server.Server = null;

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_impl.allocator();
    defer _ = gpa_impl.deinit();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    // wm2k <SERVER_CMD> <DB_PATH> <PORT>
    // to start a web server.
    // This is to be run as a subprocess called by the main program.
    if (argv.len == 4 and std.mem.eql(u8, argv[1], server.SERVER_CMD)) {
        try server.serve(gpa, argv[2], argv[3]);
        return;
    }

    // init SDL backend (creates and owns OS window)
    var backend = try Backend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .min_size = .{ .w = 500, .h = 500 },
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

    var core = Core{};
    defer core.deinit();

    if (argv.len == 2 and std.mem.endsWith(u8, argv[1], "." ++ EXTENSION)) {
        // TODO: how to handle errors (e.g. file not found) here? We can't draw
        // anything at this stage.

        const existing_file_path = argv[1];
        const conn = try sql.openWithSaneDefaults(existing_file_path, zqlite.OpenFlags.EXResCode);
        core.maybe_db = try Database.init(gpa, conn, existing_file_path);

        try sql.execNoArgs(conn, "pragma foreign_keys = on");

        // TODO: read user_version pragma to check if the db was initialized
        // correctly. If not, abort with error message somehow.

        const filename = std.fs.path.basename(existing_file_path);
        try queries.setStatusText(gpa, conn, "Opened {s}", .{existing_file_path});
        const window_title = try std.fmt.allocPrintZ(gpa, "{s} - WebMaker2000", .{filename});
        defer gpa.free(window_title);
        _ = Backend.c.SDL_SetWindowTitle(backend.window, window_title);

        maybe_server = try server.Server.init(gpa, existing_file_path, PORT);
    }

    try djot.init(gpa);
    defer djot.deinit();

    // Create arena that is reset every frame:
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // In each frame:
    // - make sure arena is reset
    // - read gui_state fresh from database
    // - (the rest is dvui boilerplate)
    main_loop: while (true) {
        defer _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 * 100 });

        core.state = try GuiState.read(core.maybe_db, arena.allocator());

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

        try gui_frame(&core, &backend, arena.allocator(), gpa);

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

    if (maybe_server) |_| {
        maybe_server.?.deinit();
    }
}

fn gui_frame(
    core: *Core,
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

    switch (core.state) {

        // Let user either create new or open existing wm2k file:
        .no_file_opened => {
            var vbox = try dvui.box(@src(), .vertical, .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
            defer vbox.deinit();

            try dvui.label(@src(), "Create new site or open an existing one?", .{}, .{});

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
                        // Apparently interaction with the system file dialog
                        // does not count as user interaction in dvui, so
                        // there's a chance the UI won't be refreshed after a
                        // file is chosen. Therefore, we need to manually
                        // tell dvui to draw the next frame right after this
                        // frame:
                        dvui.refresh(null, @src(), null);

                        // Assuming the native "save file" dialog has
                        // already asked for user confirmation if the chosen
                        // file already exists, we can safely delete it now:
                        std.fs.deleteFileAbsolute(new_file_path) catch |err| {
                            if (err != error.FileNotFound) {
                                return err;
                            }
                        };

                        const conn = try sql.openWithSaneDefaults(
                            new_file_path,
                            zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.Create,
                        );
                        core.maybe_db = try Database.init(gpa, conn, new_file_path);

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

                        maybe_server = try server.Server.init(gpa, new_file_path, PORT);
                    }
                }

                if (try dvui.button(@src(), "Open...", .{}, .{})) {
                    if (try dvui.dialogNativeFileOpen(arena, .{
                        .title = "Open site",
                        .filters = &.{"*." ++ EXTENSION},
                    })) |existing_file_path| {
                        // Apparently interaction with the system file dialog
                        // does not count as user interaction in dvui, so
                        // there's a chance the UI won't be refreshed after a
                        // file is chosen. Therefore, we need to manually
                        // tell dvui to draw the next frame right after this
                        // frame:
                        dvui.refresh(null, @src(), null);

                        const conn = try sql.openWithSaneDefaults(existing_file_path, zqlite.OpenFlags.EXResCode);
                        core.maybe_db = try Database.init(gpa, conn, existing_file_path);

                        try sql.execNoArgs(conn, "pragma foreign_keys = on");

                        // TODO: read user_version pragma to check if the db was initialized
                        // correctly. If not, abort with error message somehow.

                        const filename = std.fs.path.basename(existing_file_path);
                        try queries.setStatusText(arena, conn, "Opened {s}", .{filename});
                        _ = Backend.c.SDL_SetWindowTitle(
                            backend.window,
                            try std.fmt.allocPrintZ(arena, "{s} - WebMaker2000", .{filename}),
                        );

                        maybe_server = try server.Server.init(gpa, existing_file_path, PORT);
                    }
                }
            }
        },

        // User has actually opened a file => show main UI:
        .opened => |state| {
            const db = core.maybe_db.?;
            const conn = db.conn;

            const undos = state.history.undos;
            const redos = state.history.redos;

            // Handle keyboard shortcuts
            const evts = dvui.events();
            for (evts) |*e| {
                switch (e.evt) {
                    .key => |key| {
                        if (key.action == .down) {
                            if (key.matchBind("wm2k_undo")) {
                                try history.undo(conn, undos);
                            } else if (key.matchBind("wm2k_redo")) {
                                try history.redo(conn, redos);
                            }
                        }
                    },
                    else => {},
                }
            }

            // Actual GUI starts here

            var frame = try dvui.box(@src(), .vertical, .{
                .expand = .both,
                .background = false,
            });
            defer frame.deinit();

            {
                var toolbar = try dvui.box(
                    @src(),
                    .horizontal,
                    .{ .expand = .horizontal },
                );
                defer toolbar.deinit();

                if (try theme.button(@src(), "Undo", .{}, .{}, undos.len == 0)) {
                    try history.undo(conn, undos);
                }

                if (try theme.button(@src(), "Redo", .{}, .{}, redos.len == 0)) {
                    try history.redo(conn, redos);
                }

                const generate_disabled = state.scene == .editing and state.scene.editing.post_errors.hasErrors();
                if (try theme.button(@src(), "Generate", .{}, .{}, generate_disabled)) {
                    var timer = try std.time.Timer.start();

                    const output_path = db.output_path();

                    var cwd = std.fs.cwd();
                    try cwd.deleteTree(output_path);

                    var out_dir = try cwd.makeOpenPath(output_path, .{});
                    defer out_dir.close();
                    try sitefs.generate(arena, conn, "", out_dir);

                    const miliseconds = timer.read() / 1_000_000;
                    try queries.setStatusText(
                        arena,
                        conn,
                        "Generated static site in {d}ms.",
                        .{miliseconds},
                    );
                }

                var buf: [100]u8 = undefined;
                const fps_str = std.fmt.bufPrint(&buf, "{d:0>3.0} fps", .{dvui.FPS()}) catch unreachable;
                try dvui.label(@src(), "{s}", .{fps_str}, .{ .gravity_x = 1 });

                const url = switch (state.scene) {
                    .listing => try allocPrint(arena, "http://localhost:{d}", .{PORT}),
                    .editing => |s| if (s.post_errors.hasErrors())
                        ""
                    else
                        try allocPrint(arena, "http://localhost:{d}/{s}", .{ PORT, s.post.slug }),
                };
                if (url.len > 0 and try dvui.labelClick(@src(), "{s}", .{url}, .{
                    .gravity_x = 1.0,
                    .color_text = .{ .color = .{ .r = 0x00, .g = 0x00, .b = 0xff } },
                })) {
                    try dvui.openURL(url);
                }
            }

            switch (state.scene) {
                .listing => |scene| {
                    try dvui.label(@src(), "Posts", .{}, .{ .font_style = .title_1 });

                    if (try theme.button(@src(), "New post", .{}, .{}, false)) {
                        try core.handleAction(conn, arena, .create_post);
                    }

                    {
                        var scroll = try dvui.scrollArea(@src(), .{}, .{
                            .expand = .both,
                            .max_size_content = .{
                                // FIXME: how to avoid hardcoded max height?
                                .h = dvui.windowRect().h - 170,
                            },
                            //.padding = .{ .x = 5 },
                            .margin = .all(5),
                            .corner_radius = .all(0),
                            .border = .all(1),
                            .color_fill = .{ .name = .fill_window },
                        });
                        defer scroll.deinit();

                        for (scene.posts, 0..) |post, i| {
                            var hbox = try dvui.box(@src(), .horizontal, .{ .id_extra = i });
                            defer hbox.deinit();

                            if (try theme.button(@src(), "Edit", .{}, .{}, false)) {
                                try core.handleAction(conn, arena, .{ .edit_post = post.id });
                            }

                            try dvui.label(
                                @src(),
                                "{d}. {s}",
                                .{ post.id, post.title },
                                .{ .id_extra = i, .gravity_y = 0.5 },
                            );
                        }
                    }

                    try dvui.label(@src(), "{s}", .{state.status_text}, .{
                        .gravity_x = 1,
                        .gravity_y = 1,
                    });
                },

                .editing => |scene| {
                    const post_errors = scene.post_errors;

                    var vbox = try dvui.box(
                        @src(),
                        .vertical,
                        .{ .expand = .both },
                    );
                    defer vbox.deinit();

                    try dvui.label(@src(), "Editing post #{d}", .{scene.post.id}, .{ .font_style = .title_1 });

                    var title_buf: []u8 = scene.post.title;
                    var slug_buf: []u8 = scene.post.slug;
                    var content_buf: []u8 = scene.post.content;

                    try dvui.label(@src(), "Title:", .{}, .{
                        .padding = .{
                            .x = 5,
                            .y = 5,
                            .w = 5,
                            .h = 0, // bottom
                        },
                    });
                    var title_entry = try theme.textEntry(
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
                        post_errors.empty_title,
                    );
                    if (title_entry.text_changed) {
                        try core.handleAction(conn, arena, .{
                            .update_post_title = .{
                                .id = scene.post.id,
                                .title = title_entry.getText(),
                            },
                        });
                    }
                    title_entry.deinit();

                    try theme.errLabel(@src(), "{s}", .{
                        if (post_errors.empty_title)
                            "Title must not be empty."
                        else
                            "",
                    });

                    try dvui.label(@src(), "Slug:", .{}, .{
                        .padding = .{
                            .x = 5,
                            .y = 5,
                            .w = 5,
                            .h = 0, // bottom
                        },
                    });
                    var slug_entry = try theme.textEntry(
                        @src(),
                        .{
                            .text = .{
                                .buffer_dynamic = .{
                                    .backing = &slug_buf,
                                    .allocator = arena,
                                },
                            },
                        },
                        .{ .expand = .horizontal },
                        post_errors.empty_slug or post_errors.duplicate_slug,
                    );
                    if (slug_entry.text_changed) {
                        try core.handleAction(conn, arena, .{
                            .update_post_slug = .{
                                .id = scene.post.id,
                                .slug = slug_entry.getText(),
                            },
                        });
                    }
                    slug_entry.deinit();

                    try theme.errLabel(@src(), "{s}{s}", .{
                        if (post_errors.empty_slug)
                            "Slug must not be empty. "
                        else
                            "",
                        if (post_errors.duplicate_slug)
                            "Slug must be unique. "
                        else
                            "",
                    });

                    try dvui.label(@src(), "Content:", .{}, .{
                        .padding = .{
                            .x = 5,
                            .y = 5,
                            .w = 5,
                            .h = 0, // bottom
                        },
                    });
                    var content_entry = try theme.textEntry(
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
                        post_errors.empty_content,
                    );
                    if (content_entry.text_changed) {
                        try core.handleAction(conn, arena, .{
                            .update_post_content = .{
                                .id = scene.post.id,
                                .content = content_entry.getText(),
                            },
                        });
                    }
                    content_entry.deinit();

                    try theme.errLabel(@src(), "{s}", .{
                        if (post_errors.empty_content)
                            "Content must not be empty."
                        else
                            "",
                    });

                    {
                        var hbox = try dvui.box(@src(), .horizontal, .{
                            .expand = .horizontal,
                            .gravity_y = 1,
                            .margin = .{ .y = 10 },
                        });
                        defer hbox.deinit();

                        const back_disabled = post_errors.hasErrors();
                        if (try theme.button(@src(), "Back", .{}, .{}, back_disabled)) {
                            try core.handleAction(conn, arena, .list_posts);
                        }

                        if (try theme.button(@src(), "Delete", .{}, .{}, false)) {
                            try core.handleAction(conn, arena, .{ .delete_post = scene.post.id });
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

                            if (try theme.button(@src(), "Yes", .{}, .{}, false)) {
                                try core.handleAction(conn, arena, .{ .delete_post_yes = scene.post.id });
                            }

                            if (try theme.button(@src(), "No", .{}, .{}, false)) {
                                try core.handleAction(conn, arena, .{ .delete_post_no = scene.post.id });
                            }
                        }
                    }
                },
            }
        },
    }
}
