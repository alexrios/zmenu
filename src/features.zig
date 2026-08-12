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
    string, // --flag value
    int, // --flag 42
    bool, // --flag (no argument)
};

/// CLI flag value (runtime representation)
pub const FlagValue = union(FlagValueType) {
    string: []const u8,
    int: i64,
    bool: bool,
};

/// CLI flag declaration
pub const CliFlag = struct {
    long: []const u8, // Long flag name (without --), e.g., "hist-file"
    short: ?u8 = null, // Optional short flag (single char), e.g., 'H'
    description: []const u8, // Help text description
    value_type: FlagValueType, // Type of value expected
    required: bool = false, // Whether flag is required
    default: ?FlagValue = null, // Default value if not provided
    int_min: ?i64 = null, // Inclusive lower bound for integer flags
    int_max: ?i64 = null, // Inclusive upper bound for integer flags
};

pub const ExitStatus = enum { completed, timed_out };

/// Cooperative deadline shared by all synchronous onExit hooks.
/// Hooks run on the main thread and cannot be forcibly interrupted safely.
pub const ExitContext = struct {
    deadline_ms: u64,
    clock_ms: *const fn () u64 = defaultExitClock,

    fn defaultExitClock() u64 {
        return sdl.timer.getMillisecondsSinceInit();
    }

    pub fn expired(self: ExitContext) bool {
        return self.clock_ms() >= self.deadline_ms;
    }

    pub fn remainingMs(self: ExitContext) u64 {
        const now = self.clock_ms();
        return if (now >= self.deadline_ms) 0 else self.deadline_ms - now;
    }
};

/// Feature initialization data (passed to onInit hook)
pub const FeatureInitData = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map = null,
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

    /// Called synchronously after selection and before SDL shutdown.
    /// Hooks must cooperate with the shared deadline and report their status.
    onExit: ?*const fn (?FeatureState, ExitContext) ExitStatus = null,
};

/// Feature definition
pub const Feature = struct {
    name: []const u8,
    hooks: Hooks,
    cli_flags: ?[]const CliFlag = null, // Optional CLI flags for this feature
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
                    if (std.mem.eql(u8, flag.long, "help") or
                        std.mem.eql(u8, flag.long, "version") or
                        std.mem.eql(u8, flag.long, "features") or
                        std.mem.eql(u8, flag.long, "monitor"))
                    {
                        @compileError("Feature '" ++ feature.name ++ "': CLI flag --" ++ flag.long ++ " is reserved");
                    }
                    // Check for required flag with default value (invalid)
                    if (flag.required and flag.default != null) {
                        @compileError("Feature '" ++ feature.name ++ "': Flag --" ++ flag.long ++
                            " cannot be both required and have a default value");
                    }
                    if (flag.value_type != .int and (flag.int_min != null or flag.int_max != null)) {
                        @compileError("Feature '" ++ feature.name ++ "': non-integer flag --" ++ flag.long ++
                            " cannot declare integer bounds");
                    }
                    if (flag.int_min != null and flag.int_max != null and flag.int_min.? > flag.int_max.?) {
                        @compileError("Feature '" ++ feature.name ++ "': invalid integer range for --" ++ flag.long);
                    }
                    if (flag.default) |default_value| {
                        if (@as(FlagValueType, default_value) != flag.value_type) {
                            @compileError("Feature '" ++ feature.name ++ "': default type does not match --" ++ flag.long);
                        }
                        if (default_value == .int) {
                            if (flag.int_min) |min| if (default_value.int < min)
                                @compileError("Feature '" ++ feature.name ++ "': default below minimum for --" ++ flag.long);
                            if (flag.int_max) |max| if (default_value.int > max)
                                @compileError("Feature '" ++ feature.name ++ "': default above maximum for --" ++ flag.long);
                        }
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
                        if (short_char == 'h' or short_char == 'v' or short_char == 'm') {
                            const short_str = &[_]u8{short_char};
                            @compileError("Feature '" ++ feature.name ++ "': CLI flag -" ++ short_str ++ " is reserved");
                        }
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

                    help = help ++ std.fmt.comptimePrint("{s}--{s}{s:<12} {s}{s}{s}\n", .{ short_part, flag.long, type_hint, flag.description, default_text, required_text });
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
pub fn initAll(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, states: *FeatureStates, parsed_flags: *const ParsedFlags) !void {
    if (enabled_count == 0) return;

    errdefer deinitAll(states, allocator);

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onInit) |initFn| {
            const init_data = FeatureInitData{
                .allocator = allocator,
                .io = io,
                .environ_map = environ_map,
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

/// Call synchronous onExit hooks within one cooperative global budget.
/// No new hook is started after the deadline. A running hook must observe the
/// context itself because forcibly interrupting SDL-dependent code is unsafe.
pub fn callOnExit(states: *FeatureStates, budget_ms: u32) ExitStatus {
    std.debug.assert(budget_ms > 0);
    if (enabled_count == 0) return .completed;
    const start_time: u64 = sdl.timer.getMillisecondsSinceInit();
    const context = ExitContext{ .deadline_ms = start_time +| @as(u64, budget_ms) };

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onExit) |exitFn| {
            if (callExitHook(feature.name, exitFn, states[i], context) == .timed_out) {
                std.log.warn("onExit budget exhausted; skipping feature '{s}'", .{feature.name});
                return .timed_out;
            }
        }
    }
    return if (context.expired()) .timed_out else .completed;
}

fn callExitHook(
    name: []const u8,
    exit_fn: *const fn (?FeatureState, ExitContext) ExitStatus,
    state: ?FeatureState,
    context: ExitContext,
) ExitStatus {
    if (context.expired()) return .timed_out;
    const status = exit_fn(state, context);
    if (status == .timed_out) std.log.warn("Feature '{s}' exhausted the onExit budget", .{name});
    return status;
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

test "onExit cooperative context skips expired hook and accepts completed hook" {
    const Clock = struct {
        var now: u64 = 0;
        fn read() u64 {
            return now;
        }
    };
    const Hook = struct {
        var calls: usize = 0;
        fn run(_: ?FeatureState, context: ExitContext) ExitStatus {
            calls += 1;
            return if (context.expired()) .timed_out else .completed;
        }
    };

    Clock.now = 10;
    Hook.calls = 0;
    const expired = ExitContext{ .deadline_ms = 10, .clock_ms = &Clock.read };
    try std.testing.expectEqual(ExitStatus.timed_out, callExitHook("test", &Hook.run, null, expired));
    try std.testing.expectEqual(@as(usize, 0), Hook.calls);

    Clock.now = 9;
    const active = ExitContext{ .deadline_ms = 10, .clock_ms = &Clock.read };
    try std.testing.expectEqual(ExitStatus.completed, callExitHook("test", &Hook.run, null, active));
    try std.testing.expectEqual(@as(usize, 1), Hook.calls);
}
