const std = @import("std");
const sdl = @import("sdl3");
const syntax_mod = @import("syntax");

/// Represents a highlighted region in the source code
pub const HighlightSpan = struct {
    start_byte: usize,
    end_byte: usize,
    scope: []const u8,
};

/// Color scheme for syntax highlighting
pub const ColorScheme = struct {
    background: sdl.pixels.Color,
    foreground: sdl.pixels.Color,
    selected: sdl.pixels.Color,
    prompt: sdl.pixels.Color,
};

/// Syntax highlighter that uses tree-sitter via flow-syntax
pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,
    query_cache: *syntax_mod.QueryCache,
    colors: ColorScheme,

    pub fn init(allocator: std.mem.Allocator, query_cache: *syntax_mod.QueryCache, colors: ColorScheme) SyntaxHighlighter {
        return .{
            .allocator = allocator,
            .query_cache = query_cache,
            .colors = colors,
        };
    }

    /// Apply syntax highlighting to content and collect highlight spans
    pub fn highlight(self: *SyntaxHighlighter, file_path: []const u8, content: []const u8, spans: *std.ArrayList(HighlightSpan)) !void {
        // Try to create syntax highlighter for this file
        const syntax = syntax_mod.create_guess_file_type_static(
            self.allocator,
            content,
            file_path,
            self.query_cache,
        ) catch return; // If we can't highlight, just return without error
        defer syntax.destroy(self.query_cache);

        // Parse the content
        syntax.refresh_full(content) catch return;

        // Collect highlight spans using a callback
        const Context = struct {
            span_list: *std.ArrayList(HighlightSpan),
            alloc: std.mem.Allocator,

            fn callback(
                ctx: *@This(),
                range: syntax_mod.Range,
                scope: []const u8,
                id: u32,
                capture_idx: usize,
                node: *const syntax_mod.Node,
            ) error{Stop}!void {
                _ = id;
                _ = capture_idx;
                _ = node;

                ctx.span_list.append(ctx.alloc, .{
                    .start_byte = range.start_byte,
                    .end_byte = range.end_byte,
                    .scope = scope,
                }) catch return error.Stop;
            }
        };
        var ctx = Context{
            .span_list = spans,
            .alloc = self.allocator,
        };

        syntax.render(&ctx, Context.callback, null) catch return;
    }

    /// Map tree-sitter scope to a color from the color scheme
    pub fn getScopeColor(self: *SyntaxHighlighter, scope: []const u8) sdl.pixels.Color {
        // Keywords, control flow
        if (std.mem.indexOf(u8, scope, "keyword") != null or
            std.mem.indexOf(u8, scope, "conditional") != null or
            std.mem.indexOf(u8, scope, "repeat") != null or
            std.mem.indexOf(u8, scope, "include") != null)
        {
            return self.colors.selected; // Use selected color for keywords
        }

        // Strings, characters
        if (std.mem.indexOf(u8, scope, "string") != null or
            std.mem.indexOf(u8, scope, "character") != null)
        {
            return self.colors.prompt; // Use prompt color for strings
        }

        // Comments (create a muted version of foreground)
        if (std.mem.indexOf(u8, scope, "comment") != null) {
            const fg = self.colors.foreground;
            return sdl.pixels.Color{
                .r = @intCast(@as(u16, fg.r) * 7 / 10),
                .g = @intCast(@as(u16, fg.g) * 7 / 10),
                .b = @intCast(@as(u16, fg.b) * 7 / 10),
                .a = fg.a,
            };
        }

        // Functions
        if (std.mem.indexOf(u8, scope, "function") != null) {
            return self.colors.prompt; // Use prompt color for functions
        }

        // Types, constants, numbers
        if (std.mem.indexOf(u8, scope, "type") != null or
            std.mem.indexOf(u8, scope, "constant") != null or
            std.mem.indexOf(u8, scope, "number") != null)
        {
            return self.colors.selected; // Use selected color for types
        }

        // Default to foreground color
        return self.colors.foreground;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "HighlightSpan - basic struct" {
    const span = HighlightSpan{
        .start_byte = 0,
        .end_byte = 10,
        .scope = "keyword",
    };
    try testing.expectEqual(@as(usize, 0), span.start_byte);
    try testing.expectEqual(@as(usize, 10), span.end_byte);
    try testing.expectEqualStrings("keyword", span.scope);
}

test "ColorScheme - create scheme" {
    const colors = ColorScheme{
        .background = sdl.pixels.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .foreground = sdl.pixels.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .selected = sdl.pixels.Color{ .r = 255, .g = 0, .b = 255, .a = 255 },
        .prompt = sdl.pixels.Color{ .r = 0, .g = 255, .b = 255, .a = 255 },
    };
    try testing.expectEqual(@as(u8, 0), colors.background.r);
    try testing.expectEqual(@as(u8, 255), colors.foreground.r);
}

test "SyntaxHighlighter - getScopeColor keyword" {
    const allocator = testing.allocator;
    const query_cache = try syntax_mod.QueryCache.create(allocator, .{});
    defer query_cache.deinit();

    const colors = ColorScheme{
        .background = sdl.pixels.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .foreground = sdl.pixels.Color{ .r = 200, .g = 200, .b = 200, .a = 255 },
        .selected = sdl.pixels.Color{ .r = 255, .g = 0, .b = 255, .a = 255 },
        .prompt = sdl.pixels.Color{ .r = 0, .g = 255, .b = 255, .a = 255 },
    };

    var highlighter = SyntaxHighlighter.init(allocator, query_cache, colors);

    // Keywords should use selected color
    const keyword_color = highlighter.getScopeColor("keyword");
    try testing.expectEqual(colors.selected.r, keyword_color.r);
    try testing.expectEqual(colors.selected.g, keyword_color.g);
    try testing.expectEqual(colors.selected.b, keyword_color.b);
}

test "SyntaxHighlighter - getScopeColor string" {
    const allocator = testing.allocator;
    const query_cache = try syntax_mod.QueryCache.create(allocator, .{});
    defer query_cache.deinit();

    const colors = ColorScheme{
        .background = sdl.pixels.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .foreground = sdl.pixels.Color{ .r = 200, .g = 200, .b = 200, .a = 255 },
        .selected = sdl.pixels.Color{ .r = 255, .g = 0, .b = 255, .a = 255 },
        .prompt = sdl.pixels.Color{ .r = 0, .g = 255, .b = 255, .a = 255 },
    };

    var highlighter = SyntaxHighlighter.init(allocator, query_cache, colors);

    // Strings should use prompt color
    const string_color = highlighter.getScopeColor("string");
    try testing.expectEqual(colors.prompt.r, string_color.r);
    try testing.expectEqual(colors.prompt.g, string_color.g);
    try testing.expectEqual(colors.prompt.b, string_color.b);
}

test "SyntaxHighlighter - getScopeColor comment" {
    const allocator = testing.allocator;
    const query_cache = try syntax_mod.QueryCache.create(allocator, .{});
    defer query_cache.deinit();

    const colors = ColorScheme{
        .background = sdl.pixels.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .foreground = sdl.pixels.Color{ .r = 200, .g = 200, .b = 200, .a = 255 },
        .selected = sdl.pixels.Color{ .r = 255, .g = 0, .b = 255, .a = 255 },
        .prompt = sdl.pixels.Color{ .r = 0, .g = 255, .b = 255, .a = 255 },
    };

    var highlighter = SyntaxHighlighter.init(allocator, query_cache, colors);

    // Comments should use dimmed foreground (70% brightness)
    const comment_color = highlighter.getScopeColor("comment");
    try testing.expectEqual(@as(u8, 140), comment_color.r); // 200 * 7/10 = 140
    try testing.expectEqual(@as(u8, 140), comment_color.g);
    try testing.expectEqual(@as(u8, 140), comment_color.b);
}

test "SyntaxHighlighter - getScopeColor default" {
    const allocator = testing.allocator;
    const query_cache = try syntax_mod.QueryCache.create(allocator, .{});
    defer query_cache.deinit();

    const colors = ColorScheme{
        .background = sdl.pixels.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .foreground = sdl.pixels.Color{ .r = 200, .g = 200, .b = 200, .a = 255 },
        .selected = sdl.pixels.Color{ .r = 255, .g = 0, .b = 255, .a = 255 },
        .prompt = sdl.pixels.Color{ .r = 0, .g = 255, .b = 255, .a = 255 },
    };

    var highlighter = SyntaxHighlighter.init(allocator, query_cache, colors);

    // Unknown scopes should use foreground
    const default_color = highlighter.getScopeColor("unknown_scope");
    try testing.expectEqual(colors.foreground.r, default_color.r);
    try testing.expectEqual(colors.foreground.g, default_color.g);
    try testing.expectEqual(colors.foreground.b, default_color.b);
}
