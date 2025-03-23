const std = @import("std");
const t = std.testing;

pub fn humanReadableSize(arena: std.mem.Allocator, bytes: i64) ![]const u8 {
    std.debug.assert(bytes >= 0);

    switch (bytes) {
        0...1023 => {
            return try std.fmt.allocPrint(arena, "{d}B", .{bytes});
        },
        1024...1024 * 1024 - 1 => {
            const bytes_float: f64 = @floatFromInt(bytes);
            const kibibytes = bytes_float / 1024.0;
            return try std.fmt.allocPrint(
                arena,
                "{d:.1}KiB",
                .{kibibytes},
            );
        },
        1024 * 1024...1024 * 1024 * 1024 - 1 => {
            const bytes_float: f64 = @floatFromInt(bytes);
            const mebibytes = bytes_float / (1024.0 * 1024.0);
            return try std.fmt.allocPrint(
                arena,
                "{d:.1}MiB",
                .{mebibytes},
            );
        },
        else => {
            const bytes_float: f64 = @floatFromInt(bytes);
            const gibibytes = bytes_float / (1024.0 * 1024.0 * 1024.0);
            return try std.fmt.allocPrint(
                arena,
                "{d:.1}GiB",
                .{gibibytes},
            );
        },
    }
}

test humanReadableSize {
    const test_alloc = std.testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(test_alloc);
    const arena = arena_impl.allocator();
    defer arena_impl.deinit();

    const cases = [_]std.meta.Tuple(&.{ i64, []const u8 }){
        .{ 0, "0B" },
        .{ 1023, "1023B" },
        .{ 1024, "1.0KiB" },
        .{ 1025, "1.0KiB" },
        .{ 1115, "1.1KiB" }, // rounds up
        .{ 1024 * 1024 - 1, "1024.0KiB" }, // ugh
        .{ 1024 * 1024, "1.0MiB" },
        .{ 1024 * 1024 * 1024, "1.0GiB" },
        .{ 1115000000, "1.0GiB" },
        .{ 2011111111, "1.9GiB" },
    };

    for (cases) |case| {
        try t.expectEqualStrings(
            case[1],
            try humanReadableSize(arena, case[0]),
        );
    }
}
