//! macOS application discovery via .app bundle walking.
//!
//! Scans standard macOS application directories for .app bundles.
//! Uses directory names as display names and `open` for launching,
//! which handles translocation, quarantine, and all macOS edge cases.

const std = @import("std");
const common = @import("common.zig");

const AppEntry = common.AppEntry;

/// macOS application directories to scan, in priority order.
/// First occurrence of an app name wins.
const app_dirs = [_][]const u8{
    "/Applications",
    "/System/Applications",
};

/// Discover installed macOS applications.
/// Caller owns the returned slice and each AppEntry's strings.
pub fn discoverApps(allocator: std.mem.Allocator) ![]AppEntry {
    var entries = std.ArrayList(AppEntry).empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    // Track seen app names for dedup (first dir wins)
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    // Scan fixed directories
    for (app_dirs) |dir_path| {
        try scanAppDirectory(allocator, dir_path, &entries, &seen);
    }

    // Scan ~/Applications if it exists
    if (std.posix.getenv("HOME")) |home| {
        const user_apps = try std.fmt.allocPrint(allocator, "{s}/Applications", .{home});
        defer allocator.free(user_apps);
        try scanAppDirectory(allocator, user_apps, &entries, &seen);
    }

    return entries.toOwnedSlice(allocator);
}

fn scanAppDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    entries: *std.ArrayList(AppEntry),
    seen: *std.StringHashMap(void),
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        if (std.mem.endsWith(u8, entry.name, ".app")) {
            try addAppBundle(allocator, dir_path, entry.name, entries, seen);
        } else if (entry.kind == .directory) {
            // Recurse into subdirectories (e.g., /Applications/Utilities/)
            const subdir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(subdir_path);
            try scanSubdirectory(allocator, subdir_path, entries, seen);
        }
    }
}

fn scanSubdirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    entries: *std.ArrayList(AppEntry),
    seen: *std.StringHashMap(void),
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".app")) continue;

        try addAppBundle(allocator, dir_path, entry.name, entries, seen);
    }
}

fn addAppBundle(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    bundle_name: []const u8,
    entries: *std.ArrayList(AppEntry),
    seen: *std.StringHashMap(void),
) !void {
    // Extract display name: "Firefox.app" → "Firefox"
    const display_name = bundle_name[0 .. bundle_name.len - 4]; // Strip ".app"
    if (display_name.len == 0) return;

    // Dedup by display name
    if (seen.contains(display_name)) return;
    const owned_key = try allocator.dupe(u8, display_name);
    errdefer allocator.free(owned_key);
    try seen.put(owned_key, {});

    // Build launch command: open "/Applications/Firefox.app"
    const full_path = try std.fmt.allocPrint(allocator, "open \"{s}/{s}\"", .{ dir_path, bundle_name });
    errdefer allocator.free(full_path);

    const owned_name = try allocator.dupe(u8, display_name);
    errdefer allocator.free(owned_name);

    try entries.append(allocator, .{
        .name = owned_name,
        .exec = full_path,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "addAppBundle - extracts display name and builds exec" {
    const allocator = std.testing.allocator;

    var entries = std.ArrayList(AppEntry).empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    try addAppBundle(allocator, "/Applications", "Firefox.app", &entries, &seen);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("Firefox", entries.items[0].name);
    try std.testing.expectEqualStrings("open \"/Applications/Firefox.app\"", entries.items[0].exec);
}

test "addAppBundle - dedup by name" {
    const allocator = std.testing.allocator;

    var entries = std.ArrayList(AppEntry).empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    try addAppBundle(allocator, "/Applications", "Firefox.app", &entries, &seen);
    try addAppBundle(allocator, "/System/Applications", "Firefox.app", &entries, &seen);

    // Should only have one entry
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
}

test "addAppBundle - empty name after strip is skipped" {
    const allocator = std.testing.allocator;

    var entries = std.ArrayList(AppEntry).empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    // ".app" alone → empty display name → skipped
    try addAppBundle(allocator, "/Applications", ".app", &entries, &seen);
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "discoverApps - returns slice without crashing" {
    // Integration test: runs actual discovery on the test machine.
    // On Linux CI this will find zero macOS apps — that's fine, it shouldn't crash.
    const allocator = std.testing.allocator;

    const apps = try discoverApps(allocator);
    defer {
        for (apps) |entry| entry.deinit(allocator);
        allocator.free(apps);
    }

    // Just verify it doesn't crash and returns a valid slice
    _ = apps.len;
}
