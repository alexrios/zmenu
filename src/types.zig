//! Shared type definitions for zmenu

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");

/// Runtime color scheme (can be overridden by ZMENU_THEME env var)
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

/// Application state for input, items, and selection
pub const AppState = struct {
    input_buffer: std.ArrayList(u8),
    items: std.ArrayList([]const u8),
    filtered_items: std.ArrayList(usize),
    selected_index: usize,
    scroll_offset: usize,
    needs_render: bool,

    pub const empty = AppState{
        .input_buffer = std.ArrayList(u8).empty,
        .items = std.ArrayList([]const u8).empty,
        .filtered_items = std.ArrayList(usize).empty,
        .selected_index = 0,
        .scroll_offset = 0,
        .needs_render = true,
    };
};

/// Render context with buffers and caches
pub const RenderContext = struct {
    // Render buffers (allocated once, reused)
    prompt_buffer: []u8,
    item_buffer: []u8,
    count_buffer: []u8,
    scroll_buffer: []u8,
    // Texture caching for text rendering performance
    prompt_cache: TextureCache,
    count_cache: TextureCache,
    no_match_cache: TextureCache,
    // High DPI state
    display_scale: f32,
    pixel_width: u32,
    pixel_height: u32,
    // Current window dimensions (logical coordinates)
    current_width: u32,
    current_height: u32,

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
