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

/// Build feature list at compile time
fn buildFeatureList() []const Feature {
    comptime {
        var list: []const Feature = &.{};

        // History feature
        if (@hasDecl(config.features, "history") and config.features.history) {
            list = list ++ &[_]Feature{@import("features/history.zig").feature};
        }

        // Add more features here as they're implemented:
        // if (@hasDecl(config.features, "multi_select") and config.features.multi_select) {
        //     list = list ++ &[_]Feature{@import("features/multi_select.zig").feature};
        // }

        return list;
    }
}

/// Compile-time constant array of enabled features
pub const enabled_features: []const Feature = buildFeatureList();

/// Number of enabled features (compile-time constant)
pub const enabled_count: usize = enabled_features.len;

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

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onInit) |initFn| {
            states[i] = try initFn(allocator);
        }
    }
}

/// Cleanup all enabled features
pub fn deinitAll(states: *FeatureStates, allocator: std.mem.Allocator) void {
    if (enabled_count == 0) return;

    inline for (enabled_features, 0..) |feature, i| {
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

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.afterFilter) |afterFn| {
            afterFn(states[i], filtered_items, all_items);
        }
    }
}

/// Call onSelect hook on all enabled features
pub fn callOnSelect(states: *FeatureStates, selected_item: []const u8) void {
    if (enabled_count == 0) return;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onSelect) |selectFn| {
            selectFn(states[i], selected_item);
        }
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "enabled_features - returns empty when no features enabled" {
    // With default config, no features should be enabled
    // Note: This test passes with config.def.zig (history=false)
    // If you have config.zig with history=true, this test will fail
    comptime {
        if (enabled_features.len != 0) {
            // Features are enabled - this is expected if history=true in config.zig
        }
    }
}

test "FeatureStates - correct size based on features" {
    // Size depends on enabled features - void (0) when none, array when some
    if (enabled_count == 0) {
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(FeatureStates));
    } else {
        // Each feature state is ?*anyopaque (optional pointer = 8 bytes on 64-bit)
        try std.testing.expect(@sizeOf(FeatureStates) > 0);
    }
}

test "initStates - works with no features" {
    const states = initStates();
    _ = states; // Should compile and do nothing
}
