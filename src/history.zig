const std = @import("std");
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const print = std.debug.print;

pub const Action = enum(i64) {
    create_post = 0,
    update_post_title = 1,
    update_post_content = 2,
    delete_post = 3,
    change_scene = 4,

    fn isDebounceable(self: Action) bool {
        return switch (self) {
            .create_post => false,
            .update_post_title => true,
            .update_post_content => true,
            .delete_post => false,
            .change_scene => false,
        };
    }

    fn userFriendlyName(self: Action) []const u8 {
        return switch (self) {
            inline .create_post => "Create new post",
            inline .update_post_title => "Update post title",
            inline .update_post_content => "Update post content",
            inline .delete_post => "Delete post",
            inline .change_scene => "Change scene",
        };
    }

    fn undoMessage(self: Action) []const u8 {
        return self.userFriendlyName();
    }
};

pub const Barrier = struct {
    id: i64,
    action: Action,
};

const HISTORY_TABLES = &.{
    "post",
    "gui_scene",
    "gui_scene_editing",
    "gui_modal",
    "gui_status_text",
};

const HistoryType = struct {
    main_table: []const u8,
    barriers_table: []const u8,
    trigger_prefix: []const u8,
    enable_triggers_column: []const u8,
};
pub const Undo = HistoryType{
    .main_table = "history_undo",
    .barriers_table = "history_barrier_undo",
    .trigger_prefix = "history_trigger_undo",
    .enable_triggers_column = "undo",
};
pub const Redo = HistoryType{
    .main_table = "history_redo",
    .barriers_table = "history_barrier_redo",
    .trigger_prefix = "history_trigger_redo",
    .enable_triggers_column = "redo",
};

pub fn createTriggers(
    comptime htype: HistoryType,
    conn: zqlite.Conn,
    gpa: std.mem.Allocator,
) !void {
    var timer = try std.time.Timer.start();
    defer std.debug.print("** createTriggers() took {}ms\n", .{timer.read() / 1_000_000});

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    inline for (HISTORY_TABLES) |table| {
        // First colect this table's column names
        var column_names = std.ArrayList([]const u8).init(arena);

        var records = try sql.rows(
            conn,
            std.fmt.comptimePrint("pragma table_info({s})", .{table}),
            .{},
        );
        defer records.deinit();

        while (records.next()) |row| {
            const column = try arena.dupe(u8, row.text(1));
            try column_names.append(column);
        }
        try sql.check(records.err, conn);

        // Now create triggers for all 3 events:

        // INSERT:
        const insert_trigger = std.fmt.comptimePrint(
            \\CREATE TRIGGER {s}_{s}_insert AFTER INSERT ON {s}
            \\WHEN (select {s} from history_enable_triggers limit 1)
            \\BEGIN
            \\  INSERT INTO {s} (statement) VALUES (
            \\      'DELETE FROM {s} WHERE id=' || new.id
            \\  );
            \\END;
        , .{
            htype.trigger_prefix,
            table,
            table,
            htype.enable_triggers_column,
            htype.main_table,
            table,
        });
        try sql.execNoArgs(conn, insert_trigger);

        // UPDATE:
        var column_updates = std.ArrayList(u8).init(arena);
        for (column_names.items, 0..) |col, i| {
            if (i != 0) {
                try column_updates.appendSlice(", ' || '");
            }
            try column_updates.appendSlice(try std.fmt.allocPrint(
                arena,
                "{s}=' || quote(old.{s}) ||'",
                .{ col, col },
            ));
        }

        const update_trigger = try std.fmt.allocPrint(
            arena,
            \\CREATE TRIGGER {s}_{s}_update AFTER UPDATE ON {s}
            \\WHEN (select {s} from history_enable_triggers limit 1)
            \\BEGIN
            \\  INSERT INTO {s} (statement) VALUES (
            \\      'UPDATE {s} SET {s} WHERE id=' || old.id
            \\  );
            \\END;
        ,
            .{
                htype.trigger_prefix,
                table,
                table,
                htype.enable_triggers_column,
                htype.main_table,
                table,
                column_updates.items,
            },
        );
        try sql.exec(conn, update_trigger, .{});

        // DELETE:
        var reinsert_values = std.ArrayList(u8).init(arena);
        for (column_names.items, 0..) |col, i| {
            if (i != 0) {
                try reinsert_values.appendSlice(", ' || '");
            }
            try reinsert_values.appendSlice(try std.fmt.allocPrint(
                arena,
                "' || quote(old.{s}) ||'",
                .{col},
            ));
        }

        const delete_trigger = try std.fmt.allocPrint(
            arena,
            \\CREATE TRIGGER {s}_{s}_delete AFTER DELETE ON {s}
            \\WHEN (select {s} from history_enable_triggers limit 1)
            \\BEGIN
            \\  INSERT INTO {s} (statement) VALUES (
            \\      'INSERT INTO {s} ({s}) VALUES ({s})'
            \\  );
            \\END;
        ,
            .{
                htype.trigger_prefix,
                table,
                table,
                htype.enable_triggers_column,
                htype.main_table,
                table,
                try std.mem.join(arena, ",", column_names.items),
                reinsert_values.items,
            },
        );
        try sql.exec(conn, delete_trigger, .{});
    }
}

pub fn undo(
    conn: zqlite.Conn,
    barriers: []Barrier,
) !void {
    if (barriers.len == 0) return;

    var timer = try std.time.Timer.start();
    defer std.debug.print(">> undo() took {}ms\n", .{timer.read() / 1_000_000});

    try disableUndoTriggers(conn);
    try enableRedoTriggers(conn);

    // First find all undo records in this barrier,
    // execute and flag them as undone:

    var undo_rows = try sql.rows(
        conn,
        \\select statement from history_undo
        \\where barrier_id = ?
        \\order by id desc
    ,
        .{barriers[0].id},
    );
    defer undo_rows.deinit();

    while (undo_rows.next()) |row| {
        const sql_stmt = row.text(0);
        try sql.exec(conn, sql_stmt, .{});
    }
    try sql.check(undo_rows.err, conn);

    // Then flag the barrier itself as undone:
    try sql.exec(
        conn,
        std.fmt.comptimePrint(
            "update {s} set undone=true where id=?",
            .{Undo.barriers_table},
        ),
        .{barriers[0].id},
    );

    try sql.exec(
        conn,
        \\insert into history_barrier_redo (action)
        \\values ((select action from history_barrier_undo order by id desc limit 1))
    ,
        .{},
    );

    const redo_barrier_id = conn.lastInsertedRowId();
    try sql.exec(
        conn,
        "update history_redo set barrier_id = ? where barrier_id is null",
        .{redo_barrier_id},
    );

    try disableRedoTriggers(conn);
    try enableUndoTriggers(conn);

    const status_text = switch (barriers[0].action) {
        .create_post => "Undone post creation.",
        .update_post_title => "Undone post title update.",
        .update_post_content => "Undone post content update.",
        .delete_post => "Undone post deletion.",
        .change_scene => "Undone scene change.",
    };
    try sql.exec(conn,
        \\update gui_status_text
        \\set status_text = ?,
        \\    expires_at = datetime('now', '+7 seconds')
    , .{status_text});
}

pub fn getBarriers(
    comptime htype: HistoryType,
    conn: zqlite.Conn,
    arena: std.mem.Allocator,
) ![]Barrier {
    var list = std.ArrayList(Barrier).init(arena);

    var rows = try sql.rows(
        conn,
        std.fmt.comptimePrint(
            \\select id, action from {s}
            \\where undone is false
            \\order by id desc
        , .{htype.barriers_table}),
        .{},
    );
    defer rows.deinit();

    while (rows.next()) |row| {
        try list.append(.{
            .id = row.int(0),
            .action = @enumFromInt(row.int(1)),
        });
    }
    try sql.check(rows.err, conn);

    return list.items;
}

// For text input changes, skip creating an undo barrier if this change is
// within a few seconds since the last change.
// This also cleans up trailing history_undo records in such cases.
fn shouldDebounceBarrier(comptime action: Action, conn: zqlite.Conn) !bool {
    if (!comptime action.isDebounceable()) {
        return false;
    }

    var prevRow = try sql.selectRow(
        conn,
        std.fmt.comptimePrint(
            \\select id
            \\from history_barrier_undo
            \\where action = {d}
            \\  and created_at >= datetime('now', '-2 seconds')
            \\  and id = (select max(id) from history_barrier_undo)
        ,
            .{@intFromEnum(action)},
        ),
        .{},
    ) orelse return false;

    const prevBarrierId = prevRow.int(0);
    try sql.exec(
        conn,
        "update history_barrier_undo set created_at = datetime('now') where id=?",
        .{prevBarrierId},
    );

    try sql.execNoArgs(conn, "delete from history_undo where barrier_id is null");
    return true;
}

pub fn addUndoBarrier(
    comptime action: Action,
    conn: zqlite.Conn,
) !void {
    if (try shouldDebounceBarrier(action, conn)) {
        return;
    }

    try sql.exec(
        conn,
        "insert into history_barrier_undo (action) values (?)",
        .{@intFromEnum(action)},
    );

    const barrier_id = conn.lastInsertedRowId();
    try sql.exec(
        conn,
        "update history_undo set barrier_id = ? where barrier_id is null",
        .{barrier_id},
    );
}

pub fn redo(
    conn: zqlite.Conn,
    barriers: []Barrier,
) !void {
    if (barriers.len == 0) return;

    var timer = try std.time.Timer.start();
    defer std.debug.print(">> redo() took {}ms\n", .{timer.read() / 1_000_000});

    try disableUndoTriggers(conn);

    var redo_rows = try sql.rows(
        conn,
        \\select id, statement from history_redo
        \\where barrier_id = ?
        \\order by id desc
    ,
        .{barriers[0].id},
    );
    defer redo_rows.deinit();

    while (redo_rows.next()) |row| {
        const id = row.text(0);
        const sql_stmt = row.text(1);
        try sql.exec(conn, sql_stmt, .{});
        try sql.exec(conn, "delete from history_redo where id=?", .{id});
    }
    try sql.check(redo_rows.err, conn);

    // disable undone flag on next undo
    try sql.exec(conn,
        \\update history_barrier_undo
        \\set undone = false
        \\where id = (
        \\  select min(id) from history_barrier_undo where undone is true
        \\)
    , .{});

    try sql.exec(
        conn,
        std.fmt.comptimePrint(
            "delete from {s} where id=?",
            .{Redo.barriers_table},
        ),
        .{barriers[0].id},
    );

    try enableUndoTriggers(conn);

    const status_text = switch (barriers[0].action) {
        .create_post => "Redone post creation.",
        .update_post_title => "Redone post title update.",
        .update_post_content => "Redone post content update.",
        .delete_post => "Redone post deletion.",
        .change_scene => "Redone scene change.",
    };
    try sql.exec(conn,
        \\update gui_status_text
        \\set status_text = ?,
        \\    expires_at = datetime('now', '+7 seconds')
    , .{status_text});
}

// The heart of emacs-style undo-redo: when the user performs an undo, then
// makes changes, we put all trailing redos into the canonical undo stack, to
// make sure that every previous state is reachable via undo.
pub fn foldRedos(conn: zqlite.Conn) !void {
    try sql.execNoArgs(conn, "update history_barrier_undo set undone=false;");

    var redo_barriers = try sql.rows(conn, "select id, action from history_barrier_redo order by id", .{});
    defer redo_barriers.deinit();

    while (redo_barriers.next()) |barrier| {
        const redo_barrier_id = barrier.int(0);
        const redo_barrier_action = barrier.text(1);

        try sql.exec(
            conn,
            "insert into history_barrier_undo (action) values (?)",
            .{redo_barrier_action},
        );

        const undo_barrier_id = conn.lastInsertedRowId();

        try sql.exec(
            conn,
            \\insert into history_undo (barrier_id, statement)
            \\select ?1, statement from history_redo where barrier_id=?2 order by id
        ,
            .{ undo_barrier_id, redo_barrier_id },
        );
    }
    try sql.check(redo_barriers.err, conn);

    try sql.execNoArgs(conn, "delete from history_redo");
    try sql.execNoArgs(conn, "delete from history_barrier_redo");
}

fn disableUndoTriggers(conn: zqlite.Conn) !void {
    try sql.execNoArgs(conn, "update history_enable_triggers set undo=false");
}
fn enableUndoTriggers(conn: zqlite.Conn) !void {
    try sql.execNoArgs(conn, "update history_enable_triggers set undo=true");
}
fn disableRedoTriggers(conn: zqlite.Conn) !void {
    try sql.execNoArgs(conn, "update history_enable_triggers set redo=false");
}
fn enableRedoTriggers(conn: zqlite.Conn) !void {
    try sql.execNoArgs(conn, "update history_enable_triggers set redo=true");
}
