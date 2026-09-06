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
        self.texture = null;
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

/// Reserve prompt, footer and margins independently of the match count.
pub fn visibleRows(height: u32, line_height: f32) usize {
    const usable = @max(0, @as(f32, @floatFromInt(height)) - config.layout.items_start_y - config.layout.bottom_margin - line_height);
    return @min(config.limits.max_visible_items, @max(1, @as(usize, @intFromFloat(@floor(usable / line_height)))));
}

pub const FitMode = enum { tail, middle };

/// Fit a label using actual glyph widths. All cuts occur at UTF-8 boundaries.
/// Paths retain their basename where it fits; queries retain their newest text.
pub fn fitText(font: anytype, buffer: []u8, prefix: []const u8, text: []const u8, width: f32, mode: FitMode) ![:0]const u8 {
    if (prefix.len + text.len + 1 <= buffer.len) {
        const full = try std.fmt.bufPrintZ(buffer, "{s}{s}", .{ prefix, text });
        const w, _ = try font.getStringSize(full);
        if (@as(f32, @floatFromInt(w)) <= width) return full;
    }
    if (buffer.len < prefix.len + 4) return error.BufferTooSmall;
    var low: usize = 0;
    var high = @min(text.len, buffer.len - prefix.len - 4);
    var best: usize = 0;
    while (low <= high) {
        const keep = low + (high - low) / 2;
        const candidate = try fitCandidate(buffer, prefix, text, keep, mode);
        const w, _ = try font.getStringSize(candidate);
        if (@as(f32, @floatFromInt(w)) <= width) {
            best = keep;
            low = keep + 1;
        } else {
            if (keep == 0) return try std.fmt.bufPrintZ(buffer, "", .{});
            high = keep - 1;
        }
    }
    return fitCandidate(buffer, prefix, text, best, mode);
}

fn fitCandidate(buffer: []u8, prefix: []const u8, text: []const u8, keep: usize, mode: FitMode) ![:0]const u8 {
    const input = @import("input.zig");
    var head: usize = 0;
    var tail = text.len;
    if (mode == .tail) {
        tail = text.len - keep;
    } else if (std.mem.lastIndexOfAny(u8, text, "/\\")) |slash| {
        const basename_len = text.len - slash - 1;
        const suffix_len = @min(keep, basename_len);
        head = input.findUtf8Boundary(text, keep - suffix_len);
        tail = text.len - suffix_len;
    } else {
        head = input.findUtf8Boundary(text, keep);
    }
    while (tail < text.len and (text[tail] & 0xc0) == 0x80) tail += 1;
    return std.fmt.bufPrintZ(buffer, "{s}{s}...{s}", .{ prefix, text[0..head], text[tail..] });
}

const TestFont = struct {
    pub fn getStringSize(_: TestFont, text: []const u8) !struct { u32, u32 } {
        return .{ @intCast((try std.unicode.utf8CountCodepoints(text)) * 10), 20 };
    }
};

test "pixel fitting preserves UTF-8, query tail and path basename" {
    var buffer: [256]u8 = undefined;
    const query = try fitText(TestFont{}, &buffer, "> ", "日本語café", 80, .tail);
    try std.testing.expect(std.unicode.utf8ValidateSlice(query));
    try std.testing.expect(std.mem.endsWith(u8, query, "afé"));
    const path = try fitText(TestFont{}, &buffer, "", "/very/long/日本語/directory/file.txt", 180, .middle);
    try std.testing.expect(std.mem.endsWith(u8, path, "file.txt"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(path));
    const w, _ = try (TestFont{}).getStringSize(path);
    try std.testing.expect(w <= 180);
    try std.testing.expectEqualStrings("", try fitText(TestFont{}, &buffer, "> ", "abc", 1, .tail));
}

test "viewport reserves footer and derives rows from height" {
    try std.testing.expectEqual(@as(usize, 12), visibleRows(300, 20));
    try std.testing.expectEqual(@as(usize, 7), visibleRows(300, 30));
}
