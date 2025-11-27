//! zmenu application core
//!
//! Contains the main App struct and all application logic.

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");
const theme = config.theme;

const sdl_context = @import("sdl_context.zig");
const types = @import("types.zig");
const input = @import("input.zig");

pub const SdlContext = sdl_context.SdlContext;
pub const ColorScheme = types.ColorScheme;
pub const TextureCache = types.TextureCache;
pub const AppState = types.AppState;
pub const RenderContext = types.RenderContext;

pub const App = struct {
    sdl: SdlContext,
    state: AppState,
    render_ctx: RenderContext,
    colors: ColorScheme,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !App {
        // Initialize SDL
        try sdl_context.initSdl();
        errdefer sdl_context.quitSdl();

        // Build runtime color scheme (compile-time defaults, overridden by env var)
        var colors = ColorScheme.fromConfig();

        // Apply theme from ZMENU_THEME environment variable (if set)
        if (std.process.getEnvVarOwned(allocator, "ZMENU_THEME")) |theme_name| {
            defer allocator.free(theme_name);
            const selected_theme = theme.getByName(theme_name);
            colors.background = selected_theme.background;
            colors.foreground = selected_theme.foreground;
            colors.selected = selected_theme.selected;
            colors.prompt = selected_theme.prompt;
        } else |_| {}

        // Create window and renderer
        const win_result = try sdl_context.createWindow();
        const window = win_result.window;
        const renderer = win_result.renderer;
        errdefer renderer.deinit();
        errdefer window.deinit();

        // Query display scale and pixel dimensions for high DPI support
        const display_scale = try window.getDisplayScale();
        const pixel_width, const pixel_height = try window.getSizeInPixels();

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
        const font_result = try sdl_context.loadFont();
        errdefer font_result.font.deinit();

        var app = App{
            .sdl = .{
                .window = window,
                .renderer = renderer,
                .font = font_result.font,
                .loaded_font_path = font_result.path,
            },
            .state = AppState.empty,
            .render_ctx = .{
                .prompt_buffer = prompt_buffer,
                .item_buffer = item_buffer,
                .count_buffer = count_buffer,
                .scroll_buffer = scroll_buffer,
                .prompt_cache = TextureCache.empty,
                .count_cache = TextureCache.empty,
                .no_match_cache = TextureCache.empty,
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
            app.state.items.deinit(app.allocator);
            app.state.filtered_items.deinit(app.allocator);
            app.state.input_buffer.deinit(app.allocator);
            return error.NoItemsProvided;
        }

        try app.updateFilter();
        try app.updateWindowSize();

        // Start text input
        try sdl.keyboard.startTextInput(window);

        return app;
    }

    pub fn deinit(self: *App) void {
        sdl.keyboard.stopTextInput(self.sdl.window) catch |err| {
            std.debug.print("Warning: Failed to stop text input: {}\n", .{err});
        };
        self.state.input_buffer.deinit(self.allocator);
        for (self.state.items.items) |item| {
            self.allocator.free(item);
        }
        self.state.items.deinit(self.allocator);
        self.state.filtered_items.deinit(self.allocator);
        self.render_ctx.deinit(self.allocator);
        self.sdl.deinit();
    }

    pub fn run(self: *App) !void {
        var running = true;

        // Initial render
        try self.render();
        self.state.needs_render = false;

        while (running) {
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
                            try self.updateDisplayScale();
                        },
                        .window_pixel_size_changed => {
                            try self.updateDisplayScale();
                        },
                        else => {},
                    }
                }
            }

            if (self.state.needs_render) {
                try self.render();
                self.state.needs_render = false;
            }
        }
    }

    // ========================================================================
    // Input Loading
    // ========================================================================

    fn loadItemsFromStdin(self: *App) !void {
        if (std.posix.isatty(std.posix.STDIN_FILENO)) {
            return error.NoItemsProvided;
        }

        const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        const max_size = 10 * 1024 * 1024;
        const content = try stdin_file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(content);

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const truncate_len = input.findUtf8Boundary(trimmed, config.limits.max_item_length);
                const final_line = trimmed[0..truncate_len];
                const owned_line = try self.allocator.dupe(u8, final_line);
                try self.state.items.append(self.allocator, owned_line);
            }
        }
    }

    // ========================================================================
    // Filtering
    // ========================================================================

    fn updateFilter(self: *App) !void {
        const prev_filtered_count = self.state.filtered_items.items.len;
        self.state.filtered_items.clearRetainingCapacity();

        if (self.state.input_buffer.items.len == 0) {
            for (self.state.items.items, 0..) |_, i| {
                try self.state.filtered_items.append(self.allocator, i);
            }
        } else {
            const query = self.state.input_buffer.items;
            for (self.state.items.items, 0..) |item, i| {
                if (input.fuzzyMatch(item, query)) {
                    try self.state.filtered_items.append(self.allocator, i);
                }
            }
        }

        if (self.state.filtered_items.items.len > 0) {
            if (self.state.selected_index >= self.state.filtered_items.items.len) {
                self.state.selected_index = self.state.filtered_items.items.len - 1;
            }
        } else {
            self.state.selected_index = 0;
        }

        self.adjustScroll();

        if (prev_filtered_count != self.state.filtered_items.items.len) {
            try self.updateWindowSize();
        }
    }

    // ========================================================================
    // Navigation
    // ========================================================================

    fn adjustScroll(self: *App) void {
        if (self.state.filtered_items.items.len == 0) {
            self.state.scroll_offset = 0;
            return;
        }

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
        self.navigate(page_size * direction);
    }

    // ========================================================================
    // Input Handling
    // ========================================================================

    fn handleKeyEvent(self: *App, event: sdl.events.Keyboard) !bool {
        const key = event.key orelse return false;

        if (key == .escape) {
            return true;
        } else if (key == .return_key or key == .kp_enter) {
            if (self.state.filtered_items.items.len > 0) {
                const selected = self.state.items.items[self.state.filtered_items.items[self.state.selected_index]];
                const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                _ = try stdout_file.write(selected);
                _ = try stdout_file.write("\n");
            }
            return true;
        } else if (key == .backspace) {
            if (self.state.input_buffer.items.len > 0) {
                input.deleteLastCodepoint(&self.state.input_buffer);
                try self.updateFilter();
                self.state.needs_render = true;
            }
        } else if (key == .u and (event.mod.left_control or event.mod.right_control)) {
            self.state.input_buffer.clearRetainingCapacity();
            try self.updateFilter();
            self.state.needs_render = true;
        } else if (key == .w and (event.mod.left_control or event.mod.right_control)) {
            input.deleteWord(&self.state.input_buffer);
            try self.updateFilter();
            self.state.needs_render = true;
        } else if (key == .up or key == .k) {
            self.navigate(-1);
        } else if (key == .down or key == .j) {
            self.navigate(1);
        } else if (key == .c and (event.mod.left_control or event.mod.right_control)) {
            return true;
        } else if (key == .tab) {
            if (event.mod.left_shift or event.mod.right_shift) {
                self.navigate(-1);
            } else {
                self.navigate(1);
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
        if (self.state.input_buffer.items.len + text.len <= config.limits.max_input_length) {
            try self.state.input_buffer.appendSlice(self.allocator, text);
            try self.updateFilter();
            self.state.needs_render = true;
        }
    }

    // ========================================================================
    // Display
    // ========================================================================

    fn updateDisplayScale(self: *App) !void {
        self.render_ctx.display_scale = try self.sdl.window.getDisplayScale();
        const pixel_width, const pixel_height = try self.sdl.window.getSizeInPixels();

        if (pixel_width > std.math.maxInt(u32) or pixel_height > std.math.maxInt(u32)) {
            return error.DisplayTooLarge;
        }

        self.render_ctx.pixel_width = @intCast(pixel_width);
        self.render_ctx.pixel_height = @intCast(pixel_height);
        self.state.needs_render = true;
    }

    fn calculateOptimalWidth(self: *App) !u32 {
        var max_width: f32 = @floatFromInt(config.window.min_width);

        const prompt_w, _ = try self.sdl.font.getStringSize(config.layout.sample_prompt_text);
        const count_w, _ = try self.sdl.font.getStringSize(config.layout.sample_count_text);
        const scroll_w, _ = try self.sdl.font.getStringSize(config.layout.sample_scroll_text);
        const right_side_width = @max(count_w, scroll_w);

        const base_width = @as(f32, @floatFromInt(prompt_w + right_side_width)) + (config.layout.width_padding * config.layout.width_padding_multiplier);
        if (base_width > max_width) max_width = base_width;

        const filtered_len = self.state.filtered_items.items.len;
        const visible_end = @min(config.limits.max_visible_items, filtered_len);

        for (0..visible_end) |i| {
            if (i >= filtered_len) break;

            const item_index = self.state.filtered_items.items[i];
            if (item_index >= self.state.items.items.len) continue;

            const item = self.state.items.items[item_index];
            const item_text = std.fmt.bufPrint(self.render_ctx.item_buffer, "> {s}", .{item}) catch continue;
            const item_w, _ = self.sdl.font.getStringSize(item_text) catch continue;

            const total_item_width = @as(f32, @floatFromInt(item_w)) + (config.layout.width_padding * 2.0);
            if (total_item_width > max_width) max_width = total_item_width;
        }

        const rounded_width = @as(u32, @intFromFloat(@ceil(max_width)));
        const final_width = @max(rounded_width, config.window.min_width);
        return @min(final_width, config.window.max_width);
    }

    fn calculateOptimalHeight(self: *App) u32 {
        const filtered_len = self.state.filtered_items.items.len;
        const visible_items = @min(filtered_len, config.limits.max_visible_items);

        const prompt_area_height = config.layout.items_start_y;
        const items_height = @as(f32, @floatFromInt(visible_items)) * config.layout.item_line_height;
        const total_height = prompt_area_height + items_height + config.layout.bottom_margin;

        const rounded_height = @as(u32, @intFromFloat(@ceil(total_height)));
        const final_height = @max(rounded_height, config.window.min_height);
        return @min(final_height, config.window.max_height);
    }

    fn updateWindowSize(self: *App) !void {
        const new_width = try self.calculateOptimalWidth();
        const new_height = self.calculateOptimalHeight();

        if (new_width != self.render_ctx.current_width or new_height != self.render_ctx.current_height) {
            self.render_ctx.current_width = new_width;
            self.render_ctx.current_height = new_height;

            try self.sdl.window.setSize(new_width, new_height);
            try self.sdl.window.setPosition(.{ .centered = null }, .{ .centered = null });

            self.state.needs_render = true;
        }
    }

    // ========================================================================
    // Rendering
    // ========================================================================

    fn render(self: *App) !void {
        try self.sdl.renderer.setDrawColor(self.colors.background);
        try self.sdl.renderer.clear();

        const scale = self.render_ctx.display_scale;

        // Prompt
        const prompt_text = if (self.state.input_buffer.items.len > 0) blk: {
            const ellipsis_threshold = config.limits.max_input_length - config.limits.input_ellipsis_margin;
            const display_input = if (self.state.input_buffer.items.len > ellipsis_threshold)
                blk2: {
                    const approx_start = self.state.input_buffer.items.len - ellipsis_threshold;
                    var start = approx_start;
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

        // Count
        const count_text = std.fmt.bufPrintZ(
            self.render_ctx.count_buffer,
            "{d}/{d}",
            .{ self.state.filtered_items.items.len, self.state.items.items.len },
        ) catch "?/?";

        const count_text_w, _ = try self.sdl.font.getStringSize(count_text);
        const count_x = (@as(f32, @floatFromInt(self.render_ctx.current_width)) - @as(f32, @floatFromInt(count_text_w)) - config.layout.width_padding) * scale;
        try self.renderCachedText(count_x, config.layout.prompt_y * scale, count_text, self.colors.foreground, &self.render_ctx.count_cache);

        // Items
        const filtered_len = self.state.filtered_items.items.len;

        if (filtered_len > 0) {
            const visible_end = @min(self.state.scroll_offset + config.limits.max_visible_items, filtered_len);
            var y_pos: f32 = config.layout.items_start_y * scale;

            for (self.state.scroll_offset..visible_end) |i| {
                if (i >= filtered_len) break;

                const item_index = self.state.filtered_items.items[i];
                if (item_index >= self.state.items.items.len) continue;

                const item = self.state.items.items[item_index];
                const is_selected = (i == self.state.selected_index);
                const prefix = if (is_selected) "> " else "  ";

                const item_text = std.fmt.bufPrintZ(self.render_ctx.item_buffer, "{s}{s}", .{ prefix, item }) catch "  [error]";

                const color = if (is_selected) self.colors.selected else self.colors.foreground;
                try self.renderText(5.0 * scale, y_pos, item_text, color);

                y_pos += config.layout.item_line_height * scale;
            }

            // Scroll indicator
            if (filtered_len > config.limits.max_visible_items) {
                const scroll_text = std.fmt.bufPrintZ(
                    self.render_ctx.scroll_buffer,
                    "[{d}-{d}]",
                    .{ self.state.scroll_offset + 1, visible_end },
                ) catch "[?]";

                const scroll_text_w, _ = try self.sdl.font.getStringSize(scroll_text);
                const scroll_x = (@as(f32, @floatFromInt(self.render_ctx.current_width)) - @as(f32, @floatFromInt(scroll_text_w)) - config.layout.width_padding) * scale;
                try self.renderText(scroll_x, config.layout.items_start_y * scale, scroll_text, self.colors.foreground);
            }
        } else {
            try self.renderCachedText(5.0 * scale, config.layout.items_start_y * scale, "No matches", self.colors.foreground, &self.render_ctx.no_match_cache);
        }

        try self.sdl.renderer.present();
    }

    fn renderText(self: *App, x: f32, y: f32, text: [:0]const u8, color: sdl.pixels.Color) !void {
        const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
        defer surface.deinit();

        const texture = try self.sdl.renderer.createTextureFromSurface(surface);
        defer texture.deinit();

        const width, const height = try texture.getSize();
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
        const text_changed = !std.mem.eql(u8, cache.last_text, text);
        const color_changed = !colorEquals(cache.last_color, color);

        if (text_changed or color_changed or cache.texture == null) {
            if (cache.texture) |old_tex| old_tex.deinit();

            self.allocator.free(cache.last_text);
            cache.last_text = try self.allocator.dupe(u8, text);
            cache.last_color = color;

            const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
            const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
            defer surface.deinit();
            cache.texture = try self.sdl.renderer.createTextureFromSurface(surface);
        }

        if (cache.texture) |texture| {
            const width, const height = try texture.getSize();
            const dst = sdl.rect.FRect{ .x = x, .y = y, .w = width, .h = height };
            try self.sdl.renderer.renderTexture(texture, null, dst);
        }
    }

    fn colorEquals(a: sdl.pixels.Color, b: sdl.pixels.Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

// ============================================================================
// TESTS
// ============================================================================

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
    try std.testing.expect(config.limits.prompt_buffer_size >= config.limits.max_input_length + 10);
    try std.testing.expect(config.limits.item_buffer_size >= config.limits.max_item_length + 10);
    try std.testing.expect(config.limits.input_ellipsis_margin < config.limits.max_input_length);
}
