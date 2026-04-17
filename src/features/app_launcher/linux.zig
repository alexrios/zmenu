//! Linux application discovery via XDG .desktop files.
//!
//! Scans standard XDG application directories (including Flatpak and Snap)
//! and parses .desktop files to discover installed applications.
//!
//! Spec: https://specifications.freedesktop.org/desktop-entry/latest/

const std = @import("std");
const common = @import("common.zig");

const AppEntry = common.AppEntry;

/// Home-relative application directories (prepended with $HOME).
/// Scanned after $XDG_DATA_HOME if set.
const home_relative_dirs = [_][]const u8{
    ".local/share/applications",
    ".local/share/flatpak/exports/share/applications",
};

/// Absolute system application directories.
const system_dirs = [_][]const u8{
    "/usr/local/share/applications",
    "/usr/share/applications",
    "/var/lib/flatpak/exports/share/applications",
    "/var/lib/snapd/desktop/applications",
};

/// Parsed fields from a .desktop file's [Desktop Entry] section
const DesktopEntry = struct {
    name: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    entry_type: ?[]const u8 = null,
    terminal: bool = false,
    no_display: bool = false,
    hidden: bool = false,
};

/// Discover installed applications by scanning XDG .desktop files.
/// Caller owns the returned slice and each AppEntry's strings.
pub fn discoverApps(allocator: std.mem.Allocator) ![]AppEntry {
    var entries = std.ArrayList(AppEntry).empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    // Track seen filenames for dedup (first dir wins per XDG spec)
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return entries.toOwnedSlice(allocator);
    const xdg_data_home = std.posix.getenv("XDG_DATA_HOME");

    // XDG_DATA_HOME has highest priority per the XDG Base Directory spec.
    // When set, it replaces ~/.local/share for application lookup.
    if (xdg_data_home) |xdg_data| {
        const xdg_apps = try std.fmt.allocPrint(allocator, "{s}/applications", .{xdg_data});
        defer allocator.free(xdg_apps);
        try scanDirectory(allocator, xdg_apps, &entries, &seen);
    }

    // Home-relative directories (skip .local/share/applications if XDG_DATA_HOME is set)
    for (home_relative_dirs) |rel_path| {
        if (xdg_data_home != null and std.mem.eql(u8, rel_path, ".local/share/applications")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, rel_path });
        defer allocator.free(full_path);
        try scanDirectory(allocator, full_path, &entries, &seen);
    }

    // Absolute system directories
    for (system_dirs) |dir_path| {
        try scanDirectory(allocator, dir_path, &entries, &seen);
    }

    return entries.toOwnedSlice(allocator);
}

fn scanDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    entries: *std.ArrayList(AppEntry),
    seen: *std.StringHashMap(void),
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

        // Dedup: first directory wins for same filename
        if (seen.contains(entry.name)) continue;
        const owned_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned_name);
        try seen.put(owned_name, {});

        if (try parseDesktopFile(allocator, dir, entry.name)) |app_entry| {
            entries.append(allocator, app_entry) catch |err| {
                app_entry.deinit(allocator);
                return err;
            };
        }
    }
}

fn parseDesktopFile(allocator: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !?AppEntry {
    const file = dir.openFile(filename, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 256 * 1024) catch return null;
    defer allocator.free(content);

    var parsed = DesktopEntry{};
    var in_desktop_entry = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header
        if (trimmed[0] == '[') {
            if (in_desktop_entry) break; // Done with [Desktop Entry]
            in_desktop_entry = std.mem.eql(u8, trimmed, "[Desktop Entry]");
            continue;
        }

        if (!in_desktop_entry) continue;

        // Parse key=value
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
            const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
            const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

            if (std.mem.eql(u8, key, "Name")) {
                parsed.name = value;
            } else if (std.mem.eql(u8, key, "Exec")) {
                parsed.exec = value;
            } else if (std.mem.eql(u8, key, "Type")) {
                parsed.entry_type = value;
            } else if (std.mem.eql(u8, key, "Terminal")) {
                parsed.terminal = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "NoDisplay")) {
                parsed.no_display = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "Hidden")) {
                parsed.hidden = std.mem.eql(u8, value, "true");
            }
        }
    }

    // Validate: must be Application type, not hidden, must have Name and Exec
    if (parsed.no_display or parsed.hidden) return null;
    if (parsed.entry_type) |t| {
        if (!std.mem.eql(u8, t, "Application")) return null;
    } else {
        return null; // Type is required
    }
    const name = parsed.name orelse return null;
    const exec = parsed.exec orelse return null;
    if (name.len == 0 or exec.len == 0) return null;

    // Clean exec field (strip %f, %u, etc.)
    const cleaned_exec = try common.cleanExec(allocator, exec);

    // Wrap in terminal if needed, handling ownership transfer carefully
    const final_exec = if (parsed.terminal) blk: {
        const wrapped = common.wrapTerminalExec(allocator, cleaned_exec) catch |err| {
            allocator.free(cleaned_exec);
            return err;
        };
        allocator.free(cleaned_exec);
        break :blk wrapped;
    } else cleaned_exec;
    errdefer allocator.free(final_exec);

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return AppEntry{
        .name = owned_name,
        .exec = final_exec,
        .terminal = parsed.terminal,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseDesktopFile - valid application" {
    const allocator = std.testing.allocator;

    // Create a temp directory with a .desktop file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\[Desktop Entry]
        \\Name=Firefox
        \\Exec=firefox %u
        \\Type=Application
        \\Terminal=false
    ;
    try tmp.dir.writeFile(.{ .sub_path = "firefox.desktop", .data = content });

    const result = try parseDesktopFile(allocator, tmp.dir, "firefox.desktop");
    try std.testing.expect(result != null);

    const entry = result.?;
    defer entry.deinit(allocator);

    try std.testing.expectEqualStrings("Firefox", entry.name);
    try std.testing.expectEqualStrings("firefox", entry.exec);
    try std.testing.expect(!entry.terminal);
}

test "parseDesktopFile - hidden app returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\[Desktop Entry]
        \\Name=Hidden App
        \\Exec=hidden
        \\Type=Application
        \\Hidden=true
    ;
    try tmp.dir.writeFile(.{ .sub_path = "hidden.desktop", .data = content });

    const result = try parseDesktopFile(allocator, tmp.dir, "hidden.desktop");
    try std.testing.expect(result == null);
}

test "parseDesktopFile - NoDisplay app returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\[Desktop Entry]
        \\Name=No Display
        \\Exec=nodisplay
        \\Type=Application
        \\NoDisplay=true
    ;
    try tmp.dir.writeFile(.{ .sub_path = "nodisplay.desktop", .data = content });

    const result = try parseDesktopFile(allocator, tmp.dir, "nodisplay.desktop");
    try std.testing.expect(result == null);
}

test "parseDesktopFile - non-Application type returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\[Desktop Entry]
        \\Name=My Link
        \\Exec=xdg-open http://example.com
        \\Type=Link
    ;
    try tmp.dir.writeFile(.{ .sub_path = "link.desktop", .data = content });

    const result = try parseDesktopFile(allocator, tmp.dir, "link.desktop");
    try std.testing.expect(result == null);
}

test "parseDesktopFile - missing Name returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\[Desktop Entry]
        \\Exec=mystery
        \\Type=Application
    ;
    try tmp.dir.writeFile(.{ .sub_path = "noname.desktop", .data = content });

    const result = try parseDesktopFile(allocator, tmp.dir, "noname.desktop");
    try std.testing.expect(result == null);
}

test "parseDesktopFile - terminal app wraps exec" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\[Desktop Entry]
        \\Name=htop
        \\Exec=htop
        \\Type=Application
        \\Terminal=true
    ;
    try tmp.dir.writeFile(.{ .sub_path = "htop.desktop", .data = content });

    const result = try parseDesktopFile(allocator, tmp.dir, "htop.desktop");
    try std.testing.expect(result != null);

    const entry = result.?;
    defer entry.deinit(allocator);

    try std.testing.expectEqualStrings("htop", entry.name);
    try std.testing.expect(entry.terminal);
    // Exec should be wrapped with a terminal emulator
    try std.testing.expect(std.mem.endsWith(u8, entry.exec, "-e htop"));
}

test "parseDesktopFile - ignores other sections" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\[Desktop Entry]
        \\Name=MyApp
        \\Exec=myapp
        \\Type=Application
        \\
        \\[Desktop Action New]
        \\Name=New Window
        \\Exec=myapp --new-window
    ;
    try tmp.dir.writeFile(.{ .sub_path = "myapp.desktop", .data = content });

    const result = try parseDesktopFile(allocator, tmp.dir, "myapp.desktop");
    try std.testing.expect(result != null);

    const entry = result.?;
    defer entry.deinit(allocator);

    try std.testing.expectEqualStrings("MyApp", entry.name);
    try std.testing.expectEqualStrings("myapp", entry.exec);
}

test "scanDirectory - gracefully handles missing directory" {
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

    // Scanning a non-existent directory should not error
    try scanDirectory(allocator, "/tmp/zmenu_nonexistent_test_dir_12345", &entries, &seen);
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}
