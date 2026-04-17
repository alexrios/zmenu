//! App Launcher feature - cross-platform application discovery
//!
//! Discovers installed applications and injects them as menu items.
//! Linux: scans XDG .desktop files (including Flatpak and Snap)
//! macOS: walks .app bundles in standard directories
//!
//! Enable: set `app_launcher = true` in config.zig
//! Usage: zmenu --app-launcher | sh

const std = @import("std");
const builtin = @import("builtin");
const features_mod = @import("../features.zig");
const types = @import("../types.zig");
const common = @import("app_launcher/common.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("app_launcher/linux.zig"),
    .macos => @import("app_launcher/macos.zig"),
    else => @compileError("app_launcher feature not supported on " ++ @tagName(builtin.os.tag)),
};

const AppLauncherState = struct {
    allocator: std.mem.Allocator,
    apps: []common.AppEntry,
    active: bool, // Whether --app-launcher flag was passed
    merge_stdin: bool, // Whether --app-merge-stdin flag was passed

    fn deinit(self: *AppLauncherState) void {
        for (self.apps) |entry| entry.deinit(self.allocator);
        self.allocator.free(self.apps);
        self.allocator.destroy(self);
    }
};

fn onInit(init_data: features_mod.FeatureInitData) anyerror!?features_mod.FeatureState {
    const allocator = init_data.allocator;
    const active = init_data.getBool("app-launcher");
    const merge_stdin = init_data.getBool("app-merge-stdin");

    const state = try allocator.create(AppLauncherState);
    errdefer allocator.destroy(state);

    if (active) {
        const apps = platform.discoverApps(allocator) catch |err| {
            std.log.warn("app launcher: discovery failed: {}", .{err});
            state.* = .{ .allocator = allocator, .apps = &.{}, .active = true, .merge_stdin = merge_stdin };
            return @ptrCast(state);
        };
        state.* = .{ .allocator = allocator, .apps = apps, .active = true, .merge_stdin = merge_stdin };
    } else {
        state.* = .{ .allocator = allocator, .apps = &.{}, .active = false, .merge_stdin = false };
    }

    return @ptrCast(state);
}

fn onDeinit(state_ptr: ?features_mod.FeatureState, _: std.mem.Allocator) void {
    const state = features_mod.castState(AppLauncherState, state_ptr) orelse return;
    state.deinit();
}

fn provideItems(
    state_ptr: ?features_mod.FeatureState,
    items: *std.ArrayList(types.Item),
    allocator: std.mem.Allocator,
) anyerror!void {
    const state = features_mod.castState(AppLauncherState, state_ptr) orelse return;
    if (!state.active) return;

    for (state.apps) |app| {
        // Build "display|value" string for Item.parse
        const raw = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ app.name, app.exec });
        // Item.parse dupes raw internally, so free our copy immediately after parse
        const item = types.Item.parse(allocator, raw) catch |err| {
            allocator.free(raw);
            return err;
        };
        allocator.free(raw);
        errdefer item.deinit(allocator);

        try items.append(allocator, item);
    }
}

/// Check if the app launcher wants to merge stdin items alongside discovered apps.
/// Returns false if feature is inactive or merge_stdin is not set.
pub fn wantsMergeStdin(state_ptr: ?features_mod.FeatureState) bool {
    const state = features_mod.castState(AppLauncherState, state_ptr) orelse return false;
    return state.active and state.merge_stdin;
}

pub const feature = features_mod.Feature{
    .name = "app_launcher",
    .hooks = .{
        .onInit = &onInit,
        .onDeinit = &onDeinit,
        .provideItems = &provideItems,
    },
    .cli_flags = &[_]features_mod.CliFlag{
        .{
            .long = "app-launcher",
            .short = 'a',
            .description = "Discover and show installed applications",
            .value_type = .bool,
        },
        .{
            .long = "app-merge-stdin",
            .description = "Merge discovered apps with stdin items",
            .value_type = .bool,
        },
    },
};
