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

    // Position window on target display
    if (target_display) |display| {
        const bounds = getDisplayBounds(display) catch |err| {
            std.log.warn("Failed to get display bounds: {}", .{err});
            // Fall back to centered positioning
            window.setPosition(.{ .centered = null }, .{ .centered = null }) catch |pos_err| {
                std.log.warn("Failed to position window: {}", .{pos_err});
            };
            return .{ .window = window, .renderer = renderer };
        };

        // Calculate centered position on target display
        const window_x = bounds.x + @divTrunc(bounds.w - @as(i32, @intCast(config.window.initial_width)), 2);
        const window_y = bounds.y + @divTrunc(bounds.h - @as(i32, @intCast(config.window.initial_height)), 2);

        window.setPosition(.{ .absolute = window_x }, .{ .absolute = window_y }) catch |err| {
            std.log.warn("Failed to position window on monitor {}: {}", .{ monitor_index.?, err });
        };
    } else {
        // No monitor specified, use default centered positioning
        window.setPosition(.{ .centered = null }, .{ .centered = null }) catch |err| {
            std.log.warn("Failed to position window: {}", .{err});
        };
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
    const stderr = std.fs.File.stderr();
    _ = stderr.write("Error: Could not find any suitable font. Tried:\n") catch {};
    if (config.font.use_embedded) {
        _ = stderr.write("  - (embedded: Crimson Pro)\n") catch {};
    }
    for (config.default_font_paths) |font_path| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  - {s}\n", .{font_path}) catch continue;
        _ = stderr.write(msg) catch {};
    }
    return error.NoFontFound;
}

/// Load font from embedded binary data.
/// Safety: close_io=true only frees the SDL_IOStream struct, not the underlying
/// memory. embedded_font_data lives in the binary's read-only segment via @embedFile
/// and is never freed by SDL_CloseIO. Verified against SDL3 source.
fn loadEmbeddedFont() !sdl.ttf.Font {
    const stream = try sdl.io_stream.Stream.initFromConstMem(embedded_font_data);
    errdefer stream.deinit() catch {};
    return try sdl.ttf.Font.initFromIO(stream, true, config.font.size);
}
