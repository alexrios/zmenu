//! zmenu - A cross-platform dmenu-like application launcher
//!
//! Usage: echo -e "Item 1\nItem 2" | zmenu
//!
//! Configuration:
//!   - Copy config.def.zig to config.zig and customize, then rebuild

const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const features = @import("features.zig");
const config = @import("config");
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

/// Parse feature CLI flags from command-line arguments
fn parseFeatureFlags(args: []const []const u8, allocator: std.mem.Allocator) !features.ParsedFlags {
    var result = features.ParsedFlags.init(allocator);
    errdefer result.deinit();

    // Initialize storage for each feature
    inline for (features.enabled_features) |_| {
        try result.values.append(allocator, std.ArrayList(?features.FlagValue).empty);
    }

    // Parse flags for each enabled feature
    inline for (features.enabled_features, 0..) |feature, feat_idx| {
        if (feature.cli_flags) |flags| {
            for (flags) |flag| {
                const value = parseFlag(args, flag) catch |err| {
                    std.log.err("error parsing --{s}: {}", .{ flag.long, err });
                    return err;
                };
                if (value) |v| {
                    try result.values.items[feat_idx].append(allocator, v);
                } else if (flag.default) |default_val| {
                    try result.values.items[feat_idx].append(allocator, default_val);
                } else if (flag.required) {
                    std.log.err("required flag --{s} not provided", .{flag.long});
                    return error.MissingRequiredFlag;
                } else {
                    // Optional flag not provided — store null (distinguishable from zero)
                    try result.values.items[feat_idx].append(allocator, null);
                }
            }
        }
    }

    return result;
}

/// Check if a value argument looks like a flag (starts with "-")
fn looksLikeFlag(value: []const u8) bool {
    return value.len > 0 and value[0] == '-';
}

/// Parse a single flag from args.
/// Returns the parsed value, null if not found, or an error.
/// Caller is responsible for user-facing error messages.
fn parseFlag(args: []const []const u8, flag: features.CliFlag) !?features.FlagValue {
    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Check long flag (no allocation: match "--" prefix then compare suffix)
        if (std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], flag.long)) {
            return try parseFlagValue(args, i, flag);
        }

        // Check short flag
        if (flag.short) |short_char| {
            const short_flag = &[_]u8{ '-', short_char };
            if (std.mem.eql(u8, arg, short_flag)) {
                return try parseFlagValue(args, i, flag);
            }
        }
    }

    return null; // Flag not found
}

/// Extract the value for a matched flag at position i in args.
fn parseFlagValue(args: []const []const u8, i: usize, flag: features.CliFlag) !features.FlagValue {
    return switch (flag.value_type) {
        .bool => features.FlagValue{ .bool = true },
        .string => blk: {
            if (i + 1 >= args.len or looksLikeFlag(args[i + 1])) {
                return error.MissingFlagValue;
            }
            break :blk features.FlagValue{ .string = args[i + 1] };
        },
        .int => blk: {
            // Int flags don't check looksLikeFlag — negative numbers start with "-"
            if (i + 1 >= args.len) {
                return error.MissingFlagValue;
            }
            const value = std.fmt.parseInt(i64, args[i + 1], 10) catch {
                return error.InvalidFlagValue;
            };
            break :blk features.FlagValue{ .int = value };
        },
    };
}

pub fn main() !void {
    // Use DebugAllocator in debug builds for leak detection,
    // SmpAllocator in release builds for production performance
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug)
        debug_alloc.allocator()
    else
        std.heap.smp_allocator;
    defer if (builtin.mode == .Debug) {
        _ = debug_alloc.deinit();
    };

    // Check for --version or --features flag
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
            try printVersion();
            return;
        } else if (std.mem.eql(u8, args[1], "--features")) {
            try printFeatures();
            return;
        } else if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            printHelp();
            return;
        }
    }

    // Parse --monitor flag
    var monitor_index: ?usize = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--monitor") or std.mem.eql(u8, args[i], "-m")) {
            if (i + 1 >= args.len) {
                std.log.err("--monitor requires a numeric argument", .{});
                std.process.exit(1);
            }
            monitor_index = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                std.log.err("--monitor argument must be a valid number", .{});
                std.process.exit(1);
            };
            i += 1; // Skip the argument value
        }
    }

    // Parse feature-specific CLI flags
    var parsed_flags = try parseFeatureFlags(args, allocator);
    defer parsed_flags.deinit();

    var application = try app.App.init(allocator, monitor_index, &parsed_flags);
    defer application.deinit();

    // Check if app launcher wants to skip stdin
    const skip_stdin = blk: {
        if (!application.has_provided_items) break :blk false;
        // If features provided items, skip stdin unless --app-merge-stdin is set
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--app-merge-stdin")) break :blk false;
        }
        break :blk true;
    };

    try application.run(skip_stdin);
}

fn printVersion() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("zmenu 0.2.0 - Cross-platform dmenu-like application launcher\n");
    try stdout.writeAll("Built with Zig 0.15.2\n");

    try stdout.flush();
}

fn printFeatures() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("zmenu compile-time features:\n\n");

    if (features.enabled_count == 0) {
        try stdout.writeAll("  [none enabled - minimal build]\n\n");
    } else {
        try stdout.print("Enabled features ({d}):\n", .{features.enabled_count});

        inline for (features.enabled_features) |feature| {
            try stdout.print("  ✓ {s}\n", .{feature.name});
        }
        try stdout.writeAll("\n");
    }

    try stdout.writeAll("Configuration:\n");
    try stdout.print("  - max_visible_items: {d}\n", .{config.limits.max_visible_items});
    try stdout.print("  - max_item_length: {d}\n", .{config.limits.max_item_length});
    try stdout.print("  - case_sensitive: {}\n", .{config.features.case_sensitive});
    try stdout.print("  - match_mode: {s}\n", .{@tagName(config.features.match_mode)});

    if (@hasDecl(config.features, "history") and config.features.history) {
        try stdout.print("  - history_max_entries: {d}\n", .{config.features.history_max_entries});
    }

    try stdout.flush();
}

fn printHelp() void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    _ = stdout.writeAll(
        \\zmenu - Cross-platform dmenu-like application launcher
        \\
        \\Usage:
        \\  echo -e "Item 1\nItem 2\nItem 3" | zmenu
        \\  seq 1 100 | zmenu
        \\
        \\Options:
        \\  -h, --help      Show this help message
        \\  -v, --version   Show version information
        \\  --features      Show compile-time features and configuration
        \\  -m, --monitor N Specify monitor/display index (0 = primary)
        \\
    ) catch {};

    // Add feature-specific flags (compile-time generated)
    const feature_help = comptime features.getFeatureFlagsHelp();
    if (feature_help.len > 0) {
        _ = stdout.writeAll(feature_help) catch {};
    }

    _ = stdout.writeAll(
        \\
        \\Configuration:
        \\  Copy config.def.zig to config.zig and customize, then rebuild
        \\
        \\Keyboard shortcuts:
        \\  Enter           Confirm selection
        \\  Escape/Ctrl+C   Cancel and exit
        \\  Up/Down/j/k     Navigate items
        \\  Tab/Shift+Tab   Navigate items
        \\  Home/End        Jump to first/last item
        \\  PgUp/PgDown     Navigate by page
        \\  Backspace       Delete character
        \\  Ctrl+U          Clear input
        \\  Ctrl+W          Delete word
        \\
    ) catch {};

    stdout.flush() catch {};
}

test "parseFlag - string flag rejects value that looks like another flag" {
    // --hist-file --hist-limit (user forgot the path argument).
    // parseFlag should reject values starting with "-" for string/int flags.

    const string_flag = features.CliFlag{
        .long = "hist-file",
        .short = 'H',
        .description = "Custom history file path",
        .value_type = .string,
    };

    // Missing value: next arg is another flag
    const args = &[_][]const u8{ "zmenu", "--hist-file", "--hist-limit" };
    const result = parseFlag(args, string_flag);
    try std.testing.expectError(error.MissingFlagValue, result);
}

test "parseFlag - short flag rejects value that looks like a flag" {
    const string_flag = features.CliFlag{
        .long = "hist-file",
        .short = 'H',
        .description = "Custom history file path",
        .value_type = .string,
    };

    const args = &[_][]const u8{ "zmenu", "-H", "--something" };
    const result = parseFlag(args, string_flag);
    try std.testing.expectError(error.MissingFlagValue, result);
}

test "parseFlag - int flag accepts negative values" {
    const int_flag = features.CliFlag{
        .long = "offset",
        .description = "An offset value",
        .value_type = .int,
    };

    const args = &[_][]const u8{ "zmenu", "--offset", "-5" };
    const result = try parseFlag(args, int_flag);
    if (result) |val| {
        try std.testing.expectEqual(@as(i64, -5), val.int);
    } else {
        return error.TestExpectedEqual;
    }
}

test "parseFlag - int flag rejects non-numeric value" {
    const int_flag = features.CliFlag{
        .long = "offset",
        .description = "An offset value",
        .value_type = .int,
    };

    const args = &[_][]const u8{ "zmenu", "--offset", "--other-flag" };
    const result = parseFlag(args, int_flag);
    try std.testing.expectError(error.InvalidFlagValue, result);
}

test "parseFlag - string flag accepts normal value" {
    const string_flag = features.CliFlag{
        .long = "hist-file",
        .short = 'H',
        .description = "Custom history file path",
        .value_type = .string,
    };

    const args = &[_][]const u8{ "zmenu", "--hist-file", "/tmp/history" };
    const result = try parseFlag(args, string_flag);
    if (result) |val| {
        try std.testing.expectEqualStrings("/tmp/history", val.string);
    } else {
        return error.TestExpectedEqual;
    }
}

test "parseFlag - uses no heap allocation for flag matching" {
    // Bug: parseFlag used allocPrint + catch unreachable to build "--flagname"
    // for comparison. This is UB in release on OOM. The fix should use
    // std.mem.startsWith which requires zero allocation.

    const test_flag = features.CliFlag{
        .long = "test-flag",
        .short = 't',
        .description = "A test flag",
        .value_type = .bool,
    };

    // This should work without any allocator — zero allocations needed
    const args = &[_][]const u8{ "zmenu", "--test-flag" };
    const result = parseFlag(args, test_flag) catch |err| {
        std.debug.print("BUG: parseFlag failed with allocator error: {}\n", .{err});
        return error.TestExpectedEqual;
    };

    // Should find the flag
    if (result) |val| {
        try std.testing.expect(val.bool == true);
    } else {
        std.debug.print("BUG: parseFlag didn't find --test-flag\n", .{});
        return error.TestExpectedEqual;
    }
}

// Re-export tests from modules
test {
    _ = @import("app.zig");
    _ = @import("input.zig");
    _ = @import("features.zig");
    _ = @import("features/history.zig");
    _ = @import("features/app_launcher/common.zig");
    if (builtin.os.tag == .linux) {
        _ = @import("features/app_launcher/linux.zig");
    }
    if (builtin.os.tag == .macos) {
        _ = @import("features/app_launcher/macos.zig");
    }
}
