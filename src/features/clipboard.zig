//! Clipboard feature - copies selected items to system clipboard
//!
//! Uses SDL3 clipboard wrapper (sdl.clipboard.setText)
//! Enable: set `clipboard = true` in config.zig

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const features_mod = @import("../features.zig");
const config = @import("config");
const types = @import("../types.zig");

pub const clipboard_config = struct {
    pub const max_clipboard_length: usize = if (@hasDecl(config.limits, "max_item_length"))
        config.limits.max_item_length
    else
        4096;
};

fn onSelect(state_ptr: ?features_mod.FeatureState, selected_item: types.Item) void {
    _ = state_ptr; // Stateless feature

    // Copy the value field (what gets output to stdout)
    const value = selected_item.value;

    // Truncate if needed (SDL requires null-terminated string)
    const copy_len = @min(value.len, clipboard_config.max_clipboard_length);

    // Stack buffer for null termination (SDL API requirement)
    var buffer: [clipboard_config.max_clipboard_length + 1]u8 = undefined;
    @memcpy(buffer[0..copy_len], value[0..copy_len]);
    buffer[copy_len] = 0; // Null terminate

    // Warn if truncated
    if (value.len > clipboard_config.max_clipboard_length) {
        std.log.warn("clipboard item truncated to {} bytes", .{clipboard_config.max_clipboard_length});
    }

    // Use SDL3 wrapper API
    sdl.clipboard.setText(buffer[0..copy_len :0]) catch |err| {
        std.log.warn("failed to set clipboard (headless/SSH?): {}", .{err});
        return;
    };
}

// Safe-Zig Rule 2 (Power of 10): all loops have a statically-provable upper bound.
// The wall-clock deadline is the functional termination condition, but each loop
// also carries a hard iteration cap so a hostile/buggy clock or runaway poll
// cannot trap us here.
const linux_pump_budget_ms: u32 = 50;
// Outer tick loop: 1ms minimum delay per iteration => ~50 iterations expected.
// 10000 gives a ~200x safety margin against a misbehaving timer.
const max_outer_iterations: u32 = 10_000;
// Inner event drain: SDL's queue is small; 256 events per tick is far beyond
// what a clipboard transfer ever produces.
const max_inner_iterations: u32 = 256;

fn onExit(state_ptr: ?features_mod.FeatureState) void {
    _ = state_ptr; // Stateless feature

    if (builtin.os.tag == .linux) {
        // Linux (X11/Wayland) requires event pumping to complete async clipboard transfer
        // The clipboard manager (xclipboard/wl_data_device) must request data via events
        // while the window is alive
        const timeout_ms: u32 = linux_pump_budget_ms;
        std.debug.assert(timeout_ms > 0); // precondition

        const start = sdl.timer.getMillisecondsSinceInit();
        const end_time = start + timeout_ms;

        // The `for (0..MAX) |_|` form encodes the static upper bound in the loop
        // itself (Safe-Zig Rule 2). The wall-clock deadline is the functional
        // termination condition; the iteration cap is the safety net against a
        // hostile/stuck clock. No invariant assert needed: the bound is encoded
        // in the loop form, making the iteration cap unreachable by construction
        // under normal operation.
        outer: for (0..max_outer_iterations) |_| {
            if (sdl.timer.getMillisecondsSinceInit() >= end_time) break :outer;

            // Pump events - allows clipboard manager to communicate
            for (0..max_inner_iterations) |_| {
                const event = sdl.events.poll() orelse break;
                _ = event; // Just process events, don't handle them
            }
            sdl.timer.delayMilliseconds(1); // Small sleep to avoid busy loop
        }
        std.log.info("clipboard: completed linux async transfer", .{});
    } else {
        // macOS/Windows handle clipboard synchronously
        sdl.timer.delayMilliseconds(10);
    }
}

pub const feature = features_mod.Feature{
    .name = "clipboard",
    .hooks = .{
        .onSelect = &onSelect,
        .onExit = &onExit,
    },
};

test "Clipboard - null termination for normal string" {
    const item = "test_item";
    var buffer: [4096 + 1]u8 = undefined;
    @memcpy(buffer[0..item.len], item);
    buffer[item.len] = 0;

    try std.testing.expectEqual(@as(u8, 0), buffer[item.len]);
    try std.testing.expectEqualStrings("test_item", buffer[0..item.len]);
}

test "Clipboard - null termination for empty string" {
    const item = "";
    var buffer: [4096 + 1]u8 = undefined;
    @memcpy(buffer[0..item.len], item);
    buffer[item.len] = 0;

    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
}

test "Clipboard - truncation for long items" {
    const long_item = "A" ** 5000;
    const max_len: usize = 4096;
    const copy_len = @min(long_item.len, max_len);

    var buffer: [4096 + 1]u8 = undefined;
    @memcpy(buffer[0..copy_len], long_item[0..copy_len]);
    buffer[copy_len] = 0;

    try std.testing.expectEqual(@as(usize, 4096), copy_len);
    try std.testing.expectEqual(@as(u8, 0), buffer[copy_len]);
    try std.testing.expectEqual(@as(u8, 'A'), buffer[0]);
}
