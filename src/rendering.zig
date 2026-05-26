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
    value_preview: sdl.pixels.Color,

    /// Create color scheme from compile-time config defaults
    pub fn fromConfig() ColorScheme {
        return .{
            .background = config.colors.background,
            .foreground = config.colors.foreground,
            .selected = config.colors.selected,
            .prompt = config.colors.prompt,
            .value_preview = config.colors.value_preview,
        };
    }
};

/// Maximum cached label length, bounded by the largest render text we ever
/// produce (the prompt with ellipsis + max input). Other cache uses (counter,
/// "No matches") are far smaller; trading ~2 KB of static storage for the
/// simplicity of a single sized type is the right Safe-Zig R3 trade.
pub const max_cache_text_len: usize = config.limits.prompt_buffer_size;

/// Text texture cache entry for rendering performance.
/// Stores its own copy of the previous frame's label in a fixed-size buffer so
/// the render path can detect changes without any heap allocation.
pub const TextureCache = struct {
    texture: ?sdl.render.Texture,
    last_text_buf: [max_cache_text_len]u8,
    last_text_len: usize,
    last_color: sdl.pixels.Color,

    pub const empty = TextureCache{
        .texture = null,
        .last_text_buf = undefined,
        .last_text_len = 0,
        .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };

    pub fn deinit(self: *TextureCache) void {
        if (self.texture) |tex| tex.deinit();
    }

    pub fn lastText(self: *const TextureCache) []const u8 {
        std.debug.assert(self.last_text_len <= self.last_text_buf.len);
        return self.last_text_buf[0..self.last_text_len];
    }

    pub fn setText(self: *TextureCache, text: []const u8) void {
        std.debug.assert(text.len <= self.last_text_buf.len);
        // @memcpy requires non-overlapping src/dst. Forbid setText(lastText()).
        const buf_start = @intFromPtr(&self.last_text_buf);
        const buf_end = buf_start + self.last_text_buf.len;
        const src_start = @intFromPtr(text.ptr);
        std.debug.assert(src_start >= buf_end or src_start + text.len <= buf_start);
        @memcpy(self.last_text_buf[0..text.len], text);
        self.last_text_len = text.len;
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
    value_preview_buffer: []u8,
    // Texture caching for text rendering performance
    prompt_cache: TextureCache,
    count_cache: TextureCache,
    no_match_cache: TextureCache,
    // Cached max item width (updated on item ingest, avoids per-frame measurement)
    cached_max_item_width: f32 = 0,
    // Window and display state
    window: Window,

    pub fn deinit(self: *RenderContext, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_buffer);
        allocator.free(self.item_buffer);
        allocator.free(self.count_buffer);
        allocator.free(self.scroll_buffer);
        allocator.free(self.value_preview_buffer);
        self.prompt_cache.deinit();
        self.count_cache.deinit();
        self.no_match_cache.deinit();
    }
};

pub fn colorEquals(a: sdl.pixels.Color, b: sdl.pixels.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}
