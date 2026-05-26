//! Core type definitions for zmenu

const std = @import("std");

/// Represents an item from stdin with optional display/value separation
/// Format: "display|value" or "text" (both display and value)
pub const Item = struct {
    /// Raw line from stdin (owned memory)
    raw: []const u8,
    /// Display text shown in UI (slice into raw, before pipe)
    display: []const u8,
    /// Value text output to stdout (slice into raw, after pipe)
    value: []const u8,

    /// Parse a line into an Item
    /// If line contains '|', splits into display|value
    /// If no pipe, entire text is both display and value
    /// UTF-8 safe: pipe is ASCII (0x7C)
    pub fn parse(allocator: std.mem.Allocator, line: []const u8) !Item {
        const owned_line = try allocator.dupe(u8, line);
        errdefer allocator.free(owned_line);

        if (std.mem.indexOfScalar(u8, owned_line, '|')) |pipe_idx| {
            // Found pipe: split into display|value
            const item = Item{
                .raw = owned_line,
                .display = owned_line[0..pipe_idx],
                .value = owned_line[pipe_idx + 1 ..],
            };
            // Round-trip: display and value are slices into raw with the pipe
            // byte as the only gap. Encodes the layout the caller depends on.
            std.debug.assert(item.display.len + 1 + item.value.len == item.raw.len);
            std.debug.assert(item.display.ptr == item.raw.ptr);
            std.debug.assert(@intFromPtr(item.value.ptr) == @intFromPtr(item.raw.ptr) + item.display.len + 1);
            return item;
        } else {
            // No pipe: entire text is both display and value
            const item = Item{
                .raw = owned_line,
                .display = owned_line,
                .value = owned_line,
            };
            std.debug.assert(item.display.ptr == item.raw.ptr and item.value.ptr == item.raw.ptr);
            std.debug.assert(item.display.len == item.raw.len and item.value.len == item.raw.len);
            return item;
        }
    }

    /// Free the item's owned memory
    pub fn deinit(self: Item, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

test "Item.parse - plain text without pipe" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "simple text");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("simple text", item.display);
    try std.testing.expectEqualStrings("simple text", item.value);
    try std.testing.expectEqualStrings("simple text", item.raw);
}

test "Item.parse - single pipe splits display and value" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "Shopping List|/path/to/shopping.txt");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("Shopping List", item.display);
    try std.testing.expectEqualStrings("/path/to/shopping.txt", item.value);
}

test "Item.parse - multiple pipes uses first as delimiter" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "display|value|extra");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("display", item.display);
    try std.testing.expectEqualStrings("value|extra", item.value);
}

test "Item.parse - UTF-8 content" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "café notes|/path/café.txt");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("café notes", item.display);
    try std.testing.expectEqualStrings("/path/café.txt", item.value);
}

test "Item.parse - empty display field" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "|value");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("", item.display);
    try std.testing.expectEqualStrings("value", item.value);
}

test "Item.parse - empty value field" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "display|");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("display", item.display);
    try std.testing.expectEqualStrings("", item.value);
}

test "Item.parse - both fields empty" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "|");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings("", item.display);
    try std.testing.expectEqualStrings("", item.value);
}

test "Item.parse - whitespace preservation" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, " display | value ");
    defer item.deinit(allocator);

    try std.testing.expectEqualStrings(" display ", item.display);
    try std.testing.expectEqualStrings(" value ", item.value);
}

test "Item.parse - memory safety no leaks" {
    const allocator = std.testing.allocator;

    // Multiple parse/deinit cycles should not leak
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const item = try Item.parse(allocator, "test|data");
        item.deinit(allocator);
    }
}

test "Item.parse - slices point into same raw memory" {
    const allocator = std.testing.allocator;

    const item = try Item.parse(allocator, "abc|def");
    defer item.deinit(allocator);

    // Verify display and value are slices into raw
    try std.testing.expect(@intFromPtr(item.display.ptr) >= @intFromPtr(item.raw.ptr));
    try std.testing.expect(@intFromPtr(item.display.ptr) < @intFromPtr(item.raw.ptr) + item.raw.len);
    try std.testing.expect(@intFromPtr(item.value.ptr) >= @intFromPtr(item.raw.ptr));
    try std.testing.expect(@intFromPtr(item.value.ptr) < @intFromPtr(item.raw.ptr) + item.raw.len);
}
