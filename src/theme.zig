const std = @import("std");
const dvui = @import("dvui");
const Adwaita = @import("Adwaita.zig");

pub fn default() dvui.Theme {
    var theme = Adwaita.light;

    theme.font_body = .{ .size = 20, .name = "Noto" };
    theme.font_heading = .{ .size = 20, .name = "NotoBd" };
    theme.font_caption = .{ .size = 16, .name = "Noto", .line_height_factor = 1.1 };
    theme.font_caption_heading = .{ .size = 16, .name = "NotoBd", .line_height_factor = 1.1 };
    theme.font_title = .{ .size = 30, .name = "Noto" };
    theme.font_title_1 = .{ .size = 28, .name = "NotoBd" };
    theme.font_title_2 = .{ .size = 26, .name = "NotoBd" };
    theme.font_title_3 = .{ .size = 24, .name = "NotoBd" };
    theme.font_title_4 = .{ .size = 22, .name = "NotoBd" };

    theme.color_fill_control = theme.color_fill_window;
    theme.color_fill_hover = dvui.Color.white;
    theme.color_border = dvui.Color.black;

    // Unfortunately some settings are configured not through the theme but via
    // some "defaults" variables instead. Setting them here isn't all that
    // clean, but at least it's nice to have all theme-related stuff in one
    // place.
    dvui.ButtonWidget.defaults.corner_radius = dvui.Rect.all(0);
    dvui.ButtonWidget.defaults.border = .{ .h = 3, .w = 3, .x = 1, .y = 1 };
    dvui.ButtonWidget.defaults.padding = .{ .h = 2, .w = 6, .x = 6, .y = 2 };
    dvui.TextEntryWidget.defaults.corner_radius = dvui.Rect.all(3);
    dvui.TextEntryWidget.defaults.color_border = .{ .color = .{ .r = 0x99, .g = 0x99, .b = 0x99 } };
    dvui.FloatingWindowWidget.defaults.corner_radius = dvui.Rect.all(0);

    return theme;
}

/// Thin wrapper to easily toggle text entry's invalid state.
/// It adds the necessary styling.
pub fn textEntry(
    src: std.builtin.SourceLocation,
    init_opts: dvui.TextEntryWidget.InitOptions,
    opts: dvui.Options,
    // TODO: maybe turn this bool into a list of errors for custom rendering?
    invalid: bool,
) *dvui.TextEntryWidget {
    if (!invalid) return dvui.textEntry(src, init_opts, opts);

    var invalid_opts = opts;
    invalid_opts.color_fill = .{ .color = .{ .r = 0xff, .g = 0xeb, .b = 0xe9 } };
    invalid_opts.color_accent = .{ .color = .{ .r = 0xff, .g = 0, .b = 0 } };
    invalid_opts.color_border = .{ .color = .{ .r = 0xff, .g = 0, .b = 0 } };
    return dvui.textEntry(src, init_opts, invalid_opts);
}

/// Thin wrapper to easily toggle button's disabled state.
/// It adds the necessary styling, and always returns false when disabled.
pub fn button(
    src: std.builtin.SourceLocation,
    label_str: []const u8,
    init_opts: dvui.ButtonWidget.InitOptions,
    opts: dvui.Options,
    disabled: bool,
) bool {
    if (!disabled) return dvui.button(src, label_str, init_opts, opts);

    var disabled_opts = opts;
    disabled_opts.color_text = .{ .name = .fill_press };
    disabled_opts.color_text_press = .{ .name = .fill_press };
    disabled_opts.color_fill_hover = .{ .name = .fill_control };
    disabled_opts.color_fill_press = .{ .name = .fill_control };
    disabled_opts.color_accent = .{ .color = dvui.Color{ .a = 0x00 } };
    _ = dvui.button(src, label_str, init_opts, disabled_opts);
    return false;
}

pub fn errLabel(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    return dvui.label(src, fmt, args, .{
        .color_text = .{ .name = .err },
        .font_style = .caption,
        .padding = .{
            .x = 5,
            .y = 0, // top
            .h = 5,
            .w = 5,
        },
    });
}
