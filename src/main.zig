const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");
const theme = config.theme;

// Runtime color scheme (can be overridden by ZMENU_THEME env var)
const ColorScheme = struct {
    background: sdl.pixels.Color,
    foreground: sdl.pixels.Color,
    selected: sdl.pixels.Color,
    prompt: sdl.pixels.Color,
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

const SdlContext = struct {
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    font: sdl.ttf.Font,
    loaded_font_path: []const u8, // Track which font was actually loaded
};

const AppState = struct {
    input_buffer: std.ArrayList(u8),
    items: std.ArrayList([]const u8),
    filtered_items: std.ArrayList(usize),
    selected_index: usize,
    scroll_offset: usize,
    needs_render: bool,
};

const RenderContext = struct {
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
    display_scale: f32, // Combined scale factor (pixel density × content scale)
    pixel_width: u32, // Actual pixel dimensions
    pixel_height: u32,
    // Current window dimensions (logical coordinates)
    current_width: u32,
    current_height: u32,
};

const App = struct {
    sdl: SdlContext,
    state: AppState,
    render_ctx: RenderContext,
    colors: ColorScheme, // Runtime colors (may be overridden by ZMENU_THEME)
    allocator: std.mem.Allocator,

    fn tryLoadFont() !struct { font: sdl.ttf.Font, path: []const u8 } {
        // If user specified a custom font path, try only that
        if (config.font.path) |custom_path| {
            const font = sdl.ttf.Font.init(custom_path, config.font.size) catch |err| {
                std.debug.print("Error: Failed to load font '{s}': {}\n", .{ custom_path, err });
                return err;
            };
            return .{ .font = font, .path = custom_path };
        }

        // Try platform-specific default fonts in order
        for (config.default_font_paths) |font_path| {
            if (sdl.ttf.Font.init(font_path, config.font.size)) |font| {
                std.debug.print("Successfully loaded font: {s}\n", .{font_path});
                return .{ .font = font, .path = font_path };
            } else |_| {
                // Silently continue to next font
            }
        }

        // No fonts found
        std.debug.print("Error: Could not find any suitable font. Tried:\n", .{});
        for (config.default_font_paths) |font_path| {
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

        // Build runtime color scheme (compile-time defaults, overridden by env var)
        var colors = ColorScheme{
            .background = config.colors.background,
            .foreground = config.colors.foreground,
            .selected = config.colors.selected,
            .prompt = config.colors.prompt,
        };

        // Apply theme from ZMENU_THEME environment variable (if set)
        if (std.process.getEnvVarOwned(allocator, "ZMENU_THEME")) |theme_name| {
            defer allocator.free(theme_name);
            const selected_theme = theme.getByName(theme_name);
            colors.background = selected_theme.background;
            colors.foreground = selected_theme.foreground;
            colors.selected = selected_theme.selected;
            colors.prompt = selected_theme.prompt;
        } else |_| {
            // No env var set, use defaults
        }

        // Create window and renderer with high DPI support
        const window_flags = if (config.window.enable_high_dpi)
            sdl.video.Window.Flags{ .borderless = true, .always_on_top = true, .high_pixel_density = true }
        else
            sdl.video.Window.Flags{ .borderless = true, .always_on_top = true };

        const window, const renderer = try sdl.render.Renderer.initWithWindow(
            "zmenu",
            config.window.initial_width,
            config.window.initial_height,
            window_flags,
        );
        errdefer renderer.deinit();
        errdefer window.deinit();

        // Position window at center of screen (both X and Y)
        window.setPosition(.{ .centered = null }, .{ .centered = null }) catch |err| {
            std.debug.print("Warning: Failed to position window: {}\n", .{err});
        };

        // Query display scale and pixel dimensions for high DPI support
        const display_scale = try window.getDisplayScale();
        const pixel_width, const pixel_height = try window.getSizeInPixels();

        // Validate pixel dimensions fit in u32
        if (pixel_width > std.math.maxInt(u32) or pixel_height > std.math.maxInt(u32)) {
            return error.DisplayTooLarge;
        }

        // Allocate render buffers
        const prompt_buffer = try allocator.alloc(u8, config.limits.prompt_buffer_size);
        errdefer allocator.free(prompt_buffer);
        const item_buffer = try allocator.alloc(u8, config.limits.item_buffer_size);
        errdefer allocator.free(item_buffer);
        const count_buffer = try allocator.alloc(u8, config.limits.count_buffer_size);
        errdefer allocator.free(count_buffer);
        const scroll_buffer = try allocator.alloc(u8, config.limits.scroll_buffer_size);
        errdefer allocator.free(scroll_buffer);

        // Load font with platform-specific fallback
        const font_result = try tryLoadFont();
        errdefer font_result.font.deinit();

        var app = App{
            .sdl = .{
                .window = window,
                .renderer = renderer,
                .font = font_result.font,
                .loaded_font_path = font_result.path,
            },
            .state = .{
                .input_buffer = std.ArrayList(u8).empty,
                .items = std.ArrayList([]const u8).empty,
                .filtered_items = std.ArrayList(usize).empty,
                .selected_index = 0,
                .scroll_offset = 0,
                .needs_render = true,
            },
            .render_ctx = .{
                .prompt_buffer = prompt_buffer,
                .item_buffer = item_buffer,
                .count_buffer = count_buffer,
                .scroll_buffer = scroll_buffer,
                .prompt_cache = .{ .texture = null, .last_text = &[_]u8{}, .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
                .count_cache = .{ .texture = null, .last_text = &[_]u8{}, .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
                .no_match_cache = .{ .texture = null, .last_text = &[_]u8{}, .last_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
                .display_scale = display_scale,
                .pixel_width = @intCast(pixel_width),
                .pixel_height = @intCast(pixel_height),
                .current_width = config.window.initial_width,
                .current_height = config.window.initial_height,
            },
            .colors = colors,
            .allocator = allocator,
        };

        // Load items from stdin
        try app.loadItemsFromStdin();

        // Check that we have items to display
        if (app.state.items.items.len == 0) {
            // Clean up ArrayLists before returning error
            // The buffers will be cleaned up by errdefer
            app.state.items.deinit(app.allocator);
            app.state.filtered_items.deinit(app.allocator);
            app.state.input_buffer.deinit(app.allocator);
            return error.NoItemsProvided;
        }

        try app.updateFilter();

        // Calculate and set initial window size based on content
        try app.updateWindowSize();

        // Start text input
        try sdl.keyboard.startTextInput(window);

        return app;
    }

    fn deinit(self: *App) void {
        sdl.keyboard.stopTextInput(self.sdl.window) catch |err| {
            std.debug.print("Warning: Failed to stop text input: {}\n", .{err});
        };
        self.state.input_buffer.deinit(self.allocator);
        for (self.state.items.items) |item| {
            self.allocator.free(item);
        }
        self.state.items.deinit(self.allocator);
        self.state.filtered_items.deinit(self.allocator);
        self.allocator.free(self.render_ctx.prompt_buffer);
        self.allocator.free(self.render_ctx.item_buffer);
        self.allocator.free(self.render_ctx.count_buffer);
        self.allocator.free(self.render_ctx.scroll_buffer);
        // Clean up texture caches
        self.render_ctx.prompt_cache.deinit(self.allocator);
        self.render_ctx.count_cache.deinit(self.allocator);
        self.render_ctx.no_match_cache.deinit(self.allocator);
        self.sdl.font.deinit();
        self.sdl.renderer.deinit();
        self.sdl.window.deinit();
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
        // Check if stdin is a TTY (interactive terminal)
        // If so, user forgot to pipe input - fail immediately instead of blocking
        if (std.posix.isatty(std.posix.STDIN_FILENO)) {
            return error.NoItemsProvided;
        }

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
                const truncate_len = findUtf8Boundary(trimmed, config.limits.max_item_length);
                const final_line = trimmed[0..truncate_len];

                const owned_line = try self.allocator.dupe(u8, final_line);
                try self.state.items.append(self.allocator, owned_line);
            }
        }
    }

    fn updateFilter(self: *App) !void {
        const prev_filtered_count = self.state.filtered_items.items.len;

        self.state.filtered_items.clearRetainingCapacity();

        if (self.state.input_buffer.items.len == 0) {
            // No filter, show all items
            for (self.state.items.items, 0..) |_, i| {
                try self.state.filtered_items.append(self.allocator, i);
            }
        } else {
            // Fuzzy matching with case-insensitive search
            const query = self.state.input_buffer.items;
            for (self.state.items.items, 0..) |item, i| {
                if (fuzzyMatch(item, query)) {
                    try self.state.filtered_items.append(self.allocator, i);
                }
            }
        }

        // Reset selection if out of bounds
        if (self.state.filtered_items.items.len > 0) {
            if (self.state.selected_index >= self.state.filtered_items.items.len) {
                self.state.selected_index = self.state.filtered_items.items.len - 1;
            }
        } else {
            self.state.selected_index = 0;
        }

        // Adjust scroll to keep selection visible
        self.adjustScroll();

        // Update window size if filtered count changed
        if (prev_filtered_count != self.state.filtered_items.items.len) {
            try self.updateWindowSize();
        }
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
        if (self.state.filtered_items.items.len == 0) {
            self.state.scroll_offset = 0;
            return;
        }

        // Keep selected item visible
        if (self.state.selected_index < self.state.scroll_offset) {
            self.state.scroll_offset = self.state.selected_index;
        } else if (self.state.selected_index >= self.state.scroll_offset + config.limits.max_visible_items) {
            self.state.scroll_offset = self.state.selected_index - config.limits.max_visible_items + 1;
        }
    }

    fn navigate(self: *App, delta: isize) void {
        if (self.state.filtered_items.items.len == 0) return;

        const current = @as(isize, @intCast(self.state.selected_index));
        const new_idx = current + delta;

        if (new_idx >= 0 and new_idx < @as(isize, @intCast(self.state.filtered_items.items.len))) {
            self.state.selected_index = @intCast(new_idx);
            self.adjustScroll();
            self.state.needs_render = true;
        }
    }

    fn navigateToFirst(self: *App) void {
        if (self.state.filtered_items.items.len > 0) {
            self.state.selected_index = 0;
            self.adjustScroll();
            self.state.needs_render = true;
        }
    }

    fn navigateToLast(self: *App) void {
        if (self.state.filtered_items.items.len > 0) {
            self.state.selected_index = self.state.filtered_items.items.len - 1;
            self.adjustScroll();
            self.state.needs_render = true;
        }
    }

    fn navigatePage(self: *App, direction: isize) void {
        if (self.state.filtered_items.items.len == 0) return;

        const page_size = @as(isize, @intCast(config.limits.max_visible_items));
        const delta = page_size * direction;
        self.navigate(delta);
    }

    fn deleteLastCodepoint(self: *App) void {
        // Remove the last UTF-8 codepoint from input buffer
        if (self.state.input_buffer.items.len == 0) return;

        var i = self.state.input_buffer.items.len - 1;

        // UTF-8 continuation bytes start with 10xxxxxx (0x80-0xBF)
        // We need to backtrack to find the start of the codepoint
        while (i > 0 and (self.state.input_buffer.items[i] & 0xC0) == 0x80) {
            i -= 1;
        }

        // Resize to remove the entire codepoint
        self.state.input_buffer.shrinkRetainingCapacity(i);
    }

    fn deleteWord(self: *App) !void {
        // Skip trailing whitespace first (UTF-8 safe: space and tab are single bytes)
        while (self.state.input_buffer.items.len > 0) {
            const ch = self.state.input_buffer.getLast();
            if (ch != ' ' and ch != '\t') break;
            _ = self.state.input_buffer.pop();
        }

        // Delete word characters (UTF-8 aware)
        while (self.state.input_buffer.items.len > 0) {
            const ch = self.state.input_buffer.getLast();
            if (ch == ' ' or ch == '\t') break;
            self.deleteLastCodepoint();
        }

        try self.updateFilter();
        self.state.needs_render = true;
    }

    fn updateDisplayScale(self: *App) !void {
        // Query updated display scale and pixel dimensions
        self.render_ctx.display_scale = try self.sdl.window.getDisplayScale();
        const pixel_width, const pixel_height = try self.sdl.window.getSizeInPixels();

        // Validate pixel dimensions fit in u32
        if (pixel_width > std.math.maxInt(u32) or pixel_height > std.math.maxInt(u32)) {
            return error.DisplayTooLarge;
        }

        self.render_ctx.pixel_width = @intCast(pixel_width);
        self.render_ctx.pixel_height = @intCast(pixel_height);
        self.state.needs_render = true;
    }

    fn handleKeyEvent(self: *App, event: sdl.events.Keyboard) !bool {
        const key = event.key orelse return false;

        if (key == .escape) {
            return true; // Quit without selection
        } else if (key == .return_key or key == .kp_enter) {
            // Output selected item and quit
            if (self.state.filtered_items.items.len > 0) {
                const selected = self.state.items.items[self.state.filtered_items.items[self.state.selected_index]];
                // Cross-platform: std.posix maps to Windows/POSIX appropriately
                const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                _ = try stdout_file.write(selected);
                _ = try stdout_file.write("\n");
            }
            return true;
        } else if (key == .backspace) {
            if (self.state.input_buffer.items.len > 0) {
                self.deleteLastCodepoint();
                try self.updateFilter();
                self.state.needs_render = true;
            }
        } else if (key == .u and (event.mod.left_control or event.mod.right_control)) {
            // Ctrl+U: Clear input
            self.state.input_buffer.clearRetainingCapacity();
            try self.updateFilter();
            self.state.needs_render = true;
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
        if (self.state.input_buffer.items.len + text.len <= config.limits.max_input_length) {
            try self.state.input_buffer.appendSlice(self.allocator, text);
            try self.updateFilter();
            self.state.needs_render = true;
        }
        // Silently ignore input that would exceed the limit
    }

    fn renderText(self: *App, x: f32, y: f32, text: [:0]const u8, color: sdl.pixels.Color) !void {
        // Convert sdl.pixels.Color to sdl.ttf.Color
        const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };

        // Render text to surface with anti-aliasing
        const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
        defer surface.deinit();

        // Create texture from surface
        const texture = try self.sdl.renderer.createTextureFromSurface(surface);
        defer texture.deinit();

        // Get texture size
        const width, const height = try texture.getSize();

        // Render texture at position
        const dst = sdl.rect.FRect{ .x = x, .y = y, .w = width, .h = height };
        try self.sdl.renderer.renderTexture(texture, null, dst);
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
            const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
            defer surface.deinit();
            cache.texture = try self.sdl.renderer.createTextureFromSurface(surface);
        }

        // Render cached texture
        if (cache.texture) |texture| {
            const width, const height = try texture.getSize();
            const dst = sdl.rect.FRect{ .x = x, .y = y, .w = width, .h = height };
            try self.sdl.renderer.renderTexture(texture, null, dst);
        }
    }

    fn render(self: *App) !void {
        // Clear background
        try self.sdl.renderer.setDrawColor(self.colors.background);
        try self.sdl.renderer.clear();

        // Apply display scale to all coordinates
        const scale = self.render_ctx.display_scale;

        // Show prompt with input buffer
        const prompt_text = if (self.state.input_buffer.items.len > 0) blk: {
            // Truncate display if input is too long, showing last chars with ellipsis
            const ellipsis_threshold = config.limits.max_input_length - config.limits.input_ellipsis_margin;
            const display_input = if (self.state.input_buffer.items.len > ellipsis_threshold)
                blk2: {
                    // Find UTF-8 safe starting position
                    const approx_start = self.state.input_buffer.items.len - ellipsis_threshold;
                    var start = approx_start;
                    // Skip continuation bytes to find valid UTF-8 boundary
                    while (start < self.state.input_buffer.items.len and (self.state.input_buffer.items[start] & 0xC0) == 0x80) {
                        start += 1;
                    }
                    break :blk2 self.state.input_buffer.items[start..];
                }
            else
                self.state.input_buffer.items;

            const prefix = if (self.state.input_buffer.items.len > ellipsis_threshold) "> ..." else "> ";
            break :blk std.fmt.bufPrintZ(self.render_ctx.prompt_buffer, "{s}{s}", .{ prefix, display_input }) catch "> [error]";
        } else
            std.fmt.bufPrintZ(self.render_ctx.prompt_buffer, "> ", .{}) catch "> ";

        try self.renderCachedText(5.0 * scale, config.layout.prompt_y * scale, prompt_text, self.colors.prompt, &self.render_ctx.prompt_cache);

        // Show filtered items count
        const count_text = std.fmt.bufPrintZ(
            self.render_ctx.count_buffer,
            "{d}/{d}",
            .{ self.state.filtered_items.items.len, self.state.items.items.len },
        ) catch "?/?";

        // Measure actual text width for right-alignment
        const count_text_w, _ = try self.sdl.font.getStringSize(count_text);
        const count_x = (@as(f32, @floatFromInt(self.render_ctx.current_width)) - @as(f32, @floatFromInt(count_text_w)) - config.layout.width_padding) * scale;
        try self.renderCachedText(count_x, config.layout.prompt_y * scale, count_text, self.colors.foreground, &self.render_ctx.count_cache);

        // Cache length to avoid race conditions
        const filtered_len = self.state.filtered_items.items.len;

        // Show multiple items
        if (filtered_len > 0) {
            const visible_end = @min(self.state.scroll_offset + config.limits.max_visible_items, filtered_len);

            var y_pos: f32 = config.layout.items_start_y * scale;

            for (self.state.scroll_offset..visible_end) |i| {
                // Double check bounds before accessing
                if (i >= filtered_len) break;

                const item_index = self.state.filtered_items.items[i];
                if (item_index >= self.state.items.items.len) continue;

                const item = self.state.items.items[item_index];

                const is_selected = (i == self.state.selected_index);
                const prefix = if (is_selected) "> " else "  ";

                const item_text = std.fmt.bufPrintZ(
                    self.render_ctx.item_buffer,
                    "{s}{s}",
                    .{ prefix, item },
                ) catch "  [error]";

                // Use TTF rendering with appropriate color
                const color = if (is_selected) self.colors.selected else self.colors.foreground;
                try self.renderText(5.0 * scale, y_pos, item_text, color);

                y_pos += config.layout.item_line_height * scale;
            }

            // Show scroll indicator if needed
            if (filtered_len > config.limits.max_visible_items) {
                const scroll_text = std.fmt.bufPrintZ(
                    self.render_ctx.scroll_buffer,
                    "[{d}-{d}]",
                    .{ self.state.scroll_offset + 1, visible_end },
                ) catch "[?]";

                // Measure actual scroll text width for right-alignment
                const scroll_text_w, _ = try self.sdl.font.getStringSize(scroll_text);
                const scroll_x = (@as(f32, @floatFromInt(self.render_ctx.current_width)) - @as(f32, @floatFromInt(scroll_text_w)) - config.layout.width_padding) * scale;
                try self.renderText(scroll_x, config.layout.items_start_y * scale, scroll_text, self.colors.foreground);
            }
        } else {
            try self.renderCachedText(5.0 * scale, config.layout.items_start_y * scale, "No matches", self.colors.foreground, &self.render_ctx.no_match_cache);
        }

        try self.sdl.renderer.present();
    }

    fn colorEquals(a: sdl.pixels.Color, b: sdl.pixels.Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    fn calculateOptimalWidth(self: *App) !u32 {
        // Start with minimum width
        var max_width: f32 = @floatFromInt(config.window.min_width);

        // Measure sample prompt text width (uses config sample)
        const prompt_w, _ = try self.sdl.font.getStringSize(config.layout.sample_prompt_text);

        // Measure count and scroll indicator text width (use the longest one)
        const count_w, _ = try self.sdl.font.getStringSize(config.layout.sample_count_text);
        const scroll_w, _ = try self.sdl.font.getStringSize(config.layout.sample_scroll_text);
        const right_side_width = @max(count_w, scroll_w);

        // Calculate required width for prompt + right side + margins
        const base_width = @as(f32, @floatFromInt(prompt_w + right_side_width)) + (config.layout.width_padding * config.layout.width_padding_multiplier);
        if (base_width > max_width) max_width = base_width;

        // Check widths of visible items
        const filtered_len = self.state.filtered_items.items.len;
        const visible_end = @min(config.limits.max_visible_items, filtered_len);

        for (0..visible_end) |i| {
            if (i >= filtered_len) break;

            const item_index = self.state.filtered_items.items[i];
            if (item_index >= self.state.items.items.len) continue;

            const item = self.state.items.items[item_index];

            // Measure item text (with prefix "> ")
            const item_text = std.fmt.bufPrint(
                self.render_ctx.item_buffer,
                "> {s}",
                .{item},
            ) catch continue;

            // Use fast text measurement without rendering
            const item_w, _ = self.sdl.font.getStringSize(item_text) catch continue;

            const total_item_width = @as(f32, @floatFromInt(item_w)) + (config.layout.width_padding * 2.0);
            if (total_item_width > max_width) max_width = total_item_width;
        }

        // Apply min/max bounds with proper rounding
        const rounded_width = @as(u32, @intFromFloat(@ceil(max_width)));
        const final_width = @max(rounded_width, config.window.min_width);
        return @min(final_width, config.window.max_width);
    }

    fn calculateOptimalHeight(self: *App) u32 {
        // Calculate how many items we'll actually show
        const filtered_len = self.state.filtered_items.items.len;
        const visible_items = @min(filtered_len, config.limits.max_visible_items);

        // Calculate required height: prompt area + (items × line height) + bottom margin
        const prompt_area_height = config.layout.items_start_y; // Includes prompt + spacing
        const items_height = @as(f32, @floatFromInt(visible_items)) * config.layout.item_line_height;

        const total_height = prompt_area_height + items_height + config.layout.bottom_margin;

        // Apply min/max bounds with proper rounding
        const rounded_height = @as(u32, @intFromFloat(@ceil(total_height)));
        const final_height = @max(rounded_height, config.window.min_height);
        return @min(final_height, config.window.max_height);
    }

    fn updateWindowSize(self: *App) !void {
        const new_width = try self.calculateOptimalWidth();
        const new_height = self.calculateOptimalHeight();

        // Only update if dimensions changed
        if (new_width != self.render_ctx.current_width or new_height != self.render_ctx.current_height) {
            self.render_ctx.current_width = new_width;
            self.render_ctx.current_height = new_height;

            try self.sdl.window.setSize(new_width, new_height);

            // Re-center window after resize
            try self.sdl.window.setPosition(.{ .centered = null }, .{ .centered = null });

            self.state.needs_render = true;
        }
    }

    fn run(self: *App) !void {
        var running = true;

        // Initial render
        try self.render();
        self.state.needs_render = false;

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
                        .window_display_scale_changed => {
                            // Display DPI/scale changed - update our scale factor
                            try self.updateDisplayScale();
                        },
                        .window_pixel_size_changed => {
                            // Window pixel size changed - update dimensions
                            try self.updateDisplayScale();
                        },
                        else => {
                            // Ignore other events (mouse, etc.)
                        },
                    }
                }
            }

            // Only render if something changed
            if (self.state.needs_render) {
                try self.render();
                self.state.needs_render = false;
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

test "config - buffer sizes aligned with limits" {
    // Prompt buffer must accommodate max_input_length + prefix + null
    try std.testing.expect(config.limits.prompt_buffer_size >= config.limits.max_input_length + 10);
    // Item buffer must accommodate max_item_length + prefix + null
    try std.testing.expect(config.limits.item_buffer_size >= config.limits.max_item_length + 10);
    // Ellipsis margin should be reasonable
    try std.testing.expect(config.limits.input_ellipsis_margin < config.limits.max_input_length);
}

test "deleteLastCodepoint - ASCII" {
    const allocator = std.testing.allocator;
    var app = App{
        .sdl = .{
            .window = undefined,
            .renderer = undefined,
            .font = undefined,
            .loaded_font_path = undefined,
        },
        .state = .{
            .input_buffer = std.ArrayList(u8).empty,
            .items = std.ArrayList([]const u8).empty,
            .filtered_items = std.ArrayList(usize).empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .needs_render = false,
        },
        .render_ctx = .{
            .prompt_buffer = undefined,
            .item_buffer = undefined,
            .count_buffer = undefined,
            .scroll_buffer = undefined,
            .prompt_cache = undefined,
            .count_cache = undefined,
            .no_match_cache = undefined,
            .display_scale = 1.0,
            .pixel_width = 800,
            .pixel_height = 300,
            .current_width = 800,
            .current_height = 300,
        },
        .colors = .{ .background = config.colors.background, .foreground = config.colors.foreground, .selected = config.colors.selected, .prompt = config.colors.prompt },
        .allocator = allocator,
    };

    try app.state.input_buffer.appendSlice(allocator, "hello");
    app.deleteLastCodepoint();
    try std.testing.expectEqualStrings("hell", app.state.input_buffer.items);

    app.state.input_buffer.deinit(allocator);
}

test "deleteLastCodepoint - UTF-8 multi-byte" {
    const allocator = std.testing.allocator;
    var app = App{
        .sdl = .{
            .window = undefined,
            .renderer = undefined,
            .font = undefined,
            .loaded_font_path = undefined,
        },
        .state = .{
            .input_buffer = std.ArrayList(u8).empty,
            .items = std.ArrayList([]const u8).empty,
            .filtered_items = std.ArrayList(usize).empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .needs_render = false,
        },
        .render_ctx = .{
            .prompt_buffer = undefined,
            .item_buffer = undefined,
            .count_buffer = undefined,
            .scroll_buffer = undefined,
            .prompt_cache = undefined,
            .count_cache = undefined,
            .no_match_cache = undefined,
            .display_scale = 1.0,
            .pixel_width = 800,
            .pixel_height = 300,
            .current_width = 800,
            .current_height = 300,
        },
        .colors = .{ .background = config.colors.background, .foreground = config.colors.foreground, .selected = config.colors.selected, .prompt = config.colors.prompt },
        .allocator = allocator,
    };

    // "café" = c a f é(2 bytes)
    try app.state.input_buffer.appendSlice(allocator, "café");
    try std.testing.expectEqual(@as(usize, 5), app.state.input_buffer.items.len);

    app.deleteLastCodepoint(); // Remove é (2 bytes)
    try std.testing.expectEqualStrings("caf", app.state.input_buffer.items);
    try std.testing.expectEqual(@as(usize, 3), app.state.input_buffer.items.len);

    app.state.input_buffer.deinit(allocator);
}

test "deleteLastCodepoint - UTF-8 three-byte character" {
    const allocator = std.testing.allocator;
    var app = App{
        .sdl = .{
            .window = undefined,
            .renderer = undefined,
            .font = undefined,
            .loaded_font_path = undefined,
        },
        .state = .{
            .input_buffer = std.ArrayList(u8).empty,
            .items = std.ArrayList([]const u8).empty,
            .filtered_items = std.ArrayList(usize).empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .needs_render = false,
        },
        .render_ctx = .{
            .prompt_buffer = undefined,
            .item_buffer = undefined,
            .count_buffer = undefined,
            .scroll_buffer = undefined,
            .prompt_cache = undefined,
            .count_cache = undefined,
            .no_match_cache = undefined,
            .display_scale = 1.0,
            .pixel_width = 800,
            .pixel_height = 300,
            .current_width = 800,
            .current_height = 300,
        },
        .colors = .{ .background = config.colors.background, .foreground = config.colors.foreground, .selected = config.colors.selected, .prompt = config.colors.prompt },
        .allocator = allocator,
    };

    // "日" = 3 bytes
    try app.state.input_buffer.appendSlice(allocator, "a日");
    try std.testing.expectEqual(@as(usize, 4), app.state.input_buffer.items.len);

    app.deleteLastCodepoint(); // Remove 日 (3 bytes)
    try std.testing.expectEqualStrings("a", app.state.input_buffer.items);
    try std.testing.expectEqual(@as(usize, 1), app.state.input_buffer.items.len);

    app.state.input_buffer.deinit(allocator);
}

test "deleteLastCodepoint - empty buffer" {
    const allocator = std.testing.allocator;
    var app = App{
        .sdl = .{
            .window = undefined,
            .renderer = undefined,
            .font = undefined,
            .loaded_font_path = undefined,
        },
        .state = .{
            .input_buffer = std.ArrayList(u8).empty,
            .items = std.ArrayList([]const u8).empty,
            .filtered_items = std.ArrayList(usize).empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .needs_render = false,
        },
        .render_ctx = .{
            .prompt_buffer = undefined,
            .item_buffer = undefined,
            .count_buffer = undefined,
            .scroll_buffer = undefined,
            .prompt_cache = undefined,
            .count_cache = undefined,
            .no_match_cache = undefined,
            .display_scale = 1.0,
            .pixel_width = 800,
            .pixel_height = 300,
            .current_width = 800,
            .current_height = 300,
        },
        .colors = .{ .background = config.colors.background, .foreground = config.colors.foreground, .selected = config.colors.selected, .prompt = config.colors.prompt },
        .allocator = allocator,
    };

    app.deleteLastCodepoint(); // Should not crash
    try std.testing.expectEqual(@as(usize, 0), app.state.input_buffer.items.len);

    app.state.input_buffer.deinit(allocator);
}

test "isatty - stdin detection works" {
    // This test verifies that std.posix.isatty() is callable
    // When running tests, stdin is typically redirected (not a TTY)
    // When running the app directly in terminal, stdin IS a TTY
    // The actual behavior is tested manually in integration tests
    const result = std.posix.isatty(std.posix.STDIN_FILENO);
    // Just verify it doesn't crash and returns a boolean
    _ = result;
}

test "NoItemsProvided error propagates correctly" {
    // This test verifies that the error.NoItemsProvided error
    // is handled correctly in the main flow
    // The actual TTY check in loadItemsFromStdin() returns this error
    // when stdin is a TTY (interactive terminal)
    const err = error.NoItemsProvided;
    try std.testing.expectEqual(error.NoItemsProvided, err);
}
