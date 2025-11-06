const std = @import("std");
const sdl = @import("sdl3");
const builtin = @import("builtin");

/// Platform-specific default font paths (tried in order)
pub const default_font_paths = switch (builtin.os.tag) {
    .linux => [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf", // Arch Linux
        "/usr/share/fonts/dejavu/DejaVuSans.ttf", // Some distros
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    },
    .macos => [_][:0]const u8{
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNSText.ttf",
        "/Library/Fonts/Arial.ttf",
    },
    .windows => [_][:0]const u8{
        "C:\\Windows\\Fonts\\arial.ttf",
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\calibri.ttf",
    },
    else => [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    },
};

pub const FontConfig = struct {
    path: ?[:0]const u8 = null, // null = use platform defaults
    size: f32 = 22,
};

/// Text texture cache entry for performance optimization
pub const TextureCache = struct {
    texture: ?sdl.render.Texture,
    last_text: []u8,
    last_color: sdl.pixels.Color,

    pub fn init() TextureCache {
        return .{
            .texture = null,
            .last_text = &[_]u8{},
            .last_color = sdl.pixels.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        };
    }

    pub fn deinit(self: *TextureCache, allocator: std.mem.Allocator) void {
        if (self.texture) |tex| tex.deinit();
        if (self.last_text.len > 0) allocator.free(self.last_text);
    }
};

/// Load a TTF font with the given configuration
/// Tries platform-specific default paths if config.path is null
pub fn loadFont(config: FontConfig, allocator: std.mem.Allocator) !struct { font: sdl.ttf.Font, path: []const u8 } {
    if (config.path) |custom_path| {
        // User provided custom font path
        const font = sdl.ttf.Font.init(custom_path, config.size) catch |err| {
            std.debug.print("Failed to load custom font from {s}: {}\n", .{ custom_path, err });
            return err;
        };
        const path_copy = try allocator.dupe(u8, custom_path);
        return .{ .font = font, .path = path_copy };
    }

    // Try platform-specific default paths
    for (default_font_paths) |font_path| {
        if (sdl.ttf.Font.init(font_path, config.size)) |font| {
            const path_copy = try allocator.dupe(u8, font_path);
            return .{ .font = font, .path = path_copy };
        } else |_| {
            // Try next path
            continue;
        }
    }

    std.debug.print("Failed to load any font. Tried paths:\n", .{});
    for (default_font_paths) |font_path| {
        std.debug.print("  - {s}\n", .{font_path});
    }
    return error.NoFontAvailable;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "FontConfig - defaults" {
    const config = FontConfig{};
    try testing.expect(config.path == null);
    try testing.expectEqual(@as(f32, 22), config.size);
}

test "FontConfig - custom values" {
    const custom_path: [:0]const u8 = "/custom/font.ttf";
    const config = FontConfig{ .path = custom_path, .size = 16 };
    try testing.expectEqualStrings(custom_path, config.path.?);
    try testing.expectEqual(@as(f32, 16), config.size);
}

test "TextureCache - init" {
    const cache = TextureCache.init();
    try testing.expect(cache.texture == null);
    try testing.expectEqual(@as(usize, 0), cache.last_text.len);
}

test "TextureCache - deinit without allocation" {
    var cache = TextureCache.init();
    cache.deinit(testing.allocator); // Should not crash
}

test "default_font_paths - not empty" {
    try testing.expect(default_font_paths.len > 0);
}

test "default_font_paths - all absolute paths" {
    for (default_font_paths) |path| {
        try testing.expect(path.len > 0);
        const is_absolute = path[0] == '/' or (path.len >= 3 and path[1] == ':');
        try testing.expect(is_absolute);
    }
}

test "default_font_paths - all font files" {
    for (default_font_paths) |path| {
        const has_ext = std.mem.endsWith(u8, path, ".ttf") or
            std.mem.endsWith(u8, path, ".ttc") or
            std.mem.endsWith(u8, path, ".otf");
        try testing.expect(has_ext);
    }
}
