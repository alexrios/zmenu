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
const Search = @import("search.zig").Search;

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

    search: Search = .{},
    actions: std.ArrayList(Action) = .empty,
    action_cursor: usize = 0,
    actions_blocked: bool = false,
    results_dirty: bool = false,

    const Action = union(enum) {
        key: sdl.events.Keyboard,
        text: struct { bytes: [config.limits.max_input_length]u8, len: usize },
    };

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
        try font.setSize(config.font.size * metrics.scale);

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
        self.search.deinit(self.allocator);
        self.actions.deinit(self.allocator);
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
        var line_cursor: usize = 0;
        var read_status: CancelableStdinReader.Status = .reading;
        defer {
            for (new_lines.items[line_cursor..]) |line| self.allocator.free(line);
            new_lines.deinit(self.allocator);
        }

        // Initial render (shows loading screen)
        try self.render();
        self.state.needs_render = false;

        var running = true;
        while (running) {
            if (!self.actions_blocked) {
                if (new_lines.items.len == 0) read_status = try stdin_reader.pollLines(&new_lines);
                try self.processNewLines(&new_lines, &line_cursor);
                if (read_status == .eof and new_lines.items.len == 0 and self.state.input_state == .loading) {
                    try self.handleEofTransition();
                }
            }
            try self.processSearchSlice();
            if (sdl.events.waitTimeout(if (new_lines.items.len > 0 or self.search.pending or self.actions.items.len > 0) 0 else 16)) {
                running = try self.processEvents();
            }
            if (running) running = try self.processActions();

            if (!running) stdin_reader.cancel();

            if (self.state.needs_render) {
                try self.render();
                self.state.needs_render = false;
            }
        }
    }

    pub fn checkThemes(self: *App) !void {
        try self.processLine("First result|/home/alexrios/first.txt");
        try self.processLine("Selected result|/home/alexrios/selected.txt");
        try self.processLine("Third result|/home/alexrios/third.txt");
        try self.handleEofTransition();
        self.navigate(1);
        for ([_][]const u8{ "latte", "mocha", "frappe", "macchiato", "dracula", "gruvbox", "nord", "solarized" }) |name| {
            const theme = config.theme.getByName(name);
            self.color_scheme = .{ .background = theme.background, .foreground = theme.foreground, .selected = theme.selected, .prompt = theme.prompt, .value_preview = theme.value_preview };
            try self.drawFrame();
            try self.saveFrame(1, name);
        }
    }

    pub fn checkCache(self: *App) !void {
        for (0..200) |i| {
            var line: [128]u8 = undefined;
            try self.processLine(try std.fmt.bufPrint(&line, "row-{d}|preview-{d}", .{ i, i }));
        }
        try self.render();
        const first = self.render_ctx.textures_created;
        try self.render();
        // Only the uncached scroll indicator is recreated on an identical frame.
        if (self.render_ctx.textures_created != first + 1) return error.RowsWereNotCached;
        self.navigate(1);
        try self.render();
        if (self.render_ctx.textures_created != first + 6) return error.SelectionRebuiltUnchangedRows;
        for (0..100) |_| {
            self.navigate(1);
            try self.render();
            if (self.render_ctx.rows.items.len > self.visibleRows()) return error.UnboundedRowCache;
        }
        const old = self.render_ctx.textures_created;
        try self.sdl.font.setSize(config.font.size + 2);
        try self.render();
        if (self.render_ctx.textures_created <= old + 1) return error.FontChangeDidNotInvalidate;
        const generation = try self.sdl.font.getGeneration();
        for (self.render_ctx.rows.items) |row| {
            if (row.display.font_generation != generation) return error.StaleFontTexture;
        }
        try self.handleTextInput("no-such-item");
        try self.finishSearch();
        try self.render();
        if (self.render_ctx.rows.items.len != 0) return error.InvisibleRowsRetained;
    }

    fn pushText(text: [:0]const u8) !void {
        try sdl.events.push(.{ .text_input = .{ .common = std.mem.zeroes(sdl.events.Common), .text = text } });
    }

    fn pushKey(key: sdl.keycode.Keycode, ctrl: bool) !void {
        var event = std.mem.zeroes(sdl.events.Keyboard);
        event.key = key;
        event.mod.left_control = ctrl;
        try sdl.events.push(.{ .key_down = event });
    }

    pub fn checkIncremental(self: *App) !void {
        try self.processLine("alpha|duplicate");
        try self.processLine("bravo|duplicate");
        try self.processLine("alps|duplicate");
        self.navigateToLast();
        try self.handleTextInput("al");
        try self.finishSearch();
        if (self.selectedItemId() != 2) return error.DuplicateIdentityLost;
        self.state.input_buffer.clearRetainingCapacity();
        try self.updateFilter();
        try self.finishSearch();
        self.navigateToFirst();
        try pushText("a");
        try pushKey(.down, false);
        try pushText("l");
        _ = try self.processEvents();
        _ = try self.processActions();
        if (!self.actions_blocked) return error.NavigationCrossedSearch;
        while (self.search.pending or self.actions.items.len > 0) {
            try self.processSearchSlice();
            _ = try self.processActions();
        }
        if (self.selectedItemId() != 0) return error.EditsCrossedNavigation;
        if (self.state.input_state != .loading) return error.ExpectedPartialResults;
        try self.handleTextInput("zzzz");
        try pushKey(.return_key, false);
        _ = try self.processEvents();
        if (!try self.processActions()) return error.StaleResultConfirmed;
        try pushKey(.escape, false);
        if (try self.processEvents()) return error.EscapeWasDeferred;
        if (!self.search.pending) return error.EscapeWaitedForSearch;
    }

    fn streamDriver(io: std.Io) !void {
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
        try pushText("zzzz");
        try pushKey(.return_key, false);
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        try pushKey(.u, true);
        try pushText("beta");
        try pushKey(.return_key, false);
    }

    pub fn checkStream(self: *App) !void {
        var driver = self.io.async(streamDriver, .{self.io});
        defer driver.cancel(self.io) catch {};
        try self.run();
        if (self.state.input_state != .loading) return error.ConfirmationWaitedForEof;
    }

    /// Offscreen layout acceptance at explicit physical pixel scales.
    pub fn checkLayout(self: *App, scale: f32) !void {
        const target = try self.sdl.renderer.createTexture(.array_rgba_32, .target, @intFromFloat(800 * scale), @intFromFloat(300 * scale));
        defer target.deinit();
        try self.sdl.renderer.setTarget(target);
        defer self.sdl.renderer.setTarget(null) catch {};
        self.render_ctx.window.current_width = 800;
        self.render_ctx.window.current_height = 300;
        self.render_ctx.window.display_scale = scale;
        try self.sdl.font.setSize(config.font.size * scale);
        try self.drawFrame();
        try self.saveFrame(scale, "loading");
        for (0..50) |i| {
            var line: [1024]u8 = undefined;
            const text = try std.fmt.bufPrint(&line, "/projects/a-very-long-directory-name/another-long-directory/café/component/{d}/important-final-filename.txt|/home/alexrios/very/long/path/to/preview-file-{d}.txt", .{ i, i });
            try self.processLine(text);
        }
        try self.drawFrame();
        try self.saveFrame(scale, "partial");
        try self.handleEofTransition();
        try self.drawFrame();
        try self.saveFrame(scale, "items");
        self.navigatePage(1);
        if (self.state.selected_index != self.visibleRows()) return error.IncorrectPageSize;
        try self.drawFrame();
        try self.saveFrame(scale, "page");
        try self.handleTextInput("a query with no matches that keeps extending until the visible prompt must show its newest characters: café 日本語 END-OF-QUERY");
        try self.finishSearch();
        if (self.render_ctx.window.current_height != 300 or self.render_ctx.window.current_width != 800) return error.UnstableViewport;
        try self.drawFrame();
        try self.saveFrame(scale, "query");
    }

    fn saveFrame(self: *App, scale: f32, scene: []const u8) !void {
        var path: [128]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&path, "benchmarks/visual/{d}-{s}.bmp", .{ @as(u32, @intFromFloat(scale * 100)), scene });
        const surface = try self.sdl.renderer.readPixels(null);
        defer surface.deinit();
        try surface.saveBmpFile(name);
    }

    pub fn checkEmptyConfirmation(self: *App) !void {
        try self.processLine("alpha|confirmed-value");
        try self.handleEofTransition();
        try self.handleTextInput("zzzz");
        try self.finishSearch();
        var event = std.mem.zeroes(sdl.events.Keyboard);
        event.key = .return_key;
        if (try self.handleKeyEvent(event)) return error.EmptyConfirmationClosedMenu;
        event.key = .u;
        event.mod.left_control = true;
        _ = try self.handleKeyEvent(event);
        try self.finishSearch();
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
        try self.benchmarkSearch();
        reportTiming("search_empty", start);
        start = sdl.timer.getPerformanceCounter();
        try self.handleTextInput("cpt99");
        try self.benchmarkSearch();
        reportTiming("search_fuzzy", start);
        start = sdl.timer.getPerformanceCounter();
        try self.handleTextInput("9");
        try self.benchmarkSearch();
        reportTiming("search_extension", start);
        std.debug.print("BENCH candidates_examined {d}\n", .{self.search.inspected});
        self.state.input_buffer.clearRetainingCapacity();
        try self.updateFilter();
        try self.benchmarkSearch();
        const history = @import("features/history.zig");
        const hist = try history.HistoryState.loadWithConfig(self.allocator, self.io, null, "/nonexistent/zmenu-benchmark-history", 100);
        defer hist.deinit();
        for (0..100) |i| hist.addEntry(self.state.items.items[count - 1 - i].display);
        start = sdl.timer.getPerformanceCounter();
        history.feature.hooks.afterFilter.?(hist, &self.state.filtered_items, self.state.items.items);
        reportTiming("history", start);
        self.render_ctx.textures_created = 0;
        for (0..20) |_| {
            start = sdl.timer.getPerformanceCounter();
            self.navigate(1);
            try self.render();
            reportTiming("render_navigation", start);
        }
        std.debug.print("BENCH textures_created {d}\n", .{self.render_ctx.textures_created});
        try self.benchmarkEvents();
    }

    /// SDL event-to-present timings, separate from internal matching time.
    /// Injection starts at SDL's queue, excluding physical keyboard latency.
    fn benchmarkEvents(self: *App) !void {
        for (0..20) |i| {
            const start = sdl.timer.getPerformanceCounter();
            try pushKey(.u, true);
            try pushText(if (i % 2 == 0) "cpt99" else "zzzzzz");
            var first_frame = true;
            while (true) {
                try self.processSearchSlice();
                if (sdl.events.waitTimeout(0)) {
                    if (!try self.processEvents()) return error.UnexpectedBenchmarkQuit;
                }
                if (!try self.processActions()) return error.UnexpectedBenchmarkConfirmation;
                if (self.state.needs_render) {
                    try self.render();
                    self.state.needs_render = false;
                    if (first_frame) {
                        reportTiming("input_first_frame", start);
                        first_frame = false;
                    }
                }
                if (!self.search.pending and self.actions.items.len == 0) break;
            }
            reportTiming("input_results_frame", start);
        }
        for (0..20) |_| {
            self.state.input_buffer.clearRetainingCapacity();
            try self.updateFilter();
            try self.processSearchSlice();
            const start = sdl.timer.getPerformanceCounter();
            try pushKey(.escape, false);
            var escaped = false;
            for (0..max_events_per_tick) |_| {
                if (sdl.events.waitTimeout(1) and !try self.processEvents()) {
                    escaped = true;
                    break;
                }
            }
            if (!escaped) return error.EscapeWasDeferred;
            reportTiming("escape_dispatch", start);
            self.search.pending = false;
        }
    }

    fn benchmarkSearch(self: *App) !void {
        while (self.search.pending) {
            const start = sdl.timer.getPerformanceCounter();
            try self.processSearchSlice();
            reportTiming("search_slice", start);
        }
    }

    fn reportTiming(label: []const u8, start: u64) void {
        const ms = @as(f64, @floatFromInt(sdl.timer.getPerformanceCounter() - start)) * 1000 / @as(f64, @floatFromInt(sdl.timer.getPerformanceFrequency()));
        std.debug.print("BENCH {s} {d:.3}\n", .{ label, ms });
    }

    fn sliceExpired(start: u64) bool {
        return sdl.timer.getPerformanceCounter() - start >= sdl.timer.getPerformanceFrequency() / 250;
    }

    fn processNewLines(self: *App, new_lines: *std.ArrayList([]u8), cursor: *usize) !void {
        if (new_lines.items.len == 0) return;
        const start = sdl.timer.getPerformanceCounter();
        while (cursor.* < new_lines.items.len) {
            const line = new_lines.items[cursor.*];
            cursor.* += 1; // processOwnedLine consumes ownership even on error.
            try self.processOwnedLine(line);
            if (sliceExpired(start)) break;
        }
        if (cursor.* == new_lines.items.len) {
            new_lines.clearRetainingCapacity();
            cursor.* = 0;
        }
        if (!self.search.pending and self.results_dirty) self.orderResults();
        self.state.needs_render = true;
    }

    fn handleEofTransition(self: *App) !void {
        std.debug.assert(self.state.input_state == .loading);
        self.state.input_state = .ready;

        if (self.state.items.items.len == 0) {
            std.debug.print("Error: No items provided on stdin\n", .{});
            return error.NoItemsProvided;
        }

        if (!self.search.pending and self.results_dirty) self.orderResults();
        self.state.needs_render = true;

        // Post: one-way transition complete; filter reflects the now-final set.
        std.debug.assert(self.state.input_state == .ready);
        std.debug.assert(self.state.filtered_items.items.len <= self.state.items.items.len);
    }

    /// SDL events are copied into a bounded action queue. Escape bypasses
    /// pending search/navigation barriers; text lifetime never escapes SDL.
    fn processEvents(self: *App) !bool {
        for (0..max_events_per_tick) |_| {
            if (self.actions.items.len - self.action_cursor >= max_events_per_tick) break;
            const event = sdl.events.poll() orelse break;
            switch (event) {
                .quit, .terminating => return false,
                .key_down => |key| {
                    if (key.key == .escape or (key.key == .c and (key.mod.left_control or key.mod.right_control))) return false;
                    try self.queueAction(.{ .key = key });
                },
                .text_input => |text| {
                    if (text.text.len > config.limits.max_input_length) continue;
                    var action: Action = .{ .text = .{ .bytes = undefined, .len = text.text.len } };
                    @memcpy(action.text.bytes[0..text.text.len], text.text);
                    try self.queueAction(action);
                },
                .window_display_scale_changed, .window_pixel_size_changed => try self.updateDisplayScale(),
                else => {},
            }
        }
        return true;
    }

    fn queueAction(self: *App, action: Action) !void {
        if (self.action_cursor > 0 and self.actions.items.len == max_events_per_tick) {
            const remaining = self.actions.items.len - self.action_cursor;
            std.mem.copyForwards(Action, self.actions.items[0..remaining], self.actions.items[self.action_cursor..]);
            self.actions.shrinkRetainingCapacity(remaining);
            self.action_cursor = 0;
        }
        try self.actions.append(self.allocator, action);
    }

    fn isSearchBarrier(event: sdl.events.Keyboard) bool {
        const key = event.key orelse return false;
        return switch (key) {
            .return_key, .kp_enter, .up, .down, .j, .k, .tab, .home, .end, .page_up, .page_down => true,
            else => false,
        };
    }

    fn processActions(self: *App) !bool {
        self.actions_blocked = false;
        while (self.action_cursor < self.actions.items.len) {
            const action = &self.actions.items[self.action_cursor];
            switch (action.*) {
                .key => |key| {
                    if (isSearchBarrier(key) and self.search.pending) {
                        // Stop ingestion until this query finishes, so a fast
                        // producer cannot indefinitely postpone navigation/Enter.
                        self.actions_blocked = true;
                        return true;
                    }
                    if (try self.handleKeyEvent(key)) return false;
                },
                .text => |*text| try self.handleTextInput(text.bytes[0..text.len]),
            }
            self.action_cursor += 1;
        }
        self.actions.clearRetainingCapacity();
        self.action_cursor = 0;
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
        space_available: std.Io.Condition = .init,
        queue_bytes: usize = 0,
        significant_len: usize = 0,
        line_started: bool = false,

        pub const max_queue_bytes = 4 * 1024 * 1024;
        pub const max_queue_lines = 4096;

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

        /// Wait for bounded queue space; cancellation interrupts this wait.
        fn emitLine(self: *CancelableStdinReader, line: []const u8) !void {
            std.debug.assert(line.len <= config.limits.max_item_length);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.lines.items.len >= max_queue_lines or self.queue_bytes + line.len > max_queue_bytes) {
                try self.space_available.wait(self.io, &self.mutex);
            }
            const owned = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(owned);
            try self.lines.append(self.allocator, owned);
            self.queue_bytes += line.len;
        }

        /// Trim before truncation, retaining only a bounded prefix plus UTF-8
        /// lookahead. significant_len tracks non-whitespace even past the cap.
        fn processChunk(self: *CancelableStdinReader, chunk: []const u8, line_buffer: *std.ArrayList(u8)) !void {
            for (chunk) |byte| {
                if (byte == '\n') {
                    try self.flushPartialLine(line_buffer);
                    line_buffer.clearRetainingCapacity();
                    self.significant_len = 0;
                    self.line_started = false;
                    continue;
                }
                const whitespace = std.ascii.isWhitespace(byte);
                if (!self.line_started and whitespace) continue;
                self.line_started = true;
                if (line_buffer.items.len < config.limits.max_item_length + 4) {
                    try line_buffer.append(self.allocator, byte);
                }
                if (!whitespace) self.significant_len = line_buffer.items.len;
            }
        }

        fn flushPartialLine(self: *CancelableStdinReader, line_buffer: *std.ArrayList(u8)) !void {
            if (self.significant_len == 0) return;
            const trimmed = line_buffer.items[0..self.significant_len];
            const length = input.findUtf8Boundary(trimmed, config.limits.max_item_length);
            try self.emitLine(trimmed[0..length]);
        }

        fn readTask(self: *CancelableStdinReader) anyerror!Status {
            var chunk_buffer: [4096]u8 = undefined;
            var line_buffer = std.ArrayList(u8).empty;
            defer line_buffer.deinit(self.allocator);

            for (0..self.max_iterations) |_| {
                const bytes_read = self.file.readStreaming(self.io, &.{&chunk_buffer}) catch |err| switch (err) {
                    error.EndOfStream => {
                        self.flushPartialLine(&line_buffer) catch |flush_err| {
                            self.status.store(if (flush_err == error.Canceled) .canceled else .failed, .release);
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
                    self.status.store(if (err == error.Canceled) .canceled else .failed, .release);
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

            // Swap only into an exhausted consumer batch. Each side retains a
            // bounded allocation; the final item collection is not bounded.
            std.debug.assert(dest.items.len == 0);
            std.mem.swap(std.ArrayList([]u8), dest, &self.lines);
            self.queue_bytes = 0;
            self.space_available.signal(self.io);

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

    // Benchmark/test adapter for borrowed lines. Production transfers ownership.
    fn processLine(self: *App, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        const length = input.findUtf8Boundary(trimmed, config.limits.max_item_length);
        try self.processOwnedLine(try self.allocator.dupe(u8, trimmed[0..length]));
    }

    /// Always consumes the line, including empty input and allocation failures.
    fn processOwnedLine(self: *App, line: []u8) !void {
        if (line.len == 0) {
            self.allocator.free(line);
            return;
        }
        const item = types.Item.fromOwned(line);
        self.state.items.append(self.allocator, item) catch |err| {
            item.deinit(self.allocator);
            return err;
        };
        if (self.state.input_state == .loading) self.state.input_state.loading.items_loaded += 1;
        try self.search.append(self.allocator, self.state.items.items, &self.state.filtered_items);
        self.results_dirty = true;
    }

    fn selectedItemId(self: *const App) ?usize {
        if (self.state.selected_index >= self.state.filtered_items.items.len) return null;
        return self.state.filtered_items.items[self.state.selected_index];
    }

    fn updateFilter(self: *App) !void {
        self.search.begin(self.state.input_buffer.items, config.features.match_mode, self.selectedItemId());
        self.state.needs_render = true;
    }

    fn orderResults(self: *App) void {
        const selected = self.selectedItemId();
        features.callAfterFilter(&self.feature_states, &self.state.filtered_items, self.state.items.items);
        self.state.selected_index = 0;
        if (selected) |id| {
            for (self.state.filtered_items.items, 0..) |candidate, i| {
                if (candidate == id) {
                    self.state.selected_index = i;
                    break;
                }
            }
        }
        self.results_dirty = false;
        self.adjustScroll();
    }

    fn processSearchSlice(self: *App) !void {
        if (!self.search.pending) return;
        const start = sdl.timer.getPerformanceCounter();
        while (self.search.pending) {
            if (try self.search.step(self.allocator, self.state.items.items, &self.state.filtered_items)) {
                self.state.selected_index = self.search.selected_result;
                self.orderResults();
                self.state.needs_render = true;
                return;
            }
            if (sliceExpired(start)) return;
        }
    }

    fn finishSearch(self: *App) !void {
        while (self.search.pending) try self.processSearchSlice();
    }

    fn adjustScroll(self: *App) void {
        const filtered_len = self.state.filtered_items.items.len;
        if (filtered_len == 0) {
            self.state.scroll_offset = 0;
            return;
        }
        std.debug.assert(self.state.selected_index < filtered_len);

        // Clamp scroll_offset when filtered list shrinks below previous range
        const max_scroll = if (filtered_len > self.visibleRows())
            filtered_len - self.visibleRows()
        else
            0;
        if (self.state.scroll_offset > max_scroll) {
            self.state.scroll_offset = max_scroll;
        }

        if (self.state.selected_index < self.state.scroll_offset) {
            self.state.scroll_offset = self.state.selected_index;
        } else if (self.state.selected_index >= self.state.scroll_offset + self.visibleRows()) {
            self.state.scroll_offset = self.state.selected_index - self.visibleRows() + 1;
        }

        // Post: the selected row is inside the visible window.
        std.debug.assert(self.state.scroll_offset <= self.state.selected_index);
        std.debug.assert(self.state.selected_index < self.state.scroll_offset + self.visibleRows());
    }

    fn navigate(self: *App, delta: isize) void {
        if (self.state.filtered_items.items.len == 0) return;
        std.debug.assert(self.state.selected_index < self.state.filtered_items.items.len);

        const current = @as(isize, @intCast(self.state.selected_index));
        const new_idx = std.math.clamp(current + delta, 0, @as(isize, @intCast(self.state.filtered_items.items.len)) - 1);

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
        const page_size = @as(isize, @intCast(self.visibleRows()));
        self.navigate(page_size * direction);
    }

    fn handleKeyEvent(self: *App, event: sdl.events.Keyboard) !bool {
        const key = event.key orelse return false;
        const ctrl = event.mod.left_control or event.mod.right_control;
        const shift = event.mod.left_shift or event.mod.right_shift;

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
        try self.sdl.font.setSize(config.font.size * self.render_ctx.window.display_scale);
        self.render_ctx.prompt_cache.deinit();
        self.render_ctx.count_cache.deinit();
        self.render_ctx.no_match_cache.deinit();
        self.render_ctx.invalidateRows();
        const w_width, const w_height = try self.sdl.window.getSizeInPixels();

        if (w_width > std.math.maxInt(u32) or w_height > std.math.maxInt(u32)) {
            return error.DisplayTooLarge;
        }

        self.render_ctx.window.width = @intCast(w_width);
        self.render_ctx.window.height = @intCast(w_height);
        const logical_w, const logical_h = try self.sdl.window.getSize();
        self.render_ctx.window.current_width = @intCast(logical_w);
        self.render_ctx.window.current_height = @intCast(logical_h);
        self.adjustScroll();
        self.state.needs_render = true;
    }

    fn lineHeight(self: *App) f32 {
        return @max(config.layout.item_line_height, @as(f32, @floatFromInt(self.sdl.font.getHeight())) / self.render_ctx.window.display_scale);
    }

    fn visibleRows(self: *App) usize {
        return rendering_mod.visibleRows(self.render_ctx.window.current_height, self.lineHeight());
    }

    fn footerY(self: *App) f32 {
        return @as(f32, @floatFromInt(self.render_ctx.window.current_height)) - self.lineHeight() - config.layout.bottom_margin;
    }

    fn updateWindowSize(self: *App) !void {
        const active_display = self.target_display orelse try self.sdl.window.getDisplayForWindow();
        const bounds = try active_display.getUsableBounds();
        const new_width = @min(config.window.initial_width, @as(u32, @intCast(@max(1, bounds.w))));
        const new_height = @min(config.window.initial_height, @as(u32, @intCast(@max(1, bounds.h))));

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
        try self.drawFrame();
        try self.sdl.renderer.present();
    }

    fn drawFrame(self: *App) !void {
        try self.renderClear();
        const scale = self.render_ctx.window.display_scale;

        try self.renderPromptLine(scale);
        try self.renderCounter(scale);
        try self.renderItemList(scale);
    }

    /// Fill the framebuffer with the configured background color.
    fn renderClear(self: *App) !void {
        try self.sdl.renderer.setDrawColor(self.color_scheme.background);
        try self.sdl.renderer.clear();
    }

    /// Render the prompt line: "> " followed by the user's input (with leading
    /// ellipsis if the input exceeds the visible threshold). UTF-8 safe.
    fn renderPromptLine(self: *App, scale: f32) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(config.limits.input_ellipsis_margin < config.limits.max_input_length);

        const width = (@as(f32, @floatFromInt(self.render_ctx.window.current_width)) - 10) * scale;
        const prompt_text = try rendering_mod.fitText(self.sdl.font, self.render_ctx.prompt_buffer, "> ", self.state.input_buffer.items, width, .tail);

        try self.renderCachedText(5.0 * scale, config.layout.prompt_y * scale, prompt_text, self.color_scheme.prompt, &self.render_ctx.prompt_cache);
    }

    /// Render the "filtered/total" match counter on the right side of the prompt row.
    fn renderCounter(self: *App, scale: f32) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(self.state.filtered_items.items.len <= self.state.items.items.len);

        const count_text = std.fmt.bufPrintZ(
            self.render_ctx.count_buffer,
            "{s}{d}/{d}",
            .{ if (self.search.pending) (if (self.state.input_state == .loading) "Reading / searching... " else "Searching... ") else if (self.state.input_state == .loading) "Reading... " else "", self.state.filtered_items.items.len, self.state.items.items.len },
        ) catch "?/?";

        try self.renderCachedText(5.0 * scale, self.footerY() * scale, count_text, self.color_scheme.foreground, &self.render_ctx.count_cache);
    }

    /// Render the filtered item list (or the empty-state message), plus the
    /// scroll indicator when the list overflows the visible window.
    fn renderItemList(self: *App, scale: f32) !void {
        std.debug.assert(scale > 0.0);

        const filtered_len = self.state.filtered_items.items.len;
        if (filtered_len == 0) {
            try self.render_ctx.prepareRows(self.allocator, &.{});
            try self.renderEmptyState(scale);
            return;
        }

        const visible_end = @min(self.state.scroll_offset + self.visibleRows(), filtered_len);
        std.debug.assert(visible_end <= filtered_len);
        std.debug.assert(self.state.scroll_offset <= visible_end);
        try self.render_ctx.prepareRows(self.allocator, self.state.filtered_items.items[self.state.scroll_offset..visible_end]);

        var y_pos: f32 = config.layout.items_start_y * scale;
        for (self.state.scroll_offset..visible_end) |i| {
            if (i >= filtered_len) break;

            const item_index = self.state.filtered_items.items[i];
            if (item_index >= self.state.items.items.len) continue;

            const item = self.state.items.items[item_index];
            const is_selected = (i == self.state.selected_index);
            try self.renderItem(scale, y_pos, item, is_selected, self.render_ctx.rowFor(item_index));
            y_pos += self.lineHeight() * scale;
        }

        if (filtered_len > self.visibleRows()) {
            try self.renderScrollIndicator(scale, visible_end);
        }
    }

    /// Render a single item row: prefix ("> " when selected, "  " otherwise),
    /// display text, and optional dimmed value-preview.
    fn renderItem(self: *App, scale: f32, y_pos: f32, item: types.Item, is_selected: bool, cache: *rendering_mod.RowCache) !void {
        std.debug.assert(scale > 0.0);
        std.debug.assert(y_pos >= 0.0);

        const prefix = if (is_selected) "> " else "  ";
        const width = (@as(f32, @floatFromInt(self.render_ctx.window.current_width)) - 10) * scale;
        const preview = config.multivalue.show_preview and item.value.ptr != item.display.ptr and item.value.len > 0;
        const display_budget = if (preview) width * 0.65 else width;
        const display_text = try rendering_mod.fitText(self.sdl.font, self.render_ctx.item_buffer, prefix, item.display, display_budget, .middle);
        if (is_selected) {
            try self.sdl.renderer.setDrawColor(self.color_scheme.selected);
            try self.sdl.renderer.renderFillRect(.{
                .x = 0,
                .y = y_pos,
                .w = @as(f32, @floatFromInt(self.render_ctx.window.current_width)) * scale,
                .h = self.lineHeight() * scale,
            });
        }
        const display_color = if (is_selected) self.color_scheme.background else self.color_scheme.foreground;
        try self.renderCachedText(5.0 * scale, y_pos, display_text, display_color, &cache.display);

        if (preview) {
            const display_w, _ = try self.sdl.font.getStringSize(display_text);
            const value_x = 5.0 * scale + @as(f32, @floatFromInt(display_w)) + config.multivalue.preview_spacing * scale;
            const preview_buffer = self.render_ctx.value_preview_buffer[0..if (config.multivalue.preview_max_length > 0) @min(self.render_ctx.value_preview_buffer.len, config.multivalue.preview_max_length + 4) else self.render_ctx.value_preview_buffer.len];
            const preview_text = try rendering_mod.fitText(self.sdl.font, preview_buffer, "", item.value, @max(0, width - (value_x - 5.0 * scale)), .middle);
            try self.renderCachedText(value_x, y_pos, preview_text, if (is_selected) self.color_scheme.background else self.color_scheme.value_preview, &cache.preview);
        } else cache.preview.deinit();
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
        const scroll_x = (@as(f32, @floatFromInt(self.render_ctx.window.current_width)) - config.layout.width_padding) * scale - @as(f32, @floatFromInt(scroll_text_w));
        try self.renderText(scroll_x, self.footerY() * scale, scroll_text, self.color_scheme.foreground);
    }

    fn renderText(self: *App, x: f32, y: f32, text: [:0]const u8, color: sdl.pixels.Color) !void {
        const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
        defer surface.deinit();

        const texture = try self.sdl.renderer.createTextureFromSurface(surface);
        self.render_ctx.textures_created += 1;
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

        if (text.len == 0) {
            cache.deinit();
            return;
        }
        const font_id = @intFromPtr(self.sdl.font.value);
        const generation = try self.sdl.font.getGeneration();
        const font_changed = cache.font_id != font_id or cache.font_generation != generation;
        const scale_changed = cache.scale != self.render_ctx.window.display_scale;
        const text_changed = !std.mem.eql(u8, cache.lastText(), text);
        const color_changed = !rendering_mod.colorEquals(cache.last_color, color);

        if (text_changed or color_changed or font_changed or scale_changed or cache.texture == null) {
            // Build the new texture before mutating cache state — if the SDL
            // call fails, the cache stays consistent with the previous frame.
            const ttf_color = sdl.ttf.Color{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
            const surface = try self.sdl.font.renderTextBlended(text, ttf_color);
            defer surface.deinit();
            const new_texture = try self.sdl.renderer.createTextureFromSurface(surface);
            self.render_ctx.textures_created += 1;

            if (cache.texture) |old_tex| old_tex.deinit();
            cache.setText(text);
            cache.last_color = color;
            cache.font_id = font_id;
            cache.font_generation = generation;
            cache.scale = self.render_ctx.window.display_scale;
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
    const read_error = if (@import("builtin").os.tag == .windows) error.AccessDenied else error.NotOpenForReading;
    try std.testing.expectError(read_error, failed.pollLines(&lines));

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

test "stdin normalization matches trim then UTF-8 truncation across chunks" {
    const allocator = std.testing.allocator;
    var reader = App.CancelableStdinReader.init(allocator, std.testing.io, std.Io.File.stdin());
    defer reader.deinit();
    var partial = std.ArrayList(u8).empty;
    defer partial.deinit(allocator);
    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, " \t");
    try source.appendNTimes(allocator, 'a', config.limits.max_item_length - 1);
    try source.appendSlice(allocator, "日本語  \r\n  display|value|extra \t\n\n \t\nfinal");
    var offset: usize = 0;
    while (offset < source.items.len) {
        const end = @min(offset + 7, source.items.len);
        try reader.processChunk(source.items[offset..end], &partial);
        try std.testing.expect(partial.items.len <= config.limits.max_item_length + 4);
        offset = end;
    }
    try reader.flushPartialLine(&partial);
    try std.testing.expectEqual(@as(usize, 3), reader.lines.items.len);
    try std.testing.expectEqual(config.limits.max_item_length - 1, reader.lines.items[0].len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(reader.lines.items[0]));
    try std.testing.expectEqualStrings("display|value|extra", reader.lines.items[1]);
    try std.testing.expectEqualStrings("final", reader.lines.items[2]);
}

test "stdin preserves whitespace at truncation boundary when later text exists" {
    var reader = App.CancelableStdinReader.init(std.testing.allocator, std.testing.io, std.Io.File.stdin());
    defer reader.deinit();
    var partial = std.ArrayList(u8).empty;
    defer partial.deinit(std.testing.allocator);
    var text: [config.limits.max_item_length + 100]u8 = undefined;
    @memset(&text, ' ');
    text[0] = 'a';
    text[text.len - 1] = 'b';
    try reader.processChunk(&text, &partial);
    try reader.flushPartialLine(&partial);
    try std.testing.expectEqual(config.limits.max_item_length, reader.lines.items[0].len);
    try std.testing.expectEqual(@as(u8, ' '), reader.lines.items[0][config.limits.max_item_length - 1]);
}

fn checkIngestionAllocationFailures(allocator: std.mem.Allocator) !void {
    var reader = App.CancelableStdinReader.init(allocator, std.testing.io, std.Io.File.stdin());
    defer reader.deinit();
    var partial = std.ArrayList(u8).empty;
    defer partial.deinit(allocator);
    try reader.processChunk(" alpha|value \nsecond\n", &partial);
    var lines = std.ArrayList([]u8).empty;
    var cursor: usize = 0;
    defer {
        for (lines.items[cursor..]) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    _ = try reader.pollLines(&lines);
    var app: App = undefined;
    app.state = AppState.empty;
    app.search = .{};
    app.results_dirty = false;
    app.allocator = allocator;
    defer {
        for (app.state.items.items) |item| item.deinit(allocator);
        app.state.items.deinit(allocator);
        app.state.filtered_items.deinit(allocator);
        app.search.deinit(allocator);
    }
    while (cursor < lines.items.len) {
        const line = lines.items[cursor];
        cursor += 1;
        try app.processOwnedLine(line);
    }
    try std.testing.expectEqualStrings("value", app.state.items.items[0].value);
}

test "stdin ownership is leak free at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkIngestionAllocationFailures, .{});
}

test "stdin byte bound blocks below the line limit and accepts cancellation" {
    const io = std.testing.io;
    var reader = App.CancelableStdinReader.init(std.testing.allocator, io, std.Io.File.stdin());
    defer reader.deinit();
    var line: [4096]u8 = undefined;
    @memset(&line, 'x');
    for (0..1024) |_| try reader.emitLine(&line);
    try std.testing.expectEqual(App.CancelableStdinReader.max_queue_bytes, reader.queue_bytes);
    try std.testing.expect(reader.lines.items.len < App.CancelableStdinReader.max_queue_lines);
    var future = io.async(App.CancelableStdinReader.emitLine, .{ &reader, &line });
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expectEqual(@as(usize, 1024), reader.lines.items.len);
}

test "stdin cancels a full line queue while producer keeps its pipe open" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "i=0; while [ \"$i\" -lt 5000 ]; do printf 'line\\n'; i=$((i+1)); done; exec sleep 30" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var reader = App.CancelableStdinReader.init(std.testing.allocator, io, child.stdout.?);
    reader.start();
    defer reader.deinit();
    var full = false;
    for (0..2000) |_| {
        reader.mutex.lockUncancelable(io);
        full = reader.lines.items.len == App.CancelableStdinReader.max_queue_lines;
        reader.mutex.unlock(io);
        if (full) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(full);
    reader.cancel();
    try std.testing.expectEqual(App.CancelableStdinReader.Status.canceled, reader.status.load(.acquire));
    try std.testing.expect(child.id != null);
}

test "stdin bounded batch swaps preserve order without loss or duplication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);
    for (0..10000) |i| {
        var line: [32]u8 = undefined;
        try data.appendSlice(allocator, try std.fmt.bufPrint(&line, "{d}\n", .{i}));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "items", .data = data.items });
    const file = try tmp.dir.openFile(io, "items", .{});
    defer file.close(io);
    var reader = App.CancelableStdinReader.init(allocator, io, file);
    reader.start();
    defer reader.deinit();
    var lines = std.ArrayList([]u8).empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    var expected: usize = 0;
    for (0..10000) |_| {
        const status = try reader.pollLines(&lines);
        try std.testing.expect(lines.items.len <= App.CancelableStdinReader.max_queue_lines);
        for (lines.items) |line| {
            try std.testing.expectEqual(expected, try std.fmt.parseInt(usize, line, 10));
            expected += 1;
        }
        for (lines.items) |line| allocator.free(line);
        lines.clearRetainingCapacity();
        if (status == .eof) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 10000), expected);
}
