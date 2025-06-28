const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const print = std.debug.print;
const fmt = std.fmt;
const log = std.log;
const allocPrint = std.fmt.allocPrint;
const dvui = @import("dvui");
const Backend = dvui.backend;
const zqlite = @import("zqlite");

const sql = @import("sql.zig");
const history = @import("history.zig");
const theme = @import("theme.zig");
const djot = @import("djot.zig");
const queries = @import("queries.zig");
const server = @import("server.zig");
const constants = @import("constants.zig");
const PORT = constants.PORT;
const EXTENSION = constants.EXTENSION;
const core_ = @import("core.zig");
const GuiState = core_.GuiState;
const Modal = core_.Modal;
const Core = core_.Core;
const sitefs = @import("sitefs.zig");
const blobstore = @import("blobstore.zig");
const println = @import("util.zig").println;
const butils = @import("backend_utils.zig");

pub const main = dvui.App.main;

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 500, .h = 500 },
            .vsync = true,
            .title = "WebMaker2000",
            .icon = @embedFile("favicon.png"),
        },
    },
    .frameFn = AppFrame,
    .initFn = AppInit,
    .deinitFn = AppDeinit,
};
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

// Globals that must be initialized (and cleaned up) by main() before use:
var core = Core{};
var argv: [][:0]u8 = undefined;
var global_dba_impl: std.heap.DebugAllocator(.{}) = .init;
var global_dba: mem.Allocator = undefined;
var frame_arena_impl: std.heap.ArenaAllocator = undefined;
var frame_arena: mem.Allocator = undefined;
var global_win: *dvui.Window = undefined;
var maybe_server: ?server.Server = null;
var default_theme: dvui.Theme = undefined;

// Runs before the first frame, after backend and dvui.Window.init()
pub fn AppInit(win: *dvui.Window) !void {
    global_dba = global_dba_impl.allocator();
    frame_arena_impl = .init(global_dba);
    frame_arena = frame_arena_impl.allocator();

    default_theme = theme.default();
    dvui.themeSet(&default_theme);

    // TODO: is there any other way to pass a window pointer to AppFrame?
    global_win = win;

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

    argv = try std.process.argsAlloc(global_dba);
    if (argv.len == 2 and mem.endsWith(u8, argv[1], "." ++ EXTENSION)) {
        // TODO: how to handle errors (e.g. file not found) here? We can't draw
        // anything at this stage.

        const existing_file_path = argv[1];

        const conn = try sql.openWithSaneDefaults(existing_file_path, zqlite.OpenFlags.EXResCode);
        core.maybe_conn = conn;
        // TODO: read user_version pragma to check if the db was initialized
        // correctly. If not, abort with error message somehow.

        // Change working directory to the same dir as the .wm2k file
        if (fs.path.dirname(existing_file_path)) |dir_path| {
            try std.posix.chdir(dir_path);
        }

        maybe_server = try server.Server.init(global_dba, PORT);

        try blobstore.ensureDir();

        const absolute_path = try fs.cwd().realpathAlloc(global_dba, ".");
        defer global_dba.free(absolute_path);

        const dir_name = fs.path.basename(absolute_path);
        const window_title = try fmt.allocPrintZ(global_dba, "{s} - WebMaker2000", .{dir_name});
        defer global_dba.free(window_title);
        try queries.setStatusText(global_dba, conn, "Opened {s}", .{dir_name});
        try butils.setWindowTitle(frame_arena, win, window_title);
    }

    try djot.init(global_dba);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit() void {
    djot.deinit();

    core.deinit();
    if (maybe_server) |_| {
        maybe_server.?.deinit();
    }

    std.process.argsFree(global_dba, argv);
    _ = frame_arena_impl.deinit();
    _ = global_dba_impl.deinit();
}

// In each frame:
// - make sure arena is reset
// - read gui_state fresh from database
// - handle actions, preferrably by calling core.handleAction() which correctly
//   wires up undo stack, etc.
pub fn AppFrame() !dvui.App.Result {
    defer _ = frame_arena_impl.reset(.{ .retain_with_limit = 1024 * 1024 * 100 });
    frame_arena = frame_arena_impl.allocator();

    core.state = try GuiState.read(core.maybe_conn, frame_arena);

    var background = dvui.overlay(@src(), .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .name = .fill_window },
    });
    defer background.deinit();

    switch (core.state) {

        // Let user either create new or open existing wm2k file:
        .no_file_opened => {
            var vbox = dvui.box(@src(), .vertical, .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
            defer vbox.deinit();

            dvui.label(@src(), "Create new site or open an existing one?", .{}, .{});

            {
                var hbox = dvui.box(@src(), .horizontal, .{ .expand = .both });
                defer hbox.deinit();

                if (dvui.button(@src(), "New...", .{}, .{})) {
                    if (try dvui.dialogNativeFolderSelect(frame_arena, .{
                        .title = "Create new site - Choose an empty folder",
                    })) |new_site_dir_path| new_site_block: {
                        var site_dir = try fs.cwd().openDir(new_site_dir_path, .{ .iterate = true });
                        defer site_dir.close();

                        // TODO: find cleaner way to check if dir has children
                        var dir_iterator = site_dir.iterate();
                        var has_children = false;
                        while (try dir_iterator.next()) |_| {
                            has_children = true;
                            break;
                        }

                        // TODO: show error message
                        if (has_children) {
                            dvui.dialog(@src(), .{}, .{
                                .title = "Chosen folder was not empty!",
                                .message = "Please choose an empty folder for your new site.",
                            });
                            break :new_site_block;
                        }

                        try site_dir.setAsCwd();

                        const conn = try sql.openWithSaneDefaults(
                            try frame_arena.dupeZ(u8, constants.SITE_FILE),
                            zqlite.OpenFlags.EXResCode | zqlite.OpenFlags.Create,
                        );
                        core.maybe_conn = conn;

                        try sql.execNoArgs(conn, "pragma foreign_keys = on");

                        try sql.execNoArgs(conn, "begin exclusive");
                        try sql.execNoArgs(conn, @embedFile("db_schema.sql"));
                        try history.createTriggers(history.Undo, conn, frame_arena);
                        try history.createTriggers(history.Redo, conn, frame_arena);
                        try sql.execNoArgs(conn, "commit");

                        const filename = fs.path.basename(new_site_dir_path);
                        try queries.setStatusText(frame_arena, conn, "Created {s}", .{filename});

                        try butils.setWindowTitle(
                            frame_arena,
                            global_win,
                            try fmt.allocPrintZ(frame_arena, "{s} - WebMaker2000", .{filename}),
                        );

                        maybe_server = try server.Server.init(global_dba, PORT);

                        try blobstore.ensureDir();

                        // Apparently interaction with the system file dialog
                        // does not count as user interaction in dvui, so
                        // there's a chance the UI won't be refreshed after a
                        // file is chosen. Therefore, we need to manually
                        // tell dvui to draw the next frame right after this
                        // frame:
                        //dvui.refresh(null, @src(), null);
                    }
                }

                if (dvui.button(@src(), "Open...", .{}, .{})) {
                    if (try dvui.dialogNativeFileOpen(frame_arena, .{
                        .title = "Open site",
                        .filters = &.{"*." ++ EXTENSION},
                    })) |existing_file_path| {
                        const conn = try sql.openWithSaneDefaults(existing_file_path, zqlite.OpenFlags.EXResCode);
                        core.maybe_conn = conn;
                        // TODO: read user_version pragma to check if the db was initialized
                        // correctly. If not, abort with error message somehow.

                        // Change working directory to the same dir as the .wm2k file
                        if (fs.path.dirname(existing_file_path)) |dir_path| {
                            println(">> dir_path: {s}", .{dir_path});
                            try std.posix.chdir(dir_path);
                            println(">> successfully changed dir", .{});
                        }

                        maybe_server = try server.Server.init(global_dba, PORT);

                        try blobstore.ensureDir();

                        const dir_name = fs.path.basename(try fs.cwd().realpathAlloc(frame_arena, "."));
                        try queries.setStatusText(frame_arena, conn, "Opened {s}", .{dir_name});

                        try butils.setWindowTitle(
                            frame_arena,
                            global_win,
                            try fmt.allocPrintZ(frame_arena, "{s} - WebMaker2000", .{dir_name}),
                        );

                        // Apparently interaction with the system file dialog
                        // does not count as user interaction in dvui, so
                        // there's a chance the UI won't be refreshed after a
                        // file is chosen. Therefore, we need to manually
                        // tell dvui to draw the next frame right after this
                        // frame:
                        //dvui.refresh(null, @src(), null);
                    }
                }
            }
        },

        // User has actually opened a file => show main UI:
        .opened => |state| {
            const conn = core.maybe_conn.?;

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

            var frame = dvui.box(@src(), .vertical, .{
                .expand = .both,
                .background = false,
            });
            defer frame.deinit();

            {
                var toolbar = dvui.box(
                    @src(),
                    .horizontal,
                    .{ .expand = .horizontal },
                );
                defer toolbar.deinit();

                if (theme.button(@src(), "Undo", .{}, .{}, undos.len == 0)) {
                    try history.undo(conn, undos);
                }

                if (theme.button(@src(), "Redo", .{}, .{}, redos.len == 0)) {
                    try history.redo(conn, redos);
                }

                const generate_disabled = state.scene == .editing and state.scene.editing.post_errors.hasErrors();
                if (theme.button(@src(), "Generate", .{}, .{}, generate_disabled)) {
                    var timer = try std.time.Timer.start();

                    var cwd = fs.cwd();
                    try cwd.deleteTree(constants.OUTPUT_DIR);

                    var out_dir = try cwd.makeOpenPath(constants.OUTPUT_DIR, .{});
                    defer out_dir.close();
                    try sitefs.generate(frame_arena, conn, "", out_dir);

                    const miliseconds = timer.read() / 1_000_000;
                    try queries.setStatusText(
                        frame_arena,
                        conn,
                        "Generated static site in {d}ms.",
                        .{miliseconds},
                    );
                }

                //var buf: [100]u8 = undefined;
                //const fps_str = fmt.bufPrint(&buf, "{d:0>3.0} fps", .{dvui.FPS()}) catch unreachable;
                //try dvui.label(@src(), "{s}", .{fps_str}, .{ .gravity_x = 1 });
                //dvui.refresh(null, @src(), null);

                const url = switch (state.scene) {
                    .listing => try allocPrint(frame_arena, "http://localhost:{d}", .{PORT}),
                    .editing => |s| if (s.post_errors.hasErrors())
                        ""
                    else
                        try allocPrint(frame_arena, "http://localhost:{d}/{s}", .{ PORT, s.post.slug }),
                };
                if (url.len > 0 and dvui.labelClick(@src(), "{s}", .{url}, .{
                    .gravity_x = 1.0,
                    .color_text = .{ .color = .{ .r = 0x00, .g = 0x00, .b = 0xff } },
                })) {
                    dvui.openURL(url);
                }
            }

            switch (state.scene) {
                .listing => |scene| {
                    dvui.label(@src(), "Posts", .{}, .{ .font_style = .title_1 });

                    if (theme.button(@src(), "New post", .{}, .{}, false)) {
                        try core.handleAction(conn, frame_arena, .create_post);
                    }

                    {
                        var scroll = dvui.scrollArea(@src(), .{}, .{
                            .expand = .both,
                            .max_size_content = .{
                                // FIXME: how to avoid hardcoded max height?
                                .h = dvui.windowRect().h - 170,
                                .w = dvui.windowRect().w,
                            },
                            //.padding = .{ .x = 5 },
                            .margin = .all(5),
                            .corner_radius = .all(0),
                            .border = .all(1),
                            .color_fill = .{ .name = .fill_window },
                        });
                        defer scroll.deinit();

                        for (scene.posts, 0..) |post, i| {
                            var hbox = dvui.box(@src(), .horizontal, .{ .id_extra = i });
                            defer hbox.deinit();

                            if (theme.button(@src(), "Edit", .{}, .{}, false)) {
                                try core.handleAction(conn, frame_arena, .{ .edit_post = post.id });
                            }

                            dvui.label(
                                @src(),
                                "{d}. {s}",
                                .{ post.id, post.title },
                                .{ .id_extra = i, .gravity_y = 0.5 },
                            );
                        }
                    }

                    dvui.label(@src(), "{s}", .{state.status_text}, .{
                        .gravity_x = 1,
                        .gravity_y = 1,
                    });
                },

                .editing => |scene| {
                    const post_errors = scene.post_errors;

                    var vbox = dvui.box(
                        @src(),
                        .vertical,
                        .{ .expand = .both },
                    );
                    defer vbox.deinit();

                    dvui.label(@src(), "Editing post #{d}", .{scene.post.id}, .{ .font_style = .title_1 });

                    var title_buf: []u8 = scene.post.title;
                    var slug_buf: []u8 = scene.post.slug;
                    var content_buf: []u8 = scene.post.content;

                    dvui.label(@src(), "Title:", .{}, .{
                        .padding = .{
                            .x = 5,
                            .y = 5,
                            .w = 5,
                            .h = 0, // bottom
                        },
                    });
                    var title_entry = theme.textEntry(
                        @src(),
                        .{
                            .text = .{
                                .buffer_dynamic = .{
                                    .backing = &title_buf,
                                    .allocator = frame_arena,
                                },
                            },
                        },
                        .{ .expand = .horizontal },
                        post_errors.empty_title,
                    );
                    if (title_entry.text_changed) {
                        try core.handleAction(conn, frame_arena, .{
                            .update_post_title = .{
                                .id = scene.post.id,
                                .title = title_entry.getText(),
                            },
                        });
                    }
                    title_entry.deinit();

                    theme.errLabel(@src(), "{s}", .{
                        if (post_errors.empty_title)
                            "Title must not be empty."
                        else
                            "",
                    });

                    dvui.label(@src(), "Slug:", .{}, .{
                        .padding = .{
                            .x = 5,
                            .y = 5,
                            .w = 5,
                            .h = 0, // bottom
                        },
                    });
                    var slug_entry = theme.textEntry(
                        @src(),
                        .{
                            .text = .{
                                .buffer_dynamic = .{
                                    .backing = &slug_buf,
                                    .allocator = frame_arena,
                                },
                            },
                        },
                        .{ .expand = .horizontal },
                        post_errors.empty_slug or post_errors.duplicate_slug,
                    );
                    if (slug_entry.text_changed) {
                        try core.handleAction(conn, frame_arena, .{
                            .update_post_slug = .{
                                .id = scene.post.id,
                                .slug = slug_entry.getText(),
                            },
                        });
                    }
                    slug_entry.deinit();

                    theme.errLabel(@src(), "{s}{s}", .{
                        if (post_errors.empty_slug)
                            "Slug must not be empty. "
                        else
                            "",
                        if (post_errors.duplicate_slug)
                            "Slug must be unique. "
                        else
                            "",
                    });

                    {
                        var paned = dvui.paned(
                            @src(),
                            .{ .direction = .horizontal, .collapsed_size = 0 },
                            .{
                                .expand = .both,
                                .background = false,
                                .min_size_content = .{ .h = 100 },
                            },
                        );
                        defer paned.deinit();

                        {
                            var content_vbox = dvui.box(@src(), .vertical, .{ .expand = .both });
                            defer content_vbox.deinit();

                            dvui.label(@src(), "Content:", .{}, .{
                                .padding = .{
                                    .x = 5,
                                    .y = 5,
                                    .w = 5,
                                    .h = 0, // bottom
                                },
                            });
                            var content_entry = theme.textEntry(
                                @src(),
                                .{
                                    .multiline = true,
                                    .break_lines = true,
                                    .scroll_horizontal = false,
                                    .text = .{
                                        .buffer_dynamic = .{
                                            .backing = &content_buf,
                                            .allocator = frame_arena,
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
                                try core.handleAction(conn, frame_arena, .{
                                    .update_post_content = .{
                                        .id = scene.post.id,
                                        .content = content_entry.getText(),
                                    },
                                });
                            }
                            const selection = content_entry.textLayout.selection;
                            if (selection.start != scene.selection.start or
                                selection.end != scene.selection.end)
                            {
                                try core.updateSelection(selection.start, selection.end);
                                println(">> {} {}", .{ selection.start, selection.end });
                            }

                            content_entry.deinit();

                            theme.errLabel(@src(), "{s}", .{
                                if (post_errors.empty_content)
                                    "Content must not be empty."
                                else
                                    "",
                            });
                        }

                        {
                            var attachments_vbox = dvui.box(@src(), .vertical, .{ .expand = .both });
                            defer attachments_vbox.deinit();

                            dvui.label(@src(), "Attachments:", .{}, .{});

                            {
                                var buttons_box = dvui.box(@src(), .horizontal, .{});
                                defer buttons_box.deinit();

                                if (theme.button(@src(), "Add...", .{}, .{}, false)) {
                                    if (try dvui.dialogNativeFileOpenMultiple(frame_arena, .{
                                        .title = "Add attachments",
                                    })) |file_paths| {
                                        try core.handleAction(conn, frame_arena, .{ .add_attachments = .{
                                            .post_id = scene.post.id,
                                            .file_paths = file_paths,
                                        } });
                                    }
                                }

                                var delete_disabled = true;
                                for (scene.attachments) |attachment| {
                                    if (attachment.selected) {
                                        delete_disabled = false;
                                        break;
                                    }
                                }
                                if (theme.button(@src(), "Delete selected", .{}, .{}, delete_disabled)) {
                                    try core.handleAction(conn, frame_arena, .{ .delete_selected_attachments = scene.post.id });
                                }
                            }
                            {
                                var scroll = dvui.scrollArea(@src(), .{}, .{
                                    .expand = .both,
                                    // FIXME: how to avoid hardcoded max height?
                                    .max_size_content = .height(attachments_vbox.child_rect.h - 100),
                                    //.padding = .{ .x = 5 },
                                    .margin = .all(5),
                                    .corner_radius = .all(0),
                                    .border = .all(1),
                                    .color_fill = .{ .name = .fill_window },
                                });
                                defer scroll.deinit();

                                var selected_bools = try std.ArrayList(bool).initCapacity(frame_arena, scene.attachments.len);
                                for (scene.attachments, 0..) |attachment, i| {
                                    try selected_bools.append(attachment.selected);

                                    var atm_group = dvui.box(@src(), .horizontal, .{ .id_extra = i });
                                    defer atm_group.deinit();

                                    if (dvui.buttonIcon(
                                        @src(),
                                        "copy",
                                        dvui.entypo.copy,
                                        .{},
                                        .{},
                                        .{ .max_size_content = .{ .h = 13, .w = 13 } },
                                    )) {
                                        dvui.clipboardTextSet(attachment.name);
                                        try queries.setStatusText(frame_arena, conn, "Copied file name: {s}", .{attachment.name});
                                    }

                                    if (dvui.checkbox(
                                        @src(),
                                        &selected_bools.items[i],
                                        "",
                                        .{ .id_extra = i },
                                    )) {
                                        if (selected_bools.items[i]) {
                                            try core.handleAction(conn, frame_arena, .{ .select_attachment = attachment.id });
                                        } else {
                                            try core.handleAction(conn, frame_arena, .{ .deselect_attachment = attachment.id });
                                        }
                                    }

                                    if (dvui.labelClick(
                                        @src(),
                                        "{s} ({s})",
                                        .{ attachment.name, attachment.size },
                                        .{ .margin = .{ .x = -10 } },
                                    )) {
                                        println("clicked {s}", .{attachment.name});
                                        const new_content = try fmt.allocPrint(frame_arena, "{s}{s}{s}", .{
                                            scene.post.content[0..scene.selection.start],
                                            attachment.name,
                                            scene.post.content[scene.selection.end..],
                                        });
                                        try core.handleAction(
                                            conn,
                                            frame_arena,
                                            .{
                                                .update_post_content = .{
                                                    .id = scene.post.id,
                                                    .content = new_content,
                                                },
                                            },
                                        );
                                    }
                                }
                            }
                        }
                    }

                    {
                        var hbox = dvui.box(@src(), .horizontal, .{
                            .expand = .horizontal,
                            .gravity_y = 1,
                            .margin = .{ .y = 10 },
                        });
                        defer hbox.deinit();

                        const back_disabled = post_errors.hasErrors();
                        if (theme.button(@src(), "Back", .{}, .{}, back_disabled)) {
                            try core.handleAction(conn, frame_arena, .list_posts);
                        }

                        if (theme.button(@src(), "Delete", .{}, .{}, false)) {
                            try core.handleAction(conn, frame_arena, .{ .delete_post = scene.post.id });
                        }

                        dvui.label(@src(), "{s}", .{state.status_text}, .{
                            .gravity_x = 1,
                            .gravity_y = 1,
                        });
                    }

                    // Post deletion confirmation modal:
                    if (scene.show_confirm_delete) {
                        var modal = dvui.floatingWindow(
                            @src(),
                            .{ .modal = true },
                            .{ .max_size_content = .width(500) },
                        );
                        defer modal.deinit();

                        _ = dvui.windowHeader("Confirm deletion", "", null);
                        dvui.label(@src(), "Are you sure you want to delete this post?", .{}, .{});

                        {
                            _ = dvui.spacer(@src(), .{ .expand = .vertical });
                            var hbox = dvui.box(@src(), .horizontal, .{ .gravity_x = 1.0 });
                            defer hbox.deinit();

                            if (theme.button(@src(), "Yes", .{}, .{}, false)) {
                                try core.handleAction(conn, frame_arena, .{ .delete_post_yes = scene.post.id });
                            }

                            if (theme.button(@src(), "No", .{}, .{}, false)) {
                                try core.handleAction(conn, frame_arena, .{ .delete_post_no = scene.post.id });
                            }
                        }
                    }
                },
            }
        },
    }

    return .ok;
}
