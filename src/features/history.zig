//! History feature - tracks and boosts recently selected items
//!
//! Storage: XDG_DATA_HOME/zmenu/history (or ~/.local/share/zmenu/history)
//! Enable: set `history = true` in config.zig

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const features_mod = @import("../features.zig");
const types = @import("../types.zig");

pub const history_config = struct {
    pub const max_entries: usize = if (@hasDecl(config.features, "history_max_entries"))
        config.features.history_max_entries
    else
        100;

    pub const filename: []const u8 = "history";
};

pub const HistoryState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList([]const u8),
    history_path: []const u8,
    max_entries: usize,
    dirty: bool = false,

    pub fn load(allocator: std.mem.Allocator, io: std.Io) !*HistoryState {
        return loadWithConfig(allocator, io, null, history_config.max_entries);
    }

    pub fn loadWithConfig(allocator: std.mem.Allocator, io: std.Io, custom_path: ?[]const u8, max_entries: usize) !*HistoryState {
        const state = try allocator.create(HistoryState);
        errdefer allocator.destroy(state);

        const history_path = if (custom_path) |path|
            try allocator.dupe(u8, path)
        else
            try getHistoryPath(allocator);

        state.* = .{
            .allocator = allocator,
            .io = io,
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
        std.debug.assert(self.history_path.len > 0);
        std.debug.assert(self.entries.items.len == 0);

        const content = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.history_path,
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (self.entries.items.len >= self.max_entries) break;
            const entry = try self.allocator.dupe(u8, line);
            try self.entries.append(self.allocator, entry);
        }
        std.debug.assert(self.entries.items.len <= self.max_entries);
    }

    pub fn save(self: *HistoryState) void {
        std.debug.assert(self.history_path.len > 0);
        std.debug.assert(self.entries.items.len <= self.max_entries);

        if (!self.dirty) return;

        if (std.fs.path.dirname(self.history_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch |err| {
                std.log.warn("could not create history dir: {}", .{err});
                return;
            };
        }

        const file = std.Io.Dir.createFileAbsolute(self.io, self.history_path, .{}) catch |err| {
            std.log.warn("could not save history: {}", .{err});
            return;
        };
        defer file.close(self.io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &write_buf);
        const writer = &file_writer.interface;
        for (self.entries.items) |entry| {
            writer.writeAll(entry) catch |err| {
                std.log.warn("history save aborted mid-write: {}", .{err});
                return;
            };
            writer.writeAll("\n") catch |err| {
                std.log.warn("history save aborted mid-write: {}", .{err});
                return;
            };
        }
        writer.flush() catch |err| std.log.warn("history flush failed: {}", .{err});
    }

    /// Add entry (moves to front if exists). Marks state as dirty.
    pub fn addEntry(self: *HistoryState, item: []const u8) void {
        std.debug.assert(self.max_entries > 0);
        std.debug.assert(self.entries.items.len <= self.max_entries);

        // Remove if exists (modifies state, so mark dirty)
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry, item)) {
                self.allocator.free(entry);
                _ = self.entries.orderedRemove(i);
                self.dirty = true;
                break;
            }
        }

        // Add to front
        const new_entry = self.allocator.dupe(u8, item) catch |err| {
            std.log.warn("history addEntry: dropped on dupe OOM: {}", .{err});
            return;
        };
        self.entries.insert(self.allocator, 0, new_entry) catch |err| {
            std.log.warn("history addEntry: dropped on insert OOM: {}", .{err});
            self.allocator.free(new_entry);
            return;
        };
        self.dirty = true;

        // Trim to max (use instance max_entries). Bounded: at most one
        // iteration since insert added exactly one element.
        std.debug.assert(self.entries.items.len <= self.max_entries + 1);
        while (self.entries.items.len > self.max_entries) {
            const removed = self.entries.items[self.entries.items.len - 1];
            self.entries.shrinkRetainingCapacity(self.entries.items.len - 1);
            self.allocator.free(removed);
        }
        std.debug.assert(self.entries.items.len <= self.max_entries);
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
    const sep = std.fs.path.sep_str;

    if (comptime builtin.os.tag == .windows) {
        // Windows: use APPDATA
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.NoHomeDirectory,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "zmenu" ++ sep ++ "{s}", .{ appdata, history_config.filename });
    } else if (comptime builtin.os.tag == .macos) {
        // macOS: ~/Library/Application Support/zmenu/ (XDG override respected)
        if (std.posix.getenv("XDG_DATA_HOME")) |xdg_data| {
            return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "zmenu" ++ sep ++ "{s}", .{ xdg_data, history_config.filename });
        }

        if (std.posix.getenv("HOME")) |home| {
            return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "Library" ++ sep ++ "Application Support" ++ sep ++ "zmenu" ++ sep ++ "{s}", .{ home, history_config.filename });
        }

        return error.NoHomeDirectory;
    } else {
        // Linux/other Unix: XDG_DATA_HOME or ~/.local/share/zmenu/
        if (std.posix.getenv("XDG_DATA_HOME")) |xdg_data| {
            return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ "zmenu" ++ sep ++ "{s}", .{ xdg_data, history_config.filename });
        }

        if (std.posix.getenv("HOME")) |home| {
            return std.fmt.allocPrint(allocator, "{s}" ++ sep ++ ".local" ++ sep ++ "share" ++ sep ++ "zmenu" ++ sep ++ "{s}", .{ home, history_config.filename });
        }

        return error.NoHomeDirectory;
    }
}

fn onInit(init_data: features_mod.FeatureInitData) anyerror!?features_mod.FeatureState {
    const allocator = init_data.allocator;

    // Extract CLI flag values by name (order-independent)
    const custom_path = init_data.getString("hist-file");
    const max_entries: usize = if (init_data.getInt("hist-limit")) |v|
        @intCast(v)
    else
        history_config.max_entries;

    // Load or create history state with custom settings
    // Degrade gracefully if history path can't be resolved (e.g., missing HOME)
    const state = HistoryState.loadWithConfig(allocator, init_data.io, custom_path, max_entries) catch |err| {
        std.log.warn("history feature unavailable: {}", .{err});
        return null;
    };
    return @ptrCast(state);
}

fn onDeinit(state_ptr: ?features_mod.FeatureState, _: std.mem.Allocator) void {
    const state = features_mod.castState(HistoryState, state_ptr) orelse return;
    state.save();
    state.deinit();
}

fn afterFilter(
    state_ptr: ?features_mod.FeatureState,
    filtered_items: *std.ArrayList(usize),
    all_items: []const types.Item,
) void {
    const state = features_mod.castState(HistoryState, state_ptr) orelse return;

    if (filtered_items.items.len <= 1) return;
    if (state.entries.items.len == 0) return;

    // Build a lookup map: display text → history position (O(N) where N = history entries)
    var position_map = std.StringHashMap(usize).init(state.allocator);
    defer position_map.deinit();
    position_map.ensureTotalCapacity(@intCast(state.entries.items.len)) catch |err| {
        std.log.warn("history: skipping reorder, lookup map allocation failed: {}", .{err});
        return;
    };
    for (state.entries.items, 0..) |entry, pos| {
        position_map.put(entry, pos) catch |err| {
            std.log.warn("history: skipping reorder, lookup map population failed: {}", .{err});
            return;
        };
    }

    // Insertion sort using O(1) lookups instead of O(N) getPosition scans
    const items = filtered_items.items;

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const idx = items[i];
        const item_pos = position_map.get(all_items[idx].display);

        var j = i;
        while (j > 0) {
            const prev_pos = position_map.get(all_items[items[j - 1]].display);

            const should_swap = if (item_pos) |ip|
                if (prev_pos) |pp| ip < pp else true
            else
                false;

            if (!should_swap) break;

            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = idx;
    }
}

fn onSelect(state_ptr: ?features_mod.FeatureState, selected_item: types.Item) void {
    const state = features_mod.castState(HistoryState, state_ptr) orelse return;
    state.addEntry(selected_item.display);
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
        .io = std.testing.io,
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
        .io = std.testing.io,
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
        .io = std.testing.io,
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
    var all_items = std.ArrayList(types.Item).empty;
    defer {
        for (all_items.items) |item| item.deinit(allocator);
        all_items.deinit(allocator);
    }

    try all_items.append(allocator, try types.Item.parse(allocator, "other_item"));
    try all_items.append(allocator, try types.Item.parse(allocator, "very_recent_item"));
    try all_items.append(allocator, try types.Item.parse(allocator, "recent_item"));
    try all_items.append(allocator, try types.Item.parse(allocator, "another_item"));

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


test "HistoryState - save creates nested directories" {
    const allocator = std.testing.allocator;

    // Use a deeply nested path where intermediate dirs don't exist
    const nested_path = "/tmp/zmenu_test_nested/level1/level2/level3/history";

    // Clean up any previous test artifacts
    std.Io.Dir.cwd().deleteTree(std.testing.io, "/tmp/zmenu_test_nested") catch {};

    var state = HistoryState{
        .allocator = allocator,
        .io = std.testing.io,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, nested_path),
        .max_entries = 100,
    };
    defer {
        for (state.entries.items) |entry| allocator.free(entry);
        state.entries.deinit(allocator);
        allocator.free(state.history_path);
    }

    state.addEntry("test_item");
    state.save();

    // Verify the file was actually created
    const file = std.Io.Dir.openFileAbsolute(std.testing.io, nested_path, .{}) catch |err| {
        std.debug.print("BUG: save() failed to create file with nested dirs: {}\n", .{err});
        // Clean up
        std.Io.Dir.cwd().deleteTree(std.testing.io, "/tmp/zmenu_test_nested") catch {};
        return error.TestExpectedEqual;
    };
    file.close(std.testing.io);

    // Clean up
    std.Io.Dir.cwd().deleteTree(std.testing.io, "/tmp/zmenu_test_nested") catch {};
}

test "History afterFilter - matches on display field not value" {
    // History tracks display text. When items have display|value format,
    // afterFilter should boost items based on display match, not value.

    const allocator = std.testing.allocator;

    var state = HistoryState{
        .allocator = allocator,
        .io = std.testing.io,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, "/tmp/test_history"),
        .max_entries = 100,
    };
    defer {
        for (state.entries.items) |entry| allocator.free(entry);
        state.entries.deinit(allocator);
        allocator.free(state.history_path);
    }

    // History tracks "Firefox" (display text, not value "/usr/bin/firefox")
    state.addEntry("Firefox");

    var all_items = std.ArrayList(types.Item).empty;
    defer {
        for (all_items.items) |item| item.deinit(allocator);
        all_items.deinit(allocator);
    }

    // Items with display|value format
    try all_items.append(allocator, try types.Item.parse(allocator, "Chrome|/usr/bin/chrome"));
    try all_items.append(allocator, try types.Item.parse(allocator, "Firefox|/usr/bin/firefox"));
    try all_items.append(allocator, try types.Item.parse(allocator, "Terminal|/usr/bin/terminal"));

    var filtered = std.ArrayList(usize).empty;
    defer filtered.deinit(allocator);
    try filtered.append(allocator, 0); // Chrome
    try filtered.append(allocator, 1); // Firefox
    try filtered.append(allocator, 2); // Terminal

    const state_ptr: ?features_mod.FeatureState = @ptrCast(&state);
    afterFilter(state_ptr, &filtered, all_items.items);

    // Firefox should be boosted to first position (matched by display "Firefox")
    try std.testing.expectEqual(@as(usize, 1), filtered.items[0]);
    // All items preserved
    try std.testing.expectEqual(@as(usize, 3), filtered.items.len);

    // Verify: an item whose VALUE matches history but DISPLAY doesn't should NOT be boosted
    // (none of our items have value="Firefox", so this is implicitly tested)
}

test "HistoryState - save skipped when no changes made" {
    // Reproduces: onDeinit always calls save(), rewriting the history file even
    // when the user pressed Escape (no selection, nothing changed). A dirty flag
    // should prevent unnecessary file I/O.

    const allocator = std.testing.allocator;

    const test_path = "/tmp/zmenu_test_dirty_flag_history";

    // Clean up any previous artifacts
    std.Io.Dir.deleteFileAbsolute(std.testing.io, test_path) catch {};

    // Create state and add entries (simulates loading from file)
    var state = HistoryState{
        .allocator = allocator,
        .io = std.testing.io,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, test_path),
        .max_entries = 100,
        .dirty = false,
    };
    defer {
        for (state.entries.items) |entry| allocator.free(entry);
        state.entries.deinit(allocator);
        allocator.free(state.history_path);
    }

    // No addEntry called — dirty should remain false
    try std.testing.expect(!state.dirty);

    // Save should be a no-op when not dirty
    state.save();

    // File should NOT exist (save was skipped)
    const file_exists = blk: {
        std.Io.Dir.accessAbsolute(std.testing.io, test_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!file_exists);

    // Now add an entry — dirty should become true
    state.addEntry("test_item");
    try std.testing.expect(state.dirty);

    // Save should write the file now
    state.save();

    // File should exist
    const file_exists2 = blk: {
        std.Io.Dir.accessAbsolute(std.testing.io, test_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(file_exists2);

    // Clean up
    std.Io.Dir.deleteFileAbsolute(std.testing.io, test_path) catch {};
}

test "History afterFilter - rapid updates" {
    // This test simulates rapid filter updates (like user typing quickly).
    // Verifies that multiple reordering operations maintain correctness.

    const allocator = std.testing.allocator;

    var state = HistoryState{
        .allocator = allocator,
        .io = std.testing.io,
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

    var all_items = std.ArrayList(types.Item).empty;
    defer {
        for (all_items.items) |item| item.deinit(allocator);
        all_items.deinit(allocator);
    }

    try all_items.append(allocator, try types.Item.parse(allocator, "other1"));
    try all_items.append(allocator, try types.Item.parse(allocator, "history3"));
    try all_items.append(allocator, try types.Item.parse(allocator, "history2"));
    try all_items.append(allocator, try types.Item.parse(allocator, "history1"));
    try all_items.append(allocator, try types.Item.parse(allocator, "other2"));

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
