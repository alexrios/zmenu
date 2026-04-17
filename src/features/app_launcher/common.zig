//! Shared types and utilities for the app launcher feature.
//! Platform backends produce AppEntry slices; the feature module converts them to Items.

const std = @import("std");

/// A discovered application entry (platform-agnostic)
pub const AppEntry = struct {
    /// Display name shown in the menu (e.g., "Firefox")
    name: []const u8,
    /// Platform-specific launch command (e.g., "firefox" or "open /Applications/Firefox.app")
    exec: []const u8,
    /// Whether this app requires a terminal emulator to run
    terminal: bool = false,

    pub fn deinit(self: AppEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.exec);
    }
};

/// Strip desktop entry field codes from an Exec string.
/// Handles: %f %F %u %U %d %D %n %N %i %c %k and %% → %
/// See: https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html
pub fn cleanExec(allocator: std.mem.Allocator, raw_exec: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < raw_exec.len) {
        if (raw_exec[i] == '%' and i + 1 < raw_exec.len) {
            const next = raw_exec[i + 1];
            if (next == '%') {
                // %% → literal %
                try result.append(allocator, '%');
                i += 2;
            } else if (isFieldCode(next)) {
                // Strip the field code
                i += 2;
                // Also strip trailing space if present
                if (i < raw_exec.len and raw_exec[i] == ' ') {
                    i += 1;
                }
            } else {
                try result.append(allocator, raw_exec[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, raw_exec[i]);
            i += 1;
        }
    }

    // Trim trailing whitespace
    var len = result.items.len;
    while (len > 0 and result.items[len - 1] == ' ') {
        len -= 1;
    }
    result.shrinkRetainingCapacity(len);

    return try result.toOwnedSlice(allocator);
}

fn isFieldCode(c: u8) bool {
    return switch (c) {
        'f', 'F', 'u', 'U', 'd', 'D', 'n', 'N', 'i', 'c', 'k' => true,
        else => false,
    };
}

/// Wrap an exec command for terminal execution.
/// Checks $TERMINAL env var first, falls back to xterm.
/// If no terminal emulator is found, returns the bare exec command
/// (the user can still pipe it to their own terminal wrapper).
pub fn wrapTerminalExec(allocator: std.mem.Allocator, exec: []const u8) ![]const u8 {
    const terminal = std.posix.getenv("TERMINAL") orelse "xterm";
    return std.fmt.allocPrint(allocator, "{s} -e {s}", .{ terminal, exec });
}

// ============================================================================
// Tests
// ============================================================================

test "cleanExec - strips single-letter field codes" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "firefox %u");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("firefox", result);
}

test "cleanExec - strips multiple field codes" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "libreoffice %U %F");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("libreoffice", result);
}

test "cleanExec - preserves literal percent" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "echo 100%%");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("echo 100%", result);
}

test "cleanExec - no field codes unchanged" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "htop");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("htop", result);
}

test "cleanExec - strips all known codes" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "app %f %F %u %U %d %D %n %N %i %c %k");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("app", result);
}

test "cleanExec - preserves arguments before field codes" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "firefox --new-window %u");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("firefox --new-window", result);
}

test "cleanExec - empty string" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "cleanExec - unknown percent code preserved" {
    const allocator = std.testing.allocator;

    const result = try cleanExec(allocator, "echo %z");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("echo %z", result);
}
