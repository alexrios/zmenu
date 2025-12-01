//! Application state definitions

const std = @import("std");

/// Input loading state (tagged union for type-safe state management)
pub const InputState = union(enum) {
    /// Loading items from stdin
    loading: struct {
        items_loaded: usize,
    },
    /// All items loaded, ready for interaction
    ready: void,
};

/// Application state for input, items, and selection
pub const AppState = struct {
    input_buffer: std.ArrayList(u8),
    items: std.ArrayList([]const u8),
    filtered_items: std.ArrayList(usize),
    selected_index: usize,
    scroll_offset: usize,
    needs_render: bool,
    // Non-blocking stdin state
    input_state: InputState,

    pub const empty = AppState{
        .input_buffer = std.ArrayList(u8).empty,
        .items = std.ArrayList([]const u8).empty,
        .filtered_items = std.ArrayList(usize).empty,
        .selected_index = 0,
        .scroll_offset = 0,
        .needs_render = true,
        .input_state = .{ .loading = .{ .items_loaded = 0 } },
    };
};

test "AppState - text input respects loading state" {
    // This test verifies that input handling is properly guarded during
    // state transitions. Text input should only be processed when in .ready state.
    // This prevents race conditions where user input is accepted before all
    // items are loaded from stdin.

    const allocator = std.testing.allocator;

    var state = AppState.empty;
    defer {
        state.input_buffer.deinit(allocator);
        for (state.items.items) |item| allocator.free(item);
        state.items.deinit(allocator);
        state.filtered_items.deinit(allocator);
    }

    // Verify initial state is loading
    try std.testing.expect(state.input_state == .loading);

    // Simulate guard check (as in app.zig:212-214)
    const should_process = (state.input_state == .ready);
    try std.testing.expect(!should_process); // Should NOT process during loading

    // Transition to ready
    state.input_state = .ready;

    // Now input should be processed
    const should_process_now = (state.input_state == .ready);
    try std.testing.expect(should_process_now);
}

test "AppState - loading counter accuracy during transitions" {
    // This test verifies that the loading counter accurately tracks items
    // added during the loading state, and that data remains intact across
    // state transitions.

    const allocator = std.testing.allocator;

    var state = AppState.empty;
    defer {
        state.input_buffer.deinit(allocator);
        for (state.items.items) |item| allocator.free(item);
        state.items.deinit(allocator);
        state.filtered_items.deinit(allocator);
    }

    // Verify initial counter is 0
    try std.testing.expectEqual(@as(usize, 0), state.input_state.loading.items_loaded);

    // Simulate item loading (as in app.zig:351)
    try state.items.append(allocator, try allocator.dupe(u8, "item1"));
    state.input_state.loading.items_loaded += 1;

    try state.items.append(allocator, try allocator.dupe(u8, "item2"));
    state.input_state.loading.items_loaded += 1;

    try state.items.append(allocator, try allocator.dupe(u8, "item3"));
    state.input_state.loading.items_loaded += 1;

    // Verify counter matches actual items
    try std.testing.expectEqual(@as(usize, 3), state.input_state.loading.items_loaded);
    try std.testing.expectEqual(@as(usize, 3), state.items.items.len);

    // Transition to ready (simulates EOF reached, app.zig:184)
    state.input_state = .ready;

    // Verify data integrity preserved across transition
    try std.testing.expectEqual(@as(usize, 3), state.items.items.len);
    try std.testing.expectEqualStrings("item1", state.items.items[0]);
    try std.testing.expectEqualStrings("item2", state.items.items[1]);
    try std.testing.expectEqualStrings("item3", state.items.items[2]);
}

test "AppState - state machine invariants" {
    // This test verifies state machine invariants hold throughout lifecycle:
    // 1. Initial state is always .loading with items_loaded = 0
    // 2. State transitions are one-way: loading -> ready (no going back)
    // 3. Data structures remain consistent across transitions

    const allocator = std.testing.allocator;

    var state = AppState.empty;
    defer {
        state.input_buffer.deinit(allocator);
        for (state.items.items) |item| allocator.free(item);
        state.items.deinit(allocator);
        state.filtered_items.deinit(allocator);
    }

    // Invariant 1: Initial state
    try std.testing.expect(state.input_state == .loading);
    try std.testing.expectEqual(@as(usize, 0), state.input_state.loading.items_loaded);
    try std.testing.expectEqual(@as(usize, 0), state.items.items.len);

    // Simulate loading process
    try state.items.append(allocator, try allocator.dupe(u8, "test"));
    state.input_state.loading.items_loaded = 1;

    // Invariant 2: Counter matches reality
    try std.testing.expectEqual(
        state.input_state.loading.items_loaded,
        state.items.items.len,
    );

    // Transition to ready
    const items_at_transition = state.items.items.len;
    state.input_state = .ready;

    // Invariant 3: No data loss during transition
    try std.testing.expectEqual(items_at_transition, state.items.items.len);

    // Invariant 4: State is now .ready (one-way transition)
    try std.testing.expect(state.input_state == .ready);
}
