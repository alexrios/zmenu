const std = @import("std");

fn parseVersionFromZon() []const u8 {
    const zon = @embedFile("build.zig.zon");
    const prefix = ".version = \"";
    const start = (std.mem.indexOf(u8, zon, prefix) orelse @compileError("no .version in build.zig.zon")) + prefix.len;
    const end = start + (std.mem.indexOf(u8, zon[start..], "\"") orelse @compileError("unterminated version string"));
    return zon[start..end];
}

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
    options.addOption([]const u8, "version", comptime parseVersionFromZon());

    // Add SDL3 dependency
    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .ext_ttf = true,
    });
    const sdl3_module = sdl3.module("sdl3");

    // Zig 0.16 translate-c emits invalid unused local declarations for the
    // MinGW fortified wcscat/wcscpy inline wrappers in optimized builds.
    // Disabling header fortification for the generated bindings avoids those
    // wrappers; SDL itself is still compiled with its configured safety mode.
    if (target.result.os.tag == .windows and optimize != .Debug) {
        const c_module = sdl3_module.import_table.get("c") orelse @panic("zig-sdl3 c module missing");
        const root = c_module.root_source_file orelse @panic("zig-sdl3 c source missing");
        const generated = switch (root) {
            .generated => |value| value,
            else => @panic("zig-sdl3 c source is not generated"),
        };
        const translate_c: *std.Build.Step.TranslateC = @fieldParentPtr("step", generated.file.step);
        translate_c.defineCMacro("_FORTIFY_SOURCE", "0");
    }

    // Check if user config exists, fallback to default
    // Users can copy config.def.zig to config.zig and customize
    const config_path: std.Build.LazyPath = blk: {
        b.build_root.handle.access(b.graph.io, "config.zig", .{}) catch break :blk b.path("config.def.zig");
        break :blk b.path("config.zig");
    };

    // Create config module that can be imported by main.zig
    const config_module = b.createModule(.{
        .root_source_file = config_path,
        .target = target,
        .optimize = optimize,
    });
    config_module.addImport("sdl3", sdl3_module);

    const exe = b.addExecutable(.{
        .name = "zmenu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Strip debug info for any non-Debug build; keeps release artifacts
            // small (38M -> 6.6M for ReleaseFast) without affecting development.
            .strip = optimize != .Debug,
        }),
    });

    // Import modules
    exe.root_module.addImport("sdl3", sdl3_module);
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
    unit_tests.root_module.addImport("sdl3", sdl3_module);
    unit_tests.root_module.addImport("config", config_module);
    unit_tests.root_module.addImport("build_options", options.createModule());

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const docs_step = b.step("docs", "Generate project documentation.");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);
}
