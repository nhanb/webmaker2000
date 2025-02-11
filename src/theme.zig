const std = @import("std");
const dvui = @import("dvui");
const Adwaita = @import("Adwaita.zig");

pub fn default() dvui.Theme {
    var theme = Adwaita.light;

    theme.font_body = .{ .size = 20, .name = "Noto" };
    theme.font_heading = .{ .size = 20, .name = "NotoBd" };
    theme.font_caption = .{ .size = 14, .name = "Noto", .line_height_factor = 1.1 };
    theme.font_caption_heading = .{ .size = 14, .name = "NotoBd", .line_height_factor = 1.1 };
    theme.font_title = .{ .size = 30, .name = "Noto" };
    theme.font_title_1 = .{ .size = 28, .name = "NotoBd" };
    theme.font_title_2 = .{ .size = 26, .name = "NotoBd" };
    theme.font_title_3 = .{ .size = 24, .name = "NotoBd" };
    theme.font_title_4 = .{ .size = 22, .name = "NotoBd" };

    theme.color_fill_control = theme.color_fill_window;
    theme.color_border = dvui.Color.black;

    // Unfortunately some settings are configured not through the theme but via
    // some "defaults" variables instead. Setting them here isn't all that
    // clean, but at least it's nice to have all theme-related stuff in one
    // place.
    dvui.ButtonWidget.defaults.corner_radius = dvui.Rect.all(0);
    dvui.ButtonWidget.defaults.border = .{ .h = 3, .w = 3, .x = 1, .y = 1 };
    //dvui.ButtonWidget.defaults.color_accent = .{ .color = dvui.Color.white };
    dvui.ButtonWidget.defaults.font = theme.font_caption_heading;
    dvui.ButtonWidget.defaults.padding = .{ .h = 2, .w = 6, .x = 6, .y = 2 };
    dvui.TextEntryWidget.defaults.corner_radius = dvui.Rect.all(0);
    dvui.FloatingWindowWidget.defaults.corner_radius = dvui.Rect.all(0);

    return theme;
}

// AFAIK there's no way to set a "default font size for buttons only".
// For such granularity, we need to override the opts param instead:
pub fn button(
    src: std.builtin.SourceLocation,
    label_str: []const u8,
    init_opts: dvui.ButtonWidget.InitOptions,
    opts: dvui.Options,
) !bool {
    //var final_opts = opts;
    //final_opts.font = .{ .size = 18, .name = "Noto" };
    return dvui.button(src, label_str, init_opts, opts);
}
