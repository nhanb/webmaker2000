const std = @import("std");
const print = std.debug.print;
const ziglua = @import("ziglua");
const djot_lua = @embedFile("djot.lua");

var lua: *ziglua.Lua = undefined;
var lua_mut = std.Thread.Mutex{};

/// Initialize the lua VM and load the necessary djot.lua library code.
/// Remember to call deinit() when you're all done.
pub fn init(gpa: std.mem.Allocator) !void {
    lua = try ziglua.Lua.init(gpa);

    // load lua standard libraries
    lua.openLibs();

    // load the djot.lua amalgamation
    lua.doString(djot_lua) catch |err| {
        print("lua error: {s}\n", .{try lua.toString(-1)});
        return err;
    };

    // define simple helper function
    lua.doString(
        \\djot = require("djot")
        \\function djotToHtml(input)
        \\  return djot.render_html(djot.parse(input))
        \\end
    ) catch |err| {
        print("lua error: {s}\n", .{try lua.toString(-1)});
        return err;
    };
}

/// Run this when you're all done, to cleanly destroy the lua VM.
pub fn deinit() void {
    lua.deinit();
}

/// The returned string is owned by the caller.
/// This function is thread-safe.
pub fn toHtml(gpa: std.mem.Allocator, input: []const u8) ![]const u8 {
    lua_mut.lock();
    defer lua_mut.unlock();

    // call the global djotToHtml function
    _ = try lua.getGlobal("djotToHtml");
    _ = lua.pushString(input);
    lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
        print("lua error: {s}\n", .{try lua.toString(-1)});
        return err;
    };

    const result = gpa.dupe(u8, try lua.toString(1));

    // All done. Pop previous result from stack.
    lua.pop(1);

    return result;
}
