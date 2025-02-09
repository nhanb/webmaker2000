const dvui = @import("dvui");
const Adwaita = @import("Adwaita.zig");

pub var default = blk: {
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

    break :blk theme;
};
