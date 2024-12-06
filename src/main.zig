const std = @import("std");
const dvui = @import("dvui");
const zqlite = @import("zqlite");

const zqlite_utils = @import("zqlite_utils.zig");
const selectInt = zqlite_utils.selectInt;
const execPrintErr = zqlite_utils.execPrintErr;

comptime {
    std.debug.assert(dvui.backend_kind == .sdl);
}
const Backend = dvui.backend;

const vsync = true;
var scale_val: f32 = 1.0;

var g_backend: ?Backend = null;

const DB_PATH = "Site1.wm2k";

const Post = struct {
    id: i64,
    title: []const u8,
    content: []const u8,
};

const Scene = enum {
    listing,
    editing,
};

const GuiState = union(Scene) {
    listing: struct {
        posts: []Post,
    },
    editing: i64, // post ID

    fn read(conn: *zqlite.Conn, arena: std.mem.Allocator) !GuiState {
        const current_scene: Scene = @enumFromInt(
            try selectInt(conn, "select current_scene from gui_scene"),
        );

        switch (current_scene) {
            .listing => {
                var posts = std.ArrayList(Post).init(arena);
                var rows = try conn.rows("SELECT id, title, content FROM post ORDER BY id DESC", .{});
                defer rows.deinit();
                while (rows.next()) |row| {
                    const post = Post{
                        .id = row.int(0),
                        .title = try arena.dupe(u8, row.text(1)),
                        .content = try arena.dupe(u8, row.text(2)),
                    };
                    try posts.append(post);
                }
                if (rows.err) |err| return err;

                return .{ .listing = .{ .posts = posts.items } };
            },

            .editing => {
                const post_id = try selectInt(conn, "select post_id from gui_scene_editing");
                return .{ .editing = post_id };
            },
        }
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
        .vsync = vsync,
        .title = "WebMaker2000",
    });
    g_backend = backend;
    defer backend.deinit();

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer win.deinit();

    // init sqlite connection
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(DB_PATH, flags);
    try conn.execNoArgs("PRAGMA foreign_keys = ON;");
    try conn.execNoArgs(
        \\CREATE TABLE post (
        \\  id INTEGER PRIMARY KEY,
        \\  title TEXT,
        \\  content TEXT
        \\);
    );
    try conn.execNoArgs(
        std.fmt.comptimePrint(
            \\CREATE TABLE gui_scene (
            \\  id INTEGER PRIMARY KEY CHECK(id = 0) DEFAULT 0,
            \\  current_scene INTEGER DEFAULT {d}
            \\);
        ,
            .{@intFromEnum(Scene.listing)},
        ),
    );
    conn.execNoArgs("insert into gui_scene (id) values (0)") catch {
        std.debug.print(">> {s}", .{conn.lastError()});
    };
    try conn.execNoArgs(
        \\create table gui_scene_editing (
        \\  id integer primary key check(id = 0) default 0,
        \\  post_id integer default null,
        \\  foreign key (post_id) references post (id) on delete set null
        \\)
    );
    try conn.execNoArgs("insert into gui_scene_editing(id) values(0)");

    try conn.exec(
        "INSERT INTO post (title, content) VALUES (?1, ?2);",
        .{ "First!", "This is my first post." },
    );
    try conn.exec(
        "INSERT INTO post (title, content) VALUES (?1, ?2);",
        .{ "Second post", "Let's keep this going.\nShall we?" },
    );
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    main_loop: while (true) {
        defer _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 * 100 });

        const gui_state: GuiState = try GuiState.read(&conn, arena.allocator());

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

        try gui_frame(&gui_state, arena.allocator(), &conn);

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

// both dvui and SDL drawing
fn gui_frame(
    gui_state: *const GuiState,
    arena: std.mem.Allocator,
    conn: *zqlite.Conn,
) !void {
    _ = arena; // Not used yet, but it doesn't hurt to have a per-frame arena

    var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = .{ .name = .fill_window } });
    defer scroll.deinit();

    switch (gui_state.*) {
        .listing => |state| {
            try dvui.label(@src(), "Posts", .{}, .{ .font_style = .title_1 });

            if (try dvui.button(@src(), "New post", .{}, .{})) {
                try conn.transaction();
                errdefer conn.rollback();
                try execPrintErr(conn, "insert into post default values", .{});
                const new_post_id = conn.lastInsertedRowId();
                try execPrintErr(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                try execPrintErr(conn, "update gui_scene_editing set post_id = ?", .{new_post_id});
                try conn.commit();
            }

            for (state.posts, 0..) |post, i| {
                var hbox = try dvui.box(@src(), .horizontal, .{ .id_extra = i });
                defer hbox.deinit();

                if (try dvui.button(@src(), "Edit", .{}, .{})) {
                    try conn.transaction();
                    errdefer conn.rollback();
                    try conn.exec("update gui_scene set current_scene = ?", .{@intFromEnum(Scene.editing)});
                    try conn.exec("update gui_scene_editing set post_id = ?", .{post.id});
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

        .editing => {
            try dvui.label(@src(), "Editing post: {d}", .{gui_state.editing}, .{ .font_style = .title_1 });

            {
                var hbox = try dvui.box(@src(), .horizontal, .{});
                defer hbox.deinit();

                if (try dvui.button(@src(), "Back", .{}, .{})) {
                    try conn.exec("update gui_scene set current_scene = ?", .{@intFromEnum(Scene.listing)});
                }
                if (try dvui.button(@src(), "Delete", .{}, .{})) {
                    try conn.transaction();
                    errdefer conn.rollback();
                    try execPrintErr(conn, "delete from post where id = ?", .{gui_state.editing});
                    try execPrintErr(conn, "update gui_scene set current_scene = ?", .{@intFromEnum(Scene.listing)});
                    try conn.commit();
                }
            }
        },
    }
}
