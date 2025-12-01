const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Log level option (default: err)
    const log_level = b.option(
        std.log.Level,
        "log-level",
        "Set the log level (err, warn, info, debug)",
    ) orelse .err;

    // Create build options for compile-time configuration
    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);

    // Add SDL3 dependency
    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .ext_ttf = true,
    });

    // Check if user config exists, fallback to default
    // Users can copy config.def.zig to config.zig and customize
    const config_path: std.Build.LazyPath = blk: {
        std.fs.cwd().access("config.zig", .{}) catch break :blk b.path("config.def.zig");
        break :blk b.path("config.zig");
    };

    // Create config module that can be imported by main.zig
    const config_module = b.createModule(.{
        .root_source_file = config_path,
        .target = target,
        .optimize = optimize,
    });
    config_module.addImport("sdl3", sdl3.module("sdl3"));

    const exe = b.addExecutable(.{
        .name = "zmenu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Import modules
    exe.root_module.addImport("sdl3", sdl3.module("sdl3"));
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("build_options", options.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Import modules for tests
    unit_tests.root_module.addImport("sdl3", sdl3.module("sdl3"));
    unit_tests.root_module.addImport("config", config_module);
    unit_tests.root_module.addImport("build_options", options.createModule());

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
