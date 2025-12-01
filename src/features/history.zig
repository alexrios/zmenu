//! History feature - tracks and boosts recently selected items
//!
//! Storage: XDG_DATA_HOME/zmenu/history (or ~/.local/share/zmenu/history)
//! Enable: set `history = true` in config.zig

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const features_mod = @import("../features.zig");

pub const history_config = struct {
    pub const max_entries: usize = if (@hasDecl(config.features, "history_max_entries"))
        config.features.history_max_entries
    else
        100;

    pub const filename: []const u8 = "history";
};

pub const HistoryState = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8),
    history_path: []const u8,
    max_entries: usize,

    pub fn load(allocator: std.mem.Allocator) !*HistoryState {
        return loadWithConfig(allocator, null, history_config.max_entries);
    }

    pub fn loadWithConfig(allocator: std.mem.Allocator, custom_path: ?[]const u8, max_entries: usize) !*HistoryState {
        const state = try allocator.create(HistoryState);
        errdefer allocator.destroy(state);

        const history_path = if (custom_path) |path|
            try allocator.dupe(u8, path)
        else
            try getHistoryPath(allocator);

        state.* = .{
            .allocator = allocator,
            .entries = std.ArrayList([]const u8).empty,
            .history_path = history_path,
            .max_entries = max_entries,
        };
        errdefer allocator.free(state.history_path);

        state.loadFromFile() catch |err| {
            if (err != error.FileNotFound) {
                std.log.warn("could not load history: {}", .{err});
            }
        };

        return state;
    }

    fn loadFromFile(self: *HistoryState) !void {
        const file = try std.fs.openFileAbsolute(self.history_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const entry = try self.allocator.dupe(u8, line);
            try self.entries.append(self.allocator, entry);
        }
    }

    pub fn save(self: *HistoryState) void {
        if (std.fs.path.dirname(self.history_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| {
                if (err != error.PathAlreadyExists) {
                    std.log.warn("could not create history dir: {}", .{err});
                    return;
                }
            };
        }

        const file = std.fs.createFileAbsolute(self.history_path, .{}) catch |err| {
            std.log.warn("could not save history: {}", .{err});
            return;
        };
        defer file.close();

        for (self.entries.items) |entry| {
            _ = file.write(entry) catch continue;
            _ = file.write("\n") catch continue;
        }
    }

    /// Add entry (moves to front if exists)
    pub fn addEntry(self: *HistoryState, item: []const u8) void {
        // Remove if exists
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry, item)) {
                self.allocator.free(entry);
                _ = self.entries.orderedRemove(i);
                break;
            }
        }

        // Add to front
        const new_entry = self.allocator.dupe(u8, item) catch return;
        self.entries.insert(self.allocator, 0, new_entry) catch {
            self.allocator.free(new_entry);
            return;
        };

        // Trim to max (use instance max_entries)
        while (self.entries.items.len > self.max_entries) {
            const removed = self.entries.items[self.entries.items.len - 1];
            self.entries.shrinkRetainingCapacity(self.entries.items.len - 1);
            self.allocator.free(removed);
        }
    }

    /// Get position (0=most recent, null=not found)
    pub fn getPosition(self: *HistoryState, item: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry, item)) {
                return i;
            }
        }
        return null;
    }

    pub fn deinit(self: *HistoryState) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.history_path);
        self.allocator.destroy(self);
    }
};

fn getHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg_data| {
        return std.fmt.allocPrint(allocator, "{s}/zmenu/{s}", .{ xdg_data, history_config.filename });
    }

    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/share/zmenu/{s}", .{ home, history_config.filename });
    }

    if (builtin.os.tag == .windows) {
        if (std.posix.getenv("APPDATA")) |appdata| {
            return std.fmt.allocPrint(allocator, "{s}\\zmenu\\{s}", .{ appdata, history_config.filename });
        }
    }

    return error.NoHomeDirectory;
}

fn onInit(init_data: features_mod.FeatureInitData) anyerror!?features_mod.FeatureState {
    const allocator = init_data.allocator;

    // Extract CLI flag values (in declaration order)
    const custom_path: ?[]const u8 = if (init_data.cli_values.len > 0 and
        init_data.cli_values[0] == .string)
        init_data.cli_values[0].string
    else
        null;

    const max_entries: usize = if (init_data.cli_values.len > 1 and
        init_data.cli_values[1] == .int)
        @intCast(init_data.cli_values[1].int)
    else
        history_config.max_entries;

    // Load or create history state with custom settings
    const state = try HistoryState.loadWithConfig(allocator, custom_path, max_entries);
    return @ptrCast(state);
}

fn onDeinit(state_ptr: ?features_mod.FeatureState, _: std.mem.Allocator) void {
    if (state_ptr) |ptr| {
        const state: *HistoryState = @ptrCast(@alignCast(ptr));
        state.save();
        state.deinit();
    }
}

fn afterFilter(
    state_ptr: ?features_mod.FeatureState,
    filtered_items: *std.ArrayList(usize),
    all_items: []const []const u8,
) void {
    const state: *HistoryState = if (state_ptr) |ptr|
        @ptrCast(@alignCast(ptr))
    else
        return;

    if (filtered_items.items.len <= 1) return;
    if (state.entries.items.len == 0) return;

    // Insertion sort: history items first (by recency), then non-history
    const items = filtered_items.items;

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const idx = items[i];
        const item_text = all_items[idx];
        const item_pos = state.getPosition(item_text);

        var j = i;
        while (j > 0) {
            const prev_idx = items[j - 1];
            const prev_text = all_items[prev_idx];
            const prev_pos = state.getPosition(prev_text);

            const should_swap = blk: {
                if (item_pos) |ip| {
                    if (prev_pos) |pp| {
                        break :blk ip < pp;
                    } else {
                        break :blk true;
                    }
                } else {
                    break :blk false;
                }
            };

            if (!should_swap) break;

            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = idx;
    }
}

fn onSelect(state_ptr: ?features_mod.FeatureState, selected_item: []const u8) void {
    if (state_ptr) |ptr| {
        const state: *HistoryState = @ptrCast(@alignCast(ptr));
        state.addEntry(selected_item);
    }
}

pub const feature = features_mod.Feature{
    .name = "history",
    .hooks = .{
        .onInit = &onInit,
        .onDeinit = &onDeinit,
        .afterFilter = &afterFilter,
        .onSelect = &onSelect,
    },
    .cli_flags = &[_]features_mod.CliFlag{
        .{
            .long = "hist-file",
            .short = 'H',
            .description = "Custom history file path",
            .value_type = .string,
        },
        .{
            .long = "hist-limit",
            .description = "Maximum history entries",
            .value_type = .int,
            .default = features_mod.FlagValue{ .int = 100 },
        },
    },
};

test "HistoryState - add and retrieve entries" {
    const allocator = std.testing.allocator;

    var state = HistoryState{
        .allocator = allocator,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, "/tmp/zmenu_test_history"),
        .max_entries = 100,
    };
    defer {
        for (state.entries.items) |entry| {
            allocator.free(entry);
        }
        state.entries.deinit(allocator);
        allocator.free(state.history_path);
    }

    state.addEntry("item1");
    state.addEntry("item2");
    state.addEntry("item3");

    try std.testing.expectEqual(@as(?usize, 0), state.getPosition("item3"));
    try std.testing.expectEqual(@as(?usize, 1), state.getPosition("item2"));
    try std.testing.expectEqual(@as(?usize, 2), state.getPosition("item1"));
    try std.testing.expectEqual(@as(?usize, null), state.getPosition("item4"));
}

test "HistoryState - re-adding moves to front" {
    const allocator = std.testing.allocator;

    var state = HistoryState{
        .allocator = allocator,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, "/tmp/zmenu_test_history"),
        .max_entries = 100,
    };
    defer {
        for (state.entries.items) |entry| {
            allocator.free(entry);
        }
        state.entries.deinit(allocator);
        allocator.free(state.history_path);
    }

    state.addEntry("item1");
    state.addEntry("item2");
    state.addEntry("item1");

    try std.testing.expectEqual(@as(?usize, 0), state.getPosition("item1"));
    try std.testing.expectEqual(@as(?usize, 1), state.getPosition("item2"));
    try std.testing.expectEqual(@as(usize, 2), state.entries.items.len);
}

test "History afterFilter - basic reordering correctness" {
    // This test verifies that the afterFilter insertion sort correctly
    // promotes history items to the front while maintaining order.
    // Tests the core reordering logic (lines 172-205).

    const allocator = std.testing.allocator;

    // Setup history with 2 entries (most recent first)
    var state = HistoryState{
        .allocator = allocator,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, "/tmp/test_history"),
        .max_entries = 100,
    };
    defer {
        for (state.entries.items) |entry| allocator.free(entry);
        state.entries.deinit(allocator);
        allocator.free(state.history_path);
    }

    state.addEntry("recent_item"); // Position 1 (older)
    state.addEntry("very_recent_item"); // Position 0 (most recent)

    // Create items list
    var all_items = std.ArrayList([]const u8).empty;
    defer {
        for (all_items.items) |item| allocator.free(item);
        all_items.deinit(allocator);
    }

    try all_items.append(allocator, try allocator.dupe(u8, "other_item"));
    try all_items.append(allocator, try allocator.dupe(u8, "very_recent_item"));
    try all_items.append(allocator, try allocator.dupe(u8, "recent_item"));
    try all_items.append(allocator, try allocator.dupe(u8, "another_item"));

    // Create filtered indices (all items match)
    var filtered = std.ArrayList(usize).empty;
    defer filtered.deinit(allocator);

    try filtered.append(allocator, 0); // other_item
    try filtered.append(allocator, 1); // very_recent_item
    try filtered.append(allocator, 2); // recent_item
    try filtered.append(allocator, 3); // another_item

    // Call afterFilter (reorders in-place)
    const state_ptr: ?features_mod.FeatureState = @ptrCast(&state);
    afterFilter(state_ptr, &filtered, all_items.items);

    // Verify: history items promoted by recency
    try std.testing.expectEqual(@as(usize, 1), filtered.items[0]); // very_recent (pos 0)
    try std.testing.expectEqual(@as(usize, 2), filtered.items[1]); // recent (pos 1)

    // Non-history items follow (order doesn't matter among them)
    try std.testing.expectEqual(@as(usize, 4), filtered.items.len); // No items lost
}


test "History afterFilter - rapid updates" {
    // This test simulates rapid filter updates (like user typing quickly).
    // Verifies that multiple reordering operations maintain correctness.

    const allocator = std.testing.allocator;

    var state = HistoryState{
        .allocator = allocator,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, "/tmp/test_history"),
        .max_entries = 100,
    };
    defer {
        for (state.entries.items) |entry| allocator.free(entry);
        state.entries.deinit(allocator);
        allocator.free(state.history_path);
    }

    state.addEntry("history1");
    state.addEntry("history2");
    state.addEntry("history3");

    var all_items = std.ArrayList([]const u8).empty;
    defer {
        for (all_items.items) |item| allocator.free(item);
        all_items.deinit(allocator);
    }

    try all_items.append(allocator, try allocator.dupe(u8, "other1"));
    try all_items.append(allocator, try allocator.dupe(u8, "history3"));
    try all_items.append(allocator, try allocator.dupe(u8, "history2"));
    try all_items.append(allocator, try allocator.dupe(u8, "history1"));
    try all_items.append(allocator, try allocator.dupe(u8, "other2"));

    // Simulate 10 rapid filter updates
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) {
        var filtered = std.ArrayList(usize).empty;
        defer filtered.deinit(allocator);

        // Different filter results each time (simulating typing)
        if (iteration % 2 == 0) {
            // All items match
            try filtered.append(allocator, 0);
            try filtered.append(allocator, 1);
            try filtered.append(allocator, 2);
            try filtered.append(allocator, 3);
            try filtered.append(allocator, 4);
        } else {
            // Only some items match
            try filtered.append(allocator, 1);
            try filtered.append(allocator, 2);
            try filtered.append(allocator, 3);
        }

        const original_len = filtered.items.len;
        const state_ptr: ?features_mod.FeatureState = @ptrCast(&state);
        afterFilter(state_ptr, &filtered, all_items.items);

        // Verify correctness after each update
        try std.testing.expectEqual(original_len, filtered.items.len);

        // Verify all indices valid
        for (filtered.items) |idx| {
            try std.testing.expect(idx < all_items.items.len);
        }
    }
}
