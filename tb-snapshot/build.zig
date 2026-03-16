const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const tb = "..";

pub fn build(b: *std.Build) !void {
    const target_opt = b.option([]const u8, "target", "Target architecture (e.g., x86_64-linux)");
    const config_release = b.option([]const u8, "config-release", "Release triple (e.g., 0.16.66)");
    const config_release_client_min = b.option(
        []const u8,
        "config-release-client-min",
        "Minimum client release (e.g., 0.16.4)",
    );

    const target = try resolve_target(b, target_opt);

    const vsr_options = b.addOptions();
    vsr_options.addOption(?[40]u8, "git_commit", null);
    vsr_options.addOption(bool, "config_verify", true);
    vsr_options.addOption([]const u8, "release", config_release orelse "0.0.0");
    vsr_options.addOption(
        []const u8,
        "release_client_min",
        config_release_client_min orelse "0.0.0",
    );
    vsr_options.addOption(bool, "config_aof_recovery", false);

    const stdx_module = b.addModule("stdx", .{
        .root_source_file = b.path(tb ++ "/src/stdx/stdx.zig"),
    });

    const vsr_module = b.addModule("vsr", .{
        .root_source_file = b.path(tb ++ "/src/vsr.zig"),
    });
    vsr_module.addImport("stdx", stdx_module);
    vsr_module.addOptions("vsr_options", vsr_options);

    // tb-snapshot binary
    const exe = b.addExecutable(.{
        .name = "tb-snapshot",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    exe.root_module.addImport("vsr", vsr_module);
    exe.root_module.addImport("stdx", stdx_module);
    exe.root_module.addOptions("vsr_options", vsr_options);
    b.installArtifact(exe);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/rewrite.zig"),
        .target = target,
    });
    unit_tests.root_module.addImport("vsr", vsr_module);
    unit_tests.root_module.addImport("stdx", stdx_module);
    unit_tests.root_module.addOptions("vsr_options", vsr_options);

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn resolve_target(b: *std.Build, target_requested: ?[]const u8) !std.Build.ResolvedTarget {
    const target_host = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
    const target = target_requested orelse target_host;
    const triples = .{
        "aarch64-linux",
        "aarch64-macos",
        "x86_64-linux",
        "x86_64-macos",
    };
    const cpus = .{
        "baseline+aes+neon",
        "baseline+aes+neon",
        "x86_64_v3+aes",
        "x86_64_v3+aes",
    };

    const arch_os, const cpu = inline for (triples, cpus) |triple, cpu| {
        if (std.mem.eql(u8, target, triple)) break .{ triple, cpu };
    } else {
        std.log.err("unsupported target: '{s}'", .{target});
        return error.UnsupportedTarget;
    };
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = arch_os,
        .cpu_features = cpu,
    });
    return b.resolveTargetQuery(query);
}
