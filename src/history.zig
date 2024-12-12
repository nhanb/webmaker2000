const std = @import("std");
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const print = std.debug.print;

pub const Barrier = struct {
    id: i64,
    description: []const u8, // extracted from the barrier row
};

const HISTORY_TABLES = &.{
    "post",
    "gui_scene",
    "gui_scene_editing",
    "gui_modal",
};

const HistoryType = struct {
    main_table: []const u8,
    barriers_table: []const u8,
    trigger_prefix: []const u8,
};
pub const Undo = HistoryType{
    .main_table = "history_undo",
    .barriers_table = "history_barrier_undo",
    .trigger_prefix = "history_trigger_undo",
};
pub const Redo = HistoryType{
    .main_table = "history_redo",
    .barriers_table = "history_barrier_redo",
    .trigger_prefix = "history_trigger_redo",
};

pub fn createTriggers(
    comptime htype: HistoryType,
    conn: zqlite.Conn,
    gpa: std.mem.Allocator,
) !void {
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
            \\CREATE TRIGGER {s}_{s}_insert AFTER INSERT ON {s} BEGIN
            \\  INSERT INTO {s} (statement) VALUES (
            \\      'DELETE FROM {s} WHERE id=' || new.id
            \\  );
            \\END;
        , .{
            htype.trigger_prefix,
            table,
            table,
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
            \\CREATE TRIGGER {s}_{s}_update AFTER UPDATE ON {s} BEGIN
            \\  INSERT INTO {s} (statement) VALUES (
            \\      'UPDATE {s} SET {s} WHERE id=' || old.id
            \\  );
            \\END;
        ,
            .{
                htype.trigger_prefix,
                table,
                table,
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
            \\CREATE TRIGGER {s}_{s}_delete AFTER DELETE ON {s} BEGIN
            \\  INSERT INTO {s} (statement) VALUES (
            \\      'INSERT INTO {s} ({s}) VALUES ({s})'
            \\  );
            \\END;
        ,
            .{
                htype.trigger_prefix,
                table,
                table,
                htype.main_table,
                table,
                try std.mem.join(arena, ",", column_names.items),
                reinsert_values.items,
            },
        );
        try sql.exec(conn, delete_trigger, .{});
    }
}

pub fn dropTriggers(
    comptime htype: HistoryType,
    conn: zqlite.Conn,
    gpa: std.mem.Allocator,
) !void {
    print("Deleting triggers for {s}\n", .{htype.main_table});

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

        // Now drop triggers for all 3 events:
        const actions: []const []const u8 = &.{ "insert", "update", "delete" };
        inline for (actions) |action| {
            try sql.execNoArgs(conn, std.fmt.comptimePrint(
                "DROP TRIGGER IF EXISTS {s}_{s}_{s}",
                .{ htype.trigger_prefix, table, action },
            ));
        }
    }
}

pub fn undo(
    arena: std.mem.Allocator,
    conn: zqlite.Conn,
    barriers: []Barrier,
) !void {
    std.debug.assert(barriers.len > 0);

    try dropTriggers(Undo, conn, arena);
    try createTriggers(Redo, conn, arena);

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

        print(">> Exec: {s}\n", .{sql_stmt});
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
        \\insert into history_barrier_redo (description)
        \\values ((select description from history_barrier_undo order by id desc limit 1))
    ,
        .{},
    );

    const redo_barrier_id = conn.lastInsertedRowId();
    try sql.exec(
        conn,
        "update history_redo set barrier_id = ? where barrier_id is null",
        .{redo_barrier_id},
    );

    try dropTriggers(Redo, conn, arena);
    try createTriggers(Undo, conn, arena);
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
            \\select id, description from {s}
            \\where undone is false
            \\order by id desc
        , .{htype.barriers_table}),
        .{},
    );
    defer rows.deinit();

    while (rows.next()) |row| {
        try list.append(.{
            .id = row.int(0),
            .description = try arena.dupe(u8, row.text(1)),
        });
    }
    try sql.check(rows.err, conn);

    return list.items;
}

pub fn addBarrier(
    comptime htype: HistoryType,
    conn: zqlite.Conn,
    description: []const u8,
) !void {
    try sql.exec(
        conn,
        std.fmt.comptimePrint(
            "insert into {s} (description) values (?)",
            .{htype.barriers_table},
        ),
        .{description},
    );

    const barrier_id = conn.lastInsertedRowId();
    try sql.exec(
        conn,
        std.fmt.comptimePrint(
            "update {s} set barrier_id = ? where barrier_id is null",
            .{htype.main_table},
        ),
        .{barrier_id},
    );
}

pub fn redo(
    arena: std.mem.Allocator,
    conn: zqlite.Conn,
    barriers: []Barrier,
) !void {
    std.debug.assert(barriers.len > 0);

    try dropTriggers(Undo, conn, arena);

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

        print(">> Exec: {s}\n", .{sql_stmt});
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

    try createTriggers(Undo, conn, arena);
}

pub fn foldRedos(conn: zqlite.Conn) !void {
    try sql.execNoArgs(conn, "update history_barrier_undo set undone=false;");

    var redo_barriers = try sql.rows(conn, "select id, description from history_barrier_redo order by id", .{});
    defer redo_barriers.deinit();

    while (redo_barriers.next()) |barrier| {
        const redo_barrier_id = barrier.int(0);
        const redo_barrier_desc = barrier.text(1);

        try sql.exec(
            conn,
            "insert into history_barrier_undo (description) values (?)",
            .{redo_barrier_desc},
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
