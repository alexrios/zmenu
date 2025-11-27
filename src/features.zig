//! Feature hook system for zmenu
//!
//! This module provides a compile-time feature registration system.
//! Features are enabled via config.zig and compiled in only when enabled.
//! Disabled features have zero runtime overhead.
//!
//! To add a new feature:
//! 1. Create src/features/myfeature.zig implementing the Feature interface
//! 2. Add `pub const myfeature: bool = false;` to config.def.zig features struct
//! 3. Register in enabledFeatures() below
//! 4. Users enable by setting `myfeature = true` in their config.zig

const std = @import("std");
const config = @import("config");

/// Feature state handle (opaque pointer to feature-specific state)
pub const FeatureState = *anyopaque;

/// Hook function signatures
pub const Hooks = struct {
    /// Called once during App.init, after core initialization
    /// Returns feature state that will be passed to other hooks
    onInit: ?*const fn (std.mem.Allocator) anyerror!?FeatureState = null,

    /// Called during App.deinit for cleanup
    onDeinit: ?*const fn (?FeatureState, std.mem.Allocator) void = null,

    /// Called after filtering - can reorder/modify filtered results
    /// Receives: feature state, filtered indices, all items
    afterFilter: ?*const fn (?FeatureState, *std.ArrayList(usize), []const []const u8) void = null,

    /// Called when user confirms selection
    /// Receives: feature state, selected item text
    onSelect: ?*const fn (?FeatureState, []const u8) void = null,
};

/// Feature definition
pub const Feature = struct {
    name: []const u8,
    hooks: Hooks,
};

/// Compile-time list of enabled features
/// This function is evaluated at compile time - disabled features generate no code
pub fn enabledFeatures() []const Feature {
    comptime {
        // Register features here based on config flags
        // When features are added, this will be built up:
        // var list: []const Feature = &.{};
        // if (@hasDecl(config.features, "history") and config.features.history) {
        //     list = list ++ &[_]Feature{@import("features/history.zig").feature};
        // }
        // return list;

        // Currently no features - return empty slice
        return &.{};
    }
}

/// Number of enabled features (compile-time constant)
pub const enabled_count = enabledFeatures().len;

/// Feature states array type - void when no features enabled
pub const FeatureStates = if (enabled_count > 0)
    [enabled_count]?FeatureState
else
    void;

/// Initialize feature states array
pub fn initStates() FeatureStates {
    if (enabled_count > 0) {
        return .{null} ** enabled_count;
    } else {
        return {};
    }
}

/// Initialize all enabled features
/// Returns initialized feature states
pub fn initAll(allocator: std.mem.Allocator, states: *FeatureStates) !void {
    if (enabled_count == 0) return;

    inline for (enabledFeatures(), 0..) |feature, i| {
        if (feature.hooks.onInit) |initFn| {
            states[i] = try initFn(allocator);
        }
    }
}

/// Cleanup all enabled features
pub fn deinitAll(states: *FeatureStates, allocator: std.mem.Allocator) void {
    if (enabled_count == 0) return;

    inline for (enabledFeatures(), 0..) |feature, i| {
        if (feature.hooks.onDeinit) |deinitFn| {
            deinitFn(states[i], allocator);
        }
    }
}

/// Call afterFilter hook on all enabled features
pub fn callAfterFilter(
    states: *FeatureStates,
    filtered_items: *std.ArrayList(usize),
    all_items: []const []const u8,
) void {
    if (enabled_count == 0) return;

    inline for (enabledFeatures(), 0..) |feature, i| {
        if (feature.hooks.afterFilter) |afterFn| {
            afterFn(states[i], filtered_items, all_items);
        }
    }
}

/// Call onSelect hook on all enabled features
pub fn callOnSelect(states: *FeatureStates, selected_item: []const u8) void {
    if (enabled_count == 0) return;

    inline for (enabledFeatures(), 0..) |feature, i| {
        if (feature.hooks.onSelect) |selectFn| {
            selectFn(states[i], selected_item);
        }
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "enabledFeatures - returns empty when no features enabled" {
    // With default config, no features should be enabled
    // Use comptime to evaluate the function
    comptime {
        const feats = enabledFeatures();
        if (feats.len != 0) {
            @compileError("Expected no features enabled by default");
        }
    }
}

test "FeatureStates - is void when no features" {
    // When no features are enabled, states should be void (zero size)
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(FeatureStates));
}

test "initStates - works with no features" {
    const states = initStates();
    _ = states; // Should compile and do nothing
}
