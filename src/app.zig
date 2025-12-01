//! zmenu application core
//!
//! Contains the main App struct and all application logic.

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");

const sdl_context = @import("sdl_context.zig");
const state_mod = @import("state.zig");
const rendering_mod = @import("rendering.zig");
const input = @import("input.zig");
const features = @import("features.zig");

pub const SdlContext = sdl_context.SDLContext;
pub const ColorScheme = rendering_mod.ColorScheme;
pub const TextureCache = rendering_mod.TextureCache;
pub const AppState = state_mod.AppState;
pub const InputState = state_mod.InputState;
pub const RenderContext = rendering_mod.RenderContext;

pub const App = struct {
    sdl: SdlContext,
    state: AppState,
    render_ctx: RenderContext,
    color_scheme: ColorScheme,
    allocator: std.mem.Allocator,
    feature_states: features.FeatureStates, // Zero-size when no features enabled

    pub fn init(allocator: std.mem.Allocator, monitor_index: ?usize, parsed_flags: *const features.ParsedFlags) !App {
        // Initialize SDL
        try sdl_context.initSDL();
        errdefer sdl_context.quitSDL();

        // Build color scheme from compile-time configuration
        const color_scheme = ColorScheme.fromConfig();


        // Create window and renderer
        const window_result = try sdl_context.createWindow(monitor_index);
        const window = window_result.window;
        const renderer = window_result.renderer;
        errdefer renderer.deinit();
        errdefer window.deinit();

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
        const font = font_result.font;
        const path = font_result.path;
        errdefer font.deinit();

        // Query display scale and pixel dimensions for high DPI support
        const display_scale = try window.getDisplayScale();
        const pixel_width, const pixel_height = try window.getSizeInPixels();

        if (pixel_width > std.math.maxInt(u32) or pixel_height > std.math.maxInt(u32)) {
            return error.DisplayTooLarge;
        }

        var app = App{
            .sdl = .{
                .window = window,
                .renderer = renderer,
                .font = font,
                .loaded_font_path = path,
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
                .window = .{
                    .display_scale = display_scale,
                    .width = @intCast(pixel_width),
                    .height = @intCast(pixel_height),
                    .current_width = config.window.initial_width,
                    .current_height = config.window.initial_height,
                },
            },
            .color_scheme = color_scheme,
            .allocator = allocator,
            .feature_states = features.initStates(),
        };

        // Initialize enabled features with parsed CLI flags
        try features.initAll(allocator, &app.feature_states, parsed_flags);

        try app.updateWindowSize();

        // Center window on initial creation
        try window.setPosition(.{ .centered = null }, .{ .centered = null });

        // Start text input
        try sdl.keyboard.startTextInput(window);

        return app;
    }

    pub fn deinit(self: *App) void {
        // Cleanup features first
        features.deinitAll(&self.feature_states, self.allocator);

        sdl.keyboard.stopTextInput(self.sdl.window) catch |err| {
            std.log.warn("Failed to stop text input: {}", .{err});
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

        // Check if stdin is a TTY (no piped input)
        if (std.posix.isatty(std.posix.STDIN_FILENO)) {
            const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            _ = stderr.write("Error: No items provided on stdin\n") catch {};
            _ = stderr.write("Usage: echo -e \"Item 1\\nItem 2\" | zmenu\n") catch {};
            return error.NoItemsProvided;
        }

        // Start threaded stdin reader (cross-platform)
        var stdin_reader = ThreadedStdinReader.init(self.allocator);
        try stdin_reader.startThread(); // Spawn thread after reader is in final memory location
        defer stdin_reader.deinit();

        // Buffer for lines from reader thread
        var new_lines = std.ArrayList([]u8).empty;
        defer {
            for (new_lines.items) |line| {
                self.allocator.free(line);
            }
            new_lines.deinit(self.allocator);
        }

        // Initial render (shows loading screen)
        try self.render();
        self.state.needs_render = false;

        while (running) {
            // Check for new lines from reader thread (non-blocking)
            const eof = try stdin_reader.pollLines(&new_lines);

            // Process any new lines
            if (new_lines.items.len > 0) {
                for (new_lines.items) |line| {
                    try self.processLine(line);
                    self.allocator.free(line);
                }
                new_lines.clearRetainingCapacity();
                self.state.needs_render = true;
            }

            // Handle EOF transition
            if (eof and self.state.input_state == .loading) {
                // Stdin complete - transition to ready state
                self.state.input_state = .ready;

                // Handle empty stdin case
                if (self.state.items.items.len == 0) {
                    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
                    _ = stderr.write("Error: No items provided on stdin\n") catch {};
                    return error.NoItemsProvided;
                }

                // Populate filtered items now that all items are loaded
                try self.updateFilter();
                self.state.needs_render = true;
            }

            // Wait for SDL events with timeout (blocks up to 16ms, returns early on event)
            // This avoids busy-waiting while still polling stdin regularly
            if (sdl.events.waitTimeout(16)) {
                // Process all queued events
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
                            // Only handle text input when ready
                            if (self.state.input_state == .ready) {
                                try self.handleTextInput(text_event.text);
                            }
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

    pub const ThreadedStdinReader = struct {
        thread: std.Thread,
        thread_started: bool,
        mutex: std.Thread.Mutex,
        lines: std.ArrayList([]u8),
        eof_reached: std.atomic.Value(bool),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) ThreadedStdinReader {
            // GPA is already thread-safe, no wrapper needed
            return ThreadedStdinReader{
                .thread = undefined,
                .thread_started = false,
                .mutex = .{},
                .lines = std.ArrayList([]u8).empty,
                .eof_reached = std.atomic.Value(bool).init(false),
                .allocator = allocator,
            };
        }

        fn startThread(self: *ThreadedStdinReader) !void {
            // Spawn background reader thread (must be called after reader is in final location)
            self.thread = try std.Thread.spawn(.{}, readerThreadFn, .{self});
            self.thread_started = true;
        }

        fn readerThreadFn(self: *ThreadedStdinReader) void {
            const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
            var chunk_buffer: [4096]u8 = undefined;
            var line_buffer = std.ArrayList(u8).empty;
            defer line_buffer.deinit(self.allocator);

            while (true) {
                // Blocking read (OK in background thread)
                const bytes_read = stdin_file.read(&chunk_buffer) catch {
                    // Error reading - set EOF and stop
                    self.eof_reached.store(true, .seq_cst);
                    break;
                };

                if (bytes_read == 0) {
                    // EOF - process any remaining buffered line
                    if (line_buffer.items.len > 0) {
                        const owned_line = self.allocator.dupe(u8, line_buffer.items) catch break;
                        self.mutex.lock();
                        self.lines.append(self.allocator, owned_line) catch {
                            self.allocator.free(owned_line);
                        };
                        self.mutex.unlock();
                    }
                    self.eof_reached.store(true, .seq_cst);
                    break;
                }

                // Process chunk for complete lines
                const chunk = chunk_buffer[0..bytes_read];
                var start: usize = 0;
                for (chunk, 0..) |byte, i| {
                    if (byte == '\n') {
                        // Complete line found
                        line_buffer.appendSlice(self.allocator, chunk[start..i]) catch break;

                        const owned_line = self.allocator.dupe(u8, line_buffer.items) catch break;
                        self.mutex.lock();
                        self.lines.append(self.allocator, owned_line) catch {
                            self.allocator.free(owned_line);
                        };
                        self.mutex.unlock();

                        line_buffer.clearRetainingCapacity();
                        start = i + 1;
                    }
                }

                // Buffer remaining partial line
                if (start < chunk.len) {
                    line_buffer.appendSlice(self.allocator, chunk[start..]) catch break;
                }
            }
        }

        /// Poll for new lines from the reader thread (non-blocking)
        /// Returns true if EOF has been reached
        pub fn pollLines(self: *ThreadedStdinReader, dest: *std.ArrayList([]u8)) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Transfer lines from thread buffer to destination
            try dest.appendSlice(self.allocator, self.lines.items);
            self.lines.clearRetainingCapacity();

            return self.eof_reached.load(.seq_cst);
        }

        pub fn deinit(self: *ThreadedStdinReader) void {
            // Wait for reader thread to finish (only if it was started)
            if (self.thread_started) {
                self.thread.join();
            }

            // Free any remaining lines
            for (self.lines.items) |line| {
                self.allocator.free(line);
            }
            self.lines.deinit(self.allocator);
        }
    };

    fn processLine(self: *App, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const truncate_len = input.findUtf8Boundary(trimmed, config.limits.max_item_length);
            const final_line = trimmed[0..truncate_len];
            const owned_line = try self.allocator.dupe(u8, final_line);
            try self.state.items.append(self.allocator, owned_line);

            // Increment items loaded counter if we're in loading state
            if (self.state.input_state == .loading) {
                self.state.input_state.loading.items_loaded += 1;
            }
        }
    }

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

        // Let features post-process filtered results (e.g., history boost)
        features.callAfterFilter(&self.feature_states, &self.state.filtered_items, self.state.items.items);

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

    fn handleKeyEvent(self: *App, event: sdl.events.Keyboard) !bool {
        const key = event.key orelse return false;

        // During loading, only allow ESC and Ctrl+C for early cancellation
        if (self.state.input_state == .loading) {
            if (key == .escape) {
                return true;
            } else if (key == .c and (event.mod.left_control or event.mod.right_control)) {
                return true;
            }
            return false;
        }

        if (key == .escape) {
            return true;
        } else if (key == .return_key or key == .kp_enter) {
            if (self.state.filtered_items.items.len > 0) {
                const selected = self.state.items.items[self.state.filtered_items.items[self.state.selected_index]];

                // Notify features of selection (e.g., for history tracking)
                features.callOnSelect(&self.feature_states, selected);

                // Allow features to perform pre-shutdown cleanup
                const all_completed = features.callOnExit(&self.feature_states, config.exit_timeout_ms);
                if (!all_completed) {
                    std.log.warn("Some features did not complete onExit within timeout", .{});
                }

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

    fn updateDisplayScale(self: *App) !void {
        self.render_ctx.window.display_scale = try self.sdl.window.getDisplayScale();
        const w_width, const w_height = try self.sdl.window.getSizeInPixels();

        if (w_width > std.math.maxInt(u32) or w_height > std.math.maxInt(u32)) {
            return error.DisplayTooLarge;
        }

        self.render_ctx.window.width = @intCast(w_width);
        self.render_ctx.window.height = @intCast(w_height);
        self.state.needs_render = true;
    }

    fn calculateOptimalWidth(self: *App) !u32 {
        var max_width: f32 = @floatFromInt(config.window.min_width);

        // Measure actual prompt text (or use sample if empty)
        const prompt_text = if (self.state.input_buffer.items.len > 0)
            std.fmt.bufPrintZ(self.render_ctx.prompt_buffer, "> {s}", .{self.state.input_buffer.items}) catch config.layout.sample_prompt_text
        else
            config.layout.sample_prompt_text;
        const prompt_w, _ = try self.sdl.font.getStringSize(prompt_text);

        // Measure actual count text
        const count_text = std.fmt.bufPrintZ(
            self.render_ctx.count_buffer,
            "{d}/{d}",
            .{ self.state.filtered_items.items.len, self.state.items.items.len },
        ) catch config.layout.sample_count_text;
        const count_w, _ = try self.sdl.font.getStringSize(count_text);

        // Measure scroll indicator if needed
        const filtered_len = self.state.filtered_items.items.len;
        const has_scroll = filtered_len > config.limits.max_visible_items;
        const scroll_w = if (has_scroll) blk: {
            const visible_end = @min(self.state.scroll_offset + config.limits.max_visible_items, filtered_len);
            const scroll_text = std.fmt.bufPrintZ(
                self.render_ctx.scroll_buffer,
                "[{d}-{d}]",
                .{ self.state.scroll_offset + 1, visible_end },
            ) catch config.layout.sample_scroll_text;
            const w, _ = try self.sdl.font.getStringSize(scroll_text);
            break :blk w;
        } else 0;

        const right_side_width = @max(count_w, scroll_w);

        // Width needed for prompt on left + right side elements + padding between
        const base_width = @as(f32, @floatFromInt(prompt_w + right_side_width)) + (config.layout.width_padding * 3.0);
        if (base_width > max_width) max_width = base_width;

        // Measure currently visible items (accounting for scroll offset)
        const visible_start = self.state.scroll_offset;
        const visible_end = @min(visible_start + config.limits.max_visible_items, filtered_len);

        for (visible_start..visible_end) |i| {
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

        if (new_width != self.render_ctx.window.current_width or new_height != self.render_ctx.window.current_height) {
            self.render_ctx.window.current_width = new_width;
            self.render_ctx.window.current_height = new_height;

            try self.sdl.window.setSize(new_width, new_height);

            self.state.needs_render = true;
        }
    }

    fn render(self: *App) !void {
        try self.sdl.renderer.setDrawColor(self.color_scheme.background);
        try self.sdl.renderer.clear();

        const scale = self.render_ctx.window.display_scale;

        // Render based on input state
        switch (self.state.input_state) {
            .loading => |data| {
                // Show loading screen while reading stdin
                const loading_text = std.fmt.bufPrintZ(
                    self.render_ctx.prompt_buffer,
                    "Loading...",
                    .{},
                ) catch "Loading...";

                try self.renderCachedText(5.0 * scale, config.layout.prompt_y * scale, loading_text, self.color_scheme.prompt, &self.render_ctx.prompt_cache);

                // Show item count
                const count_text = std.fmt.bufPrintZ(
                    self.render_ctx.count_buffer,
                    "Loaded {d} items",
                    .{data.items_loaded},
                ) catch "Loading...";

                try self.renderCachedText(5.0 * scale, config.layout.items_start_y * scale, count_text, self.color_scheme.foreground, &self.render_ctx.count_cache);

                try self.sdl.renderer.present();
                return;
            },
            .ready => {},
        }

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

        try self.renderCachedText(5.0 * scale, config.layout.prompt_y * scale, prompt_text, self.color_scheme.prompt, &self.render_ctx.prompt_cache);

        // Count
        const count_text = std.fmt.bufPrintZ(
            self.render_ctx.count_buffer,
            "{d}/{d}",
            .{ self.state.filtered_items.items.len, self.state.items.items.len },
        ) catch "?/?";

        const count_text_w, _ = try self.sdl.font.getStringSize(count_text);
        const count_x = (@as(f32, @floatFromInt(self.render_ctx.window.current_width)) - @as(f32, @floatFromInt(count_text_w)) - config.layout.width_padding) * scale;
        try self.renderCachedText(count_x, config.layout.prompt_y * scale, count_text, self.color_scheme.foreground, &self.render_ctx.count_cache);

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

                const color = if (is_selected) self.color_scheme.selected else self.color_scheme.foreground;
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
                const scroll_x = (@as(f32, @floatFromInt(self.render_ctx.window.current_width)) - @as(f32, @floatFromInt(scroll_text_w)) - config.layout.width_padding) * scale;
                try self.renderText(scroll_x, config.layout.items_start_y * scale, scroll_text, self.color_scheme.foreground);
            }
        } else {
            try self.renderCachedText(5.0 * scale, config.layout.items_start_y * scale, "No matches", self.color_scheme.foreground, &self.render_ctx.no_match_cache);
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
        const color_changed = !rendering_mod.colorEquals(cache.last_color, color);

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
};

test "colorEquals - same colors" {
    const color1 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 64, .a = 255 };
    const color2 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 64, .a = 255 };
    try std.testing.expect(rendering_mod.colorEquals(color1, color2));
}

test "colorEquals - different colors" {
    const color1 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 64, .a = 255 };
    const color2 = sdl.pixels.Color{ .r = 255, .g = 128, .b = 65, .a = 255 };
    try std.testing.expect(!rendering_mod.colorEquals(color1, color2));
}

test "config - buffer sizes aligned with limits" {
    try std.testing.expect(config.limits.prompt_buffer_size >= config.limits.max_input_length + 10);
    try std.testing.expect(config.limits.item_buffer_size >= config.limits.max_item_length + 10);
    try std.testing.expect(config.limits.input_ellipsis_margin < config.limits.max_input_length);
}
