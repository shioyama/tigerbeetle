//! Build helpers for the fork-only tb-snapshot tool.
//!
//! Kept in a fork-only file (rather than inlined into the main `build.zig`) to
//! minimize fork divergence.

const std = @import("std");

pub fn build_tb_snapshot(
    b: *std.Build,
    step_tb_snapshot: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const exe = b.addExecutable(.{
        .name = "tb-snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shopify/tb_snapshot/main.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    exe.root_module.addImport("stdx", options.stdx_module);
    exe.root_module.addImport("vsr", options.vsr_module);
    exe.root_module.addOptions("vsr_options", options.vsr_options);
    const install_artifact = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_artifact.step);
    step_tb_snapshot.dependOn(&install_artifact.step);
}

pub fn build_tb_snapshot_test(
    b: *std.Build,
    steps: struct {
        @"test": *std.Build.Step,
        test_unit: *std.Build.Step,
        test_unit_build: *std.Build.Step,
    },
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module_test: *std.Build.Module,
        vsr_options_test: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    // tb-snapshot tests live in a separate artifact because rewrite.zig
    // imports vsr as a module, which conflicts with unit_tests.zig directly
    // importing src/vsr.zig.
    const tests = b.addTest(.{
        .name = "test-tb-snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shopify/tb_snapshot/rewrite.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
        .filters = b.args orelse &.{},
        .test_runner = .{
            .path = b.path("src/shopify/test_runner.zig"),
            .mode = .simple,
        },
    });
    tests.root_module.addImport("stdx", options.stdx_module);
    tests.root_module.addImport("vsr", options.vsr_module_test);
    tests.root_module.addOptions("vsr_options", options.vsr_options_test);

    steps.test_unit_build.dependOn(&b.addInstallArtifact(tests, .{}).step);

    const run = b.addRunArtifact(tests);
    if (b.args != null) run.has_side_effects = true;

    steps.test_unit.dependOn(&run.step);
    steps.@"test".dependOn(&run.step);
}
