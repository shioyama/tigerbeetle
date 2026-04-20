//! Tidy checks for Shopify fork conventions.
//!
//!   1. Every commit on the PR branch must be prefixed with `[shopify]`.
//!   2. If any non-test `src/` file changed, `SHOPIFY-CHANGELOG.md` must be updated in
//!      the same PR.
//!
//! Both checks require a PR context (base branch to diff against) and silently skip
//! when `BUILDKITE_PULL_REQUEST_BASE_BRANCH` is not set (e.g. on main, locally).

const std = @import("std");
const mem = std.mem;

const Shell = @import("./shell.zig");

test "tidy shopify fork" {
    const allocator = std.testing.allocator;
    const shell = try Shell.create(allocator);
    defer shell.destroy();

    const base_branch = shell.env_get_option("BUILDKITE_PULL_REQUEST_BASE_BRANCH") orelse return;

    shell.exec("git fetch origin {base_branch}", .{ .base_branch = base_branch }) catch {
        std.debug.print(
            "warning: could not fetch base branch '{s}', skipping\n",
            .{base_branch},
        );
        return;
    };

    // Check 1: All PR commits must be prefixed with [shopify].
    {
        const log_output = try shell.exec_stdout("git log --format=%s FETCH_HEAD..HEAD", .{});
        var has_bad_commits = false;
        var lines = mem.splitScalar(u8, log_output, '\n');
        while (lines.next()) |subject| {
            if (subject.len == 0) continue;
            if (!mem.startsWith(u8, subject, "[shopify]")) {
                std.debug.print("error: commit missing [shopify] prefix: {s}\n", .{subject});
                has_bad_commits = true;
            }
        }
        if (has_bad_commits) return error.BadCommitPrefix;
    }

    // Check 2: If non-test src/ files changed, SHOPIFY-CHANGELOG.md must be updated.
    {
        const diff_output = try shell.exec_stdout("git diff --name-only FETCH_HEAD HEAD", .{});
        var has_src_changes = false;
        var changelog_changed = false;
        var lines = mem.splitScalar(u8, diff_output, '\n');
        while (lines.next()) |path| {
            if (path.len == 0) continue;
            if (mem.eql(u8, path, "SHOPIFY-CHANGELOG.md")) {
                changelog_changed = true;
                continue;
            }
            if (mem.startsWith(u8, path, "src/") and !is_test_file(path)) {
                has_src_changes = true;
            }
        }
        if (has_src_changes and !changelog_changed) {
            std.debug.print(
                "error: non-test src/ files changed but " ++
                    "SHOPIFY-CHANGELOG.md was not updated\n",
                .{},
            );
            return error.ChangelogNotUpdated;
        }
    }
}

fn is_test_file(path: []const u8) bool {
    const test_dir_prefixes = [_][]const u8{
        "src/testing/",
        "src/stdx/testing/",
    };
    for (test_dir_prefixes) |prefix| {
        if (mem.startsWith(u8, path, prefix)) return true;
    }

    const basename = std.fs.path.basename(path);
    const test_patterns = [_][]const u8{
        "_test.",
        "_tests.",
        "_fuzz.",
        "fuzz_tests.",
    };
    for (test_patterns) |pattern| {
        if (mem.indexOf(u8, basename, pattern) != null) return true;
    }

    if (mem.eql(u8, basename, "tidy.zig")) return true;
    if (mem.eql(u8, basename, "tidy_shopify.zig")) return true;

    const dir = std.fs.path.dirname(path) orelse "";
    if (mem.endsWith(u8, dir, "/tests") or mem.endsWith(u8, dir, "/src/test")) return true;
    if (mem.startsWith(u8, basename, "test.")) return true;

    return false;
}
