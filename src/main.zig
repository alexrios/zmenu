const std = @import("std");
const sdl = @import("sdl3");
const builtin = @import("builtin");

// Platform-specific default font paths (tried in order)
const default_font_paths = switch (builtin.os.tag) {
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

const Config = struct {
    window_width: u32 = 800,
    window_height: u32 = 300,
    background_color: sdl.pixels.Color = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e, .a = 0xff },
    foreground_color: sdl.pixels.Color = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4, .a = 0xff },
    selected_color: sdl.pixels.Color = .{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 0xff },
    prompt_color: sdl.pixels.Color = .{ .r = 0xf5, .g = 0xe0, .b = 0xdc, .a = 0xff },
    max_visible_items: usize = 10,
    max_item_length: usize = 4096,
    max_input_length: usize = 1024,
    input_ellipsis_margin: usize = 100, // Show ellipsis when input within this margin of max
    prompt_buffer_size: usize = 1024 + 16, // max_input_length + prefix + safety
    item_buffer_size: usize = 4096 + 16, // max_item_length + prefix + safety
    count_buffer_size: usize = 64,
    scroll_buffer_size: usize = 64,
    item_line_height: f32 = 20.0,
    prompt_y: f32 = 5.0,
    items_start_y: f32 = 30.0,
    right_margin_offset: f32 = 60.0,
    // Font configuration
    font_path: ?[:0]const u8 = null, // null = use platform defaults
    font_size: f32 = 22,
};

// Text texture cache entry
const TextureCache = struct {
    texture: ?sdl.render.Texture,
    last_text: []u8,
    last_color: sdl.pixels.Color,

    fn deinit(self: *TextureCache, allocator: std.mem.Allocator) void {
        if (self.texture) |tex| tex.deinit();
        allocator.free(self.last_text);
    }
};

const App = struct {
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    config: Config,
    input_buffer: std.ArrayList(u8),
    items: std.ArrayList([]const u8),
    filtered_items: std.ArrayList(usize),
    selected_index: usize,
    scroll_offset: usize,
    allocator: std.mem.Allocator,
    needs_render: bool,
    // Render buffers (allocated once, reused)
    prompt_buffer: []u8,
    item_buffer: []u8,
    count_buffer: []u8,
    scroll_buffer: []u8,
    // Font
    font: sdl.ttf.Font,
    loaded_font_path: []const u8, // Track which font was actually loaded
    // Texture caching for text rendering performance
    prompt_cache: TextureCache,
    count_cache: TextureCache,
    no_match_cache: TextureCache,

    fn tryLoadFont(config: Config) !struct { font: sdl.ttf.Font, path: []const u8 } {
        // If user specified a custom font path, try only that
        if (config.font_path) |custom_path| {
            const font = sdl.ttf.Font.init(custom_path, config.font_size) catch |err| {
                std.debug.print("Error: Failed to load font '{s}': {}\n", .{ custom_path, err });
                return err;
            };
            return .{ .font = font, .path = custom_path };
        }

        // Try platform-specific default fonts in order
        for (default_font_paths) |font_path| {
            if (sdl.ttf.Font.init(font_path, config.font_size)) |font| {
                std.debug.print("Successfully loaded font: {s}\n", .{font_path});
                return .{ .font = font, .path = font_path };
            } else |_| {
                // Silently continue to next font
            }
        }

        // No fonts found
        std.debug.print("Error: Could not find any suitable font. Tried:\n", .{});
        for (default_font_paths) |font_path| {
            std.debug.print("  - {s}\n", .{font_path});
        }
        return error.NoFontFound;
    }

    fn init(allocator: std.mem.Allocator) !App {
        // Initialize SDL
        const init_flags = sdl.InitFlags{ .video = true, .events = true };
        try sdl.init(init_flags);
        errdefer {
            const quit_flags = sdl.InitFlags{ .video = true, .events = true };
            sdl.quit(quit_flags);
        }

        // Initialize SDL_ttf
        try sdl.ttf.init();
        errdefer sdl.ttf.quit();

        const config = Config{};

        // Create window and renderer
        const window, const renderer = try sdl.render.Renderer.initWithWindow(
            "zmenu",
            config.window_width,
            config.window_height,
            .{ .borderless = true, .always_on_top = true },
        );
        errdefer renderer.deinit();
        errdefer window.deinit();

        // Position window at top center of screen
        window.setPosition(.{ .centered = null }, .{ .absolute = 0 }) catch |err| {
            std.debug.print("Warning: Failed to position window: {}\n", .{err});
        };

        // Allocate render buffers
        const prompt_buffer = try allocator.alloc(u8, config.prompt_buffer_size);
        errdefer allocator.free(prompt_buffer);
        const item_buffer = try allocator.alloc(u8, config.item_buffer_size);
        errdefer allocator.free(item_buffer);
        const count_buffer = try allocator.alloc(u8, config.count_buffer_size);
        errdefer allocator.free(count_buffer);
        const scroll_buffer = try allocator.alloc(u8, config.scroll_buffer_size);
        errdefer allocator.free(scroll_buffer);

        // Load font with platform-specific fallback
        const font_result = try tryLoadFont(config);
        errdefer font_result.font.deinit();

        var app = App{
            .window = window,
            .renderer = renderer,
            .config = config,
            .input_buffer = std.ArrayList(u8).empty,
            .items = std.ArrayList([]const u8).empty,
            .filtered_items = std.ArrayList(usize).empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .allocator = allocator,
            .needs_render = true,
            .prompt_buffer = prompt_buffer,
            .item_buffer = item_buffer,
            .count_buffer = count_buffer,
            .scroll_buffer = scroll_buffer,
            .font = font_result.font,
            .loaded_font_path = font_result.path,
            .prompt_cache = .{ .texture = null, .last_text = &[_]u8{}, .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .count_cache = .{ .texture = null, .last_text = &[_]u8{}, .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .no_match_cache = .{ .texture = null, .last_text = &[_]u8{}, .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        };

        // Load items from stdin
        try app.loadItemsFromStdin();

        // Check that we have items to display
        if (app.items.items.len == 0) {
            // Clean up ArrayLists before returning error
            // The buffers will be cleaned up by errdefer
            app.items.deinit(app.allocator);
            app.filtered_items.deinit(app.allocator);
            app.input_buffer.deinit(app.allocator);
            return error.NoItemsProvided;
        }

        try app.updateFilter();

        // Start text input
        try sdl.keyboard.startTextInput(window);

        return app;
    }

    fn deinit(self: *App) void {
        sdl.keyboard.stopTextInput(self.window) catch |err| {
            std.debug.print("Warning: Failed to stop text input: {}\n", .{err});
        };
        self.input_buffer.deinit(self.allocator);
        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit(self.allocator);
        self.filtered_items.deinit(self.allocator);
        self.allocator.free(self.prompt_buffer);
        self.allocator.free(self.item_buffer);
        self.allocator.free(self.count_buffer);
        self.allocator.free(self.scroll_buffer);
        // Clean up texture caches
        self.prompt_cache.deinit(self.allocator);
        self.count_cache.deinit(self.allocator);
        self.no_match_cache.deinit(self.allocator);
        self.font.deinit();
        self.renderer.deinit();
        self.window.deinit();
        sdl.ttf.quit();
        const quit_flags = sdl.InitFlags{ .video = true, .events = true };
        sdl.quit(quit_flags);
    }

    fn findUtf8Boundary(text: []const u8, max_len: usize) usize {
        // Find the last valid UTF-8 character boundary at or before max_len
        if (text.len <= max_len) return text.len;

        var pos = max_len;
        // Walk backwards to find a non-continuation byte
        // UTF-8 continuation bytes have the pattern 10xxxxxx (0x80-0xBF)
        while (pos > 0 and (text[pos] & 0xC0) == 0x80) {
            pos -= 1;
        }
        return pos;
    }

    fn loadItemsFromStdin(self: *App) !void {
        const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        const max_size = 10 * 1024 * 1024; // 10MB max
        const content = try stdin_file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(content);

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            // Trim whitespace and skip empty lines
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                // Validate and truncate if needed (UTF-8 safe)
                const truncate_len = findUtf8Boundary(trimmed, self.config.max_item_length);
                const final_line = trimmed[0..truncate_len];

                const owned_line = try self.allocator.dupe(u8, final_line);
                try self.items.append(self.allocator, owned_line);
            }
        }
    }

    fn updateFilter(self: *App) !void {
        self.filtered_items.clearRetainingCapacity();

        if (self.input_buffer.items.len == 0) {
            // No filter, show all items
            for (self.items.items, 0..) |_, i| {
                try self.filtered_items.append(self.allocator, i);
            }
        } else {
            // Fuzzy matching with case-insensitive search
            const query = self.input_buffer.items;
            for (self.items.items, 0..) |item, i| {
                if (fuzzyMatch(item, query)) {
                    try self.filtered_items.append(self.allocator, i);
                }
            }
        }

        // Reset selection if out of bounds
        if (self.filtered_items.items.len > 0) {
            if (self.selected_index >= self.filtered_items.items.len) {
                self.selected_index = self.filtered_items.items.len - 1;
            }
        } else {
            self.selected_index = 0;
        }

        // Adjust scroll to keep selection visible
        self.adjustScroll();
    }

    fn fuzzyMatch(haystack: []const u8, needle: []const u8) bool {
        var h_idx: usize = 0;
        for (needle) |n_char| {
            // Handle UTF-8 gracefully - only process valid ASCII for case-insensitive match
            const n_lower = if (n_char < 128) std.ascii.toLower(n_char) else n_char;
            var found = false;
            while (h_idx < haystack.len) : (h_idx += 1) {
                const h_char = haystack[h_idx];
                const h_lower = if (h_char < 128) std.ascii.toLower(h_char) else h_char;
                if (h_lower == n_lower) {
                    h_idx += 1;
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn adjustScroll(self: *App) void {
        if (self.filtered_items.items.len == 0) {
            self.scroll_offset = 0;
            return;
        }

        // Keep selected item visible
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + self.config.max_visible_items) {
            self.scroll_offset = self.selected_index - self.config.max_visible_items + 1;
        }
    }

    fn navigate(self: *App, delta: isize) void {
        if (self.filtered_items.items.len == 0) return;

        const current = @as(isize, @intCast(self.selected_index));
        const new_idx = current + delta;

        if (new_idx >= 0 and new_idx < @as(isize, @intCast(self.filtered_items.items.len))) {
            self.selected_index = @intCast(new_idx);
            self.adjustScroll();
            self.needs_render = true;
        }
    }

    fn navigateToFirst(self: *App) void {
        if (self.filtered_items.items.len > 0) {
            self.selected_index = 0;
            self.adjustScroll();
            self.needs_render = true;
        }
    }

    fn navigateToLast(self: *App) void {
        if (self.filtered_items.items.len > 0) {
            self.selected_index = self.filtered_items.items.len - 1;
            self.adjustScroll();
            self.needs_render = true;
        }
    }

    fn navigatePage(self: *App, direction: isize) void {
        if (self.filtered_items.items.len == 0) return;

        const page_size = @as(isize, @intCast(self.config.max_visible_items));
        const delta = page_size * direction;
        self.navigate(delta);
    }

    fn deleteLastCodepoint(self: *App) void {
        // Remove the last UTF-8 codepoint from input buffer
        if (self.input_buffer.items.len == 0) return;

        var i = self.input_buffer.items.len - 1;

        // UTF-8 continuation bytes start with 10xxxxxx (0x80-0xBF)
        // We need to backtrack to find the start of the codepoint
        while (i > 0 and (self.input_buffer.items[i] & 0xC0) == 0x80) {
            i -= 1;
        }

        // Resize to remove the entire codepoint
        self.input_buffer.shrinkRetainingCapacity(i);
    }

    fn deleteWord(self: *App) !void {
        // Skip trailing whitespace first (UTF-8 safe: space and tab are single bytes)
        while (self.input_buffer.items.len > 0) {
            const ch = self.input_buffer.getLast();
            if (ch != ' ' and ch != '\t') break;
            _ = self.input_buffer.pop();
        }

        // Delete word characters (UTF-8 aware)
        while (self.input_buffer.items.len > 0) {
            const ch = self.input_buffer.getLast();
            if (ch == ' ' or ch == '\t') break;
            self.deleteLastCodepoint();
        }

        try self.updateFilter();
        self.needs_render = true;
    }

    fn handleKeyEvent(self: *App, event: sdl.events.Keyboard) !bool {
        const key = event.key orelse return false;

        if (key == .escape) {
            return true; // Quit without selection
        } else if (key == .return_key or key == .kp_enter) {
            // Output selected item and quit
            if (self.filtered_items.items.len > 0) {
                const selected = self.items.items[self.filtered_items.items[self.selected_index]];
                // Cross-platform: std.posix maps to Windows/POSIX appropriately
                const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                _ = try stdout_file.write(selected);
                _ = try stdout_file.write("\n");
            }
            return true;
        } else if (key == .backspace) {
            if (self.input_buffer.items.len > 0) {
                self.deleteLastCodepoint();
                try self.updateFilter();
                self.needs_render = true;
            }
        } else if (key == .u and (event.mod.left_control or event.mod.right_control)) {
            // Ctrl+U: Clear input
            self.input_buffer.clearRetainingCapacity();
            try self.updateFilter();
            self.needs_render = true;
        } else if (key == .w and (event.mod.left_control or event.mod.right_control)) {
            // Ctrl+W: Delete last word
            try self.deleteWord();
        } else if (key == .up or key == .k) {
            self.navigate(-1);
        } else if (key == .down or key == .j) {
            self.navigate(1);
        } else if (key == .c and (event.mod.left_control or event.mod.right_control)) {
            // Ctrl+C: Quit without selection
            return true;
        } else if (key == .tab) {
            if (event.mod.left_shift or event.mod.right_shift) {
                self.navigate(-1); // Shift+Tab: previous
            } else {
                self.navigate(1); // Tab: next
            }
        } else if (key == .home) {
            self.navigateToFirst();
        } else if (key == .end) {
            self.navigateToLast();
        } else if (key == .page_up) {
            self.navigatePage(-1);
        } else if (key == .page_down) {
            self.navigatePage(1);
        }

        return false;
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        // Check if adding this text would exceed max input length
        if (self.input_buffer.items.len + text.len <= self.config.max_input_length) {
            try self.input_buffer.appendSlice(self.allocator, text);
            try self.updateFilter();
            self.needs_render = true;
        }
        // Silently ignore input that would exceed the limit
    }

    fn renderText(self: *App, x: f32, y: f32, text: [:0]const u8, color: sdl.pixels.Color) !void {
        // Convert sdl.pixels.Color to sdl.ttf.Color
        const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };

        // Render text to surface with anti-aliasing
        const surface = try self.font.renderTextBlended(text, ttf_color);
        defer surface.deinit();

        // Create texture from surface
        const texture = try self.renderer.createTextureFromSurface(surface);
        defer texture.deinit();

        // Get texture size
        const width, const height = try texture.getSize();

        // Render texture at position
        const dst = sdl.rect.FRect{ .x = x, .y = y, .w = width, .h = height };
        try self.renderer.renderTexture(texture, null, dst);
    }

    fn renderCachedText(
        self: *App,
        x: f32,
        y: f32,
        text: [:0]const u8,
        color: sdl.pixels.Color,
        cache: *TextureCache,
    ) !void {
        // Check if we can reuse cached texture
        const text_changed = !std.mem.eql(u8, cache.last_text, text);
        const color_changed = !colorEquals(cache.last_color, color);

        if (text_changed or color_changed or cache.texture == null) {
            // Invalidate old texture
            if (cache.texture) |old_tex| old_tex.deinit();

            // Update cache metadata
            self.allocator.free(cache.last_text);
            cache.last_text = try self.allocator.dupe(u8, text);
            cache.last_color = color;

            // Render new texture with anti-aliasing
            const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
            const surface = try self.font.renderTextBlended(text, ttf_color);
            defer surface.deinit();
            cache.texture = try self.renderer.createTextureFromSurface(surface);
        }

        // Render cached texture
        if (cache.texture) |texture| {
            const width, const height = try texture.getSize();
            const dst = sdl.rect.FRect{ .x = x, .y = y, .w = width, .h = height };
            try self.renderer.renderTexture(texture, null, dst);
        }
    }

    fn render(self: *App) !void {
        // Clear background
        try self.renderer.setDrawColor(self.config.background_color);
        try self.renderer.clear();

        // Show prompt with input buffer
        const prompt_text = if (self.input_buffer.items.len > 0) blk: {
            // Truncate display if input is too long, showing last chars with ellipsis
            const ellipsis_threshold = self.config.max_input_length - self.config.input_ellipsis_margin;
            const display_input = if (self.input_buffer.items.len > ellipsis_threshold)
                blk2: {
                    // Find UTF-8 safe starting position
                    const approx_start = self.input_buffer.items.len - ellipsis_threshold;
                    var start = approx_start;
                    // Skip continuation bytes to find valid UTF-8 boundary
                    while (start < self.input_buffer.items.len and (self.input_buffer.items[start] & 0xC0) == 0x80) {
                        start += 1;
                    }
                    break :blk2 self.input_buffer.items[start..];
                }
            else
                self.input_buffer.items;

            const prefix = if (self.input_buffer.items.len > ellipsis_threshold) "> ..." else "> ";
            break :blk std.fmt.bufPrintZ(self.prompt_buffer, "{s}{s}", .{ prefix, display_input }) catch "> [error]";
        } else
            std.fmt.bufPrintZ(self.prompt_buffer, "> ", .{}) catch "> ";

        try self.renderCachedText(5, self.config.prompt_y, prompt_text, self.config.prompt_color, &self.prompt_cache);

        // Show filtered items count
        const count_text = std.fmt.bufPrintZ(
            self.count_buffer,
            "{d}/{d}",
            .{ self.filtered_items.items.len, self.items.items.len },
        ) catch "?/?";

        const count_x = @as(f32, @floatFromInt(self.config.window_width)) - self.config.right_margin_offset;
        try self.renderCachedText(count_x, self.config.prompt_y, count_text, self.config.foreground_color, &self.count_cache);

        // Cache length to avoid race conditions
        const filtered_len = self.filtered_items.items.len;

        // Show multiple items
        if (filtered_len > 0) {
            const visible_end = @min(self.scroll_offset + self.config.max_visible_items, filtered_len);

            var y_pos: f32 = self.config.items_start_y;

            for (self.scroll_offset..visible_end) |i| {
                // Double check bounds before accessing
                if (i >= filtered_len) break;

                const item_index = self.filtered_items.items[i];
                if (item_index >= self.items.items.len) continue;

                const item = self.items.items[item_index];

                const is_selected = (i == self.selected_index);
                const prefix = if (is_selected) "> " else "  ";

                const item_text = std.fmt.bufPrintZ(
                    self.item_buffer,
                    "{s}{s}",
                    .{ prefix, item },
                ) catch "  [error]";

                // Use TTF rendering with appropriate color
                const color = if (is_selected) self.config.selected_color else self.config.foreground_color;
                try self.renderText(5, y_pos, item_text, color);

                y_pos += self.config.item_line_height;
            }

            // Show scroll indicator if needed
            if (filtered_len > self.config.max_visible_items) {
                const scroll_text = std.fmt.bufPrintZ(
                    self.scroll_buffer,
                    "[{d}-{d}]",
                    .{ self.scroll_offset + 1, visible_end },
                ) catch "[?]";

                try self.renderText(count_x, self.config.items_start_y, scroll_text, self.config.foreground_color);
            }
        } else {
            try self.renderCachedText(5, self.config.items_start_y, "No matches", self.config.foreground_color, &self.no_match_cache);
        }

        try self.renderer.present();
    }

    fn colorEquals(a: sdl.pixels.Color, b: sdl.pixels.Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    fn run(self: *App) !void {
        var running = true;

        // Initial render
        try self.render();
        self.needs_render = false;

        while (running) {
            // Wait for event with timeout to reduce CPU usage
            // Use a small timeout to keep UI responsive
            const has_event = sdl.events.waitTimeout(16);

            if (has_event) {
                while (sdl.events.poll()) |event| {
                    switch (event) {
                        .quit => running = false,
                        .terminating => running = false,
                        .key_down => |key_event| {
                            if (try self.handleKeyEvent(key_event)) {
                                running = false;
                            }
                        },
                        .text_input => |text_event| {
                            try self.handleTextInput(text_event.text);
                        },
                        else => {
                            // Ignore other events (mouse, etc.)
                        },
                    }
                }
            }

            // Only render if something changed
            if (self.needs_render) {
                try self.render();
                self.needs_render = false;
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App.init(allocator) catch |err| {
        if (err == error.NoItemsProvided) {
            std.debug.print("Error: No items provided on stdin\n", .{});
            std.debug.print("Usage: echo -e \"Item 1\\nItem 2\" | zmenu\n", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer app.deinit();

    try app.run();
}

// ============================================================================
// TESTS
// ============================================================================

test "fuzzyMatch - basic matching" {
    try std.testing.expect(App.fuzzyMatch("hello world", "hello"));
    try std.testing.expect(App.fuzzyMatch("hello world", "hlo"));
    try std.testing.expect(App.fuzzyMatch("hello world", "hw"));
    try std.testing.expect(App.fuzzyMatch("hello world", ""));
    try std.testing.expect(!App.fuzzyMatch("hello world", "xyz"));
    try std.testing.expect(!App.fuzzyMatch("hello world", "dlrow"));
}

test "fuzzyMatch - case insensitive" {
    try std.testing.expect(App.fuzzyMatch("Hello World", "hello"));
    try std.testing.expect(App.fuzzyMatch("HELLO WORLD", "hello"));
    try std.testing.expect(App.fuzzyMatch("HeLLo WoRLD", "hw"));
}

test "fuzzyMatch - UTF-8 safe" {
    // UTF-8 bytes are matched as-is (no case conversion for non-ASCII)
    try std.testing.expect(App.fuzzyMatch("café résumé", "café"));
    try std.testing.expect(App.fuzzyMatch("日本語テスト", "日本"));
    // ASCII parts still case-insensitive
    try std.testing.expect(App.fuzzyMatch("CAFÉ", "caf")); // Matches CAF
    // Mixed case in non-ASCII doesn't match differently-cased ASCII
    try std.testing.expect(!App.fuzzyMatch("café", "cafe")); // é != e
    try std.testing.expect(!App.fuzzyMatch("Düsseldorf", "dusseldorf")); // ü != u
}

test "findUtf8Boundary - no truncation needed" {
    const text = "hello";
    try std.testing.expectEqual(@as(usize, 5), App.findUtf8Boundary(text, 10));
    try std.testing.expectEqual(@as(usize, 5), App.findUtf8Boundary(text, 5));
}

test "findUtf8Boundary - ASCII truncation" {
    const text = "hello world";
    try std.testing.expectEqual(@as(usize, 5), App.findUtf8Boundary(text, 5));
}

test "findUtf8Boundary - UTF-8 truncation" {
    // "café" = c(1) a(1) f(1) é(2 bytes: 0xC3 0xA9) = 5 bytes total
    const text = "café";
    try std.testing.expectEqual(@as(usize, 5), App.findUtf8Boundary(text, 10)); // No truncation
    try std.testing.expectEqual(@as(usize, 5), App.findUtf8Boundary(text, 5)); // Exactly at boundary
    try std.testing.expectEqual(@as(usize, 3), App.findUtf8Boundary(text, 4)); // Would split é, backs up to 3
    try std.testing.expectEqual(@as(usize, 3), App.findUtf8Boundary(text, 3)); // At 'f'
}

test "findUtf8Boundary - multi-byte characters" {
    // "日本語" = 3 chars, each 3 bytes = 9 bytes total
    const text = "日本語";
    try std.testing.expectEqual(@as(usize, 9), App.findUtf8Boundary(text, 10));
    try std.testing.expectEqual(@as(usize, 9), App.findUtf8Boundary(text, 9));
    try std.testing.expectEqual(@as(usize, 6), App.findUtf8Boundary(text, 8)); // Would split 3rd char
    try std.testing.expectEqual(@as(usize, 6), App.findUtf8Boundary(text, 7)); // Would split 3rd char
    try std.testing.expectEqual(@as(usize, 6), App.findUtf8Boundary(text, 6)); // At boundary
    try std.testing.expectEqual(@as(usize, 3), App.findUtf8Boundary(text, 5)); // Would split 2nd char
}

test "colorEquals - same colors" {
    const color1 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 64, .a = 255 };
    const color2 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 64, .a = 255 };
    try std.testing.expect(App.colorEquals(color1, color2));
}

test "colorEquals - different colors" {
    const color1 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 64, .a = 255 };
    const color2 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 65, .a = 255 };
    try std.testing.expect(!App.colorEquals(color1, color2));
}

test "Config - buffer sizes aligned with limits" {
    const config = Config{};
    // Prompt buffer must accommodate max_input_length + prefix + null
    try std.testing.expect(config.prompt_buffer_size >= config.max_input_length + 10);
    // Item buffer must accommodate max_item_length + prefix + null
    try std.testing.expect(config.item_buffer_size >= config.max_item_length + 10);
    // Ellipsis margin should be reasonable
    try std.testing.expect(config.input_ellipsis_margin < config.max_input_length);
}

test "deleteLastCodepoint - ASCII" {
    const allocator = std.testing.allocator;
    var app = App{
        .window = undefined,
        .renderer = undefined,
        .config = Config{},
        .input_buffer = std.ArrayList(u8).empty,
        .items = std.ArrayList([]const u8).empty,
        .filtered_items = std.ArrayList(usize).empty,
        .selected_index = 0,
        .scroll_offset = 0,
        .allocator = allocator,
        .needs_render = false,
        .prompt_buffer = undefined,
        .item_buffer = undefined,
        .count_buffer = undefined,
        .scroll_buffer = undefined,
        .font = undefined,
        .loaded_font_path = undefined,
        .prompt_cache = undefined,
        .count_cache = undefined,
        .no_match_cache = undefined,
    };

    try app.input_buffer.appendSlice(allocator, "hello");
    app.deleteLastCodepoint();
    try std.testing.expectEqualStrings("hell", app.input_buffer.items);

    app.input_buffer.deinit(allocator);
}

test "deleteLastCodepoint - UTF-8 multi-byte" {
    const allocator = std.testing.allocator;
    var app = App{
        .window = undefined,
        .renderer = undefined,
        .config = Config{},
        .input_buffer = std.ArrayList(u8).empty,
        .items = std.ArrayList([]const u8).empty,
        .filtered_items = std.ArrayList(usize).empty,
        .selected_index = 0,
        .scroll_offset = 0,
        .allocator = allocator,
        .needs_render = false,
        .prompt_buffer = undefined,
        .item_buffer = undefined,
        .count_buffer = undefined,
        .scroll_buffer = undefined,
        .font = undefined,
        .loaded_font_path = undefined,
        .prompt_cache = undefined,
        .count_cache = undefined,
        .no_match_cache = undefined,
    };

    // "café" = c a f é(2 bytes)
    try app.input_buffer.appendSlice(allocator, "café");
    try std.testing.expectEqual(@as(usize, 5), app.input_buffer.items.len);

    app.deleteLastCodepoint(); // Remove é (2 bytes)
    try std.testing.expectEqualStrings("caf", app.input_buffer.items);
    try std.testing.expectEqual(@as(usize, 3), app.input_buffer.items.len);

    app.input_buffer.deinit(allocator);
}

test "deleteLastCodepoint - UTF-8 three-byte character" {
    const allocator = std.testing.allocator;
    var app = App{
        .window = undefined,
        .renderer = undefined,
        .config = Config{},
        .input_buffer = std.ArrayList(u8).empty,
        .items = std.ArrayList([]const u8).empty,
        .filtered_items = std.ArrayList(usize).empty,
        .selected_index = 0,
        .scroll_offset = 0,
        .allocator = allocator,
        .needs_render = false,
        .prompt_buffer = undefined,
        .item_buffer = undefined,
        .count_buffer = undefined,
        .scroll_buffer = undefined,
        .font = undefined,
        .loaded_font_path = undefined,
        .prompt_cache = undefined,
        .count_cache = undefined,
        .no_match_cache = undefined,
    };

    // "日" = 3 bytes
    try app.input_buffer.appendSlice(allocator, "a日");
    try std.testing.expectEqual(@as(usize, 4), app.input_buffer.items.len);

    app.deleteLastCodepoint(); // Remove 日 (3 bytes)
    try std.testing.expectEqualStrings("a", app.input_buffer.items);
    try std.testing.expectEqual(@as(usize, 1), app.input_buffer.items.len);

    app.input_buffer.deinit(allocator);
}

test "deleteLastCodepoint - empty buffer" {
    const allocator = std.testing.allocator;
    var app = App{
        .window = undefined,
        .renderer = undefined,
        .config = Config{},
        .input_buffer = std.ArrayList(u8).empty,
        .items = std.ArrayList([]const u8).empty,
        .filtered_items = std.ArrayList(usize).empty,
        .selected_index = 0,
        .scroll_offset = 0,
        .allocator = allocator,
        .needs_render = false,
        .prompt_buffer = undefined,
        .item_buffer = undefined,
        .count_buffer = undefined,
        .scroll_buffer = undefined,
        .font = undefined,
        .loaded_font_path = undefined,
        .prompt_cache = undefined,
        .count_cache = undefined,
        .no_match_cache = undefined,
    };

    app.deleteLastCodepoint(); // Should not crash
    try std.testing.expectEqual(@as(usize, 0), app.input_buffer.items.len);

    app.input_buffer.deinit(allocator);
}
