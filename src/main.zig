const std = @import("std");
const dvui = @import("dvui");
const zqlite = @import("zqlite");
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

const GuiState = union(enum) {
    listing: struct {
        posts: []Post,
    },
    editing: i64, // post ID

    fn read(conn: *zqlite.Conn, arena: std.mem.Allocator) !GuiState {
        var current_scene_id: i64 = undefined;

        if (try conn.row("SELECT current_scene FROM gui_scene;", .{})) |row| {
            defer row.deinit();
            current_scene_id = row.int(0);
        }

        switch (current_scene_id) {
            @intFromEnum(GuiState.listing) => {
                var posts = std.ArrayList(Post).init(arena);
                var rows = try conn.rows("SELECT id, title, content FROM post ORDER BY id DESC", .{});
                defer rows.deinit();
                while (rows.next()) |row| {
                    const post = Post{
                        .id = row.int(0),
                        .title = try arena.dupe(u8, row.text(1)),
                        .content = try arena.dupe(u8, row.text(2)),
                    };
                    std.debug.print(">> post: {d}, {s}, {s}\n", .{ post.id, post.title, post.content });
                    try posts.append(post);
                }
                if (rows.err) |err| return err;

                return .{ .listing = .{ .posts = posts.items } };
            },

            @intFromEnum(GuiState.editing) => return .{ .editing = 99 },

            else => unreachable,
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
            .{@intFromEnum(GuiState.listing)},
        ),
    );
    conn.execNoArgs("INSERT INTO gui_scene(id) VALUES(0);") catch {
        std.debug.print(">> {s}", .{conn.lastError()});
    };

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

        try gui_frame(&gui_state, arena.allocator());

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
fn gui_frame(gui_state: *const GuiState, arena: std.mem.Allocator) !void {
    {
        var m = try dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
        defer m.deinit();

        if (try dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
            defer fw.deinit();

            if (try dvui.menuItemLabel(@src(), "Close Menu", .{}, .{}) != null) {
                m.close();
            }
        }

        if (try dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
            defer fw.deinit();
            _ = try dvui.menuItemLabel(@src(), "Dummy", .{}, .{ .expand = .horizontal });
            _ = try dvui.menuItemLabel(@src(), "Dummy Long", .{}, .{ .expand = .horizontal });
            _ = try dvui.menuItemLabel(@src(), "Dummy Super Long", .{}, .{ .expand = .horizontal });
        }
    }

    var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = .{ .name = .fill_window } });
    defer scroll.deinit();

    var tl = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font_style = .title_1 });
    const header = switch (gui_state.*) {
        GuiState.listing => "Posts",
        GuiState.editing => |post_id| try std.fmt.allocPrint(arena, "Editing Post: {d}", .{post_id}),
    };
    try tl.addText(header, .{});
    tl.deinit();

    switch (gui_state.*) {
        .listing => |state| {
            var tl1 = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer tl1.deinit();
            for (state.posts) |post| {
                try tl1.addText(
                    try std.fmt.allocPrint(arena, "{d}. {s} - {s}\n", .{ post.id, post.title, post.content }),
                    .{},
                );
            }
        },
        .editing => {},
    }

    var tl2 = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    try tl2.addText(
        try std.fmt.allocPrint(arena, "GuiState: {}", .{gui_state}),
        .{},
    );
    try tl2.addText("\n\n", .{});
    try tl2.addText("Framerate is variable and adjusts as needed for input events and animations.", .{});
    try tl2.addText("\n\n", .{});
    if (vsync) {
        try tl2.addText("Framerate is capped by vsync.", .{});
    } else {
        try tl2.addText("Framerate is uncapped.", .{});
    }
    try tl2.addText("\n\n", .{});
    try tl2.addText("Cursor is always being set by dvui.", .{});
    try tl2.addText("\n\n", .{});
    if (dvui.useFreeType) {
        try tl2.addText("Fonts are being rendered by FreeType 2.", .{});
    } else {
        try tl2.addText("Fonts are being rendered by stb_truetype.", .{});
    }
    tl2.deinit();

    const label = if (dvui.Examples.show_demo_window) "Hide Demo Window" else "Show Demo Window";
    if (try dvui.button(@src(), label, .{}, .{})) {
        dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
    }

    {
        var scaler = try dvui.scale(@src(), scale_val, .{ .expand = .horizontal });
        defer scaler.deinit();

        {
            var hbox = try dvui.box(@src(), .horizontal, .{});
            defer hbox.deinit();

            if (try dvui.button(@src(), "Zoom In", .{}, .{})) {
                scale_val = @round(dvui.themeGet().font_body.size * scale_val + 1.0) / dvui.themeGet().font_body.size;
            }

            if (try dvui.button(@src(), "Zoom Out", .{}, .{})) {
                scale_val = @round(dvui.themeGet().font_body.size * scale_val - 1.0) / dvui.themeGet().font_body.size;
            }
        }
    }
}
