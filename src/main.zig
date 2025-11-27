//! zmenu - A cross-platform dmenu-like application launcher
//!
//! Usage: echo -e "Item 1\nItem 2" | zmenu
//!
//! Configuration:
//!   - Copy config.def.zig to config.zig and customize, then rebuild
//!   - Set ZMENU_THEME environment variable for runtime theme selection

const std = @import("std");
const app = @import("app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var application = app.App.init(allocator) catch |err| {
        if (err == error.NoItemsProvided) {
            std.debug.print("Error: No items provided on stdin\n", .{});
            std.debug.print("Usage: echo -e \"Item 1\\nItem 2\" | zmenu\n", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer application.deinit();

    try application.run();
}

// Re-export tests from modules
test {
    _ = @import("app.zig");
    _ = @import("input.zig");
    _ = @import("features.zig");
    _ = @import("features/history.zig");
}
