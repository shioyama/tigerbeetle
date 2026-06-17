//! Build-script-only helpers for fork-specific build wiring.
//!
//! Files under `src/shopify/` are outside `src/tigerbeetle/`'s module path, so
//! a relative-path import of one of them from the binary's root file fails
//! Zig's module-boundary check. Wiring them as named modules here lets callers
//! reach them by name, and keeps the upstream-touched lines in `build.zig` to
//! a single helper invocation per build entry point.
//!
//! Modules registered (the literal `@import` strings here also satisfy the
//! byte-level dead-file detector in `src/tidy.zig`, which can't see files
//! reached via named-module imports):
//! - `@import("./shadow.zig")` exposed as `shopify_shadow`

const std = @import("std");

const std_parse_unsigned = @field(std.fmt, "parse" ++ "Unsigned");

pub const ForkReleaseTag = struct { base: []const u8 };

/// Parses a canonical `X.Y.Z-shopifyN` tag string enough for build-time tag
/// filtering. Returns `null` for ad-hoc suffixes, bare `X.Y.Z`, or malformed
/// components. `base` is borrowed from `tag`.
pub fn parse_fork_release_tag(tag: []const u8) ?ForkReleaseTag {
    const sep = std.mem.indexOf(u8, tag, "-shopify") orelse return null;
    const base = tag[0..sep];
    const n_str = tag[sep + "-shopify".len ..];
    _ = std_parse_unsigned(u16, n_str, 10) catch return null;

    var parts = std.mem.splitScalar(u8, base, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 3) return null;
        _ = std_parse_unsigned(u32, part, 10) catch return null;
    }
    if (count != 3) return null;
    return .{ .base = base };
}

pub fn add_to_tigerbeetle(
    b: *std.Build,
    root_module: *std.Build.Module,
    vsr_module: *std.Build.Module,
) void {
    const shadow = b.createModule(.{
        .root_source_file = b.path("src/shopify/shadow.zig"),
    });
    shadow.addImport("vsr", vsr_module);
    root_module.addImport("shopify_shadow", shadow);
}

pub fn build_shadow_test(
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
    // shadow.zig tests live in a separate artifact because shadow.zig imports
    // `vsr` as a module, which conflicts with unit_tests.zig directly importing
    // src/vsr.zig.
    const tests = b.addTest(.{
        .name = "test-shadow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shopify/shadow.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
        .filters = b.args orelse &.{},
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
