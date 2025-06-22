const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const Backend = dvui.backend;

pub fn setWindowTitle(arena: std.mem.Allocator, window: *dvui.Window, title: [:0]const u8) !void {
    switch (Backend.kind) {
        .sdl3 => {
            _ = Backend.c.SDL_SetWindowTitle(window.backend.impl.window, title);
        },
        .dx11 => {
            const win32 = Backend.win32;
            const hwnd: win32.HWND = @ptrCast(window.backend.impl);
            const win_title = try std.unicode.utf8ToUtf16LeAllocZ(arena, title);
            defer arena.free(win_title);
            _ = win32.SetWindowTextW(hwnd, win_title);
        },
        else => @panic("Unsupported backend."),
    }
}
