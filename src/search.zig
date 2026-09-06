//! Cooperative search state. Published indices remain immutable during a scan.
const std = @import("std");
const config = @import("config");
const input = @import("input.zig");
const Item = @import("types.zig").Item;

pub const Search = struct {
    pending: bool = false,
    reuse_candidates: bool = false,
    cursor: usize = 0,
    tail_cursor: usize = 0,
    scanned_count: usize = 0,
    query: [config.limits.max_input_length]u8 = undefined,
    query_len: usize = 0,
    published_query: [config.limits.max_input_length]u8 = undefined,
    published_len: usize = 0,
    mode: config.MatchMode = config.features.match_mode,
    work: std.ArrayList(usize) = .empty,
    selected_id: ?usize = null,
    selected_result: usize = 0,
    inspected: usize = 0,

    pub fn deinit(self: *Search, allocator: std.mem.Allocator) void {
        self.work.deinit(allocator);
    }

    pub fn begin(self: *Search, query: []const u8, mode: config.MatchMode, selected_id: ?usize) void {
        std.debug.assert(query.len <= self.query.len);
        self.reuse_candidates = mode != .exact and query.len >= self.published_len and
            std.mem.startsWith(u8, query, self.published_query[0..self.published_len]);
        @memcpy(self.query[0..query.len], query);
        self.query_len = query.len;
        self.mode = mode;
        self.selected_id = selected_id;
        self.selected_result = 0;
        self.work.clearRetainingCapacity();
        self.cursor = 0;
        self.tail_cursor = if (self.reuse_candidates) self.scanned_count else 0;
        self.inspected = 0;
        self.pending = true;
    }

    fn matches(self: *const Search, text: []const u8) bool {
        const query = self.query[0..self.query_len];
        if (query.len == 0) return true;
        return switch (self.mode) {
            .fuzzy => input.fuzzyMatch(text, query),
            .prefix => input.prefixMatch(text, query),
            .exact => input.exactMatch(text, query),
        };
    }

    /// New items are checked immediately when no scan is in progress. During a
    /// scan they are visited by the tail cursor, using the current query.
    pub fn append(self: *Search, allocator: std.mem.Allocator, items: []const Item, published: *std.ArrayList(usize)) !void {
        if (self.pending) return;
        std.debug.assert(self.scanned_count + 1 == items.len);
        const id = items.len - 1;
        if (self.matches(items[id].display)) try published.append(allocator, id);
        self.scanned_count = items.len;
    }

    /// One bounded unit of work. The caller checks its clock between items.
    /// Returns true only after publishing a complete result for the current query.
    pub fn step(self: *Search, allocator: std.mem.Allocator, items: []const Item, published: *std.ArrayList(usize)) !bool {
        if (!self.pending) return false;
        const id = if (self.reuse_candidates and self.cursor < published.items.len) blk: {
            const value = published.items[self.cursor];
            self.cursor += 1;
            break :blk value;
        } else if (self.tail_cursor < items.len) blk: {
            const value = self.tail_cursor;
            self.tail_cursor += 1;
            break :blk value;
        } else {
            std.mem.swap(std.ArrayList(usize), published, &self.work);
            @memcpy(self.published_query[0..self.query_len], self.query[0..self.query_len]);
            self.published_len = self.query_len;
            self.scanned_count = items.len;
            self.pending = false;
            return true;
        };
        self.inspected += 1;
        if (self.matches(items[id].display)) {
            if (self.selected_id == id) self.selected_result = self.work.items.len;
            try self.work.append(allocator, id);
        }
        return false;
    }
};

fn referenceMatch(text: []const u8, query: []const u8, mode: config.MatchMode) bool {
    if (query.len == 0) return true;
    var normalized_text: [128]u8 = undefined;
    var normalized_query: [128]u8 = undefined;
    for (text, 0..) |ch, i| normalized_text[i] = if (config.features.case_sensitive) ch else std.ascii.toLower(ch);
    for (query, 0..) |ch, i| normalized_query[i] = if (config.features.case_sensitive) ch else std.ascii.toLower(ch);
    const haystack = normalized_text[0..text.len];
    const needle = normalized_query[0..query.len];
    if (mode == .exact) return std.mem.eql(u8, haystack, needle);
    if (mode == .prefix) return std.mem.startsWith(u8, haystack, needle);
    var rest = haystack;
    for (needle) |ch| {
        const pos = std.mem.indexOfScalar(u8, rest, ch) orelse return false;
        rest = rest[pos + 1 ..];
    }
    return true;
}

test "incremental search equals independent reference under edits and arrivals" {
    const allocator = std.testing.allocator;
    for ([_]config.MatchMode{ .fuzzy, .prefix, .exact }) |mode| {
        var search: Search = .{};
        defer search.deinit(allocator);
        var items: std.ArrayList(Item) = .empty;
        defer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        var published: std.ArrayList(usize) = .empty;
        defer published.deinit(allocator);
        for (0..200) |i| {
            var text: [128]u8 = undefined;
            try items.append(allocator, try Item.parse(allocator, try std.fmt.bufPrint(&text, "Alpha-{d}-café|duplicate", .{i % 11})));
            try search.append(allocator, items.items, &published);
        }
        const queries = [_][]const u8{ "a", "al", "Alpha-1", "zz", "", "café", "cf", "Alpha-1-café", "Alpha-1-café!", "Alpha-1-café" };
        for (queries) |query| {
            // Replace an unfinished query, then add an item while scanning.
            search.begin("superseded", mode, null);
            _ = try search.step(allocator, items.items, &published);
            search.begin(query, mode, 11);
            for (0..3) |_| _ = try search.step(allocator, items.items, &published);
            try items.append(allocator, try Item.parse(allocator, "Alpha-1-café|duplicate"));
            try search.append(allocator, items.items, &published);
            while (search.pending) _ = try search.step(allocator, items.items, &published);
            var result: usize = 0;
            for (items.items, 0..) |item, id| {
                if (referenceMatch(item.display, query, mode)) {
                    try std.testing.expect(result < published.items.len);
                    try std.testing.expectEqual(id, published.items[result]);
                    result += 1;
                }
            }
            try std.testing.expectEqual(result, published.items.len);
            if (referenceMatch(items.items[11].display, query, mode)) {
                try std.testing.expectEqual(@as(usize, 11), published.items[search.selected_result]);
            } else try std.testing.expectEqual(@as(usize, 0), search.selected_result);
        }
    }
}

test "extension visits candidates while deletion and exact rescan the collection" {
    const allocator = std.testing.allocator;
    var search: Search = .{};
    defer search.deinit(allocator);
    const items = [_]Item{ try Item.parse(allocator, "alpha"), try Item.parse(allocator, "beta") };
    defer for (items) |item| item.deinit(allocator);
    var published: std.ArrayList(usize) = .empty;
    defer published.deinit(allocator);
    search.begin("al", .fuzzy, null);
    while (search.pending) _ = try search.step(allocator, &items, &published);
    search.begin("alp", .fuzzy, null);
    while (search.pending) _ = try search.step(allocator, &items, &published);
    try std.testing.expectEqual(@as(usize, 1), search.inspected);
    search.begin("a", .fuzzy, null);
    while (search.pending) _ = try search.step(allocator, &items, &published);
    try std.testing.expectEqual(items.len, search.inspected);
    search.begin("alpha", .exact, null);
    while (search.pending) _ = try search.step(allocator, &items, &published);
    try std.testing.expectEqual(items.len, search.inspected);
}
