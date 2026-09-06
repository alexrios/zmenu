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

/// Maximum read operations the asynchronous stdin task will perform before it
/// gives up. 1 million chunks × 4 KiB = 4 GiB of stdin — orders of magnitude
/// beyond any reasonable launcher input. Functional termination still occurs
/// on `error.EndOfStream`, cancellation, or a propagated read/processing error.
const max_stdin_read_iterations: u32 = 1_000_000;

pub const App = struct {
    sdl: SdlContext,
    state: AppState,
    render_ctx: RenderContext,
    color_scheme: ColorScheme,
    allocator: std.mem.Allocator,
    io: std.Io,
    target_display: ?sdl.video.Display,
    monitor_index: ?usize,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, monitor_index: ?usize, parsed_flags: *const features.ParsedFlags) !App {
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
            .target_display = window_result.display,
            .monitor_index = monitor_index,
            .feature_states = features.initStates(),
        };

        try features.initAll(allocator, io, environ_map, &app.feature_states, parsed_flags);
        errdefer features.deinitAll(&app.feature_states, allocator);
        try app.updateWindowSize();
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

        var stdin_reader = CancelableStdinReader.init(self.allocator, self.io, std.Io.File.stdin());
        stdin_reader.start();
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
            const read_status = try stdin_reader.pollLines(&new_lines);
            try self.processNewLines(&new_lines);
            if (read_status == .eof and self.state.input_state == .loading) {
                try self.handleEofTransition();
            }

            if (sdl.events.waitTimeout(16)) {
                running = try self.processEvents();
            }

            if (!running) stdin_reader.cancel();

            if (self.state.needs_render) {
                try self.render();
                self.state.needs_render = false;
            }
        }
    }

    pub fn checkEmptyConfirmation(self: *App) !void {
        try self.processLine("alpha|confirmed-value");
        try self.handleEofTransition();
        try self.handleTextInput("zzzz");
        var event = std.mem.zeroes(sdl.events.Keyboard);
        event.key = .return_key;
        if (try self.handleKeyEvent(event)) return error.EmptyConfirmationClosedMenu;
        event.key = .u;
        event.mod.left_control = true;
        _ = try self.handleKeyEvent(event);
        if (self.state.filtered_items.items.len != 1) return error.SearchDidNotRecover;
        event.key = .return_key;
        event.mod.left_control = false;
        if (!try self.handleKeyEvent(event)) return error.ValidConfirmationDidNotClose;
    }

    /// Internal benchmark entrypoint; never used by the launcher's CLI.
    pub fn benchmark(self: *App, count: usize) !void {
        var line: [1024]u8 = undefined;
        var start = sdl.timer.getPerformanceCounter();
        for (0..count) |i| {
            const text = try std.fmt.bufPrint(&line, "/projects/long/deterministic/path/日本語/café/component-{d}/repeated-{d}.txt|value-{d}", .{ i, i % 100, i });
            try self.processLine(text);
        }
        reportTiming("ingest", start);
        self.state.input_state = .ready;
        start = sdl.timer.getPerformanceCounter();
        try self.updateFilter();
        reportTiming("search_empty", start);
        start = sdl.timer.getPerformanceCounter();
        try self.handleTextInput("cpt99");
        reportTiming("search_fuzzy", start);
        self.state.input_buffer.clearRetainingCapacity();
        try self.updateFilter();
        const history = @import("features/history.zig");
        const hist = try history.HistoryState.loadWithConfig(self.allocator, self.io, null, "/nonexistent/zmenu-benchmark-history", 100);
        defer hist.deinit();
        for (0..100) |i| hist.addEntry(self.state.items.items[count - 1 - i].display);
        start = sdl.timer.getPerformanceCounter();
        history.feature.hooks.afterFilter.?(hist, &self.state.filtered_items, self.state.items.items);
        reportTiming("history", start);
        for (0..20) |_| {
            start = sdl.timer.getPerformanceCounter();
            self.navigate(1);
            try self.render();
            reportTiming("render_navigation", start);
        }
    }

    fn reportTiming(label: []const u8, start: u64) void {
        const ms = @as(f64, @floatFromInt(sdl.timer.getPerformanceCounter() - start)) * 1000 / @as(f64, @floatFromInt(sdl.timer.getPerformanceFrequency()));
        std.debug.print("BENCH {s} {d:.3}\n", .{ label, ms });
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

        // Post: one-way transition complete; filter reflects the now-final set.
        std.debug.assert(self.state.input_state == .ready);
        std.debug.assert(self.state.filtered_items.items.len <= self.state.items.items.len);
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

    pub const CancelableStdinReader = struct {
        pub const Status = enum(u8) { reading, eof, canceled, failed };

        future: std.Io.Future(anyerror!Status),
        started: bool,
        mutex: std.Io.Mutex,
        lines: std.ArrayList([]u8),
        status: std.atomic.Value(Status),
        allocator: std.mem.Allocator,
        io: std.Io,
        file: std.Io.File,
        max_iterations: u32,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) CancelableStdinReader {
            return .{
                .future = undefined,
                .started = false,
                .mutex = .init,
                .lines = std.ArrayList([]u8).empty,
                .status = std.atomic.Value(Status).init(.reading),
                .allocator = allocator,
                .io = io,
                .file = file,
                .max_iterations = max_stdin_read_iterations,
            };
        }

        fn initWithLimit(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, max_iterations: u32) CancelableStdinReader {
            var result = CancelableStdinReader.init(allocator, io, file);
            result.max_iterations = max_iterations;
            return result;
        }

        pub fn start(self: *CancelableStdinReader) void {
            std.debug.assert(!self.started);
            self.future = self.io.async(readTask, .{self});
            self.started = true;
        }

        /// Dupe `line` into heap memory, then enqueue it on the shared list
        /// under the mutex. Returns OOM on either allocation failure; caller
        /// should stop reading rather than masking the failure.
        fn emitLine(self: *CancelableStdinReader, line: []const u8) std.mem.Allocator.Error!void {
            const owned = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(owned);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.lines.append(self.allocator, owned);
        }

        /// Split one chunk on '\n', emit each completed line, and buffer the
        /// trailing partial line (if any) into `line_buffer` for the next chunk
        /// to complete. Propagates OOM.
        fn processChunk(
            self: *CancelableStdinReader,
            chunk: []const u8,
            line_buffer: *std.ArrayList(u8),
        ) std.mem.Allocator.Error!void {
            var chunk_start: usize = 0;
            for (chunk, 0..) |byte, i| {
                std.debug.assert(chunk_start <= chunk.len);
                if (byte != '\n') continue;
                try line_buffer.appendSlice(self.allocator, chunk[chunk_start..i]);
                try self.emitLine(line_buffer.items);
                line_buffer.clearRetainingCapacity();
                chunk_start = i + 1;
            }
            if (chunk_start < chunk.len) {
                try line_buffer.appendSlice(self.allocator, chunk[chunk_start..]);
            }
        }

        /// Emit any final partial line at EOF (stdin without trailing newline).
        /// Allocation failures propagate to the task result.
        fn flushPartialLine(self: *CancelableStdinReader, line_buffer: *std.ArrayList(u8)) !void {
            if (line_buffer.items.len == 0) return;
            try self.emitLine(line_buffer.items);
        }

        fn readTask(self: *CancelableStdinReader) anyerror!Status {
            var chunk_buffer: [4096]u8 = undefined;
            var line_buffer = std.ArrayList(u8).empty;
            defer line_buffer.deinit(self.allocator);

            for (0..self.max_iterations) |_| {
                const bytes_read = self.file.readStreaming(self.io, &.{&chunk_buffer}) catch |err| switch (err) {
                    error.EndOfStream => {
                        self.flushPartialLine(&line_buffer) catch |flush_err| {
                            self.status.store(.failed, .release);
                            return flush_err;
                        };
                        self.status.store(.eof, .release);
                        return .eof;
                    },
                    error.Canceled => {
                        self.status.store(.canceled, .release);
                        return .canceled;
                    },
                    else => {
                        self.status.store(.failed, .release);
                        return err;
                    },
                };
                std.debug.assert(bytes_read <= chunk_buffer.len);
                self.processChunk(chunk_buffer[0..bytes_read], &line_buffer) catch |err| {
                    self.status.store(.failed, .release);
                    return err;
                };
            }
            self.status.store(.failed, .release);
            return error.StdinReadLimitExceeded;
        }

        /// Poll for new lines from the reader thread (non-blocking)
        pub fn pollLines(self: *CancelableStdinReader, dest: *std.ArrayList([]u8)) !Status {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // Transfer lines from thread buffer to destination
            try dest.appendSlice(self.allocator, self.lines.items);
            self.lines.clearRetainingCapacity();

            const current = self.status.load(.acquire);
            if (current == .failed) {
                _ = try self.future.await(self.io);
                unreachable;
            }
            return current;
        }

        pub fn cancel(self: *CancelableStdinReader) void {
            if (!self.started or self.status.load(.acquire) != .reading) return;
            _ = self.future.cancel(self.io) catch |err| switch (err) {
                error.Canceled => {},
                else => std.log.warn("stdin reader cancellation failed: {}", .{err}),
            };
        }

        pub fn deinit(self: *CancelableStdinReader) void {
            if (self.started) {
                if (self.status.load(.acquire) == .reading) self.cancel();
                if (self.future.any_future != null) _ = self.future.await(self.io) catch {};
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
            std.debug.assert(trimmed.len <= line.len);

            const truncate_len = input.findUtf8Boundary(trimmed, config.limits.max_item_length);
            // Paired with findUtf8Boundary's internal postcondition: the
            // returned index must be on a leading byte (or at end / zero).
            std.debug.assert(truncate_len <= trimmed.len);
            std.debug.assert(truncate_len <= config.limits.max_item_length);
            std.debug.assert(truncate_len == 0 or truncate_len == trimmed.len or (trimmed[truncate_len] & 0xC0) != 0x80);

            const final_line = trimmed[0..truncate_len];
            const item = try types.Item.parse(self.allocator, final_line);
            std.debug.assert(item.display.len <= config.limits.max_item_length);
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
        // bufPrint failure here means item_buffer_size is misconfigured (smaller
        // than max_item_length + prefix). This is a comptime invariant per
        // CLAUDE.md; assert it instead of silently degrading.
        std.debug.assert(self.render_ctx.item_buffer.len >= config.limits.max_item_length + 16);

        const display_text = std.fmt.bufPrint(self.render_ctx.item_buffer, "> {s}", .{item.display}) catch |err| {
            std.log.warn("measureItemWidth: display bufPrint failed ({}); width may be wrong", .{err});
            return 0;
        };
        const display_w, _ = self.sdl.font.getStringSize(display_text) catch |err| {
            std.log.warn("measureItemWidth: SDL getStringSize failed ({}); width may be wrong", .{err});
            return 0;
        };
        var total: f32 = @floatFromInt(display_w);

        if (config.multivalue.show_preview and item.value.ptr != item.display.ptr) {
            const preview_len = if (config.multivalue.preview_max_length > 0)
                @min(item.value.len, config.multivalue.preview_max_length)
            else
                item.value.len;

            const preview_text = std.fmt.bufPrint(self.render_ctx.value_preview_buffer, "{s}", .{item.value[0..preview_len]}) catch |err| {
                std.log.warn("measureItemWidth: preview bufPrint failed ({}); width may be wrong", .{err});
                return total;
            };
            const preview_w, _ = self.sdl.font.getStringSize(preview_text) catch |err| {
                std.log.warn("measureItemWidth: preview getStringSize failed ({}); width may be wrong", .{err});
                return total;
            };

            total += config.multivalue.preview_spacing + @as(f32, @floatFromInt(preview_w));
        }

        total += config.layout.width_padding * 2.0;
        std.debug.assert(total >= 0.0);
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
        // Defend against a future feature that mutates indices: every entry
        // must still point inside self.state.items.items.
        for (self.state.filtered_items.items) |idx| {
            std.debug.assert(idx < total_items);
        }

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
        std.debug.assert(self.state.selected_index < filtered_len);

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

        // Post: the selected row is inside the visible window.
        std.debug.assert(self.state.scroll_offset <= self.state.selected_index);
        std.debug.assert(self.state.selected_index < self.state.scroll_offset + config.limits.max_visible_items);
    }

    fn navigate(self: *App, delta: isize) void {
        if (self.state.filtered_items.items.len == 0) return;
        std.debug.assert(self.state.selected_index < self.state.filtered_items.items.len);

        const current = @as(isize, @intCast(self.state.selected_index));
        const new_idx = current + delta;

        if (new_idx >= 0 and new_idx < @as(isize, @intCast(self.state.filtered_items.items.len))) {
            self.state.selected_index = @intCast(new_idx);
            self.adjustScroll();
            self.state.needs_render = true;
        }

        std.debug.assert(self.state.selected_index < self.state.filtered_items.items.len);
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
            return try self.handleConfirm();
        }

        if (key == .backspace) {
            if (self.state.input_buffer.items.len > 0) {
                const old_len = self.state.input_buffer.items.len;
                input.deleteLastCodepoint(&self.state.input_buffer);
                // Paired with deleteLastCodepoint's internal asserts: removed
                // exactly one codepoint, so 1..=4 bytes (UTF-8 max width).
                const removed = old_len - self.state.input_buffer.items.len;
                std.debug.assert(self.state.input_buffer.items.len < old_len);
                std.debug.assert(removed >= 1 and removed <= 4);

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
    fn handleConfirm(self: *App) !bool {
        if (self.state.filtered_items.items.len == 0) return false;
        std.debug.assert(self.state.selected_index < self.state.filtered_items.items.len);

        const item_idx = self.state.filtered_items.items[self.state.selected_index];
        std.debug.assert(item_idx < self.state.items.items.len);
        const selected_item = self.state.items.items[item_idx];

        // Notify features of selection with full Item (features choose display/value).
        features.callOnSelect(&self.feature_states, selected_item);

        const exit_budget_ms: u32 = if (@hasDecl(config, "exit_budget_ms"))
            config.exit_budget_ms
        else if (@hasDecl(config, "exit_timeout_ms"))
            config.exit_timeout_ms
        else
            500;
        if (features.callOnExit(&self.feature_states, exit_budget_ms) == .timed_out) {
            std.log.warn("Some features did not complete onExit within the cooperative budget", .{});
        }

        // Output value field only to stdout.
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(selected_item.value);
        try stdout.writeAll("\n");
        try stdout.flush();
        return true;
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
        const result = @min(final_width, config.window.max_width);
        std.debug.assert(result >= config.window.min_width);
        std.debug.assert(result <= config.window.max_width);
        return result;
    }

    fn calculateOptimalHeight(self: *App) u32 {
        const filtered_len = self.state.filtered_items.items.len;
        const visible_items = @min(filtered_len, config.limits.max_visible_items);
        std.debug.assert(visible_items <= config.limits.max_visible_items);

        const prompt_area_height = config.layout.items_start_y;
        const items_height = @as(f32, @floatFromInt(visible_items)) * config.layout.item_line_height;
        const total_height = prompt_area_height + items_height + config.layout.bottom_margin;

        const rounded_height = @as(u32, @intFromFloat(@ceil(total_height)));
        const final_height = @max(rounded_height, config.window.min_height);
        const result = @min(final_height, config.window.max_height);
        std.debug.assert(result >= config.window.min_height);
        std.debug.assert(result <= config.window.max_height);
        return result;
    }

    fn updateWindowSize(self: *App) !void {
        const new_width = try self.calculateOptimalWidth();
        const new_height = self.calculateOptimalHeight();

        if (new_width != self.render_ctx.window.current_width or new_height != self.render_ctx.window.current_height) {
            self.render_ctx.window.current_width = new_width;
            self.render_ctx.window.current_height = new_height;

            try self.sdl.window.setSize(new_width, new_height);
            if (self.target_display) |display| {
                sdl_context.positionOnDisplay(self.sdl.window, display, self.monitor_index.?, new_width, new_height);
            }

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
            const display_input = if (self.state.input_buffer.items.len > ellipsis_threshold) blk2: {
                const approx_start = self.state.input_buffer.items.len - ellipsis_threshold;
                var start = approx_start;
                while (start < self.state.input_buffer.items.len and (self.state.input_buffer.items[start] & 0xC0) == 0x80) {
                    start += 1;
                }
                break :blk2 self.state.input_buffer.items[start..];
            } else self.state.input_buffer.items;

            const prefix = if (self.state.input_buffer.items.len > ellipsis_threshold) "> ..." else "> ";
            break :blk std.fmt.bufPrintZ(self.render_ctx.prompt_buffer, "{s}{s}", .{ prefix, display_input }) catch "> [error]";
        } else std.fmt.bufPrintZ(self.render_ctx.prompt_buffer, "> ", .{}) catch "> ";

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
                // Paired: re-verify the boundary on the caller's side.
                std.debug.assert(truncate_len <= item.value.len);
                std.debug.assert(truncate_len == 0 or truncate_len == item.value.len or (item.value[truncate_len] & 0xC0) != 0x80);
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
        // R3: hot path. Comparison reads from cache.last_text_buf (stack/struct
        // memory); setText below uses @memcpy. No heap allocation per frame.
        std.debug.assert(text.len <= rendering_mod.max_cache_text_len);

        const text_changed = !std.mem.eql(u8, cache.lastText(), text);
        const color_changed = !rendering_mod.colorEquals(cache.last_color, color);

        if (text_changed or color_changed or cache.texture == null) {
            // Build the new texture before mutating cache state — if the SDL
            // call fails, the cache stays consistent with the previous frame.
            const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
            const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
            defer surface.deinit();
            const new_texture = try self.sdl.renderer.createTextureFromSurface(surface);

            if (cache.texture) |old_tex| old_tex.deinit();
            cache.setText(text);
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

test "CancelableStdinReader.processChunk splits lines and preserves final partial line" {
    const allocator = std.testing.allocator;
    var reader = App.CancelableStdinReader.init(allocator, std.testing.io, std.Io.File.stdin());
    defer reader.deinit();

    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    try reader.processChunk("a\nbb\nccc", &line_buffer);
    try std.testing.expectEqual(@as(usize, 2), reader.lines.items.len);
    try std.testing.expectEqualStrings("a", reader.lines.items[0]);
    try std.testing.expectEqualStrings("bb", reader.lines.items[1]);
    try std.testing.expectEqualStrings("ccc", line_buffer.items);

    try reader.processChunk("DD\nE", &line_buffer);
    try std.testing.expectEqual(@as(usize, 3), reader.lines.items.len);
    try std.testing.expectEqualStrings("cccDD", reader.lines.items[2]);
    try std.testing.expectEqualStrings("E", line_buffer.items);

    try reader.flushPartialLine(&line_buffer);
    try std.testing.expectEqual(@as(usize, 4), reader.lines.items.len);
    try std.testing.expectEqualStrings("E", reader.lines.items[3]);
}

test "CancelableStdinReader.emitLine owns queued input" {
    const allocator = std.testing.allocator;
    var reader = App.CancelableStdinReader.init(allocator, std.testing.io, std.Io.File.stdin());
    defer reader.deinit();

    var transient: [16]u8 = undefined;
    @memcpy(transient[0..5], "hello");
    try reader.emitLine(transient[0..5]);

    @memcpy(transient[0..5], "WORLD");

    try std.testing.expectEqual(@as(usize, 1), reader.lines.items.len);
    try std.testing.expectEqualStrings("hello", reader.lines.items[0]);
}

test "CancelableStdinReader.flushPartialLine ignores empty buffer" {
    const allocator = std.testing.allocator;
    var reader = App.CancelableStdinReader.init(allocator, std.testing.io, std.Io.File.stdin());
    defer reader.deinit();

    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    try reader.flushPartialLine(&line_buffer);
    try std.testing.expectEqual(@as(usize, 0), reader.lines.items.len);
}

test "CancelableStdinReader reads complete input including final line without newline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input", .data = "one\ntwo\nfinal" });
    const file = try tmp.dir.openFile(std.testing.io, "input", .{});
    defer file.close(std.testing.io);

    var reader = App.CancelableStdinReader.init(std.testing.allocator, std.testing.io, file);
    reader.start();
    defer reader.deinit();
    try std.testing.expectEqual(App.CancelableStdinReader.Status.eof, try reader.future.await(std.testing.io));

    var lines = std.ArrayList([]u8).empty;
    defer {
        for (lines.items) |line| std.testing.allocator.free(line);
        lines.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(App.CancelableStdinReader.Status.eof, try reader.pollLines(&lines));
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("final", lines.items[2]);
}

test "CancelableStdinReader propagates read errors and iteration exhaustion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const write_only = try tmp.dir.createFile(std.testing.io, "write-only", .{ .read = false });
    defer write_only.close(std.testing.io);

    var failed = App.CancelableStdinReader.init(std.testing.allocator, std.testing.io, write_only);
    failed.start();
    defer failed.deinit();
    _ = failed.future.await(std.testing.io) catch {};
    var lines = std.ArrayList([]u8).empty;
    defer lines.deinit(std.testing.allocator);
    try std.testing.expectError(error.NotOpenForReading, failed.pollLines(&lines));

    var limited = App.CancelableStdinReader.initWithLimit(std.testing.allocator, std.testing.io, write_only, 0);
    limited.start();
    defer limited.deinit();
    try std.testing.expectError(error.StdinReadLimitExceeded, limited.future.await(std.testing.io));
    try std.testing.expectEqual(App.CancelableStdinReader.Status.failed, limited.status.load(.acquire));
}

test "CancelableStdinReader cancels while producer keeps pipe open" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", "printf 'line\\n'; sleep 30" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(std.testing.io);
    const source = child.stdout.?;

    var reader = App.CancelableStdinReader.init(std.testing.allocator, std.testing.io, source);
    reader.start();
    defer reader.deinit();
    reader.cancel();
    try std.testing.expectEqual(App.CancelableStdinReader.Status.canceled, reader.status.load(.acquire));
    try std.testing.expect(child.id != null);
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

test "TextureCache - empty has zero-length text" {
    const cache = TextureCache.empty;
    try std.testing.expectEqual(@as(usize, 0), cache.last_text_len);
    try std.testing.expectEqualStrings("", cache.lastText());
    try std.testing.expect(cache.texture == null);
}

test "TextureCache - setText / lastText round-trip" {
    var cache = TextureCache.empty;
    cache.setText("hello world");
    try std.testing.expectEqual(@as(usize, 11), cache.last_text_len);
    try std.testing.expectEqualStrings("hello world", cache.lastText());

    // Overwrite with shorter text — length tracking must shrink.
    cache.setText("hi");
    try std.testing.expectEqual(@as(usize, 2), cache.last_text_len);
    try std.testing.expectEqualStrings("hi", cache.lastText());

    // Overwrite with empty — back to zero.
    cache.setText("");
    try std.testing.expectEqual(@as(usize, 0), cache.last_text_len);
    try std.testing.expectEqualStrings("", cache.lastText());
}

test "TextureCache - max-size text fits exactly" {
    var cache = TextureCache.empty;
    var buf: [rendering_mod.max_cache_text_len]u8 = undefined;
    @memset(&buf, 'X');
    cache.setText(&buf);
    try std.testing.expectEqual(rendering_mod.max_cache_text_len, cache.last_text_len);
    try std.testing.expectEqualSlices(u8, &buf, cache.lastText());
}
