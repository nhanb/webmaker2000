const std = @import("std");
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const print = std.debug.print;

const BARRIER_HEADER = "--BARRIER ";

pub const UndoBarrier = struct {
    id: i64,
    undo_id: i64,
    description: []const u8, // extracted from the barrier row
};

const HISTORY_TABLES = &.{
    "post",
    "gui_scene",
    "gui_scene_editing",
    "gui_modal",
};

pub fn registerUndo(
    conn: zqlite.Conn,
    gpa: std.mem.Allocator,
) !void {
    print("Registering undo for {d} tables:\n", .{HISTORY_TABLES.len});

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    inline for (HISTORY_TABLES) |table| {
        print("- table {s}\n", .{table});

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
            print("    column {s}\n", .{column});
            try column_names.append(column);
        }
        try sql.check(records.err, conn);

        // Now create triggers for all 3 events:

        // INSERT:
        const insert_trigger = std.fmt.comptimePrint(
            \\CREATE TRIGGER undo_{s}_insert AFTER INSERT ON {s} BEGIN
            \\  INSERT INTO history_undo (statement) VALUES (
            \\      'DELETE FROM {s} WHERE id=' || new.id
            \\  );
            \\END;
        , .{
            table,
            table,
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
            \\CREATE TRIGGER undo_{s}_update AFTER UPDATE ON {s} BEGIN
            \\  INSERT INTO history_undo (statement) VALUES (
            \\      'UPDATE {s} SET {s} WHERE id=' || old.id
            \\  );
            \\END;
        ,
            .{
                table,
                table,
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
            \\CREATE TRIGGER undo_{s}_delete AFTER DELETE ON {s} BEGIN
            \\  INSERT INTO history_undo (statement) VALUES (
            \\      'INSERT INTO {s} ({s}) VALUES ({s})'
            \\  );
            \\END;
        ,
            .{
                table,
                table,
                table,
                try std.mem.join(arena, ",", column_names.items),
                reinsert_values.items,
            },
        );
        try sql.exec(conn, delete_trigger, .{});
    }
}

pub fn undo(conn: zqlite.Conn, barriers: []UndoBarrier) !void {
    try sql.execNoArgs(conn, "begin");
    errdefer conn.rollback();

    var prev_barrier_undo_id: i64 = -1;
    if (barriers.len > 1) {
        prev_barrier_undo_id = barriers[1].undo_id;
    }

    var undo_rows = try sql.rows(
        conn,
        \\select id, statement from history_undo
        \\where ?1 < id and id <= ?2
        \\order by id desc
    ,
        .{
            prev_barrier_undo_id,
            barriers[0].undo_id,
        },
    );
    defer undo_rows.deinit();

    while (undo_rows.next()) |row| {
        const id = row.text(0);
        const sql_stmt = row.text(1);

        print(">> Exec: {s}\n", .{sql_stmt});
        try sql.exec(conn, sql_stmt, .{});

        // TODO: somehow convert and put this onto the redo stack instead.
        try sql.exec(conn, "delete from history_undo where id=?", .{id});
    }
    try sql.check(undo_rows.err, conn);

    try sql.execNoArgs(conn, "commit");
}

pub fn getUndoBarriers(conn: zqlite.Conn, arena: std.mem.Allocator) ![]UndoBarrier {
    var list = std.ArrayList(UndoBarrier).init(arena);

    var rows = try sql.rows(
        conn,
        "select id, history_undo_id, description from history_undo_barrier order by id desc",
        .{},
    );
    defer rows.deinit();

    while (rows.next()) |row| {
        try list.append(.{
            .id = row.int(0),
            .undo_id = row.int(1),
            .description = try arena.dupe(u8, row.text(2)),
        });
    }
    try sql.check(rows.err, conn);

    return list.items;
}

pub fn addUndoBarrier(conn: zqlite.Conn, description: []const u8) !void {
    try sql.exec(conn,
        \\insert into history_undo_barrier (history_undo_id, description)
        \\values (
        \\  (select max(id) from history_undo limit 1),
        \\  ?
        \\)
    , .{description});
}
