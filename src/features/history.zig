//! History feature for zmenu
//!
//! Tracks recently selected items and boosts them in filter results.
//! History is stored in XDG_DATA_HOME/zmenu/history (or ~/.local/share/zmenu/history)
//!
//! To enable: set `history = true` in config.zig features struct

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const features_mod = @import("../features.zig");

/// History configuration
pub const history_config = struct {
    /// Maximum number of history entries to keep
    pub const max_entries: usize = if (@hasDecl(config.features, "history_max_entries"))
        config.features.history_max_entries
    else
        100;

    /// History file name
    pub const filename: []const u8 = "history";
};

/// History state maintained across hooks
pub const HistoryState = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8),
    history_path: []const u8,

    /// Load history from disk
    pub fn load(allocator: std.mem.Allocator) !*HistoryState {
        const state = try allocator.create(HistoryState);
        errdefer allocator.destroy(state);

        state.* = .{
            .allocator = allocator,
            .entries = std.ArrayList([]const u8).empty,
            .history_path = try getHistoryPath(allocator),
        };
        errdefer allocator.free(state.history_path);

        // Try to load existing history
        state.loadFromFile() catch |err| {
            // File not existing is fine, other errors are logged but not fatal
            if (err != error.FileNotFound) {
                std.debug.print("zmenu: warning: could not load history: {}\n", .{err});
            }
        };

        return state;
    }

    fn loadFromFile(self: *HistoryState) !void {
        const file = try std.fs.openFileAbsolute(self.history_path, .{});
        defer file.close();

        // Read entire file content
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        // Split into lines
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const entry = try self.allocator.dupe(u8, line);
            try self.entries.append(self.allocator, entry);
        }
    }

    /// Save history to disk
    pub fn save(self: *HistoryState) void {
        // Ensure directory exists
        if (std.fs.path.dirname(self.history_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| {
                if (err != error.PathAlreadyExists) {
                    std.debug.print("zmenu: warning: could not create history dir: {}\n", .{err});
                    return;
                }
            };
        }

        const file = std.fs.createFileAbsolute(self.history_path, .{}) catch |err| {
            std.debug.print("zmenu: warning: could not save history: {}\n", .{err});
            return;
        };
        defer file.close();

        // Write each entry followed by newline
        for (self.entries.items) |entry| {
            _ = file.write(entry) catch continue;
            _ = file.write("\n") catch continue;
        }
    }

    /// Add an entry to history (moves to front if exists)
    pub fn addEntry(self: *HistoryState, item: []const u8) void {
        // Remove if already exists (will re-add at front)
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

        // Trim to max entries
        while (self.entries.items.len > history_config.max_entries) {
            const removed = self.entries.items[self.entries.items.len - 1];
            self.entries.shrinkRetainingCapacity(self.entries.items.len - 1);
            self.allocator.free(removed);
        }
    }

    /// Get position in history (0 = most recent, null = not in history)
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

/// Get the history file path
fn getHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
    // Try XDG_DATA_HOME first
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg_data| {
        return std.fmt.allocPrint(allocator, "{s}/zmenu/{s}", .{ xdg_data, history_config.filename });
    }

    // Fall back to ~/.local/share
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/share/zmenu/{s}", .{ home, history_config.filename });
    }

    // Windows fallback
    if (builtin.os.tag == .windows) {
        if (std.posix.getenv("APPDATA")) |appdata| {
            return std.fmt.allocPrint(allocator, "{s}\\zmenu\\{s}", .{ appdata, history_config.filename });
        }
    }

    return error.NoHomeDirectory;
}

// ============================================================================
// HOOK IMPLEMENTATIONS
// ============================================================================

fn onInit(allocator: std.mem.Allocator) anyerror!?features_mod.FeatureState {
    const state = try HistoryState.load(allocator);
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

    // Sort filtered items: history items first (by recency), then non-history items
    // Use insertion sort to maintain stability for non-history items
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

            // Compare: items with history position come before those without
            // Among history items, lower position (more recent) comes first
            const should_swap = blk: {
                if (item_pos) |ip| {
                    if (prev_pos) |pp| {
                        break :blk ip < pp; // Both in history: more recent first
                    } else {
                        break :blk true; // item in history, prev not: swap
                    }
                } else {
                    break :blk false; // item not in history: don't swap
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

// ============================================================================
// FEATURE DEFINITION
// ============================================================================

/// Feature registration for the hook system
pub const feature = features_mod.Feature{
    .name = "history",
    .hooks = .{
        .onInit = &onInit,
        .onDeinit = &onDeinit,
        .afterFilter = &afterFilter,
        .onSelect = &onSelect,
    },
};

// ============================================================================
// TESTS
// ============================================================================

test "HistoryState - add and retrieve entries" {
    const allocator = std.testing.allocator;

    // Create state without file
    var state = HistoryState{
        .allocator = allocator,
        .entries = std.ArrayList([]const u8).empty,
        .history_path = try allocator.dupe(u8, "/tmp/zmenu_test_history"),
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
    state.addEntry("item1"); // Re-add

    try std.testing.expectEqual(@as(?usize, 0), state.getPosition("item1"));
    try std.testing.expectEqual(@as(?usize, 1), state.getPosition("item2"));
    try std.testing.expectEqual(@as(usize, 2), state.entries.items.len);
}
