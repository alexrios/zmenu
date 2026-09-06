const std = @import("std");
const App = @import("app.zig").App;
const features = @import("features.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var flags = features.ParsedFlags.init(std.heap.smp_allocator);
    defer flags.deinit();
    var app = try App.init(std.heap.smp_allocator, init.io, null, null, &flags);
    defer app.deinit();
    if (std.mem.eql(u8, args[1], "check-themes")) return app.checkThemes();
    if (std.mem.eql(u8, args[1], "check-cache")) return app.checkCache();
    if (std.mem.eql(u8, args[1], "check-incremental")) return app.checkIncremental();
    if (std.mem.eql(u8, args[1], "check-stream")) return app.checkStream();
    if (std.mem.eql(u8, args[1], "check-confirm")) return app.checkEmptyConfirmation();
    if (std.mem.eql(u8, args[1], "check-layout")) return app.checkLayout(try std.fmt.parseFloat(f32, args[2]));
    const count = try std.fmt.parseInt(usize, args[1], 10);
    if (count < 100) return error.TooFewItems;
    try app.benchmark(count);
}
