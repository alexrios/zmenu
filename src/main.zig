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

const CliAction = enum { run, help, version, features };

const ParsedCli = struct {
    action: CliAction = .run,
    monitor_index: ?usize = null,
    feature_flags: features.ParsedFlags,

    fn deinit(self: *ParsedCli) void {
        self.feature_flags.deinit();
    }
};

const FeatureFlagLocation = struct { feature_index: usize, flag_index: usize };

fn findFeatureFlag(arg: []const u8) ?FeatureFlagLocation {
    for (features.enabled_features, 0..) |feature, feature_index| {
        const flags = feature.cli_flags orelse continue;
        for (flags, 0..) |flag, flag_index| {
            if (std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], flag.long))
                return .{ .feature_index = feature_index, .flag_index = flag_index };
            if (flag.short) |short| {
                if (arg.len == 2 and arg[0] == '-' and arg[1] == short)
                    return .{ .feature_index = feature_index, .flag_index = flag_index };
            }
        }
    }
    return null;
}

fn parseFlagValue(args: []const []const u8, i: usize, flag: features.CliFlag) !features.FlagValue {
    const value: features.FlagValue = switch (flag.value_type) {
        .bool => features.FlagValue{ .bool = true },
        .string => blk: {
            if (i + 1 >= args.len or (args[i + 1].len > 0 and args[i + 1][0] == '-')) {
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
                if (args[i + 1].len > 0 and args[i + 1][0] == '-') return error.MissingFlagValue;
                return error.InvalidFlagValue;
            };
            if (flag.int_min) |min| if (parsed < min) return error.FlagValueOutOfRange;
            if (flag.int_max) |max| if (parsed > max) return error.FlagValueOutOfRange;
            break :blk features.FlagValue{ .int = parsed };
        },
    };
    std.debug.assert(@as(features.FlagValueType, value) == flag.value_type);
    return value;
}

/// Parse every argument exactly once. Informational options are accepted in any
/// position but cannot be combined with execution options or each other.
fn parseCli(args: []const []const u8, allocator: std.mem.Allocator) !ParsedCli {
    if (args.len == 0) return error.MissingArgvZero;

    var result = ParsedCli{ .feature_flags = features.ParsedFlags.init(allocator) };
    errdefer result.deinit();
    var seen = std.ArrayList(std.ArrayList(bool)).empty;
    defer {
        for (seen.items) |*feature_seen| feature_seen.deinit(allocator);
        seen.deinit(allocator);
    }

    for (features.enabled_features) |feature| {
        const flags = feature.cli_flags orelse &.{};
        try result.feature_flags.values.append(allocator, std.ArrayList(?features.FlagValue).empty);
        try seen.append(allocator, std.ArrayList(bool).empty);
        const values = &result.feature_flags.values.items[result.feature_flags.values.items.len - 1];
        const feature_seen = &seen.items[seen.items.len - 1];
        for (flags) |flag| {
            try values.append(allocator, flag.default);
            try feature_seen.append(allocator, false);
        }
    }

    var action: ?CliAction = null;
    var execution_seen = false;
    var monitor_seen = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const info: ?CliAction = if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))
            .help
        else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))
            .version
        else if (std.mem.eql(u8, arg, "--features"))
            .features
        else
            null;
        if (info) |requested| {
            if (action != null) return error.DuplicateOrIncompatibleOption;
            if (execution_seen) return error.IncompatibleInformationalOption;
            action = requested;
            continue;
        }
        if (action != null) return error.IncompatibleInformationalOption;

        if (std.mem.eql(u8, arg, "--monitor") or std.mem.eql(u8, arg, "-m")) {
            if (monitor_seen) return error.DuplicateOption;
            if (i + 1 >= args.len) return error.MonitorIndexRequired;
            result.monitor_index = std.fmt.parseInt(usize, args[i + 1], 10) catch return error.InvalidMonitorIndex;
            monitor_seen = true;
            execution_seen = true;
            i += 1;
            continue;
        }

        if (findFeatureFlag(arg)) |location| {
            if (seen.items[location.feature_index].items[location.flag_index]) return error.DuplicateOption;
            const flag = features.enabled_features[location.feature_index].cli_flags.?[location.flag_index];
            const value = try parseFlagValue(args, i, flag);
            result.feature_flags.values.items[location.feature_index].items[location.flag_index] = value;
            seen.items[location.feature_index].items[location.flag_index] = true;
            execution_seen = true;
            if (flag.value_type != .bool) i += 1;
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') return error.UnknownOption;
        return error.UnexpectedPositionalArgument;
    }

    for (features.enabled_features, 0..) |feature, feature_index| {
        const flags = feature.cli_flags orelse continue;
        for (flags, 0..) |flag, flag_index| {
            if (flag.required and !seen.items[feature_index].items[flag_index]) return error.MissingRequiredFlag;
        }
    }
    result.action = action orelse .run;
    return result;
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

    var cli = parseCli(args, allocator) catch |err| {
        std.log.err("invalid command line: {}", .{err});
        return err;
    };
    defer cli.deinit();
    switch (cli.action) {
        .help => {
            printHelp(io);
            return;
        },
        .version => {
            try printVersion(io);
            return;
        },
        .features => {
            try printFeatures(io);
            return;
        },
        .run => {},
    }

    var application = try app.App.init(allocator, io, init.environ_map, cli.monitor_index, &cli.feature_flags);
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
        \\Examples:
        \\  echo -e "Apple\nBanana\nCherry" | zmenu
        \\  find . -type f | zmenu
        \\  cat items.txt | zmenu
        \\
    );

    try stdout.flush();
}

test "parseFlagValue validates missing strings and integer bounds" {
    const string_flag = features.CliFlag{
        .long = "hist-file",
        .short = 'H',
        .description = "Custom history file path",
        .value_type = .string,
    };

    const args = &[_][]const u8{ "zmenu", "--hist-file", "--hist-limit" };
    try std.testing.expectError(error.MissingFlagValue, parseFlagValue(args, 1, string_flag));

    const int_flag = features.CliFlag{
        .long = "limit",
        .description = "A bounded count",
        .value_type = .int,
        .int_min = 1,
        .int_max = 10_000,
    };
    try std.testing.expectError(error.FlagValueOutOfRange, parseFlagValue(&.{ "zmenu", "--limit", "0" }, 1, int_flag));
    try std.testing.expectError(error.FlagValueOutOfRange, parseFlagValue(&.{ "zmenu", "--limit", "-1" }, 1, int_flag));
    try std.testing.expectError(error.FlagValueOutOfRange, parseFlagValue(&.{ "zmenu", "--limit", "10001" }, 1, int_flag));
    const valid = try parseFlagValue(&.{ "zmenu", "--limit", "10000" }, 1, int_flag);
    try std.testing.expectEqual(@as(i64, 10_000), valid.int);
}

test "single-pass CLI accepts valid forms and rejects ambiguous input" {
    var help = try parseCli(&.{ "zmenu", "--help" }, std.testing.allocator);
    defer help.deinit();
    try std.testing.expectEqual(CliAction.help, help.action);

    var monitor = try parseCli(&.{ "zmenu", "-m", "2" }, std.testing.allocator);
    defer monitor.deinit();
    try std.testing.expectEqual(@as(?usize, 2), monitor.monitor_index);

    try std.testing.expectError(error.UnknownOption, parseCli(&.{ "zmenu", "--unknown" }, std.testing.allocator));
    try std.testing.expectError(error.UnexpectedPositionalArgument, parseCli(&.{ "zmenu", "item" }, std.testing.allocator));
    try std.testing.expectError(error.DuplicateOption, parseCli(&.{ "zmenu", "-m", "1", "--monitor", "2" }, std.testing.allocator));
    try std.testing.expectError(error.MonitorIndexRequired, parseCli(&.{ "zmenu", "--monitor" }, std.testing.allocator));
    try std.testing.expectError(error.IncompatibleInformationalOption, parseCli(&.{ "zmenu", "-m", "1", "--version" }, std.testing.allocator));
    try std.testing.expectError(error.DuplicateOrIncompatibleOption, parseCli(&.{ "zmenu", "--help", "--version" }, std.testing.allocator));
}

test "history CLI validates limits, duplicates, ordering, and configured default" {
    const location = findFeatureFlag("--hist-limit") orelse return;

    var defaults = try parseCli(&.{"zmenu"}, std.testing.allocator);
    defer defaults.deinit();
    const default_value = defaults.feature_flags.values.items[location.feature_index].items[location.flag_index].?;
    try std.testing.expectEqual(@as(i64, @intCast(config.features.history_max_entries)), default_value.int);

    var ordered = try parseCli(&.{ "zmenu", "--monitor", "1", "--hist-limit", "25" }, std.testing.allocator);
    defer ordered.deinit();
    try std.testing.expectEqual(@as(i64, 25), ordered.feature_flags.values.items[location.feature_index].items[location.flag_index].?.int);

    try std.testing.expectError(error.FlagValueOutOfRange, parseCli(&.{ "zmenu", "--hist-limit", "0" }, std.testing.allocator));
    try std.testing.expectError(error.FlagValueOutOfRange, parseCli(&.{ "zmenu", "--hist-limit", "-1" }, std.testing.allocator));
    try std.testing.expectError(error.FlagValueOutOfRange, parseCli(&.{ "zmenu", "--hist-limit", "10001" }, std.testing.allocator));
    try std.testing.expectError(error.DuplicateOption, parseCli(&.{ "zmenu", "--hist-limit", "2", "--hist-limit", "3" }, std.testing.allocator));
}

// Re-export tests from modules
test {
    _ = @import("app.zig");
    _ = @import("input.zig");
    _ = @import("features.zig");
    _ = @import("features/history.zig");
}
