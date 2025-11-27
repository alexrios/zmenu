//! zmenu default configuration
//!
//! To customize: copy this file to config.zig and edit.
//! The build system will use config.zig if present, otherwise config.def.zig.
//!
//! After changes: zig build

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
pub const theme = @import("src/theme.zig");

// ============================================================================
// WINDOW
// ============================================================================

pub const window = struct {
    pub const initial_width: u32 = 800;
    pub const initial_height: u32 = 300;
    pub const min_width: u32 = 600;
    pub const min_height: u32 = 150;
    pub const max_width: u32 = 1600;
    pub const max_height: u32 = 800;
    pub const enable_high_dpi: bool = true;
};

// ============================================================================
// COLORS
// ============================================================================

/// Color scheme - pick a theme or define custom colors
/// Available themes: mocha, latte, frappe, macchiato, dracula, gruvbox, nord, solarized
pub const colors = struct {
    pub const background: sdl.pixels.Color = theme.default.background;
    pub const foreground: sdl.pixels.Color = theme.default.foreground;
    pub const selected: sdl.pixels.Color = theme.default.selected;
    pub const prompt: sdl.pixels.Color = theme.default.prompt;
};

// ============================================================================
// LIMITS
// ============================================================================

pub const limits = struct {
    pub const max_visible_items: usize = 30;
    pub const max_item_length: usize = 4096;
    pub const max_input_length: usize = 1024;
    pub const input_ellipsis_margin: usize = 100;

    // Derived buffer sizes - these must accommodate max lengths + prefixes
    pub const prompt_buffer_size: usize = max_input_length + 16;
    pub const item_buffer_size: usize = max_item_length + 16;
    pub const count_buffer_size: usize = 64;
    pub const scroll_buffer_size: usize = 64;
};

// ============================================================================
// LAYOUT
// ============================================================================

pub const layout = struct {
    /// Base dimensions (before DPI scaling) in logical coordinates
    pub const item_line_height: f32 = 20.0;
    pub const prompt_y: f32 = 5.0;
    pub const items_start_y: f32 = 30.0;
    pub const right_margin_offset: f32 = 60.0;
    pub const bottom_margin: f32 = 10.0;

    /// Width calculation settings
    pub const width_padding: f32 = 10.0;
    pub const width_padding_multiplier: f32 = 4.0;

    /// Sample text for dimension calculations
    pub const sample_prompt_text: [:0]const u8 = "> Sample Input Text";
    pub const sample_count_text: [:0]const u8 = "999/999";
    pub const sample_scroll_text: [:0]const u8 = "[999-999]";
};

// ============================================================================
// FONT
// ============================================================================

pub const font = struct {
    /// Custom font path (null = use platform defaults)
    pub const path: ?[:0]const u8 = null;
    pub const size: f32 = 22;
};

/// Platform-specific default font paths (tried in order)
pub const default_font_paths = switch (builtin.os.tag) {
    .linux => [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    },
    .macos => [_][:0]const u8{
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNSText.ttf",
        "/Library/Fonts/Arial.ttf",
    },
    .windows => [_][:0]const u8{
        "C:\\Windows\\Fonts\\arial.ttf",
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\calibri.ttf",
    },
    else => [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    },
};

// ============================================================================
// FEATURES (compile-time toggles)
// ============================================================================

/// Feature flags - set to true to enable, false to disable
/// Disabled features are completely removed from the binary (zero overhead)
pub const features = struct {
    /// Case-sensitive matching (default: false = case-insensitive)
    pub const case_sensitive: bool = false;

    /// Matching algorithm
    pub const match_mode: MatchMode = .fuzzy;

    // Future features (added via patches):
    // pub const history: bool = false;
    // pub const multi_select: bool = false;
};

pub const MatchMode = enum {
    fuzzy,
    prefix,
    exact,
};
