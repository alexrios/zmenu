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
                    switch (err) {
                        error.MissingFlagValue => std.log.err("--{s} requires a value", .{flag.long}),
                        error.InvalidFlagValue => std.log.err("--{s} requires a valid value", .{flag.long}),
                    }
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
    std.debug.assert(args.len > 0); // Process always has at least argv[0]
    std.debug.assert(flag.long.len > 0);

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Check long flag (no allocation: match "--" prefix then compare suffix)
        if (std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], flag.long)) {
            const value = try parseFlagValue(args, i, flag);
            std.debug.assert(@as(features.FlagValueType, value) == flag.value_type);
            return value;
        }

        // Check short flag
        if (flag.short) |short_char| {
            const short_flag = &[_]u8{ '-', short_char };
            if (std.mem.eql(u8, arg, short_flag)) {
                const value = try parseFlagValue(args, i, flag);
                std.debug.assert(@as(features.FlagValueType, value) == flag.value_type);
                return value;
            }
        }
    }

    return null; // Flag not found
}

/// Extract the value for a matched flag at position i in args.
fn parseFlagValue(args: []const []const u8, i: usize, flag: features.CliFlag) !features.FlagValue {
    std.debug.assert(i < args.len);
    const value: features.FlagValue = switch (flag.value_type) {
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
            const parsed = std.fmt.parseInt(i64, args[i + 1], 10) catch {
                return error.InvalidFlagValue;
            };
            break :blk features.FlagValue{ .int = parsed };
        },
    };
    std.debug.assert(@as(features.FlagValueType, value) == flag.value_type);
    return value;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    // Use DebugAllocator in debug builds for leak detection,
    // SmpAllocator in release builds for production performance
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug)
        debug_alloc.allocator()
    else
        std.heap.smp_allocator;
    defer if (builtin.mode == .Debug) {
        switch (debug_alloc.deinit()) {
            .ok => {},
            .leak => std.debug.panic("memory leak detected in debug allocator", .{}),
        }
    };

    // Args are owned by the process arena and live for the program's lifetime.
    // Sentinel-terminated strings coerce to non-sentinel slices element-wise.
    const zsentinel_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, zsentinel_args.len);
    for (zsentinel_args, args) |z, *out| out.* = z;
    std.debug.assert(args.len == zsentinel_args.len);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
            try printVersion(io);
            return;
        } else if (std.mem.eql(u8, args[1], "--features")) {
            try printFeatures(io);
            return;
        } else if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            printHelp(io);
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

    var application = try app.App.init(allocator, io, monitor_index, &parsed_flags);
    defer application.deinit();

    try application.run();
}

fn printVersion(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("zmenu " ++ build_options.version ++ " - Cross-platform dmenu-like application launcher\n");

    try stdout.flush();
}

fn printFeatures(io: std.Io) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
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

fn printHelp(io: std.Io) void {
    // Single error-handling site: writeHelpBody uses try throughout, so any
    // writeAll/flush failure short-circuits and is logged once. Previously each
    // call had its own silent catch{}, masking broken-pipe and disk-full from
    // both the user and any caller of zmenu --help.
    writeHelpBody(io) catch |err| {
        std.log.warn("help output truncated: {}", .{err});
    };
}

fn writeHelpBody(io: std.Io) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
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
    );

    const feature_help = comptime features.getFeatureFlagsHelp();
    if (feature_help.len > 0) {
        try stdout.writeAll(feature_help);
    }

    try stdout.writeAll(
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
        \\  Type to filter   Fuzzy search
        \\
        \\Environment Variables:
        \\  ZMENU_THEME      Set color theme (default: mocha)
        \\                   Available: mocha, latte, frappe, macchiato,
        \\                              dracula, gruvbox, nord, solarized
        \\
        \\Examples:
        \\  echo -e "Apple\nBanana\nCherry" | zmenu
        \\  find . -type f | zmenu
        \\  cat items.txt | zmenu
        \\  echo -e "Option A\nOption B" | ZMENU_THEME=dracula zmenu
        \\
    );

    try stdout.flush();
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
}
