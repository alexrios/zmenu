//! zmenu - A cross-platform dmenu-like application launcher
//!
//! Usage: echo -e "Item 1\nItem 2" | zmenu
//!
//! Configuration:
//!   - Copy config.def.zig to config.zig and customize, then rebuild

const std = @import("std");
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
        try result.values.append(allocator, std.ArrayList(features.FlagValue).empty);
    }

    // Parse flags for each enabled feature
    inline for (features.enabled_features, 0..) |feature, feat_idx| {
        if (feature.cli_flags) |flags| {
            for (flags) |flag| {
                const value = try parseFlag(args, flag, allocator);
                if (value) |v| {
                    try result.values.items[feat_idx].append(allocator, v);
                } else if (flag.default) |default_val| {
                    try result.values.items[feat_idx].append(allocator, default_val);
                } else if (flag.required) {
                    std.log.err("required flag --{s} not provided", .{flag.long});
                    return error.MissingRequiredFlag;
                } else {
                    // Optional flag not provided, use zero value
                    const zero_value = switch (flag.value_type) {
                        .string => features.FlagValue{ .string = "" },
                        .int => features.FlagValue{ .int = 0 },
                        .bool => features.FlagValue{ .bool = false },
                    };
                    try result.values.items[feat_idx].append(allocator, zero_value);
                }
            }
        }
    }

    return result;
}

/// Parse a single flag from args
fn parseFlag(args: []const []const u8, flag: features.CliFlag, allocator: std.mem.Allocator) !?features.FlagValue {
    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Check long flag
        const long_flag = std.fmt.allocPrint(allocator, "--{s}", .{flag.long}) catch unreachable;
        defer allocator.free(long_flag);

        if (std.mem.eql(u8, arg, long_flag)) {
            return switch (flag.value_type) {
                .bool => features.FlagValue{ .bool = true },
                .string => blk: {
                    if (i + 1 >= args.len) {
                        std.log.err("--{s} requires a value", .{flag.long});
                        return error.MissingFlagValue;
                    }
                    break :blk features.FlagValue{ .string = args[i + 1] };
                },
                .int => blk: {
                    if (i + 1 >= args.len) {
                        std.log.err("--{s} requires a numeric value", .{flag.long});
                        return error.MissingFlagValue;
                    }
                    const value = std.fmt.parseInt(i64, args[i + 1], 10) catch {
                        std.log.err("--{s} requires a valid integer (got: '{s}')", .{ flag.long, args[i + 1] });
                        return error.InvalidFlagValue;
                    };
                    break :blk features.FlagValue{ .int = value };
                },
            };
        }

        // Check short flag
        if (flag.short) |short_char| {
            const short_flag = &[_]u8{ '-', short_char };
            if (std.mem.eql(u8, arg, short_flag)) {
                return switch (flag.value_type) {
                    .bool => features.FlagValue{ .bool = true },
                    .string => blk: {
                        if (i + 1 >= args.len) {
                            std.log.err("-{c} requires a value", .{short_char});
                            return error.MissingFlagValue;
                        }
                        break :blk features.FlagValue{ .string = args[i + 1] };
                    },
                    .int => blk: {
                        if (i + 1 >= args.len) {
                            std.log.err("-{c} requires a numeric value", .{short_char});
                            return error.MissingFlagValue;
                        }
                        const value = std.fmt.parseInt(i64, args[i + 1], 10) catch {
                            std.log.err("-{c} requires a valid integer (got: '{s}')", .{ short_char, args[i + 1] });
                            return error.InvalidFlagValue;
                        };
                        break :blk features.FlagValue{ .int = value };
                    },
                };
            }
        }
    }

    return null; // Flag not found
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    try application.run();
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

// Re-export tests from modules
test {
    _ = @import("app.zig");
    _ = @import("input.zig");
    _ = @import("features.zig");
    _ = @import("features/history.zig");
}
