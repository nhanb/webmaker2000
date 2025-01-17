const dvui = @import("dvui");
const Adwaita = @import("Adwaita.zig");

pub var default = blk: {
    var theme = Adwaita.light;
    //theme.color_border = dvui.Color{ .r = 0xff, .g = 0x55, .b = 0x55 };
    theme.font_body.name = "Noto";
    theme.font_body.size = 20;
    break :blk theme;
};
