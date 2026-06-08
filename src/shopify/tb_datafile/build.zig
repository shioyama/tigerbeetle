//! Build helpers for the fork-only tb-datafile tool.
//!
//! Kept in a fork-only file (rather than inlined into the main `build.zig`) to
//! minimize fork divergence.

const std = @import("std");

pub fn build_tb_datafile(
    b: *std.Build,
    step_tb_datafile: *std.Build.Step,
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module: *std.Build.Module,
        vsr_options: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const exe = b.addExecutable(.{
        .name = "tb-datafile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shopify/tb_datafile/main.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    exe.root_module.addImport("stdx", options.stdx_module);
    exe.root_module.addImport("vsr", options.vsr_module);
    exe.root_module.addOptions("vsr_options", options.vsr_options);
    const install_artifact = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_artifact.step);
    step_tb_datafile.dependOn(&install_artifact.step);
}

pub fn build_tb_datafile_test(
    b: *std.Build,
    steps: struct {
        @"test": *std.Build.Step,
        tb_datafile: *std.Build.Step,
        test_tb_datafile: *std.Build.Step,
    },
    options: struct {
        stdx_module: *std.Build.Module,
        vsr_module_test: *std.Build.Module,
        vsr_options_test: *std.Build.Step.Options,
        target: std.Build.ResolvedTarget,
        mode: std.builtin.OptimizeMode,
    },
) void {
    const tests = b.addTest(.{
        .name = "test-tb-datafile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shopify/tb_datafile/identity.zig"),
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

    const run = b.addRunArtifact(tests);
    if (b.args != null) run.has_side_effects = true;

    steps.test_tb_datafile.dependOn(steps.tb_datafile);
    steps.test_tb_datafile.dependOn(&run.step);
    steps.@"test".dependOn(steps.tb_datafile);
    steps.@"test".dependOn(&run.step);
}
