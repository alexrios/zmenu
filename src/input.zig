//! Input handling and text matching utilities for zmenu

const std = @import("std");
const config = @import("config");

/// Normalize a character for comparison based on config.features.case_sensitive
inline fn normalizeChar(ch: u8) u8 {
    if (config.features.case_sensitive) return ch;
    return if (ch < 128) std.ascii.toLower(ch) else ch;
}

/// Match items against a query using the configured match mode and case sensitivity.
/// Dispatches to fuzzy, prefix, or exact matching based on config.features.match_mode.
pub fn matchItem(haystack: []const u8, needle: []const u8) bool {
    return switch (config.features.match_mode) {
        .fuzzy => fuzzyMatch(haystack, needle),
        .prefix => prefixMatch(haystack, needle),
        .exact => exactMatch(haystack, needle),
    };
}

/// Fuzzy match: check if all characters in needle appear in haystack (in order)
pub fn fuzzyMatch(haystack: []const u8, needle: []const u8) bool {
    var h_idx: usize = 0;
    for (needle) |n_char| {
        const n_norm = normalizeChar(n_char);
        var found = false;
        while (h_idx < haystack.len) : (h_idx += 1) {
            const h_norm = normalizeChar(haystack[h_idx]);
            if (h_norm == n_norm) {
                h_idx += 1;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Prefix match: haystack must start with needle
pub fn prefixMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (normalizeChar(h) != normalizeChar(n)) return false;
    }
    return true;
}

/// Exact match: haystack must equal needle
pub fn exactMatch(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len != needle.len) return false;
    for (haystack, needle) |h, n| {
        if (normalizeChar(h) != normalizeChar(n)) return false;
    }
    return true;
}

/// Find the last valid UTF-8 character boundary at or before max_len
/// Prevents truncating in the middle of a multi-byte character
pub fn findUtf8Boundary(text: []const u8, max_len: usize) usize {
    if (text.len <= max_len) return text.len;

    var pos = max_len;
    // Walk backwards to find a non-continuation byte
    // UTF-8 continuation bytes have the pattern 10xxxxxx (0x80-0xBF)
    while (pos > 0 and (text[pos] & 0xC0) == 0x80) {
        pos -= 1;
    }
    return pos;
}

/// Delete the last UTF-8 codepoint from a buffer
/// Handles multi-byte characters correctly
pub fn deleteLastCodepoint(buffer: *std.ArrayList(u8)) void {
    if (buffer.items.len == 0) return;

    var i = buffer.items.len - 1;

    // UTF-8 continuation bytes start with 10xxxxxx (0x80-0xBF)
    // We need to backtrack to find the start of the codepoint
    while (i > 0 and (buffer.items[i] & 0xC0) == 0x80) {
        i -= 1;
    }

    // Resize to remove the entire codepoint
    buffer.shrinkRetainingCapacity(i);
}

/// Delete the last word from a buffer (Ctrl+W behavior)
pub fn deleteWord(buffer: *std.ArrayList(u8)) void {
    // Skip trailing whitespace first (UTF-8 safe: space and tab are single bytes)
    while (buffer.items.len > 0) {
        const ch = buffer.getLast();
        if (ch != ' ' and ch != '\t') break;
        _ = buffer.pop();
    }

    // Delete word characters (UTF-8 aware)
    while (buffer.items.len > 0) {
        const ch = buffer.getLast();
        if (ch == ' ' or ch == '\t') break;
        deleteLastCodepoint(buffer);
    }
}


test "fuzzyMatch - basic matching" {
    try std.testing.expect(fuzzyMatch("hello world", "hello"));
    try std.testing.expect(fuzzyMatch("hello world", "hlo"));
    try std.testing.expect(fuzzyMatch("hello world", "hw"));
    try std.testing.expect(fuzzyMatch("hello world", ""));
    try std.testing.expect(!fuzzyMatch("hello world", "xyz"));
    try std.testing.expect(!fuzzyMatch("hello world", "dlrow"));
}

test "fuzzyMatch - case behavior follows config" {
    // With default config (case_sensitive=false), these should match
    if (!config.features.case_sensitive) {
        try std.testing.expect(fuzzyMatch("Hello World", "hello"));
        try std.testing.expect(fuzzyMatch("HELLO WORLD", "hello"));
        try std.testing.expect(fuzzyMatch("HeLLo WoRLD", "hw"));
    }
}

test "prefixMatch - basic" {
    try std.testing.expect(prefixMatch("hello world", "hello"));
    try std.testing.expect(prefixMatch("hello", "hello"));
    try std.testing.expect(prefixMatch("hello", ""));
    try std.testing.expect(!prefixMatch("hello", "world"));
    try std.testing.expect(!prefixMatch("hello", "hello world"));
}

test "prefixMatch - case behavior follows config" {
    if (!config.features.case_sensitive) {
        try std.testing.expect(prefixMatch("Hello World", "hello"));
        try std.testing.expect(prefixMatch("HELLO", "hello"));
    }
}

test "exactMatch - basic" {
    try std.testing.expect(exactMatch("hello", "hello"));
    try std.testing.expect(exactMatch("", ""));
    try std.testing.expect(!exactMatch("hello", "hell"));
    try std.testing.expect(!exactMatch("hello", "hello world"));
}

test "exactMatch - case behavior follows config" {
    if (!config.features.case_sensitive) {
        try std.testing.expect(exactMatch("Hello", "hello"));
        try std.testing.expect(exactMatch("HELLO", "hello"));
    }
}

test "matchItem - dispatches to configured mode" {
    // With default config (match_mode=fuzzy), matchItem should do fuzzy matching
    if (config.features.match_mode == .fuzzy) {
        try std.testing.expect(matchItem("hello world", "hw"));
        try std.testing.expect(!matchItem("hello world", "xyz"));
    }
}

test "fuzzyMatch - UTF-8 safe" {
    try std.testing.expect(fuzzyMatch("café résumé", "café"));
    try std.testing.expect(fuzzyMatch("日本語テスト", "日本"));
    try std.testing.expect(fuzzyMatch("CAFÉ", "caf"));
    try std.testing.expect(!fuzzyMatch("café", "cafe"));
    try std.testing.expect(!fuzzyMatch("Düsseldorf", "dusseldorf"));
}

test "findUtf8Boundary - no truncation needed" {
    const text = "hello";
    try std.testing.expectEqual(@as(usize, 5), findUtf8Boundary(text, 10));
    try std.testing.expectEqual(@as(usize, 5), findUtf8Boundary(text, 5));
}

test "findUtf8Boundary - max_len zero" {
    try std.testing.expectEqual(@as(usize, 0), findUtf8Boundary("hello", 0));
    try std.testing.expectEqual(@as(usize, 0), findUtf8Boundary("café", 0));
    try std.testing.expectEqual(@as(usize, 0), findUtf8Boundary("日本語", 0));
    try std.testing.expectEqual(@as(usize, 0), findUtf8Boundary("", 0));
}

test "findUtf8Boundary - ASCII truncation" {
    const text = "hello world";
    try std.testing.expectEqual(@as(usize, 5), findUtf8Boundary(text, 5));
}

test "findUtf8Boundary - UTF-8 truncation" {
    const text = "café";
    try std.testing.expectEqual(@as(usize, 5), findUtf8Boundary(text, 10));
    try std.testing.expectEqual(@as(usize, 5), findUtf8Boundary(text, 5));
    try std.testing.expectEqual(@as(usize, 3), findUtf8Boundary(text, 4));
    try std.testing.expectEqual(@as(usize, 3), findUtf8Boundary(text, 3));
}

test "findUtf8Boundary - multi-byte characters" {
    const text = "日本語";
    try std.testing.expectEqual(@as(usize, 9), findUtf8Boundary(text, 10));
    try std.testing.expectEqual(@as(usize, 9), findUtf8Boundary(text, 9));
    try std.testing.expectEqual(@as(usize, 6), findUtf8Boundary(text, 8));
    try std.testing.expectEqual(@as(usize, 6), findUtf8Boundary(text, 7));
    try std.testing.expectEqual(@as(usize, 6), findUtf8Boundary(text, 6));
    try std.testing.expectEqual(@as(usize, 3), findUtf8Boundary(text, 5));
}

test "deleteLastCodepoint - ASCII" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "hello");
    deleteLastCodepoint(&buffer);
    try std.testing.expectEqualStrings("hell", buffer.items);
}

test "deleteLastCodepoint - UTF-8 multi-byte" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "café");
    try std.testing.expectEqual(@as(usize, 5), buffer.items.len);

    deleteLastCodepoint(&buffer);
    try std.testing.expectEqualStrings("caf", buffer.items);
    try std.testing.expectEqual(@as(usize, 3), buffer.items.len);
}

test "deleteLastCodepoint - UTF-8 three-byte character" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "a日");
    try std.testing.expectEqual(@as(usize, 4), buffer.items.len);

    deleteLastCodepoint(&buffer);
    try std.testing.expectEqualStrings("a", buffer.items);
    try std.testing.expectEqual(@as(usize, 1), buffer.items.len);
}

test "deleteWord - ASCII whitespace then word" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "hello world");
    deleteWord(&buffer);
    try std.testing.expectEqualStrings("hello ", buffer.items);
}

test "deleteWord - UTF-8 word with trailing spaces" {
    // Verifies that pop() for whitespace stripping is safe:
    // pop() only runs when getLast() matches ' ' or '\t' (single-byte ASCII).
    // UTF-8 continuation bytes (0x80-0xBF) never match these values.
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "hello café  ");
    deleteWord(&buffer);
    // Should strip trailing spaces, then delete "café" via deleteLastCodepoint
    try std.testing.expectEqualStrings("hello ", buffer.items);
}

test "deleteWord - UTF-8 only word" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "日本語");
    deleteWord(&buffer);
    try std.testing.expectEqualStrings("", buffer.items);
}

test "deleteWord - mixed ASCII then multi-byte" {
    // Verifies deleteLastCodepoint correctly removes trailing multi-byte
    // characters without stomping ASCII prefix bytes.
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "abc日本");
    deleteWord(&buffer);
    try std.testing.expectEqualStrings("", buffer.items);
}

test "deleteWord - word boundary between ASCII and UTF-8" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "hello 日本語");
    deleteWord(&buffer);
    try std.testing.expectEqualStrings("hello ", buffer.items);
}

test "deleteLastCodepoint - empty buffer" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    deleteLastCodepoint(&buffer);
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
}
