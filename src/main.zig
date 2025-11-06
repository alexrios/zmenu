const std = @import("std");
const sdl = @import("sdl3");
const builtin = @import("builtin");
const theme = @import("theme.zig");
const syntax_mod = @import("syntax");
const font_mod = @import("font.zig");
const preview_mod = @import("preview.zig");
const syntax_highlight = @import("syntax_highlight.zig");

const WindowConfig = struct {
    initial_width: u32 = 800,
    initial_height: u32 = 300,
    min_width: u32 = 600,
    min_height: u32 = 150,
    max_width: u32 = 1600,
    max_height: u32 = 800,
    enable_high_dpi: bool = true, // Request high pixel density when available
};

const ColorScheme = struct {
    background: sdl.pixels.Color = theme.default.background,
    foreground: sdl.pixels.Color = theme.default.foreground,
    selected: sdl.pixels.Color = theme.default.selected,
    prompt: sdl.pixels.Color = theme.default.prompt,
};

const Limits = struct {
    max_visible_items: usize = 30,
    max_item_length: usize = 4096,
    max_input_length: usize = 1024,
    input_ellipsis_margin: usize = 100, // Show ellipsis when input within this margin of max
    prompt_buffer_size: usize = 1024 + 16, // max_input_length + prefix + safety
    item_buffer_size: usize = 4096 + 16, // max_item_length + prefix + safety
    count_buffer_size: usize = 64,
    scroll_buffer_size: usize = 64,
};

const Layout = struct {
    // Base dimensions (before scaling) - these are in logical coordinates
    item_line_height: f32 = 20.0,
    prompt_y: f32 = 5.0,
    items_start_y: f32 = 30.0,
    right_margin_offset: f32 = 60.0,
    bottom_margin: f32 = 10.0, // Bottom margin for height calculation
    // Width calculation settings
    width_padding: f32 = 10.0, // Horizontal padding for width calculation
    width_padding_multiplier: f32 = 4.0, // Accounts for left/right margins + spacing
    sample_prompt_text: [:0]const u8 = "> Sample Input Text",
    sample_count_text: [:0]const u8 = "999/999",
    sample_scroll_text: [:0]const u8 = "[999-999]", // Longest possible scroll indicator
};

const Config = struct {
    window: WindowConfig = .{},
    colors: ColorScheme = .{},
    limits: Limits = .{},
    layout: Layout = .{},
    font: font_mod.FontConfig = .{},
    preview: preview_mod.PreviewConfig = .{},
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
    // Preview state
    preview_enabled: bool, // Current toggle state
    preview_content: std.ArrayList(u8), // Preview text content
    preview_state: preview_mod.PreviewState, // Current preview state
    last_previewed_item: ?[]const u8, // Track which item we last previewed
    highlight_spans: std.ArrayList(syntax_highlight.HighlightSpan), // Syntax highlight information
    preview_scroll_offset: usize, // Scroll position in preview (line number)
};

const RenderContext = struct {
    // Render buffers (allocated once, reused)
    prompt_buffer: []u8,
    item_buffer: []u8,
    count_buffer: []u8,
    scroll_buffer: []u8,
    // Texture caching for text rendering performance (using font module)
    prompt_cache: font_mod.TextureCache,
    count_cache: font_mod.TextureCache,
    no_match_cache: font_mod.TextureCache,
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
    config: Config,
    allocator: std.mem.Allocator,
    query_cache: *syntax_mod.QueryCache,


    fn init(allocator: std.mem.Allocator) !App {
        // Initialize QueryCache for syntax highlighting
        const query_cache = try syntax_mod.QueryCache.create(allocator, .{});
        errdefer query_cache.deinit();

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

        var config = Config{};

        // Apply theme from ZMENU_THEME environment variable (if set)
        if (std.process.getEnvVarOwned(allocator, "ZMENU_THEME")) |theme_name| {
            defer allocator.free(theme_name);
            const selected_theme = theme.getByName(theme_name);
            config.colors.background = selected_theme.background;
            config.colors.foreground = selected_theme.foreground;
            config.colors.selected = selected_theme.selected;
            config.colors.prompt = selected_theme.prompt;
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
        const font_result = try font_mod.loadFont(config.font, allocator);
        errdefer font_result.font.deinit();
        errdefer allocator.free(font_result.path);

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
                .preview_enabled = config.preview.enable_preview,
                .preview_content = std.ArrayList(u8).empty,
                .preview_state = .none,
                .last_previewed_item = null,
                .highlight_spans = std.ArrayList(syntax_highlight.HighlightSpan).empty,
                .preview_scroll_offset = 0,
            },
            .render_ctx = .{
                .prompt_buffer = prompt_buffer,
                .item_buffer = item_buffer,
                .count_buffer = count_buffer,
                .scroll_buffer = scroll_buffer,
                .prompt_cache = font_mod.TextureCache.init(),
                .count_cache = font_mod.TextureCache.init(),
                .no_match_cache = font_mod.TextureCache.init(),
                .display_scale = display_scale,
                .pixel_width = @intCast(pixel_width),
                .pixel_height = @intCast(pixel_height),
                .current_width = config.window.initial_width,
                .current_height = config.window.initial_height,
            },
            .config = config,
            .allocator = allocator,
            .query_cache = query_cache,
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
        self.state.preview_content.deinit(self.allocator);
        self.state.highlight_spans.deinit(self.allocator);
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
        self.allocator.free(self.sdl.loaded_font_path); // Free font path copy
        self.sdl.renderer.deinit();
        self.sdl.window.deinit();
        sdl.ttf.quit();
        const quit_flags = sdl.InitFlags{ .video = true, .events = true };
        sdl.quit(quit_flags);
        // Clean up query cache last
        self.query_cache.deinit();
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
                const truncate_len = findUtf8Boundary(trimmed, self.config.limits.max_item_length);
                const final_line = trimmed[0..truncate_len];

                const owned_line = try self.allocator.dupe(u8, final_line);
                try self.state.items.append(self.allocator, owned_line);
            }
        }
    }

    fn scrollPreviewDown(self: *App) void {
        const line_count = preview_mod.countLines(self.state.preview_content.items);
        const max_visible = self.config.limits.max_visible_items;

        // Calculate maximum scroll offset (can't scroll past last page)
        const max_offset = if (line_count > max_visible)
            line_count - max_visible
        else
            0;

        if (self.state.preview_scroll_offset < max_offset) {
            self.state.preview_scroll_offset += 1;
        }
    }

    fn scrollPreviewDownPage(self: *App) void {
        const line_count = preview_mod.countLines(self.state.preview_content.items);
        const max_visible = self.config.limits.max_visible_items;

        const max_offset = if (line_count > max_visible)
            line_count - max_visible
        else
            0;

        // Scroll down by page size
        self.state.preview_scroll_offset = @min(
            self.state.preview_scroll_offset + max_visible,
            max_offset,
        );
    }

    fn loadPreview(self: *App, item_path: []const u8) void {
        // Check if preview is enabled
        if (!self.state.preview_enabled) {
            self.state.preview_state = .none;
            return;
        }

        // Clear previous preview content and reset scroll
        self.state.preview_content.clearRetainingCapacity();
        self.state.preview_scroll_offset = 0;
        self.state.preview_state = .loading;

        // Check if it's a known binary file
        if (preview_mod.isBinaryFile(item_path)) {
            self.state.preview_state = .binary;
            self.state.last_previewed_item = item_path;
            return;
        }

        // Try to open and read the file
        const file = std.fs.cwd().openFile(item_path, .{}) catch |err| {
            self.state.preview_state = switch (err) {
                error.FileNotFound => .not_found,
                error.AccessDenied => .permission_denied,
                else => .not_found,
            };
            self.state.last_previewed_item = item_path;
            return;
        };
        defer file.close();

        // Check file size
        const file_size = file.getEndPos() catch {
            self.state.preview_state = .not_found;
            self.state.last_previewed_item = item_path;
            return;
        };

        if (file_size > self.config.preview.max_preview_bytes) {
            self.state.preview_state = .too_large;
            self.state.last_previewed_item = item_path;
            return;
        }

        // Read file content
        const content = file.readToEndAlloc(self.allocator, self.config.preview.max_preview_bytes) catch {
            self.state.preview_state = .permission_denied;
            self.state.last_previewed_item = item_path;
            return;
        };
        defer self.allocator.free(content);

        // Check if content is text (no null bytes in first 512 bytes)
        const check_len = @min(content.len, 512);
        if (!preview_mod.isTextFile(item_path) and preview_mod.containsNullByte(content[0..check_len])) {
            self.state.preview_state = .binary;
            self.state.last_previewed_item = item_path;
            return;
        }

        // Copy content to preview buffer (no line limit, only byte limit enforced by file read)
        self.state.preview_content.appendSlice(self.allocator, content) catch {
            self.state.preview_state = .too_large;
            self.state.last_previewed_item = item_path;
            return;
        };

        // Apply syntax highlighting
        self.state.highlight_spans.clearRetainingCapacity();

        const colors = syntax_highlight.ColorScheme{
            .background = self.config.colors.background,
            .foreground = self.config.colors.foreground,
            .selected = self.config.colors.selected,
            .prompt = self.config.colors.prompt,
        };
        var highlighter = syntax_highlight.SyntaxHighlighter.init(self.allocator, self.query_cache, colors);
        highlighter.highlight(item_path, self.state.preview_content.items, &self.state.highlight_spans) catch |err| {
            // If highlighting fails, clear spans to prevent stale data
            self.state.highlight_spans.clearRetainingCapacity();
            std.debug.print("Warning: Syntax highlighting failed for {s}: {}\n", .{ item_path, err });
        };

        self.state.preview_state = .text;
        self.state.last_previewed_item = item_path;
    }

    fn renderHighlightedLine(self: *App, x: f32, y: f32, line: []const u8, line_start_byte: usize) !void {
        // If no highlights or line is empty, render normally
        if (self.state.highlight_spans.items.len == 0 or line.len == 0) {
            if (line.len > 0) {
                var line_buffer: [4096]u8 = undefined;
                const line_z = std.fmt.bufPrintZ(&line_buffer, "{s}", .{line}) catch return;
                self.renderText(x, y, line_z, self.config.colors.foreground) catch {};
            }
            return;
        }

        const line_end_byte = line_start_byte + line.len;
        var current_x = x;

        // Simple approach: find highlight spans and render segments
        var pos: usize = 0;
        const default_color = self.config.colors.foreground;

        // Create highlighter for color mapping
        const colors = syntax_highlight.ColorScheme{
            .background = self.config.colors.background,
            .foreground = self.config.colors.foreground,
            .selected = self.config.colors.selected,
            .prompt = self.config.colors.prompt,
        };
        var highlighter = syntax_highlight.SyntaxHighlighter.init(self.allocator, self.query_cache, colors);

        while (pos < line.len) {
            // Find if current position is in any highlight span
            var found_span: ?syntax_highlight.HighlightSpan = null;
            for (self.state.highlight_spans.items) |span| {
                const byte_pos = line_start_byte + pos;
                if (byte_pos >= span.start_byte and byte_pos < span.end_byte) {
                    found_span = span;
                    break;
                }
            }

            if (found_span) |span| {
                // Calculate segment within this span
                const start_pos = pos;
                const span_relative_end = span.end_byte - line_start_byte;
                const end_pos = @min(span_relative_end, line.len);

                // Render highlighted segment
                const segment = line[start_pos..end_pos];
                if (segment.len > 0) {
                    var buffer: [4096]u8 = undefined;
                    const text_z = std.fmt.bufPrintZ(&buffer, "{s}", .{segment}) catch {
                        pos = end_pos;
                        continue;
                    };
                    const color = highlighter.getScopeColor(span.scope);
                    const w, _ = self.sdl.font.getStringSize(text_z) catch {
                        pos = end_pos;
                        continue;
                    };
                    self.renderText(current_x, y, text_z, color) catch {};
                    current_x += @floatFromInt(w);
                }
                pos = end_pos;
            } else {
                // Find next highlight start or end of line
                var next_pos = line.len;
                for (self.state.highlight_spans.items) |span| {
                    if (span.start_byte > line_start_byte + pos and span.start_byte < line_end_byte) {
                        const span_start_in_line = span.start_byte - line_start_byte;
                        next_pos = @min(next_pos, span_start_in_line);
                    }
                }

                // Render unhighlighted segment
                const segment = line[pos..next_pos];
                if (segment.len > 0) {
                    var buffer: [4096]u8 = undefined;
                    const text_z = std.fmt.bufPrintZ(&buffer, "{s}", .{segment}) catch {
                        pos = next_pos;
                        continue;
                    };
                    const w, _ = self.sdl.font.getStringSize(text_z) catch {
                        pos = next_pos;
                        continue;
                    };
                    self.renderText(current_x, y, text_z, default_color) catch {};
                    current_x += @floatFromInt(w);
                }
                pos = next_pos;
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
        } else if (self.state.selected_index >= self.state.scroll_offset + self.config.limits.max_visible_items) {
            self.state.scroll_offset = self.state.selected_index - self.config.limits.max_visible_items + 1;
        }
    }

    fn updatePreview(self: *App) void {
        if (!self.state.preview_enabled) return;
        if (self.state.filtered_items.items.len == 0) {
            self.state.preview_state = .none;
            return;
        }

        const item_index = self.state.filtered_items.items[self.state.selected_index];
        const item = self.state.items.items[item_index];

        // Skip if already previewed this item
        if (self.state.last_previewed_item) |last| {
            if (std.mem.eql(u8, last, item)) return;
        }

        const old_line_count = blk: {
            var count: usize = 0;
            var iter = std.mem.splitScalar(u8, self.state.preview_content.items, '\n');
            while (iter.next()) |_| count += 1;
            break :blk count;
        };

        self.loadPreview(item);

        // If preview content line count changed, update window size
        const new_line_count = blk: {
            var count: usize = 0;
            var iter = std.mem.splitScalar(u8, self.state.preview_content.items, '\n');
            while (iter.next()) |_| count += 1;
            break :blk count;
        };

        if (old_line_count != new_line_count) {
            self.updateWindowSize() catch {};
        }
    }

    fn navigate(self: *App, delta: isize) void {
        if (self.state.filtered_items.items.len == 0) return;

        const current = @as(isize, @intCast(self.state.selected_index));
        const new_idx = current + delta;

        if (new_idx >= 0 and new_idx < @as(isize, @intCast(self.state.filtered_items.items.len))) {
            self.state.selected_index = @intCast(new_idx);
            self.adjustScroll();
            self.updatePreview();
            self.state.needs_render = true;
        }
    }

    fn navigateToFirst(self: *App) void {
        if (self.state.filtered_items.items.len > 0) {
            self.state.selected_index = 0;
            self.adjustScroll();
            self.updatePreview();
            self.state.needs_render = true;
        }
    }

    fn navigateToLast(self: *App) void {
        if (self.state.filtered_items.items.len > 0) {
            self.state.selected_index = self.state.filtered_items.items.len - 1;
            self.adjustScroll();
            self.updatePreview();
            self.state.needs_render = true;
        }
    }

    fn navigatePage(self: *App, direction: isize) void {
        if (self.state.filtered_items.items.len == 0) return;

        const page_size = @as(isize, @intCast(self.config.limits.max_visible_items));
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
        } else if (key == .up and (event.mod.left_alt or event.mod.right_alt)) {
            // Alt+Up: Scroll preview up (check this BEFORE regular up)
            if (self.state.preview_enabled and self.state.preview_state == .text) {
                if (self.state.preview_scroll_offset > 0) {
                    self.state.preview_scroll_offset -= 1;
                    self.state.needs_render = true;
                }
            }
        } else if (key == .down and (event.mod.left_alt or event.mod.right_alt)) {
            // Alt+Down: Scroll preview down (check this BEFORE regular down)
            if (self.state.preview_enabled and self.state.preview_state == .text) {
                self.scrollPreviewDown();
                self.state.needs_render = true;
            }
        } else if (key == .page_up and (event.mod.left_alt or event.mod.right_alt)) {
            // Alt+PageUp: Scroll preview up by page (check this BEFORE regular page up)
            if (self.state.preview_enabled and self.state.preview_state == .text) {
                if (self.state.preview_scroll_offset >= self.config.limits.max_visible_items) {
                    self.state.preview_scroll_offset -= self.config.limits.max_visible_items;
                } else {
                    self.state.preview_scroll_offset = 0;
                }
                self.state.needs_render = true;
            }
        } else if (key == .page_down and (event.mod.left_alt or event.mod.right_alt)) {
            // Alt+PageDown: Scroll preview down by page (check this BEFORE regular page down)
            if (self.state.preview_enabled and self.state.preview_state == .text) {
                self.scrollPreviewDownPage();
                self.state.needs_render = true;
            }
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
        } else if (key == .p and (event.mod.left_control or event.mod.right_control)) {
            // Ctrl+P: Toggle preview pane
            self.state.preview_enabled = !self.state.preview_enabled;
            if (self.state.preview_enabled) {
                // Load preview for current selection
                self.updatePreview();
            }
            // Recalculate window size to fit preview pane
            try self.updateWindowSize();
            self.state.needs_render = true;
        }

        return false;
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        // Check if adding this text would exceed max input length
        if (self.state.input_buffer.items.len + text.len <= self.config.limits.max_input_length) {
            try self.state.input_buffer.appendSlice(self.allocator, text);
            try self.updateFilter();
            self.state.needs_render = true;
        }
        // Silently ignore input that would exceed the limit
    }

    fn renderText(self: *App, x: f32, y: f32, text: [:0]const u8, color: sdl.pixels.Color) !void {
        // SDL_ttf cannot render empty strings
        if (text.len == 0) return;

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
        cache: *font_mod.TextureCache,
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
        try self.sdl.renderer.setDrawColor(self.config.colors.background);
        try self.sdl.renderer.clear();

        // Apply display scale to all coordinates
        const scale = self.render_ctx.display_scale;

        // Calculate layout dimensions
        const window_width = @as(f32, @floatFromInt(self.render_ctx.current_width));
        const items_pane_width = if (self.state.preview_enabled)
            window_width * (100.0 - @as(f32, @floatFromInt(self.config.preview.preview_width_percent))) / 100.0
        else
            window_width;

        // Show prompt with input buffer
        const prompt_text = if (self.state.input_buffer.items.len > 0) blk: {
            // Truncate display if input is too long, showing last chars with ellipsis
            const ellipsis_threshold = self.config.limits.max_input_length - self.config.limits.input_ellipsis_margin;
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

        try self.renderCachedText(5.0 * scale, self.config.layout.prompt_y * scale, prompt_text, self.config.colors.prompt, &self.render_ctx.prompt_cache);

        // Show filtered items count and preview status
        const count_text = if (self.state.preview_enabled)
            std.fmt.bufPrintZ(
                self.render_ctx.count_buffer,
                "{d}/{d} Preview: ON",
                .{ self.state.filtered_items.items.len, self.state.items.items.len },
            ) catch "?/? Preview: ON"
        else
            std.fmt.bufPrintZ(
                self.render_ctx.count_buffer,
                "{d}/{d}",
                .{ self.state.filtered_items.items.len, self.state.items.items.len },
            ) catch "?/?";

        // Measure actual text width for right-alignment
        const count_text_w, _ = try self.sdl.font.getStringSize(count_text);
        const count_x = (window_width - @as(f32, @floatFromInt(count_text_w)) - self.config.layout.width_padding) * scale;
        try self.renderCachedText(count_x, self.config.layout.prompt_y * scale, count_text, self.config.colors.foreground, &self.render_ctx.count_cache);

        // Cache length to avoid race conditions
        const filtered_len = self.state.filtered_items.items.len;

        // Set clipping rectangle for items pane if preview is enabled
        if (self.state.preview_enabled) {
            const clip_rect = sdl.rect.IRect{
                .x = 0,
                .y = 0,
                .w = @intFromFloat(items_pane_width * scale),
                .h = @intCast(self.render_ctx.pixel_height),
            };
            try self.sdl.renderer.setClipRect(clip_rect);
        }

        // Show multiple items (in left pane if preview enabled)
        if (filtered_len > 0) {
            const visible_end = @min(self.state.scroll_offset + self.config.limits.max_visible_items, filtered_len);

            var y_pos: f32 = self.config.layout.items_start_y * scale;

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
                const color = if (is_selected) self.config.colors.selected else self.config.colors.foreground;
                try self.renderText(5.0 * scale, y_pos, item_text, color);

                y_pos += self.config.layout.item_line_height * scale;
            }

            // Show scroll indicator if needed (only in items pane)
            if (filtered_len > self.config.limits.max_visible_items) {
                const scroll_text = std.fmt.bufPrintZ(
                    self.render_ctx.scroll_buffer,
                    "[{d}-{d}]",
                    .{ self.state.scroll_offset + 1, visible_end },
                ) catch "[?]";

                // Measure actual scroll text width for right-alignment within items pane
                const scroll_text_w, _ = try self.sdl.font.getStringSize(scroll_text);
                const scroll_x = (items_pane_width - @as(f32, @floatFromInt(scroll_text_w)) - self.config.layout.width_padding) * scale;
                try self.renderText(scroll_x, self.config.layout.items_start_y * scale, scroll_text, self.config.colors.foreground);
            }
        } else {
            try self.renderCachedText(5.0 * scale, self.config.layout.items_start_y * scale, "No matches", self.config.colors.foreground, &self.render_ctx.no_match_cache);
        }

        // Clear clipping for preview pane
        if (self.state.preview_enabled) {
            try self.sdl.renderer.setClipRect(null);
        }

        // Render preview pane if enabled
        if (self.state.preview_enabled) {
            const divider_x = items_pane_width * scale;
            const preview_x = (items_pane_width + 10.0) * scale; // 10px padding
            const preview_y = self.config.layout.items_start_y * scale;

            // Draw vertical divider line
            try self.sdl.renderer.setDrawColor(self.config.colors.foreground);
            const line_start = sdl.rect.FPoint{ .x = divider_x, .y = 0 };
            const line_end = sdl.rect.FPoint{ .x = divider_x, .y = @floatFromInt(self.render_ctx.pixel_height) };
            try self.sdl.renderer.renderLine(line_start, line_end);

            // Render preview content based on state
            switch (self.state.preview_state) {
                .none => {
                    try self.renderText(preview_x, preview_y, "(no preview available)", self.config.colors.foreground);
                },
                .loading => {
                    try self.renderText(preview_x, preview_y, "Loading preview...", self.config.colors.foreground);
                },
                .text => {
                    // Render preview text line by line with syntax highlighting and scrolling
                    var line_y = preview_y;
                    var byte_offset: usize = 0;
                    var line_index: usize = 0;
                    var visible_lines: usize = 0;
                    const max_visible = self.config.limits.max_visible_items;

                    var iter = std.mem.splitScalar(u8, self.state.preview_content.items, '\n');
                    while (iter.next()) |line| {
                        // Skip lines before scroll offset
                        if (line_index < self.state.preview_scroll_offset) {
                            byte_offset += line.len + 1; // +1 for newline
                            line_index += 1;
                            continue;
                        }

                        // Stop if we've rendered max visible lines
                        if (visible_lines >= max_visible) break;

                        // Skip rendering empty lines but still count them
                        if (line.len == 0) {
                            line_y += self.config.layout.item_line_height * scale;
                            byte_offset += 1; // Account for newline character
                            line_index += 1;
                            visible_lines += 1;
                            continue;
                        }

                        // Try to render with syntax highlighting
                        self.renderHighlightedLine(preview_x, line_y, line, byte_offset) catch {
                            // If rendering fails, show a placeholder
                            self.renderText(preview_x, line_y, "[line cannot be displayed]", self.config.colors.foreground) catch {};
                        };

                        line_y += self.config.layout.item_line_height * scale;
                        byte_offset += line.len + 1; // +1 for newline
                        line_index += 1;
                        visible_lines += 1;
                    }
                },
                .binary => {
                    try self.renderText(preview_x, preview_y, "Binary file (no preview)", self.config.colors.foreground);
                },
                .not_found => {
                    try self.renderText(preview_x, preview_y, "File not found", self.config.colors.foreground);
                },
                .permission_denied => {
                    try self.renderText(preview_x, preview_y, "Permission denied", self.config.colors.foreground);
                },
                .too_large => {
                    try self.renderText(preview_x, preview_y, "File too large", self.config.colors.foreground);
                },
            }

            // Show scroll indicator for preview if needed
            if (self.state.preview_state == .text) {
                // Count total lines using consistent method
                const total_lines = preview_mod.countLines(self.state.preview_content.items);

                // Show indicator if there are more lines than visible
                if (total_lines > self.config.limits.max_visible_items) {
                    const visible_end = @min(
                        self.state.preview_scroll_offset + self.config.limits.max_visible_items,
                        total_lines,
                    );

                    var scroll_indicator_buffer: [64]u8 = undefined;
                    const scroll_text = std.fmt.bufPrintZ(
                        &scroll_indicator_buffer,
                        "[{d}-{d}/{d}]",
                        .{ self.state.preview_scroll_offset + 1, visible_end, total_lines },
                    ) catch "[?]";

                    // Position in top-right of preview pane, below the prompt line to avoid overlap
                    const scroll_text_w, _ = try self.sdl.font.getStringSize(scroll_text);
                    const preview_pane_width = window_width - items_pane_width;
                    const scroll_x = ((items_pane_width + preview_pane_width - @as(f32, @floatFromInt(scroll_text_w)) / scale) - self.config.layout.width_padding) * scale;
                    const scroll_y = (self.config.layout.prompt_y + self.config.layout.item_line_height) * scale;
                    try self.renderText(scroll_x, scroll_y, scroll_text, self.config.colors.foreground);
                }
            }
        }

        try self.sdl.renderer.present();
    }

    fn colorEquals(a: sdl.pixels.Color, b: sdl.pixels.Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    fn calculateOptimalWidth(self: *App) !u32 {
        // Start with minimum width
        var max_width: f32 = @floatFromInt(self.config.window.min_width);

        // Measure sample prompt text width (uses config sample)
        const prompt_w, _ = try self.sdl.font.getStringSize(self.config.layout.sample_prompt_text);

        // Measure count and scroll indicator text width (use the longest one)
        const count_w, _ = try self.sdl.font.getStringSize(self.config.layout.sample_count_text);
        const scroll_w, _ = try self.sdl.font.getStringSize(self.config.layout.sample_scroll_text);
        const right_side_width = @max(count_w, scroll_w);

        // Calculate required width for prompt + right side + margins
        const base_width = @as(f32, @floatFromInt(prompt_w + right_side_width)) + (self.config.layout.width_padding * self.config.layout.width_padding_multiplier);
        if (base_width > max_width) max_width = base_width;

        // Check widths of visible items
        const filtered_len = self.state.filtered_items.items.len;
        const visible_end = @min(self.config.limits.max_visible_items, filtered_len);

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

            const total_item_width = @as(f32, @floatFromInt(item_w)) + (self.config.layout.width_padding * 2.0);
            if (total_item_width > max_width) max_width = total_item_width;
        }

        // If preview is enabled, adjust width calculation
        // The items pane takes (100 - preview_width_percent)% of the window
        // So we need to scale up max_width to account for the preview pane
        if (self.state.preview_enabled) {
            const items_pane_percent = 100.0 - @as(f32, @floatFromInt(self.config.preview.preview_width_percent));
            // Scale up the required width: if items need X pixels and take Y% of window,
            // then total window width = X / (Y / 100)
            max_width = max_width * (100.0 / items_pane_percent);
        }

        // Apply min/max bounds with proper rounding
        const rounded_width = @as(u32, @intFromFloat(@ceil(max_width)));
        const final_width = @max(rounded_width, self.config.window.min_width);
        return @min(final_width, self.config.window.max_width);
    }

    fn calculateOptimalHeight(self: *App) u32 {
        // Calculate how many items we'll actually show
        const filtered_len = self.state.filtered_items.items.len;
        const visible_items = @min(filtered_len, self.config.limits.max_visible_items);

        // Calculate required height: prompt area + (items × line height) + bottom margin
        const prompt_area_height = self.config.layout.items_start_y; // Includes prompt + spacing
        const items_height = @as(f32, @floatFromInt(visible_items)) * self.config.layout.item_line_height;

        var total_height = prompt_area_height + items_height + self.config.layout.bottom_margin;

        // If preview is enabled and has text content, calculate preview height
        if (self.state.preview_enabled and self.state.preview_state == .text) {
            // Count lines using consistent method
            const line_count = preview_mod.countLines(self.state.preview_content.items);

            // Limit visible preview lines to max_visible_items (for scrolling)
            const visible_preview_lines = @min(line_count, self.config.limits.max_visible_items);

            // Calculate preview height based on visible lines only
            const preview_height = prompt_area_height +
                (@as(f32, @floatFromInt(visible_preview_lines)) * self.config.layout.item_line_height) +
                self.config.layout.bottom_margin;

            // Use the maximum of items height and preview height
            total_height = @max(total_height, preview_height);
        }

        // Apply min/max bounds with proper rounding
        const rounded_height = @as(u32, @intFromFloat(@ceil(total_height)));
        const final_height = @max(rounded_height, self.config.window.min_height);
        return @min(final_height, self.config.window.max_height);
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

test "Config - buffer sizes aligned with limits" {
    const config = Config{};
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
            .preview_enabled = false,
            .preview_content = std.ArrayList(u8).empty,
            .preview_state = .none,
            .last_previewed_item = null,
            .highlight_spans = std.ArrayList(syntax_highlight.HighlightSpan).empty,
            .preview_scroll_offset = 0,
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
        .config = Config{},
        .allocator = allocator,
        .query_cache = undefined,
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
            .preview_enabled = false,
            .preview_content = std.ArrayList(u8).empty,
            .preview_state = .none,
            .last_previewed_item = null,
            .highlight_spans = std.ArrayList(syntax_highlight.HighlightSpan).empty,
            .preview_scroll_offset = 0,
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
        .config = Config{},
        .allocator = allocator,
        .query_cache = undefined,
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
            .preview_enabled = false,
            .preview_content = std.ArrayList(u8).empty,
            .preview_state = .none,
            .last_previewed_item = null,
            .highlight_spans = std.ArrayList(syntax_highlight.HighlightSpan).empty,
            .preview_scroll_offset = 0,
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
        .config = Config{},
        .allocator = allocator,
        .query_cache = undefined,
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
            .preview_enabled = false,
            .preview_content = std.ArrayList(u8).empty,
            .preview_state = .none,
            .last_previewed_item = null,
            .highlight_spans = std.ArrayList(syntax_highlight.HighlightSpan).empty,
            .preview_scroll_offset = 0,
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
        .config = Config{},
        .allocator = allocator,
        .query_cache = undefined,
    };

    app.deleteLastCodepoint(); // Should not crash
    try std.testing.expectEqual(@as(usize, 0), app.state.input_buffer.items.len);

    app.state.input_buffer.deinit(allocator);
}
