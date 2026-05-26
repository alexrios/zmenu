//! SDL context management for zmenu
//!
//! Handles SDL initialization, window/renderer creation, and font loading.

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");

/// Embedded Crimson Pro font (compiled into binary)
const embedded_font_data = @embedFile("assets/fonts/CrimsonPro-Regular.ttf");

/// SDL context holding window, renderer, and font
pub const SDLContext = struct {
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    font: sdl.ttf.Font,
    loaded_font_path: []const u8,

    pub fn deinit(self: *SDLContext) void {
        self.font.deinit();
        self.renderer.deinit();
        self.window.deinit();
        sdl.ttf.quit();
        const quit_flags = sdl.InitFlags{ .video = true, .events = true };
        sdl.quit(quit_flags);
    }
};

/// Initialize SDL subsystems
pub fn initSDL() !void {
    const sdl_flags = sdl.InitFlags{ .video = true, .events = true };
    try sdl.init(sdl_flags);
    errdefer {
        sdl.quit(sdl_flags);
    }
    try sdl.ttf.init();
}

/// Clean up SDL on init failure
pub fn quitSDL() void {
    sdl.ttf.quit();
    const quit_flags = sdl.InitFlags{ .video = true, .events = true };
    sdl.quit(quit_flags);
}

/// Get all available display IDs
pub fn getDisplays(allocator: std.mem.Allocator) ![]sdl.video.Display {
    const displays_slice = try sdl.video.getDisplays();

    // Copy to owned slice since SDL's slice is temporary
    const displays = try allocator.alloc(sdl.video.Display, displays_slice.len);
    errdefer allocator.free(displays);

    @memcpy(displays, displays_slice);

    return displays;
}

/// Get display bounds (position and dimensions)
pub fn getDisplayBounds(display: sdl.video.Display) !struct { x: i32, y: i32, w: i32, h: i32 } {
    const bounds = try display.getBounds();

    return .{
        .x = bounds.x,
        .y = bounds.y,
        .w = bounds.w,
        .h = bounds.h,
    };
}

/// Center the window via SDL's centered positioning, logging on failure.
/// Used as the fallback whenever per-monitor placement is not possible.
fn centerFallback(window: sdl.video.Window) void {
    window.setPosition(.{ .centered = null }, .{ .centered = null }) catch |pos_err| {
        std.log.warn("Failed to position window: {}", .{pos_err});
    };
}

/// Position the window on the given display, falling back to centered on any error.
fn positionOnDisplay(window: sdl.video.Window, display: sdl.video.Display, monitor_index: usize) void {
    const bounds = getDisplayBounds(display) catch |err| {
        std.log.warn("Failed to get display bounds: {}", .{err});
        centerFallback(window);
        return;
    };

    // Guard the u32->i32 cast: any config above maxInt(i32) would silently wrap.
    comptime {
        std.debug.assert(config.window.initial_width <= std.math.maxInt(i32));
        std.debug.assert(config.window.initial_height <= std.math.maxInt(i32));
    }
    const window_w: i32 = @intCast(config.window.initial_width);
    const window_h: i32 = @intCast(config.window.initial_height);

    // Guard against bounds smaller than the window: avoid negative offsets producing
    // an off-screen window. Fall back to SDL-centered positioning.
    if (bounds.w < window_w or bounds.h < window_h) {
        std.log.warn("Display {} smaller than window ({}x{} < {}x{}), falling back to centered", .{ monitor_index, bounds.w, bounds.h, window_w, window_h });
        centerFallback(window);
        return;
    }

    // Use @addWithOverflow to defend against bounds.x/y near i32 extremes.
    const ox = @addWithOverflow(bounds.x, @divTrunc(bounds.w - window_w, 2));
    const oy = @addWithOverflow(bounds.y, @divTrunc(bounds.h - window_h, 2));
    if (ox[1] != 0 or oy[1] != 0) {
        std.log.warn("Display {} bounds produced overflow, falling back to centered", .{monitor_index});
        centerFallback(window);
        return;
    }

    window.setPosition(.{ .absolute = ox[0] }, .{ .absolute = oy[0] }) catch |err| {
        std.log.warn("Failed to position window on monitor {}: {}", .{ monitor_index, err });
    };
}

/// Create window and renderer with configured settings
pub fn createWindow(allocator: std.mem.Allocator, monitor_index: ?usize) !struct { window: sdl.video.Window, renderer: sdl.render.Renderer } {
    // Validate monitor if specified
    var target_display: ?sdl.video.Display = null;
    if (monitor_index) |idx| {
        const displays = getDisplays(allocator) catch |err| {
            std.log.err("Failed to enumerate displays: {}", .{err});
            return error.FailedToEnumerateDisplays;
        };
        defer allocator.free(displays);

        if (idx >= displays.len) {
            std.log.err("Monitor index {} not found (only {} displays available)", .{ idx, displays.len });
            return error.InvalidMonitorIndex;
        }

        target_display = displays[idx];
    }

    // Create window
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

    if (target_display) |display| {
        positionOnDisplay(window, display, monitor_index.?);
    } else {
        centerFallback(window);
    }

    return .{ .window = window, .renderer = renderer };
}

/// Load font with embedded/custom/system fallback
pub fn loadFont() !struct { font: sdl.ttf.Font, path: []const u8 } {
    // Priority 1: User specified a custom font path
    if (config.font.path) |custom_path| {
        const font = sdl.ttf.Font.init(custom_path, config.font.size) catch |err| {
            std.log.err("Failed to load font '{s}': {}", .{ custom_path, err });
            return err;
        };
        return .{ .font = font, .path = custom_path };
    }

    // Priority 2: Try embedded font if enabled
    if (config.font.use_embedded) {
        if (loadEmbeddedFont()) |font| {
            std.log.info("Loaded embedded font: Crimson Pro Regular", .{});
            return .{ .font = font, .path = "(embedded: Crimson Pro)" };
        } else |err| {
            std.log.warn("Failed to load embedded font: {}, trying system fonts", .{err});
        }
    }

    // Priority 3: Try platform-specific default fonts in order
    for (config.default_font_paths) |font_path| {
        if (sdl.ttf.Font.init(font_path, config.font.size)) |font| {
            std.log.info("Successfully loaded font: {s}", .{font_path});
            return .{ .font = font, .path = font_path };
        } else |_| {
            // Silently continue to next font
        }
    }

    // No fonts found
    std.debug.print("Error: Could not find any suitable font. Tried:\n", .{});
    if (config.font.use_embedded) {
        std.debug.print("  - (embedded: Crimson Pro)\n", .{});
    }
    for (config.default_font_paths) |font_path| {
        std.debug.print("  - {s}\n", .{font_path});
    }
    return error.NoFontFound;
}

/// Load font from embedded binary data.
/// Safety: close_io=true only frees the SDL_IOStream struct, not the underlying
/// memory. embedded_font_data lives in the binary's read-only segment via @embedFile
/// and is never freed by SDL_CloseIO. Verified against SDL3 source.
fn loadEmbeddedFont() !sdl.ttf.Font {
    const stream = try sdl.io_stream.Stream.initFromConstMem(embedded_font_data);
    errdefer stream.deinit() catch |err| std.log.warn("failed to close embedded font stream: {}", .{err});
    return try sdl.ttf.Font.initFromIO(stream, true, config.font.size);
}
