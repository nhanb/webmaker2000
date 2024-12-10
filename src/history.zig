const std = @import("std");
const zqlite = @import("zqlite");
const sql = @import("sql.zig");
const print = std.debug.print;

pub const Barrier = struct {
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

pub fn registerTriggers(
    comptime htype: HistoryType,
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

pub fn undo(
    comptime htype: HistoryType,
    conn: zqlite.Conn,
    barriers: []Barrier,
) !void {
    try sql.execNoArgs(conn, "begin");
    errdefer conn.rollback();

    var prev_barrier_undo_id: i64 = -1;
    if (barriers.len > 1) {
        prev_barrier_undo_id = barriers[1].undo_id;
    }

    var undo_rows = try sql.rows(
        conn,
        std.fmt.comptimePrint(
            \\select id, statement from {s}
            \\where ?1 < id and id <= ?2
            \\order by id desc
        ,
            .{htype.main_table},
        ),
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
        try sql.exec(
            conn,
            std.fmt.comptimePrint("delete from {s} where id=?", .{htype.main_table}),
            .{id},
        );
    }
    try sql.check(undo_rows.err, conn);

    try sql.execNoArgs(conn, "commit");
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
            "select id, history_id, description from {s} order by id desc",
            .{htype.barriers_table},
        ),
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

pub fn addBarrier(
    comptime htype: HistoryType,
    conn: zqlite.Conn,
    description: []const u8,
) !void {
    try sql.exec(
        conn,
        std.fmt.comptimePrint(
            \\insert into {s} (history_id, description)
            \\values (
            \\  (select max(id) from {s} limit 1),
            \\  ?
            \\)
        ,
            .{ htype.barriers_table, htype.main_table },
        ),
        .{description},
    );
}
