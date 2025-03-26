const std = @import("std");

/// I keep forgetting the trailing \n, so this helper pays for itself
pub fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}
