//! Compile-time feature registration with zero overhead for disabled features.
//! See docs/features.md for detailed documentation.

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");
const types = @import("types.zig");

/// Feature state handle (opaque pointer to feature-specific state)
pub const FeatureState = *anyopaque;

/// Type-safe cast from opaque feature state to concrete type.
/// Centralizes the @ptrCast/@alignCast pattern so each feature doesn't
/// scatter raw casts through its hooks.
pub fn castState(comptime T: type, state_ptr: ?FeatureState) ?*T {
    const ptr = state_ptr orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// CLI flag value types
pub const FlagValueType = enum {
    string,  // --flag value
    int,     // --flag 42
    bool,    // --flag (no argument)
};

/// CLI flag value (runtime representation)
pub const FlagValue = union(FlagValueType) {
    string: []const u8,
    int: i64,
    bool: bool,
};

/// CLI flag declaration
pub const CliFlag = struct {
    long: []const u8,           // Long flag name (without --), e.g., "hist-file"
    short: ?u8 = null,          // Optional short flag (single char), e.g., 'H'
    description: []const u8,    // Help text description
    value_type: FlagValueType,  // Type of value expected
    required: bool = false,     // Whether flag is required
    default: ?FlagValue = null, // Default value if not provided
};

/// Feature initialization data (passed to onInit hook)
pub const FeatureInitData = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cli_values: []const ?FlagValue, // Parsed CLI flag values (null = not provided)
    cli_flags: []const CliFlag, // Flag declarations (for name-based lookup)

    /// Look up a flag value by name. Returns null if not found or not provided.
    pub fn getFlag(self: FeatureInitData, name: []const u8) ?FlagValue {
        for (self.cli_flags, 0..) |flag, i| {
            if (std.mem.eql(u8, flag.long, name)) {
                if (i < self.cli_values.len) return self.cli_values[i];
                return null;
            }
        }
        return null;
    }

    /// Get a string flag value by name. Returns null only if the flag wasn't
    /// supplied on the command line. Calling this for a non-string flag is a
    /// programmer error and traps in debug.
    pub fn getString(self: FeatureInitData, name: []const u8) ?[]const u8 {
        const val = self.getFlag(name) orelse return null;
        std.debug.assert(val == .string);
        return val.string;
    }

    /// Get an int flag value by name. Returns null only if the flag wasn't
    /// supplied. Calling this for a non-int flag traps in debug.
    pub fn getInt(self: FeatureInitData, name: []const u8) ?i64 {
        const val = self.getFlag(name) orelse return null;
        std.debug.assert(val == .int);
        return val.int;
    }

    /// Get a bool flag value by name. Returns false if not supplied.
    /// Calling this for a non-bool flag traps in debug.
    pub fn getBool(self: FeatureInitData, name: []const u8) bool {
        const val = self.getFlag(name) orelse return false;
        std.debug.assert(val == .bool);
        return val.bool;
    }
};

/// Storage for parsed CLI flag values for all features
pub const ParsedFlags = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(std.ArrayList(?FlagValue)), // values[feature_idx][flag_idx], null = absent

    pub fn init(allocator: std.mem.Allocator) ParsedFlags {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(std.ArrayList(?FlagValue)).empty,
        };
    }

    pub fn deinit(self: *ParsedFlags) void {
        for (self.values.items) |*feature_values| {
            feature_values.deinit(self.allocator);
        }
        self.values.deinit(self.allocator);
    }

    pub fn getFeatureValues(self: *const ParsedFlags, feature_idx: usize) []const ?FlagValue {
        if (feature_idx >= self.values.items.len) return &.{};
        return self.values.items[feature_idx].items;
    }
};

/// Hook function signatures - all optional
pub const Hooks = struct {
    /// Called during App.init() - return feature state or null
    /// Receives FeatureInitData with allocator and parsed CLI flag values
    onInit: ?*const fn (FeatureInitData) anyerror!?FeatureState = null,

    /// Called during App.deinit() - cleanup feature state
    onDeinit: ?*const fn (?FeatureState, std.mem.Allocator) void = null,

    /// Called after filtering - can reorder filtered_items
    afterFilter: ?*const fn (?FeatureState, *std.ArrayList(usize), []const types.Item) void = null,

    /// Called when user selects an item (presses Enter)
    /// Receives the full Item so features can choose display or value field
    onSelect: ?*const fn (?FeatureState, types.Item) void = null,

    /// Called after user selects an item (presses Enter), before SDL shutdown
    /// Must complete within global timeout (see config.exit_timeout_ms)
    /// No allocations allowed, no error returns
    onExit: ?*const fn (?FeatureState) void = null,
};

/// Feature definition
pub const Feature = struct {
    name: []const u8,
    hooks: Hooks,
    cli_flags: ?[]const CliFlag = null,  // Optional CLI flags for this feature
};

/// Validate CLI flags at compile time
fn validateCliFlags(features_list: []const Feature) void {
    comptime {
        // Track seen flag names to detect duplicates
        var seen_long: []const []const u8 = &.{};
        var seen_short: []const u8 = &.{};

        for (features_list) |feature| {
            if (feature.cli_flags) |flags| {
                for (flags) |flag| {
                    // Empty long name would silently break flag matching at
                    // runtime; reject at the registration boundary.
                    if (flag.long.len == 0) {
                        @compileError("Feature '" ++ feature.name ++ "': CLI flag has empty .long name");
                    }
                    // Check for required flag with default value (invalid)
                    if (flag.required and flag.default != null) {
                        @compileError("Feature '" ++ feature.name ++ "': Flag --" ++ flag.long ++
                            " cannot be both required and have a default value");
                    }

                    // Check for duplicate long flags
                    for (seen_long) |existing_long| {
                        if (std.mem.eql(u8, flag.long, existing_long)) {
                            @compileError("Duplicate CLI flag --" ++ flag.long ++
                                " found in feature '" ++ feature.name ++ "'");
                        }
                    }
                    seen_long = seen_long ++ &[_][]const u8{flag.long};

                    // Check for duplicate short flags
                    if (flag.short) |short_char| {
                        for (seen_short) |existing_short| {
                            if (short_char == existing_short) {
                                const short_str = &[_]u8{short_char};
                                @compileError("Duplicate CLI flag -" ++ short_str ++
                                    " found in feature '" ++ feature.name ++ "'");
                            }
                        }
                        seen_short = seen_short ++ &[_]u8{short_char};
                    }
                }
            }
        }
    }
}

/// Generate help text for feature CLI flags at compile time
pub fn getFeatureFlagsHelp() []const u8 {
    comptime {
        if (enabled_count == 0) return "";

        var has_flags = false;
        for (enabled_features) |feature| {
            if (feature.cli_flags) |flags| {
                if (flags.len > 0) {
                    has_flags = true;
                    break;
                }
            }
        }

        if (!has_flags) return "";

        var help: []const u8 = "\nFeature-specific options:\n";

        for (enabled_features) |feature| {
            if (feature.cli_flags) |flags| {
                for (flags) |flag| {
                    // Format short flag part
                    const short_part = if (flag.short) |s|
                        std.fmt.comptimePrint("  -{c}, ", .{s})
                    else
                        "      ";

                    // Format type hint
                    const type_hint = switch (flag.value_type) {
                        .string => " PATH",
                        .int => " N",
                        .bool => "",
                    };

                    // Format default value
                    const default_text = if (flag.default) |default_val| blk: {
                        const val_str = switch (default_val) {
                            .string => |s| std.fmt.comptimePrint("\"{s}\"", .{s}),
                            .int => |i| std.fmt.comptimePrint("{d}", .{i}),
                            .bool => |b| if (b) "true" else "false",
                        };
                        break :blk std.fmt.comptimePrint(" [default: {s}]", .{val_str});
                    } else "";

                    // Format required marker
                    const required_text = if (flag.required) " [required]" else "";

                    help = help ++ std.fmt.comptimePrint(
                        "{s}--{s}{s:<12} {s}{s}{s}\n",
                        .{ short_part, flag.long, type_hint, flag.description, default_text, required_text }
                    );
                }
            }
        }

        return help;
    }
}

/// Build feature list at compile time (registration point for new features)
fn buildFeatureList() []const Feature {
    comptime {
        var list: []const Feature = &.{};

        if (@hasDecl(config.features, "history") and config.features.history) {
            if (@hasDecl(config.features, "history_max_entries")) {
                if (config.features.history_max_entries == 0)
                    @compileError("history_max_entries must be > 0 when history is enabled");
                if (config.features.history_max_entries > 10000)
                    @compileError("history_max_entries too large (max: 10000)");
            }
            list = list ++ &[_]Feature{@import("features/history.zig").feature};
        }

        if (@hasDecl(config.features, "clipboard") and config.features.clipboard) {
            list = list ++ &[_]Feature{@import("features/clipboard.zig").feature};
        }

        validateCliFlags(list);
        return list;
    }
}

/// Enabled features (compile-time constant)
pub const enabled_features: []const Feature = buildFeatureList();

/// Number of enabled features (0 = zero-cost abstraction)
pub const enabled_count: usize = enabled_features.len;

/// Feature states storage ([N]?FeatureState or void when N=0)
pub const FeatureStates = if (enabled_count > 0)
    [enabled_count]?FeatureState
else
    void;

/// Initialize states array to null
pub fn initStates() FeatureStates {
    if (enabled_count > 0) {
        return .{null} ** enabled_count;
    } else {
        return {};
    }
}

/// Initialize all enabled features - called from App.init()
/// On failure, cleans up any features that were already initialized.
pub fn initAll(allocator: std.mem.Allocator, io: std.Io, states: *FeatureStates, parsed_flags: *const ParsedFlags) !void {
    if (enabled_count == 0) return;

    errdefer deinitAll(states, allocator);

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onInit) |initFn| {
            const init_data = FeatureInitData{
                .allocator = allocator,
                .io = io,
                .cli_values = parsed_flags.getFeatureValues(i),
                .cli_flags = feature.cli_flags orelse &.{},
            };
            states[i] = try initFn(init_data);
        }
    }
}

/// Cleanup all enabled features - called from App.deinit()
pub fn deinitAll(states: *FeatureStates, allocator: std.mem.Allocator) void {
    if (enabled_count == 0) return;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onDeinit) |deinitFn| {
            deinitFn(states[i], allocator);
        }
    }
}

/// Call afterFilter hooks - called after fuzzy matching
pub fn callAfterFilter(
    states: *FeatureStates,
    filtered_items: *std.ArrayList(usize),
    all_items: []const types.Item,
) void {
    if (enabled_count == 0) return;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.afterFilter) |afterFn| {
            afterFn(states[i], filtered_items, all_items);
        }
    }
}

/// Call onSelect hooks - called when user presses Enter
pub fn callOnSelect(states: *FeatureStates, selected_item: types.Item) void {
    if (enabled_count == 0) return;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onSelect) |selectFn| {
            selectFn(states[i], selected_item);
        }
    }
}

/// Call onExit hooks with timeout - called after onSelect, before deinit
/// Returns true if all hooks completed within timeout, false if any timed out
pub fn callOnExit(states: *FeatureStates, timeout_ms: u32) bool {
    std.debug.assert(timeout_ms > 0);
    if (enabled_count == 0) return true;

    // Deadline-based to avoid bare unsigned subtraction on the SDL timer:
    // saturating add for the cutoff, comparison against `now`. Plain `-` for
    // the elapsed-time diagnostic is safe inside each guarded branch — `now`
    // is provably greater than the start it's subtracted from.
    const start_time: u64 = sdl.timer.getMillisecondsSinceInit();
    const total_deadline: u64 = start_time +| @as(u64, timeout_ms);
    var all_completed = true;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onExit) |exitFn| {
            const hook_start: u64 = sdl.timer.getMillisecondsSinceInit();
            const hook_deadline: u64 = hook_start +| @as(u64, timeout_ms);
            exitFn(states[i]);
            const hook_now: u64 = sdl.timer.getMillisecondsSinceInit();

            if (hook_now > hook_deadline) {
                std.debug.assert(hook_now > hook_start);
                const hook_duration: u64 = hook_now - hook_start;
                std.log.warn("Feature '{s}' onExit exceeded timeout ({d}ms > {d}ms)", .{ feature.name, hook_duration, timeout_ms });
                all_completed = false;
            }
        }

        const now: u64 = sdl.timer.getMillisecondsSinceInit();
        if (now > total_deadline) {
            std.debug.assert(now > start_time);
            const total_elapsed: u64 = now - start_time;
            std.log.warn("onExit total timeout exceeded ({d}ms > {d}ms), skipping remaining features", .{ total_elapsed, timeout_ms });
            return false;
        }
    }

    return all_completed;
}

test "Feature hooks - handle empty filtered items gracefully" {
    // Verifies that afterFilter hooks handle edge cases:
    // - Empty filtered items list
    // - Single item
    // - Null states

    const allocator = std.testing.allocator;

    var filtered = std.ArrayList(usize).empty;
    defer filtered.deinit(allocator);

    var items = std.ArrayList(types.Item).empty;
    defer items.deinit(allocator);

    var states = initStates();

    // Test 1: Empty filtered list (should not crash)
    callAfterFilter(&states, &filtered, items.items);

    // Test 2: Add one item
    try items.append(allocator, try types.Item.parse(allocator, "single"));
    try filtered.append(allocator, 0);

    callAfterFilter(&states, &filtered, items.items);

    // Cleanup
    for (items.items) |item| item.deinit(allocator);
    deinitAll(&states, allocator);
}

test "FeatureInitData - getFlag finds flag by name" {
    const flags = &[_]CliFlag{
        .{ .long = "file", .description = "A file", .value_type = .string },
        .{ .long = "count", .description = "A count", .value_type = .int },
        .{ .long = "verbose", .description = "Verbose", .value_type = .bool },
    };
    const values = &[_]?FlagValue{
        FlagValue{ .string = "/tmp/test" },
        null,
        FlagValue{ .bool = true },
    };

    const init_data = FeatureInitData{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cli_values = values,
        .cli_flags = flags,
    };

    // Found flags
    const file_val = init_data.getFlag("file");
    try std.testing.expect(file_val != null);
    try std.testing.expectEqualStrings("/tmp/test", file_val.?.string);

    // Null (absent) flag
    try std.testing.expect(init_data.getFlag("count") == null);

    // Bool flag
    const verbose_val = init_data.getFlag("verbose");
    try std.testing.expect(verbose_val != null);
    try std.testing.expect(verbose_val.?.bool == true);

    // Unknown flag
    try std.testing.expect(init_data.getFlag("unknown") == null);
}

test "FeatureInitData - typed getters" {
    const flags = &[_]CliFlag{
        .{ .long = "path", .description = "Path", .value_type = .string },
        .{ .long = "limit", .description = "Limit", .value_type = .int },
        .{ .long = "dry-run", .description = "Dry run", .value_type = .bool },
        .{ .long = "absent", .description = "Absent", .value_type = .string },
    };
    const values = &[_]?FlagValue{
        FlagValue{ .string = "/tmp" },
        FlagValue{ .int = 42 },
        FlagValue{ .bool = true },
        null,
    };

    const init_data = FeatureInitData{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cli_values = values,
        .cli_flags = flags,
    };

    // getString — only valid for declared string flags.
    try std.testing.expectEqualStrings("/tmp", init_data.getString("path").?);
    try std.testing.expect(init_data.getString("absent") == null); // not supplied
    try std.testing.expect(init_data.getString("unknown") == null); // not declared

    // getInt — only valid for declared int flags.
    try std.testing.expectEqual(@as(i64, 42), init_data.getInt("limit").?);
    try std.testing.expect(init_data.getInt("unknown") == null); // not declared

    // getBool — only valid for declared bool flags.
    try std.testing.expect(init_data.getBool("dry-run") == true);
    try std.testing.expect(init_data.getBool("unknown") == false); // not declared
}

test "FeatureInitData - empty flags" {
    const init_data = FeatureInitData{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cli_values = &.{},
        .cli_flags = &.{},
    };

    try std.testing.expect(init_data.getFlag("anything") == null);
    try std.testing.expect(init_data.getString("anything") == null);
    try std.testing.expect(init_data.getInt("anything") == null);
    try std.testing.expect(init_data.getBool("anything") == false);
}

test "castState - typed cast from opaque pointer" {
    const TestState = struct {
        value: u32,
    };

    var state = TestState{ .value = 42 };
    const opaque_ptr: FeatureState = @ptrCast(&state);

    // Valid cast returns pointer to concrete type
    const result = castState(TestState, opaque_ptr);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 42), result.?.value);

    // Null input returns null
    const null_result = castState(TestState, null);
    try std.testing.expect(null_result == null);
}
