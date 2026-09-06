const std = @import("std");
const App = @import("app.zig").App;
const features = @import("features.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const count = try std.fmt.parseInt(usize, args[1], 10);
    if (count < 100) return error.TooFewItems;
    var flags = features.ParsedFlags.init(std.heap.smp_allocator);
    defer flags.deinit();
    var app = try App.init(std.heap.smp_allocator, init.io, null, null, &flags);
    defer app.deinit();
    try app.benchmark(count);
}
