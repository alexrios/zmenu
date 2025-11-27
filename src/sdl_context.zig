//! SDL context management for zmenu
//!
//! Handles SDL initialization, window/renderer creation, and font loading.

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");

/// SDL context holding window, renderer, and font
pub const SdlContext = struct {
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    font: sdl.ttf.Font,
    loaded_font_path: []const u8,

    pub fn deinit(self: *SdlContext) void {
        self.font.deinit();
        self.renderer.deinit();
        self.window.deinit();
        sdl.ttf.quit();
        const quit_flags = sdl.InitFlags{ .video = true, .events = true };
        sdl.quit(quit_flags);
    }
};

/// Initialize SDL subsystems
pub fn initSdl() !void {
    const init_flags = sdl.InitFlags{ .video = true, .events = true };
    try sdl.init(init_flags);
    errdefer {
        const quit_flags = sdl.InitFlags{ .video = true, .events = true };
        sdl.quit(quit_flags);
    }
    try sdl.ttf.init();
}

/// Clean up SDL on init failure
pub fn quitSdl() void {
    sdl.ttf.quit();
    const quit_flags = sdl.InitFlags{ .video = true, .events = true };
    sdl.quit(quit_flags);
}

/// Create window and renderer with configured settings
pub fn createWindow() !struct { window: sdl.video.Window, renderer: sdl.render.Renderer } {
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

    // Position window at center of screen
    window.setPosition(.{ .centered = null }, .{ .centered = null }) catch |err| {
        std.debug.print("Warning: Failed to position window: {}\n", .{err});
    };

    return .{ .window = window, .renderer = renderer };
}

/// Load font with platform-specific fallback
pub fn loadFont() !struct { font: sdl.ttf.Font, path: []const u8 } {
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
