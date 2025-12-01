const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add SDL3 dependency
    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .ext_ttf = true,
    });

    // Add flow-syntax dependency
    const flow_syntax = b.dependency("flow_syntax", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zmenu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Import SDL3 module
    exe.root_module.addImport("sdl3", sdl3.module("sdl3"));
    // Import flow-syntax module
    exe.root_module.addImport("syntax", flow_syntax.module("syntax"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Main tests (embedded in main.zig)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Import SDL3 module for tests
    unit_tests.root_module.addImport("sdl3", sdl3.module("sdl3"));
    // Import flow-syntax module for tests
    unit_tests.root_module.addImport("syntax", flow_syntax.module("syntax"));

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
