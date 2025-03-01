const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

fn escape(allocator: std.mem.Allocator, attr: []const u8) []const u8 {
    var escaped: []u8 = undefined;
    var unescaped: []const u8 = attr;
    inline for (.{
        "&",
        "\"",
        "'",
        "<",
        ">",
    }, .{
        "&amp;",
        "&quot;",
        "&#39;",
        "&lt;",
        "&gt;",
    }) |needle, replacement| {
        const size = std.mem.replacementSize(u8, unescaped, needle, replacement);
        escaped = allocator.alloc(u8, size) catch unreachable;
        _ = std.mem.replace(u8, unescaped, needle, replacement, escaped);
        unescaped = escaped;
    }
    return escaped;
}

pub const Element = struct {
    allocator: Allocator,
    tag: []const u8,
    attrs: []const Attr,
    children: ?[]const Child,

    pub fn writeTo(self: Element, writer: anytype) !void {
        try writer.writeAll("<");
        try writer.writeAll(self.tag);

        for (self.attrs) |attr| {
            try writer.writeAll(" ");
            try writer.writeAll(attr.name);
            try writer.writeAll("=\"");
            try writer.writeAll(escape(self.allocator, attr.value));
            try writer.writeAll("\"");
        }

        try writer.writeAll(">");

        if (self.children) |children| {
            for (children) |child| switch (child) {
                .text => |text| try writer.writeAll(escape(self.allocator, text)),
                .elem => |elem| try elem.writeTo(writer),
            };
            try writer.writeAll("</");
            try writer.writeAll(self.tag);
            try writer.writeAll(">");
        }
    }

    /// Caller owns result memory
    pub fn toHtml(self: Element, arena: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(arena);
        try self.writeTo(buf.writer());
        return buf.items;
    }
};

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Child = union(enum) {
    text: []const u8,
    elem: Element,
};

test "Element" {
    const test_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();

    const h = Builder{ .allocator = arena.allocator() };
    const doc2 = h.html(
        .{ .lang = "en", .style = "font-family: monospace;" },
        .{
            h.head(null, .{h.title(null, .{"My title"})}),
            h.body(null, .{
                h.h1(null, .{"Hello!"}),
                h.hr(null),
                h.p(
                    .{ .@"escapes<&" = "&<>\"'" },
                    .{"Escape me: &<>\"'"},
                ),
            }),
        },
    );

    var output = ArrayList(u8).init(arena.allocator());
    var writer = output.writer();

    try doc2.writeTo(&writer);

    try std.testing.expectEqualStrings(
        \\<html lang="en" style="font-family: monospace;"><head><title>My title</title></head><body><h1>Hello!</h1><hr><p escapes<&="&amp;&lt;&gt;&quot;&#39;">Escape me: &amp;&lt;&gt;&quot;&#39;</p></body></html>
    ,
        output.items,
    );
}

pub const Builder = struct {
    allocator: Allocator,

    fn element(self: Builder, comptime tag: []const u8, attrs: anytype, children: anytype) Element {
        var attrs_list = ArrayList(Attr).init(self.allocator);

        if (@TypeOf(attrs) != @TypeOf(null)) {
            inline for (@typeInfo(@TypeOf(attrs)).@"struct".fields) |field| {
                comptime {
                    // https://html.spec.whatwg.org/multipage/syntax.html#attributes-2
                    // Attribute names must consist of one or more characters other than
                    // controls, U+0020 SPACE, U+0022 ("), U+0027 ('), U+003E (>), U+002F (/),
                    // U+003D (=), and noncharacters. In the HTML syntax, attribute names, even
                    // those for foreign elements, may be written with any mix of ASCII lower
                    // and ASCII upper alphas.
                    for (field.name) |char| {
                        if (!std.ascii.isASCII(char)) {
                            unreachable; // found non-ascii char in html attribute name
                        }
                        if (std.ascii.isControl(char)) {
                            unreachable; // found forbidden control char in html attribute name
                        }
                        for (" \"'>/=") |forbidden_char| {
                            if (char == forbidden_char) {
                                unreachable; // found forbidden char in html attribute name
                            }
                        }
                    }
                }

                attrs_list.append(.{
                    .name = field.name,
                    .value = @field(attrs, field.name),
                }) catch unreachable;
            }
        }

        if (@TypeOf(children) == @TypeOf(null)) {
            return Element{
                .allocator = self.allocator,
                .tag = tag,
                .attrs = attrs_list.items,
                .children = children,
            };
        }

        // Each item in the `children` tuple can be an Element, []Element, []Child, or string.
        // This makes composition (read: templates) easier.
        var children_list = ArrayList(Child).init(self.allocator);
        inline for (children) |child| switch (@TypeOf(child)) {
            Element => children_list.append(.{ .elem = child }) catch unreachable,
            []Element => {
                for (child) |c| {
                    children_list.append(.{ .elem = c }) catch unreachable;
                }
            },
            Child => {
                children_list.append(child) catch unreachable;
            },
            []Child => {
                for (child) |c| {
                    children_list.append(c) catch unreachable;
                }
            },
            else => children_list.append(.{ .text = @as([]const u8, child) }) catch unreachable,
        };
        return Element{
            .allocator = self.allocator,
            .tag = tag,
            .attrs = attrs_list.items,
            .children = children_list.items,
        };
    }

    pub fn writeDoctype(_: Builder, writer: anytype) !void {
        try writer.writeAll("<!DOCTYPE html>\n");
    }

    pub fn area(self: Builder, attrs: anytype) Element {
        return self.element("area", attrs, null);
    }
    pub fn base(self: Builder, attrs: anytype) Element {
        return self.element("base", attrs, null);
    }
    pub fn br(self: Builder, attrs: anytype) Element {
        return self.element("br", attrs, null);
    }
    pub fn col(self: Builder, attrs: anytype) Element {
        return self.element("col", attrs, null);
    }
    pub fn embed(self: Builder, attrs: anytype) Element {
        return self.element("embed", attrs, null);
    }
    pub fn hr(self: Builder, attrs: anytype) Element {
        return self.element("hr", attrs, null);
    }
    pub fn img(self: Builder, attrs: anytype) Element {
        return self.element("img", attrs, null);
    }
    pub fn input(self: Builder, attrs: anytype) Element {
        return self.element("input", attrs, null);
    }
    pub fn link(self: Builder, attrs: anytype) Element {
        return self.element("link", attrs, null);
    }
    pub fn meta(self: Builder, attrs: anytype) Element {
        return self.element("meta", attrs, null);
    }
    pub fn source(self: Builder, attrs: anytype) Element {
        return self.element("source", attrs, null);
    }
    pub fn track(self: Builder, attrs: anytype) Element {
        return self.element("track", attrs, null);
    }
    pub fn wbr(self: Builder, attrs: anytype) Element {
        return self.element("wbr", attrs, null);
    }
    pub fn a(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("a", attrs, children);
    }
    pub fn abbr(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("abbr", attrs, children);
    }
    pub fn acronym(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("acronym", attrs, children);
    }
    pub fn address(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("address", attrs, children);
    }
    pub fn article(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("article", attrs, children);
    }
    pub fn aside(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("aside", attrs, children);
    }
    pub fn audio(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("audio", attrs, children);
    }
    pub fn b(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("b", attrs, children);
    }
    pub fn bdi(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("bdi", attrs, children);
    }
    pub fn bdo(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("bdo", attrs, children);
    }
    pub fn big(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("big", attrs, children);
    }
    pub fn blockquote(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("blockquote", attrs, children);
    }
    pub fn body(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("body", attrs, children);
    }
    pub fn button(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("button", attrs, children);
    }
    pub fn canvas(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("canvas", attrs, children);
    }
    pub fn caption(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("caption", attrs, children);
    }
    pub fn center(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("center", attrs, children);
    }
    pub fn cite(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("cite", attrs, children);
    }
    pub fn code(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("code", attrs, children);
    }
    pub fn colgroup(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("colgroup", attrs, children);
    }
    pub fn data(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("data", attrs, children);
    }
    pub fn datalist(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("datalist", attrs, children);
    }
    pub fn dd(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("dd", attrs, children);
    }
    pub fn del(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("del", attrs, children);
    }
    pub fn details(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("details", attrs, children);
    }
    pub fn dfn(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("dfn", attrs, children);
    }
    pub fn dialog(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("dialog", attrs, children);
    }
    pub fn dir(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("dir", attrs, children);
    }
    pub fn div(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("div", attrs, children);
    }
    pub fn dl(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("dl", attrs, children);
    }
    pub fn dt(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("dt", attrs, children);
    }
    pub fn em(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("em", attrs, children);
    }
    pub fn fieldset(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("fieldset", attrs, children);
    }
    pub fn figcaption(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("figcaption", attrs, children);
    }
    pub fn figure(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("figure", attrs, children);
    }
    pub fn font(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("font", attrs, children);
    }
    pub fn footer(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("footer", attrs, children);
    }
    pub fn form(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("form", attrs, children);
    }
    pub fn frame(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("frame", attrs, children);
    }
    pub fn frameset(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("frameset", attrs, children);
    }
    pub fn h1(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("h1", attrs, children);
    }
    pub fn head(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("head", attrs, children);
    }
    pub fn header(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("header", attrs, children);
    }
    pub fn hgroup(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("hgroup", attrs, children);
    }
    pub fn html(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("html", attrs, children);
    }
    pub fn i(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("i", attrs, children);
    }
    pub fn iframe(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("iframe", attrs, children);
    }
    pub fn image(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("image", attrs, children);
    }
    pub fn ins(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("ins", attrs, children);
    }
    pub fn kbd(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("kbd", attrs, children);
    }
    pub fn label(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("label", attrs, children);
    }
    pub fn legend(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("legend", attrs, children);
    }
    pub fn li(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("li", attrs, children);
    }
    pub fn main(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("main", attrs, children);
    }
    pub fn map(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("map", attrs, children);
    }
    pub fn mark(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("mark", attrs, children);
    }
    pub fn marquee(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("marquee", attrs, children);
    }
    pub fn menu(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("menu", attrs, children);
    }
    pub fn menuitem(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("menuitem", attrs, children);
    }
    pub fn meter(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("meter", attrs, children);
    }
    pub fn nav(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("nav", attrs, children);
    }
    pub fn nobr(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("nobr", attrs, children);
    }
    pub fn noembed(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("noembed", attrs, children);
    }
    pub fn noframes(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("noframes", attrs, children);
    }
    pub fn noscript(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("noscript", attrs, children);
    }
    pub fn object(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("object", attrs, children);
    }
    pub fn ol(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("ol", attrs, children);
    }
    pub fn optgroup(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("optgroup", attrs, children);
    }
    pub fn option(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("option", attrs, children);
    }
    pub fn output(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("output", attrs, children);
    }
    pub fn p(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("p", attrs, children);
    }
    pub fn param(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("param", attrs, children);
    }
    pub fn picture(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("picture", attrs, children);
    }
    pub fn plaintext(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("plaintext", attrs, children);
    }
    pub fn portal(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("portal", attrs, children);
    }
    pub fn pre(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("pre", attrs, children);
    }
    pub fn progress(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("progress", attrs, children);
    }
    pub fn q(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("q", attrs, children);
    }
    pub fn rb(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("rb", attrs, children);
    }
    pub fn rp(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("rp", attrs, children);
    }
    pub fn rt(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("rt", attrs, children);
    }
    pub fn rtc(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("rtc", attrs, children);
    }
    pub fn ruby(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("ruby", attrs, children);
    }
    pub fn s(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("s", attrs, children);
    }
    pub fn samp(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("samp", attrs, children);
    }
    pub fn script(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("script", attrs, children);
    }
    pub fn search(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("search", attrs, children);
    }
    pub fn section(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("section", attrs, children);
    }
    pub fn select(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("select", attrs, children);
    }
    pub fn slot(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("slot", attrs, children);
    }
    pub fn small(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("small", attrs, children);
    }
    pub fn span(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("span", attrs, children);
    }
    pub fn strike(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("strike", attrs, children);
    }
    pub fn strong(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("strong", attrs, children);
    }
    pub fn style(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("style", attrs, children);
    }
    pub fn sub(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("sub", attrs, children);
    }
    pub fn summary(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("summary", attrs, children);
    }
    pub fn sup(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("sup", attrs, children);
    }
    pub fn table(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("table", attrs, children);
    }
    pub fn tbody(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("tbody", attrs, children);
    }
    pub fn td(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("td", attrs, children);
    }
    pub fn template(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("template", attrs, children);
    }
    pub fn textarea(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("textarea", attrs, children);
    }
    pub fn tfoot(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("tfoot", attrs, children);
    }
    pub fn th(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("th", attrs, children);
    }
    pub fn thead(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("thead", attrs, children);
    }
    pub fn time(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("time", attrs, children);
    }
    pub fn title(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("title", attrs, children);
    }
    pub fn tr(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("tr", attrs, children);
    }
    pub fn tt(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("tt", attrs, children);
    }
    pub fn u(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("u", attrs, children);
    }
    pub fn ul(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("ul", attrs, children);
    }
    pub fn @"var"(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("var", attrs, children);
    }
    pub fn video(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("video", attrs, children);
    }
    pub fn xmp(self: Builder, attrs: anytype, children: anytype) Element {
        return self.element("xmp", attrs, children);
    }
};
