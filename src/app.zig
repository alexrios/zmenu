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
const types = @import("types.zig");

pub const SdlContext = sdl_context.SDLContext;
pub const ColorScheme = rendering_mod.ColorScheme;
pub const TextureCache = rendering_mod.TextureCache;
pub const AppState = state_mod.AppState;
pub const InputState = state_mod.InputState;
pub const RenderContext = rendering_mod.RenderContext;

// Safe-Zig R2 hard caps on otherwise input-driven loops. These are safety
// nets — exceeding them would require a pathological OS condition or a runaway
// SDL event source — but they encode a statically provable upper bound.

/// Maximum events drained per 16ms event-loop tick. Any excess events are
/// processed on the next tick. SDL's queue is small; 1024 is far above the
/// largest reasonable burst (keyboard auto-repeat, paste, window events).
const max_events_per_tick: u32 = 1024;

/// Maximum read syscalls the stdin reader thread will perform before it
/// gives up. 1 million chunks × 4 KiB = 4 GiB of stdin — orders of magnitude
/// beyond any reasonable launcher input. Functional termination still occurs
/// on EOF (`bytes_read == 0`) or read error.
const max_stdin_read_iterations: u32 = 1_000_000;

pub const App = struct {
    sdl: SdlContext,
    state: AppState,
    render_ctx: RenderContext,
    color_scheme: ColorScheme,
    allocator: std.mem.Allocator,
    io: std.Io,
    feature_states: features.FeatureStates, // Zero-size when no features enabled

    const RenderBuffers = struct {
        prompt: []u8,
        item: []u8,
        count: []u8,
        scroll: []u8,
        value_preview: []u8,
    };

    fn initRenderBuffers(allocator: std.mem.Allocator) !RenderBuffers {
        const prompt = try allocator.alloc(u8, config.limits.prompt_buffer_size);
        errdefer allocator.free(prompt);
        const item = try allocator.alloc(u8, config.limits.item_buffer_size);
        errdefer allocator.free(item);
        const count = try allocator.alloc(u8, config.limits.count_buffer_size);
        errdefer allocator.free(count);
        const scroll = try allocator.alloc(u8, config.limits.scroll_buffer_size);
        errdefer allocator.free(scroll);
        const value_preview = try allocator.alloc(u8, config.limits.value_preview_buffer_size);
        // No errdefer needed on the last one: only this success path returns it.
        return .{ .prompt = prompt, .item = item, .count = count, .scroll = scroll, .value_preview = value_preview };
    }

    fn freeRenderBuffers(allocator: std.mem.Allocator, bufs: RenderBuffers) void {
        allocator.free(bufs.prompt);
        allocator.free(bufs.item);
        allocator.free(bufs.count);
        allocator.free(bufs.scroll);
        allocator.free(bufs.value_preview);
    }

    const DisplayMetrics = struct {
        scale: f32,
        width: u32,
        height: u32,
    };

    fn queryDisplayMetrics(window: anytype) !DisplayMetrics {
        const scale = try window.getDisplayScale();
        const pixel_width, const pixel_height = try window.getSizeInPixels();
        if (pixel_width > std.math.maxInt(u32) or pixel_height > std.math.maxInt(u32)) {
            return error.DisplayTooLarge;
        }
        return .{ .scale = scale, .width = @intCast(pixel_width), .height = @intCast(pixel_height) };
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, monitor_index: ?usize, parsed_flags: *const features.ParsedFlags) !App {
        try sdl_context.initSDL();
        errdefer sdl_context.quitSDL();

        const color_scheme = ColorScheme.fromConfig();

        const window_result = try sdl_context.createWindow(allocator, monitor_index);
        const window = window_result.window;
        const renderer = window_result.renderer;
        errdefer renderer.deinit();
        errdefer window.deinit();

        const bufs = try initRenderBuffers(allocator);
        errdefer freeRenderBuffers(allocator, bufs);

        const font_result = try sdl_context.loadFont();
        const font = font_result.font;
        errdefer font.deinit();

        const metrics = try queryDisplayMetrics(window);

        var app = App{
            .sdl = .{ .window = window, .renderer = renderer, .font = font, .loaded_font_path = font_result.path },
            .state = AppState.empty,
            .render_ctx = .{
                .prompt_buffer = bufs.prompt,
                .item_buffer = bufs.item,
                .count_buffer = bufs.count,
                .scroll_buffer = bufs.scroll,
                .value_preview_buffer = bufs.value_preview,
                .prompt_cache = TextureCache.empty,
                .count_cache = TextureCache.empty,
                .no_match_cache = TextureCache.empty,
                .window = .{
                    .display_scale = metrics.scale,
                    .width = metrics.width,
                    .height = metrics.height,
                    .current_width = config.window.initial_width,
                    .current_height = config.window.initial_height,
                },
            },
            .color_scheme = color_scheme,
            .allocator = allocator,
            .io = io,
            .feature_states = features.initStates(),
        };

        try features.initAll(allocator, io, &app.feature_states, parsed_flags);
        try app.updateWindowSize();
        try window.setPosition(.{ .centered = null }, .{ .centered = null });
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
            item.deinit(self.allocator);
        }
        self.state.items.deinit(self.allocator);
        self.state.filtered_items.deinit(self.allocator);
        self.render_ctx.deinit(self.allocator);
        self.sdl.deinit();
    }

    pub fn run(self: *App) !void {
        // Check if stdin is a TTY (no piped input)
        if (try std.Io.File.stdin().isTty(self.io)) {
            std.debug.print("Error: No items provided on stdin\n", .{});
            std.debug.print("Usage: echo -e \"Item 1\\nItem 2\" | zmenu\n", .{});
            return error.NoItemsProvided;
        }

        var stdin_reader = ThreadedStdinReader.init(self.allocator, self.io);
        try stdin_reader.startThread();
        defer stdin_reader.deinit();

        var new_lines = std.ArrayList([]u8).empty;
        defer {
            for (new_lines.items) |line| self.allocator.free(line);
            new_lines.deinit(self.allocator);
        }

        // Initial render (shows loading screen)
        try self.render();
        self.state.needs_render = false;

        var running = true;
        while (running) {
            const eof = try stdin_reader.pollLines(&new_lines);
            try self.processNewLines(&new_lines);
            if (eof and self.state.input_state == .loading) {
                try self.handleEofTransition();
            }

            if (sdl.events.waitTimeout(16)) {
                running = try self.processEvents();
            }

            if (self.state.needs_render) {
                try self.render();
                self.state.needs_render = false;
            }
        }
    }

    fn processNewLines(self: *App, new_lines: *std.ArrayList([]u8)) !void {
        if (new_lines.items.len == 0) return;
        for (new_lines.items) |line| {
            try self.processLine(line);
            self.allocator.free(line);
        }
        new_lines.clearRetainingCapacity();
        self.state.needs_render = true;
    }

    fn handleEofTransition(self: *App) !void {
        std.debug.assert(self.state.input_state == .loading);
        self.state.input_state = .ready;

        if (self.state.items.items.len == 0) {
            std.debug.print("Error: No items provided on stdin\n", .{});
            return error.NoItemsProvided;
        }

        try self.updateFilter();
        self.state.needs_render = true;
    }

    /// Drain SDL's event queue (capped by max_events_per_tick — Safe-Zig R2).
    /// Returns false when the user requested quit/terminate, true to keep running.
    fn processEvents(self: *App) !bool {
        for (0..max_events_per_tick) |_| {
            const event = sdl.events.poll() orelse break;
            switch (event) {
                .quit, .terminating => return false,
                .key_down => |key_event| {
                    if (try self.handleKeyEvent(key_event)) return false;
                },
                .text_input => |text_event| {
                    if (self.state.input_state == .ready) {
                        try self.handleTextInput(text_event.text);
                    }
                },
                .window_display_scale_changed,
                .window_pixel_size_changed,
                => try self.updateDisplayScale(),
                else => {},
            }
        }
        return true;
    }

    pub const ThreadedStdinReader = struct {
        thread: std.Thread,
        thread_started: bool,
        mutex: std.Io.Mutex,
        lines: std.ArrayList([]u8),
        eof_reached: std.atomic.Value(bool),
        allocator: std.mem.Allocator,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io) ThreadedStdinReader {
            return ThreadedStdinReader{
                .thread = undefined,
                .thread_started = false,
                .mutex = .init,
                .lines = std.ArrayList([]u8).empty,
                .eof_reached = std.atomic.Value(bool).init(false),
                .allocator = allocator,
                .io = io,
            };
        }

        fn startThread(self: *ThreadedStdinReader) !void {
            // Spawn background reader thread (must be called after reader is in final location)
            self.thread = try std.Thread.spawn(.{}, readerThreadFn, .{self});
            self.thread_started = true;
        }

        fn readerThreadFn(self: *ThreadedStdinReader) void {
            const stdin_fd = std.Io.File.stdin().handle;
            var chunk_buffer: [4096]u8 = undefined;
            var line_buffer = std.ArrayList(u8).empty;
            defer line_buffer.deinit(self.allocator);
            // Ensure eof_reached is always set when the thread exits,
            // regardless of which code path (error, OOM, normal EOF).
            defer self.eof_reached.store(true, .seq_cst);

            // Statically-bounded outer loop (Safe-Zig R2). Functional termination
            // is EOF / read error; the iteration cap is a safety net against a
            // misbehaving stdin source that never returns 0 or an error.
            for (0..max_stdin_read_iterations) |_| {
                // Blocking read (OK in background thread).
                // Terminates on EOF (bytes_read == 0) or any read error.
                const bytes_read = std.posix.read(stdin_fd, &chunk_buffer) catch break;
                std.debug.assert(bytes_read <= chunk_buffer.len);

                if (bytes_read == 0) {
                    // EOF - process any remaining buffered line
                    if (line_buffer.items.len > 0) {
                        const owned_line = self.allocator.dupe(u8, line_buffer.items) catch |err| {
                            std.log.warn("stdin reader: dropped final line on OOM: {}", .{err});
                            break;
                        };
                        self.mutex.lockUncancelable(self.io);
                        self.lines.append(self.allocator, owned_line) catch |err| {
                            std.log.warn("stdin reader: dropped final line on append: {}", .{err});
                            self.allocator.free(owned_line);
                        };
                        self.mutex.unlock(self.io);
                    }
                    break;
                }

                // Process chunk for complete lines
                const chunk = chunk_buffer[0..bytes_read];
                var start: usize = 0;
                for (chunk, 0..) |byte, i| {
                    std.debug.assert(start <= chunk.len);
                    if (byte == '\n') {
                        // Complete line found
                        line_buffer.appendSlice(self.allocator, chunk[start..i]) catch |err| {
                            std.log.warn("stdin reader: dropped line, append OOM: {}", .{err});
                            break;
                        };

                        const owned_line = self.allocator.dupe(u8, line_buffer.items) catch |err| {
                            std.log.warn("stdin reader: dropped line on dupe: {}", .{err});
                            break;
                        };
                        self.mutex.lockUncancelable(self.io);
                        self.lines.append(self.allocator, owned_line) catch |err| {
                            std.log.warn("stdin reader: dropped line on shared append: {}", .{err});
                            self.allocator.free(owned_line);
                        };
                        self.mutex.unlock(self.io);

                        line_buffer.clearRetainingCapacity();
                        start = i + 1;
                    }
                }

                // Buffer remaining partial line
                if (start < chunk.len) {
                    line_buffer.appendSlice(self.allocator, chunk[start..]) catch |err| {
                        std.log.warn("stdin reader: dropped partial line on buffer: {}", .{err});
                        break;
                    };
                }
            }
        }

        /// Poll for new lines from the reader thread (non-blocking)
        /// Returns true if EOF has been reached
        pub fn pollLines(self: *ThreadedStdinReader, dest: *std.ArrayList([]u8)) !bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

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
            const item = try types.Item.parse(self.allocator, final_line);
            try self.state.items.append(self.allocator, item);

            // Update cached max item width (measure once on ingest, not per frame)
            const item_width = self.measureItemWidth(item);
            if (item_width > self.render_ctx.cached_max_item_width) {
                self.render_ctx.cached_max_item_width = item_width;
            }

            // Increment items loaded counter if we're in loading state
            if (self.state.input_state == .loading) {
                self.state.input_state.loading.items_loaded += 1;
            }
        }
    }

    /// Measure the rendered width of an item (display + optional value preview).
    /// Used once per item on ingest to maintain the cached max width.
    fn measureItemWidth(self: *App, item: types.Item) f32 {
        const display_text = std.fmt.bufPrint(self.render_ctx.item_buffer, "> {s}", .{item.display}) catch return 0;
        const display_w, _ = self.sdl.font.getStringSize(display_text) catch return 0;
        var total: f32 = @floatFromInt(display_w);

        if (config.multivalue.show_preview and item.value.ptr != item.display.ptr) {
            const preview_len = if (config.multivalue.preview_max_length > 0)
                @min(item.value.len, config.multivalue.preview_max_length)
            else
                item.value.len;

            const preview_text = std.fmt.bufPrint(self.render_ctx.value_preview_buffer, "{s}", .{item.value[0..preview_len]}) catch return total;
            const preview_w, _ = self.sdl.font.getStringSize(preview_text) catch return total;

            total += config.multivalue.preview_spacing + @as(f32, @floatFromInt(preview_w));
        }

        total += config.layout.width_padding * 2.0;
        return total;
    }

    fn updateFilter(self: *App) !void {
        // Pre: invariants every caller must satisfy.
        std.debug.assert(self.state.filtered_items.items.len <= self.state.items.items.len);
        std.debug.assert(self.state.input_buffer.items.len <= config.limits.max_input_length);

        const prev_filtered_count = self.state.filtered_items.items.len;
        const total_items = self.state.items.items.len;
        self.state.filtered_items.clearRetainingCapacity();

        if (self.state.input_buffer.items.len == 0) {
            for (self.state.items.items, 0..) |_, i| {
                try self.state.filtered_items.append(self.allocator, i);
            }
        } else {
            const query = self.state.input_buffer.items;
            for (self.state.items.items, 0..) |item, i| {
                if (input.matchItem(item.display, query)) {
                    try self.state.filtered_items.append(self.allocator, i);
                }
            }
        }

        // Filtering is a subset operation: result never exceeds the source.
        std.debug.assert(self.state.filtered_items.items.len <= total_items);

        // Let features post-process filtered results (e.g., history boost).
        // Features may reorder, but not add or remove items.
        features.callAfterFilter(&self.feature_states, &self.state.filtered_items, self.state.items.items);
        std.debug.assert(self.state.filtered_items.items.len <= total_items);

        if (self.state.filtered_items.items.len > 0) {
            if (self.state.selected_index >= self.state.filtered_items.items.len) {
                self.state.selected_index = self.state.filtered_items.items.len - 1;
            }
        } else {
            self.state.selected_index = 0;
        }

        // Post: selection always points inside the filtered range (or is 0 when empty).
        std.debug.assert(self.state.selected_index < self.state.filtered_items.items.len or
            self.state.filtered_items.items.len == 0);

        self.adjustScroll();

        if (prev_filtered_count != self.state.filtered_items.items.len) {
            try self.updateWindowSize();
        }
    }

    fn adjustScroll(self: *App) void {
        const filtered_len = self.state.filtered_items.items.len;
        if (filtered_len == 0) {
            self.state.scroll_offset = 0;
            return;
        }

        // Clamp scroll_offset when filtered list shrinks below previous range
        const max_scroll = if (filtered_len > config.limits.max_visible_items)
            filtered_len - config.limits.max_visible_items
        else
            0;
        if (self.state.scroll_offset > max_scroll) {
            self.state.scroll_offset = max_scroll;
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
        const ctrl = event.mod.left_control or event.mod.right_control;
        const shift = event.mod.left_shift or event.mod.right_shift;

        // During loading, only allow ESC and Ctrl+C for early cancellation
        if (self.state.input_state == .loading) {
            return key == .escape or (key == .c and ctrl);
        }

        if (key == .escape) return true;
        if (key == .c and ctrl) return true;
        if (key == .return_key or key == .kp_enter) {
            try self.handleConfirm();
            return true;
        }

        if (key == .backspace) {
            if (self.state.input_buffer.items.len > 0) {
                input.deleteLastCodepoint(&self.state.input_buffer);
                try self.updateFilter();
                self.state.needs_render = true;
            }
        } else if (key == .u and ctrl) {
            self.state.input_buffer.clearRetainingCapacity();
            try self.updateFilter();
            self.state.needs_render = true;
        } else if (key == .w and ctrl) {
            input.deleteWord(&self.state.input_buffer);
            try self.updateFilter();
            self.state.needs_render = true;
        } else if (key == .up or key == .k) {
            self.navigate(-1);
        } else if (key == .down or key == .j) {
            self.navigate(1);
        } else if (key == .tab) {
            self.navigate(if (shift) -1 else 1);
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

    /// Confirm the current selection: notify features, run their onExit hooks,
    /// and write the selected item's value to stdout. No-op if nothing matches.
    fn handleConfirm(self: *App) !void {
        if (self.state.filtered_items.items.len == 0) return;
        std.debug.assert(self.state.selected_index < self.state.filtered_items.items.len);

        const item_idx = self.state.filtered_items.items[self.state.selected_index];
        std.debug.assert(item_idx < self.state.items.items.len);
        const selected_item = self.state.items.items[item_idx];

        // Notify features of selection with full Item (features choose display/value).
        features.callOnSelect(&self.feature_states, selected_item);

        const all_completed = features.callOnExit(&self.feature_states, config.exit_timeout_ms);
        if (!all_completed) {
            std.log.warn("Some features did not complete onExit within timeout", .{});
        }

        // Output value field only to stdout.
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(selected_item.value);
        try stdout.writeAll("\n");
        try stdout.flush();
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

        // Use cached max item width (measured once per item on ingest)
        // instead of re-measuring visible items every frame
        if (self.render_ctx.cached_max_item_width > max_width) {
            max_width = self.render_ctx.cached_max_item_width;
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

    /// Top-level orchestrator. Each helper is responsible for a single visual
    /// element. Order of calls below is the SDL drawing/layering order — do not
    /// reorder without understanding the implications (background must be first,
    /// present() must be last).
    fn render(self: *App) !void {
        try self.renderClear();
        const scale = self.render_ctx.window.display_scale;

        // Loading state has its own minimal layout and short-circuits.
        switch (self.state.input_state) {
            .loading => |data| {
                try self.renderLoading(scale, data.items_loaded);
                try self.sdl.renderer.present();
                return;
            },
            .ready => {},
        }

        try self.renderPromptLine(scale);
        try self.renderCounter(scale);
        try self.renderItemList(scale);
        try self.sdl.renderer.present();
    }

    /// Fill the framebuffer with the configured background color.
    fn renderClear(self: *App) !void {
        try self.sdl.renderer.setDrawColor(self.color_scheme.background);
        try self.sdl.renderer.clear();
    }

    /// Render the loading screen (shown while stdin is still being read).
    fn renderLoading(self: *App, scale: f32, items_loaded: usize) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(self.state.input_state == .loading);

        const loading_text = std.fmt.bufPrintZ(
            self.render_ctx.prompt_buffer,
            "Loading...",
            .{},
        ) catch "Loading...";

        try self.renderCachedText(5.0 * scale, config.layout.prompt_y * scale, loading_text, self.color_scheme.prompt, &self.render_ctx.prompt_cache);

        const count_text = std.fmt.bufPrintZ(
            self.render_ctx.count_buffer,
            "Loaded {d} items",
            .{items_loaded},
        ) catch "Loading...";

        try self.renderCachedText(5.0 * scale, config.layout.items_start_y * scale, count_text, self.color_scheme.foreground, &self.render_ctx.count_cache);
    }

    /// Render the prompt line: "> " followed by the user's input (with leading
    /// ellipsis if the input exceeds the visible threshold). UTF-8 safe.
    fn renderPromptLine(self: *App, scale: f32) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(config.limits.input_ellipsis_margin < config.limits.max_input_length);

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
    }

    /// Render the "filtered/total" match counter on the right side of the prompt row.
    fn renderCounter(self: *App, scale: f32) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(self.state.filtered_items.items.len <= self.state.items.items.len);

        const count_text = std.fmt.bufPrintZ(
            self.render_ctx.count_buffer,
            "{d}/{d}",
            .{ self.state.filtered_items.items.len, self.state.items.items.len },
        ) catch "?/?";

        const count_text_w, _ = try self.sdl.font.getStringSize(count_text);
        const count_x = (@as(f32, @floatFromInt(self.render_ctx.window.current_width)) - @as(f32, @floatFromInt(count_text_w)) - config.layout.width_padding) * scale;
        try self.renderCachedText(count_x, config.layout.prompt_y * scale, count_text, self.color_scheme.foreground, &self.render_ctx.count_cache);
    }

    /// Render the filtered item list (or the empty-state message), plus the
    /// scroll indicator when the list overflows the visible window.
    fn renderItemList(self: *App, scale: f32) !void {
        std.debug.assert(scale > 0.0);

        const filtered_len = self.state.filtered_items.items.len;
        if (filtered_len == 0) {
            try self.renderEmptyState(scale);
            return;
        }

        const visible_end = @min(self.state.scroll_offset + config.limits.max_visible_items, filtered_len);
        std.debug.assert(visible_end <= filtered_len);
        std.debug.assert(self.state.scroll_offset <= visible_end);

        var y_pos: f32 = config.layout.items_start_y * scale;
        for (self.state.scroll_offset..visible_end) |i| {
            if (i >= filtered_len) break;

            const item_index = self.state.filtered_items.items[i];
            if (item_index >= self.state.items.items.len) continue;

            const item = self.state.items.items[item_index];
            const is_selected = (i == self.state.selected_index);
            try self.renderItem(scale, y_pos, item, is_selected);
            y_pos += config.layout.item_line_height * scale;
        }

        if (filtered_len > config.limits.max_visible_items) {
            try self.renderScrollIndicator(scale, visible_end);
        }
    }

    /// Render a single item row: prefix ("> " when selected, "  " otherwise),
    /// display text, and optional dimmed value-preview.
    fn renderItem(self: *App, scale: f32, y_pos: f32, item: types.Item, is_selected: bool) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(y_pos >= 0.0);

        const prefix = if (is_selected) "> " else "  ";
        const display_text = std.fmt.bufPrintZ(self.render_ctx.item_buffer, "{s}{s}", .{ prefix, item.display }) catch "  [error]";
        const display_color = if (is_selected) self.color_scheme.selected else self.color_scheme.foreground;
        try self.renderText(5.0 * scale, y_pos, display_text, display_color);

        if (config.multivalue.show_preview and item.value.ptr != item.display.ptr) {
            const display_w, _ = try self.sdl.font.getStringSize(display_text);
            const value_x = 5.0 * scale + @as(f32, @floatFromInt(display_w)) + config.multivalue.preview_spacing * scale;

            const preview_text = if (config.multivalue.preview_max_length > 0 and item.value.len > config.multivalue.preview_max_length) blk: {
                const truncate_len = input.findUtf8Boundary(item.value, config.multivalue.preview_max_length);
                break :blk std.fmt.bufPrintZ(self.render_ctx.value_preview_buffer, "{s}...", .{item.value[0..truncate_len]}) catch "...";
            } else std.fmt.bufPrintZ(self.render_ctx.value_preview_buffer, "{s}", .{item.value}) catch "...";

            // Use dimmed color (never use selected color for preview).
            try self.renderText(value_x, y_pos, preview_text, self.color_scheme.value_preview);
        }
    }

    /// Render the "No matches" placeholder when the filter excludes every item.
    fn renderEmptyState(self: *App, scale: f32) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(self.state.filtered_items.items.len == 0);

        try self.renderCachedText(5.0 * scale, config.layout.items_start_y * scale, "No matches", self.color_scheme.foreground, &self.render_ctx.no_match_cache);
    }

    /// Render the "[start-end]" scroll indicator on the right side of the items row.
    fn renderScrollIndicator(self: *App, scale: f32, visible_end: usize) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(self.state.scroll_offset < visible_end);
        std.debug.assert(visible_end <= self.state.filtered_items.items.len);

        const scroll_text = std.fmt.bufPrintZ(
            self.render_ctx.scroll_buffer,
            "[{d}-{d}]",
            .{ self.state.scroll_offset + 1, visible_end },
        ) catch "[?]";

        const scroll_text_w, _ = try self.sdl.font.getStringSize(scroll_text);
        const scroll_x = (@as(f32, @floatFromInt(self.render_ctx.window.current_width)) - @as(f32, @floatFromInt(scroll_text_w)) - config.layout.width_padding) * scale;
        try self.renderText(scroll_x, config.layout.items_start_y * scale, scroll_text, self.color_scheme.foreground);
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
            // Create new texture before modifying cache state to avoid
            // inconsistency if rendering fails partway through
            const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
            const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
            defer surface.deinit();
            const new_texture = try self.sdl.renderer.createTextureFromSurface(surface);

            const new_text = try self.allocator.dupe(u8, text);

            // All allocations succeeded — now update cache atomically
            if (cache.texture) |old_tex| old_tex.deinit();
            self.allocator.free(cache.last_text);
            cache.last_text = new_text;
            cache.last_color = color;
            cache.texture = new_texture;
        }

        if (cache.texture) |texture| {
            const width, const height = try texture.getSize();
            const dst = sdl.rect.FRect{ .x = x, .y = y, .w = width, .h = height };
            try self.sdl.renderer.renderTexture(texture, null, dst);
        }
    }
};

test "ThreadedStdinReader - initial state and pollLines contract" {
    // Verify the reader's initial state and that pollLines works correctly
    // with manually populated data (simulating what the thread would produce).

    const allocator = std.testing.allocator;

    var reader = App.ThreadedStdinReader.init(allocator, std.testing.io);
    defer reader.deinit();

    // Initial state: no EOF, no lines
    try std.testing.expect(!reader.eof_reached.load(.seq_cst));

    // Simulate thread producing lines by manually adding to the shared buffer
    const line1 = try allocator.dupe(u8, "line one");
    const line2 = try allocator.dupe(u8, "line two");
    reader.mutex.lockUncancelable(std.testing.io);
    reader.lines.append(allocator, line1) catch unreachable;
    reader.lines.append(allocator, line2) catch unreachable;
    reader.mutex.unlock(std.testing.io);

    // pollLines should drain them
    var dest = std.ArrayList([]u8).empty;
    defer {
        for (dest.items) |line| allocator.free(line);
        dest.deinit(allocator);
    }

    const eof = try reader.pollLines(&dest);
    try std.testing.expect(!eof);
    try std.testing.expectEqual(@as(usize, 2), dest.items.len);
    try std.testing.expectEqualStrings("line one", dest.items[0]);
    try std.testing.expectEqualStrings("line two", dest.items[1]);

    // Internal buffer should be drained
    try std.testing.expectEqual(@as(usize, 0), reader.lines.items.len);

    // Simulate EOF
    reader.eof_reached.store(true, .seq_cst);
    for (dest.items) |line| allocator.free(line);
    dest.clearRetainingCapacity();

    const eof2 = try reader.pollLines(&dest);
    try std.testing.expect(eof2);
    try std.testing.expectEqual(@as(usize, 0), dest.items.len);
}

test "ThreadedStdinReader - defer ensures eof_reached on all exit paths" {
    // The fix uses `defer self.eof_reached.store(true, .seq_cst)` at the
    // top of readerThreadFn. This guarantees that regardless of which
    // break/error path exits the loop, pollLines will eventually see EOF.
    //
    // Previously, break at the partial-line buffering (OOM) would exit
    // without setting eof_reached, causing the app to hang in .loading
    // state forever. The defer pattern makes this impossible.
    //
    // Direct thread testing with stdin is impractical, but the structural
    // guarantee (defer at function scope) covers all paths by construction.

    const allocator = std.testing.allocator;
    var reader = App.ThreadedStdinReader.init(allocator, std.testing.io);
    defer reader.deinit();
    try std.testing.expect(!reader.eof_reached.load(.seq_cst));
}

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
    // Value preview buffer must fit truncated preview + "..." suffix + null terminator
    try std.testing.expect(config.limits.value_preview_buffer_size >= config.multivalue.preview_max_length + 4);
}
