const dvui = @import("dvui");

const fill: dvui.Color = .fromHex("#2c3332");
const text: dvui.Color = .fromHex("#82a29f");
const border: dvui.Color = .fromHex("#60827d");

pub const theme: dvui.Theme = blk: {
    @setEvalBranchQuota(4000);
    break :blk .{
        .name = "Terminal",
        .dark = true,

        .font_body = .find(.{ .family = "Vera Sans Mono" }),
        .font_heading = .find(.{ .family = "Vera Sans Mono", .weight = .bold }),
        .font_title = .find(.{ .family = "Vera Sans Mono", .size = dvui.Font.DefaultSize + 2 }),
        .font_mono = .find(.{ .family = "Vera Sans Mono" }),

        .focus = .fromHex("#638465"),
        .fill = fill,
        .text = text,
        .border = border,
        .fill_hover = .fromHex("#334e57"),
        .fill_press = .fromHex("#3b6357"),
        .text_press = .fromHex("#97af81"),

        .control = .{
            .fill = .fromHex("#2c3334"),
            .fill_hover = .fromHex("#334e57"),
            .fill_press = .fromHex("#3b6357"),
            .text_press = .fromHex("#97af81"),
        },
        .window = .{
            .fill = .fromHex("#2b3a3a"),
        },
        .highlight = .{
            .fill = .fromHex("#475b4b"),
            .fill_hover = .fromHex("#334e57"),
            .fill_press = .fromHex("#3b6357"),
            .text = .fromHex("#2c3332"),
            .text_press = .fromHex("#090909"),
        },

        .err = .{
            .fill = .average(.red, fill),
            .text = .average(.red, text),
            .border = .average(.red, border),
        },
    };
};
