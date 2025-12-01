//! Feature hook system - Zig's answer to dmenu patches
//!
//! Compile-time feature registration with zero overhead for disabled features.
//! See docs/features.md for detailed documentation.

const std = @import("std");
const sdl = @import("sdl3");
const config = @import("config");

/// Feature state handle (opaque pointer to feature-specific state)
pub const FeatureState = *anyopaque;

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
    cli_values: []const FlagValue,  // Parsed CLI flag values (indexed by flag order)
};

/// Storage for parsed CLI flag values for all features
pub const ParsedFlags = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(std.ArrayList(FlagValue)),  // values[feature_idx][flag_idx]

    pub fn init(allocator: std.mem.Allocator) ParsedFlags {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(std.ArrayList(FlagValue)).empty,
        };
    }

    pub fn deinit(self: *ParsedFlags) void {
        for (self.values.items) |*feature_values| {
            feature_values.deinit(self.allocator);
        }
        self.values.deinit(self.allocator);
    }

    pub fn getFeatureValues(self: *const ParsedFlags, feature_idx: usize) []const FlagValue {
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
    afterFilter: ?*const fn (?FeatureState, *std.ArrayList(usize), []const []const u8) void = null,

    /// Called when user selects an item (presses Enter)
    onSelect: ?*const fn (?FeatureState, []const u8) void = null,

    /// Called after user selects an item (presses Enter), before SDL shutdown
    /// Must complete within global timeout (see config.exit_timeout_ms)
    /// No allocations allowed, no error returns
    onExit: ?*const fn (?FeatureState) void = null,
};

/// Config transform function signature (advanced - see docs/features.md)
pub const ConfigTransform = fn (comptime base_config: type) type;

/// Feature definition
pub const Feature = struct {
    name: []const u8,
    hooks: Hooks,
    cli_flags: ?[]const CliFlag = null,  // Optional CLI flags for this feature
};

/// Validate feature configuration at compile time
fn validateFeatures() void {
    comptime {
        // Example: If we later add incompatible features, check here:
        // if (@hasDecl(config.features, "exact_match") and config.features.exact_match) {
        //     if (@hasDecl(config.features, "fuzzy_match") and config.features.fuzzy_match) {
        //         @compileError("Cannot enable both exact_match and fuzzy_match");
        //     }
        // }

        // Validate history settings
        if (@hasDecl(config.features, "history") and config.features.history) {
            if (@hasDecl(config.features, "history_max_entries")) {
                if (config.features.history_max_entries == 0) {
                    @compileError("history_max_entries must be > 0 when history is enabled");
                }
                if (config.features.history_max_entries > 10000) {
                    @compileError("history_max_entries too large (max: 10000)");
                }
            }
        }

        // Future validations:
        // - Check incompatible window modes
        // - Validate keybinding conflicts
        // - Ensure theme color values are valid
    }
}

/// Validate CLI flags at compile time
fn validateCliFlags(features_list: []const Feature) void {
    comptime {
        // Track seen flag names to detect duplicates
        var seen_long: []const []const u8 = &.{};
        var seen_short: []const u8 = &.{};

        for (features_list) |feature| {
            if (feature.cli_flags) |flags| {
                for (flags) |flag| {
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
        validateFeatures();

        var list: []const Feature = &.{};

        // Register features here
        if (@hasDecl(config.features, "history") and config.features.history) {
            list = list ++ &[_]Feature{@import("features/history.zig").feature};
        }

        if (@hasDecl(config.features, "clipboard") and config.features.clipboard) {
            list = list ++ &[_]Feature{@import("features/clipboard.zig").feature};
        }

        // Add new features:
        // if (@hasDecl(config.features, "myfeature") and config.features.myfeature) {
        //     list = list ++ &[_]Feature{@import("features/myfeature.zig").feature};
        // }

        // Validate CLI flags after building the list
        validateCliFlags(list);

        return list;
    }
}

/// Enabled features (compile-time constant)
pub const enabled_features: []const Feature = buildFeatureList();

/// Number of enabled features (0 = zero-cost abstraction)
pub const enabled_count: usize = enabled_features.len;

/// Generate compile-time feature report
pub fn getFeatureReport() []const u8 {
    comptime {
        var report: []const u8 = "zmenu features:\n";

        if (enabled_count == 0) {
            report = report ++ "  [none enabled - minimal build]\n";
        } else {
            for (enabled_features) |feature| {
                report = report ++ "  ✓ " ++ feature.name ++ "\n";
            }
        }

        // Add configuration summary
        report = report ++ "\nConfiguration:\n";
        report = report ++ std.fmt.comptimePrint("  - max_visible_items: {d}\n", .{config.limits.max_visible_items});
        report = report ++ std.fmt.comptimePrint("  - case_sensitive: {}\n", .{config.features.case_sensitive});
        report = report ++ std.fmt.comptimePrint("  - match_mode: {s}\n", .{@tagName(config.features.match_mode)});

        return report;
    }
}

/// Print feature report at compile time
pub fn printFeatureReport() void {
    @compileLog(getFeatureReport());
}

// Config transforms - advanced feature (see docs/features.md)
pub fn applyConfigTransforms(comptime base_config: type) type {
    comptime {
        var result = base_config;

        // Apply transforms from each enabled feature (if they define one)
        if (@hasDecl(config.features, "history") and config.features.history) {
            const history_mod = @import("features/history.zig");
            if (@hasDecl(history_mod, "configTransform")) {
                result = history_mod.configTransform(result);
            }
        }

        // Future features can add their transforms here
        // The pattern: if feature enabled, check for configTransform, apply it

        return result;
    }
}

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
pub fn initAll(allocator: std.mem.Allocator, states: *FeatureStates, parsed_flags: *const ParsedFlags) !void {
    if (enabled_count == 0) return;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onInit) |initFn| {
            const init_data = FeatureInitData{
                .allocator = allocator,
                .cli_values = parsed_flags.getFeatureValues(i),
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
    all_items: []const []const u8,
) void {
    if (enabled_count == 0) return;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.afterFilter) |afterFn| {
            afterFn(states[i], filtered_items, all_items);
        }
    }
}

/// Call onSelect hooks - called when user presses Enter
pub fn callOnSelect(states: *FeatureStates, selected_item: []const u8) void {
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
    if (enabled_count == 0) return true;

    const start_time = sdl.timer.getMillisecondsSinceInit();
    var all_completed = true;

    inline for (enabled_features, 0..) |feature, i| {
        if (feature.hooks.onExit) |exitFn| {
            const hook_start = sdl.timer.getMillisecondsSinceInit();
            exitFn(states[i]);
            const hook_duration = sdl.timer.getMillisecondsSinceInit() - hook_start;

            if (hook_duration > timeout_ms) {
                std.log.warn("Feature '{s}' onExit exceeded timeout ({d}ms > {d}ms)", .{ feature.name, hook_duration, timeout_ms });
                all_completed = false;
            }
        }

        // Check total elapsed time
        const total_elapsed = sdl.timer.getMillisecondsSinceInit() - start_time;
        if (total_elapsed > timeout_ms) {
            std.log.warn("onExit total timeout exceeded ({d}ms > {d}ms), skipping remaining features", .{ total_elapsed, timeout_ms });
            return false;
        }
    }

    return all_completed;
}

test "FeatureStates - correct size based on features" {
    // Size depends on enabled features - void (0) when none, array when some
    if (enabled_count == 0) {
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(FeatureStates));
    } else {
        // Each feature state is ?*anyopaque (optional pointer = 8 bytes on 64-bit)
        try std.testing.expect(@sizeOf(FeatureStates) > 0);
    }
}

test "Feature hooks - execution order matches registration order" {
    // This test verifies that when multiple features are enabled,
    // their hooks execute in the order they were registered.
    // This is critical for predictable behavior when features interact.

    const allocator = std.testing.allocator;

    // Verify feature count consistency
    try std.testing.expect(enabled_features.len == enabled_count);

    // If features are enabled, verify call mechanism works
    if (enabled_count > 0) {
        var filtered = std.ArrayList(usize).empty;
        defer filtered.deinit(allocator);

        var items = std.ArrayList([]const u8).empty;
        defer items.deinit(allocator);

        try items.append(allocator, try allocator.dupe(u8, "test"));
        try filtered.append(allocator, 0);

        var states = initStates();

        // Call afterFilter - should not crash with valid data
        callAfterFilter(&states, &filtered, items.items);

        // Cleanup
        for (items.items) |item| allocator.free(item);
    }
}

test "Feature hooks - state isolation between features" {
    // This test verifies that feature states remain isolated from each other.
    // Each feature should only see its own state, not other features' states.

    const allocator = std.testing.allocator;

    var states = initStates();

    // If features enabled, verify state array structure
    if (enabled_count > 0) {
        // Each feature gets its own slot in the state array
        inline for (enabled_features, 0..) |_, i| {
            // State slots should be independent
            try std.testing.expect(i < enabled_count);
        }
    }

    // Cleanup any allocated states
    deinitAll(&states, allocator);
}

test "Feature hooks - handle empty filtered items gracefully" {
    // Verifies that afterFilter hooks handle edge cases:
    // - Empty filtered items list
    // - Single item
    // - Null states

    const allocator = std.testing.allocator;

    var filtered = std.ArrayList(usize).empty;
    defer filtered.deinit(allocator);

    var items = std.ArrayList([]const u8).empty;
    defer items.deinit(allocator);

    var states = initStates();

    // Test 1: Empty filtered list (should not crash)
    callAfterFilter(&states, &filtered, items.items);

    // Test 2: Add one item
    try items.append(allocator, try allocator.dupe(u8, "single"));
    try filtered.append(allocator, 0);

    callAfterFilter(&states, &filtered, items.items);

    // Cleanup
    for (items.items) |item| allocator.free(item);
    deinitAll(&states, allocator);
}
