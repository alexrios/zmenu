const std = @import("std");
const sdl = @import("sdl3");

/// Theme definition with 4 core colors
pub const Theme = struct {
    background: sdl.pixels.Color,
    foreground: sdl.pixels.Color,
    selected: sdl.pixels.Color,
    prompt: sdl.pixels.Color,
};

/// Catppuccin Mocha - Dark pastel theme (default)
pub const mocha = Theme{
    .background = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e, .a = 0xff },
    .foreground = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4, .a = 0xff },
    .selected = .{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 0xff },
    .prompt = .{ .r = 0xf5, .g = 0xe0, .b = 0xdc, .a = 0xff },
};

/// Catppuccin Latte - Light pastel theme
pub const latte = Theme{
    .background = .{ .r = 0xef, .g = 0xf1, .b = 0xf5, .a = 0xff },
    .foreground = .{ .r = 0x4c, .g = 0x4f, .b = 0x69, .a = 0xff },
    .selected = .{ .r = 0x1e, .g = 0x66, .b = 0xf5, .a = 0xff },
    .prompt = .{ .r = 0xdc, .g = 0x8a, .b = 0x78, .a = 0xff },
};

/// Catppuccin Frappé - Medium pastel theme
pub const frappe = Theme{
    .background = .{ .r = 0x30, .g = 0x30, .b = 0x46, .a = 0xff },
    .foreground = .{ .r = 0xc6, .g = 0xd0, .b = 0xf5, .a = 0xff },
    .selected = .{ .r = 0x8c, .g = 0xaa, .b = 0xee, .a = 0xff },
    .prompt = .{ .r = 0xf2, .g = 0xd5, .b = 0xcf, .a = 0xff },
};

/// Catppuccin Macchiato - Dark-medium pastel theme
pub const macchiato = Theme{
    .background = .{ .r = 0x24, .g = 0x27, .b = 0x3a, .a = 0xff },
    .foreground = .{ .r = 0xca, .g = 0xd3, .b = 0xf5, .a = 0xff },
    .selected = .{ .r = 0x8a, .g = 0xad, .b = 0xf4, .a = 0xff },
    .prompt = .{ .r = 0xf4, .g = 0xdb, .b = 0xd6, .a = 0xff },
};

/// Dracula - Popular dark theme with vibrant colors
pub const dracula = Theme{
    .background = .{ .r = 0x28, .g = 0x2a, .b = 0x36, .a = 0xff },
    .foreground = .{ .r = 0xf8, .g = 0xf8, .b = 0xf2, .a = 0xff },
    .selected = .{ .r = 0xff, .g = 0x79, .b = 0xc6, .a = 0xff },
    .prompt = .{ .r = 0x8b, .g = 0xe9, .b = 0xfd, .a = 0xff },
};

/// Gruvbox Dark - Retro warm dark theme
pub const gruvbox = Theme{
    .background = .{ .r = 0x28, .g = 0x28, .b = 0x28, .a = 0xff },
    .foreground = .{ .r = 0xeb, .g = 0xdb, .b = 0xb2, .a = 0xff },
    .selected = .{ .r = 0xfa, .g = 0xbd, .b = 0x2f, .a = 0xff },
    .prompt = .{ .r = 0x8e, .g = 0xc0, .b = 0x7c, .a = 0xff },
};

/// Nord - Cool arctic-inspired theme
pub const nord = Theme{
    .background = .{ .r = 0x2e, .g = 0x34, .b = 0x40, .a = 0xff },
    .foreground = .{ .r = 0xec, .g = 0xef, .b = 0xf4, .a = 0xff },
    .selected = .{ .r = 0x88, .g = 0xc0, .b = 0xd0, .a = 0xff },
    .prompt = .{ .r = 0x81, .g = 0xa1, .b = 0xc1, .a = 0xff },
};

/// Solarized Dark - Popular low-contrast theme
pub const solarized = Theme{
    .background = .{ .r = 0x00, .g = 0x2b, .b = 0x36, .a = 0xff },
    .foreground = .{ .r = 0x83, .g = 0x94, .b = 0x96, .a = 0xff },
    .selected = .{ .r = 0x26, .g = 0x8b, .b = 0xd2, .a = 0xff },
    .prompt = .{ .r = 0x2a, .g = 0xa1, .b = 0x98, .a = 0xff },
};

/// Default theme (mocha)
pub const default = mocha;

/// Compile-time map for theme lookup
const theme_map = std.StaticStringMap(Theme).initComptime(.{
    .{ "mocha", mocha },
    .{ "latte", latte },
    .{ "frappe", frappe },
    .{ "macchiato", macchiato },
    .{ "dracula", dracula },
    .{ "gruvbox", gruvbox },
    .{ "nord", nord },
    .{ "solarized", solarized },
});

/// Get theme by name (case-insensitive)
/// Returns default theme if name not found
pub fn getByName(name: []const u8) Theme {
    var lower_buf: [32]u8 = undefined;
    if (name.len > lower_buf.len) return default;

    const lower = std.ascii.lowerString(&lower_buf, name);
    return theme_map.get(lower) orelse default;
}

// Tests
test "theme lookup - valid names" {
    const t = getByName("dracula");
    try std.testing.expectEqual(@as(u8, 0x28), t.background.r);
    try std.testing.expectEqual(@as(u8, 0xff), t.selected.r);
}

test "theme lookup - case insensitive" {
    const t1 = getByName("NORD");
    const t2 = getByName("nord");
    const t3 = getByName("NoRd");
    try std.testing.expectEqual(t1.background.r, t2.background.r);
    try std.testing.expectEqual(t2.background.r, t3.background.r);
}

test "theme lookup - invalid name returns default" {
    const t = getByName("nonexistent");
    try std.testing.expectEqual(default.background.r, t.background.r);
    try std.testing.expectEqual(default.foreground.r, t.foreground.r);
}

test "theme lookup - empty string returns default" {
    const t = getByName("");
    try std.testing.expectEqual(default.background.r, t.background.r);
}

test "theme lookup - name too long returns default" {
    const t = getByName("this_is_a_very_long_theme_name_that_exceeds_buffer");
    try std.testing.expectEqual(default.background.r, t.background.r);
}
