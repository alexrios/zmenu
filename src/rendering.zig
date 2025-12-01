//! Rendering types and functionality

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");

/// Color scheme configured at compile-time
pub const ColorScheme = struct {
    background: sdl.pixels.Color,
    foreground: sdl.pixels.Color,
    selected: sdl.pixels.Color,
    prompt: sdl.pixels.Color,

    /// Create color scheme from compile-time config defaults
    pub fn fromConfig() ColorScheme {
        return .{
            .background = config.colors.background,
            .foreground = config.colors.foreground,
            .selected = config.colors.selected,
            .prompt = config.colors.prompt,
        };
    }
};

/// Text texture cache entry for rendering performance
pub const TextureCache = struct {
    texture: ?sdl.render.Texture,
    last_text: []u8,
    last_color: sdl.pixels.Color,

    pub const empty = TextureCache{
        .texture = null,
        .last_text = &[_]u8{},
        .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };

    pub fn deinit(self: *TextureCache, allocator: std.mem.Allocator) void {
        if (self.texture) |tex| tex.deinit();
        allocator.free(self.last_text);
    }
};

/// Render context with buffers and caches
pub const RenderContext = struct {
    /// Window and display properties
    pub const Window = struct {
        display_scale: f32,
        width: u32, // Physical pixels
        height: u32, // Physical pixels
        current_width: u32, // Logical coordinates
        current_height: u32, // Logical coordinates
    };

    // Render buffers (allocated once, reused)
    prompt_buffer: []u8,
    item_buffer: []u8,
    count_buffer: []u8,
    scroll_buffer: []u8,
    // Texture caching for text rendering performance
    prompt_cache: TextureCache,
    count_cache: TextureCache,
    no_match_cache: TextureCache,
    // Window and display state
    window: Window,

    pub fn deinit(self: *RenderContext, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_buffer);
        allocator.free(self.item_buffer);
        allocator.free(self.count_buffer);
        allocator.free(self.scroll_buffer);
        self.prompt_cache.deinit(allocator);
        self.count_cache.deinit(allocator);
        self.no_match_cache.deinit(allocator);
    }
};

pub fn colorEquals(a: sdl.pixels.Color, b: sdl.pixels.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}
