//! Tidy checks for Shopify fork conventions.
//!
//!   1. Every commit on the PR branch must be prefixed with `[shopify]`.
//!   2. If any non-test `src/` file changed, `SHOPIFY-CHANGELOG.md` must be updated in
//!      the same PR. A commit whose message contains `skip-changelog-check` exempts
//!      its own changes only — other commits in the PR still trigger the check.
//!   3. `SHOPIFY-CHANGELOG.md` is well-formed — every entry sits under a section
//!      and carries a fork-PR link.
//!   4. Functions in `src/shopify/` use snake_case, matching TigerBeetle's convention
//!      (not Zig stdlib's camelCase). PascalCase type-returning functions are allowed.
//!   5. `.shopify-build/fork-versions.txt` lists the four most recent `-shopify*` tags
//!      reachable from `HEAD^`, newest first. Forces the manifest to stay in sync with
//!      git so CI stages the right binaries for vortex's multi-version slots.
//!
//! Checks 1 and 2 diff against `BUILDKITE_PULL_REQUEST_BASE_BRANCH` if set, and fall back
//! to `main` otherwise so the checks exercise locally too. Checks 3, 4, and 5 run
//! unconditionally.

const std = @import("std");
const mem = std.mem;

const Shell = @import("../shell.zig");
const validate_shopify_changelog_structure =
    @import("changelog.zig").validate_shopify_changelog_structure;

test "tidy shopify fork" {
    const allocator = std.testing.allocator;
    const shell = try Shell.create(allocator);
    defer shell.destroy();

    // Check 3: SHOPIFY-CHANGELOG.md is structurally well-formed. Runs
    // unconditionally — independent of git history — so it catches malformed
    // entries even on branches that don't touch `src/`.
    try validate_shopify_changelog_structure(shell);

    // Check 4: Functions in src/shopify/ use snake_case.
    try validate_snake_case_functions(shell);

    // Check 5: fork-versions.txt manifest matches git tag history.
    try validate_fork_versions_manifest(shell);

    const base_branch = shell.env_get_option("BUILDKITE_PULL_REQUEST_BASE_BRANCH") orelse "main";

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
    // Per-commit: a commit whose message contains `skip-changelog-check` exempts
    // its own src/ changes, but other commits' changes still trigger the check.
    {
        const shas = try shell.exec_stdout("git log --format=%H FETCH_HEAD..HEAD", .{});
        var has_unskipped_src_changes = false;
        var changelog_changed = false;
        var sha_lines = mem.splitScalar(u8, shas, '\n');
        while (sha_lines.next()) |sha| {
            if (sha.len == 0) continue;
            const msg = try shell.exec_stdout(
                "git log -1 --format=%B {sha}",
                .{ .sha = sha },
            );
            const skipped = mem.indexOf(u8, msg, "skip-changelog-check") != null;
            if (skipped) {
                std.debug.print(
                    "note: skip-changelog-check applied to {s}\n",
                    .{sha[0..@min(sha.len, 7)]},
                );
            }
            const files = try shell.exec_stdout(
                "git diff-tree --no-commit-id --name-only -r {sha}",
                .{ .sha = sha },
            );
            var file_lines = mem.splitScalar(u8, files, '\n');
            while (file_lines.next()) |path| {
                if (path.len == 0) continue;
                if (mem.eql(u8, path, "SHOPIFY-CHANGELOG.md")) {
                    changelog_changed = true;
                    continue;
                }
                if (skipped) continue;
                if (mem.startsWith(u8, path, "src/") and !is_test_file(path)) {
                    has_unskipped_src_changes = true;
                }
            }
        }
        if (has_unskipped_src_changes and !changelog_changed) {
            std.debug.print(
                "error: non-test src/ files changed but " ++
                    "SHOPIFY-CHANGELOG.md was not updated\n",
                .{},
            );
            return error.ChangelogNotUpdated;
        }
    }
}

// Walk every .zig file under src/shopify/ and report any function declarations whose
// names use camelCase. PascalCase (type-returning) functions are allowed because that
// is how Zig conventionally names generic-type constructors.
fn validate_snake_case_functions(shell: *Shell) !void {
    const allocator = shell.arena.allocator();
    const paths = try shell.find(.{
        .where = &.{"src/shopify"},
        .extension = ".zig",
    });

    var has_offenders = false;
    for (paths) |path| {
        const text = try shell.project_root.readFileAlloc(
            allocator,
            path,
            10 * 1024 * 1024,
        );
        var lines = mem.splitScalar(u8, text, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line| {
            line_number += 1;
            const offender = find_camel_case_fn(line) orelse continue;
            std.debug.print(
                "error: {s}:{d}: function `{s}` should use snake_case\n",
                .{ path, line_number, offender },
            );
            has_offenders = true;
        }
    }
    if (has_offenders) return error.CamelCaseFunction;
}

// Number of prior-version slots vortex consumes from `release_history()`
// (`server_exes[2..6]` in build.zig).
const fork_versions_max = 4;
const fork_versions_manifest = ".shopify-build/fork-versions.txt";

// The manifest must equal the most recent `-shopify*` tags reachable from `HEAD^`,
// newest first, capped at `fork_versions_max`. Keeps `.fork-bins/` in sync with what
// `release_history()` will iterate. Once enough fork tags exist to fill every slot,
// `.shopify-build/fetch-upstream-tags.sh` becomes redundant and can be retired.
fn validate_fork_versions_manifest(shell: *Shell) !void {
    const allocator = shell.arena.allocator();

    const tags_output = shell.exec_stdout(
        "git tag --merged HEAD^ --sort=-committerdate",
        .{},
    ) catch {
        std.debug.print(
            "warning: could not list git tags, skipping fork-versions check\n",
            .{},
        );
        return;
    };

    var expected: std.ArrayListUnmanaged(u8) = .empty;
    var found: u32 = 0;
    var lines = mem.splitScalar(u8, tags_output, '\n');
    while (lines.next()) |tag| {
        if (tag.len == 0) continue;
        if (mem.indexOf(u8, tag, "-shopify") == null) continue;
        try expected.appendSlice(allocator, tag);
        try expected.append(allocator, '\n');
        found += 1;
        if (found >= fork_versions_max) break;
    }

    const manifest = shell.project_root.readFileAlloc(
        allocator,
        fork_versions_manifest,
        4096,
    ) catch |err| {
        std.debug.print(
            "error: could not read {s}: {s}\n",
            .{ fork_versions_manifest, @errorName(err) },
        );
        return error.ForkVersionsMissing;
    };

    if (!mem.eql(u8, manifest, expected.items)) {
        std.debug.print(
            "error: {s} is out of sync with git tags.\n" ++
                "expected (most recent {d} -shopify* tags reachable from HEAD^, newest first):\n" ++
                "{s}" ++
                "got:\n" ++
                "{s}",
            .{ fork_versions_manifest, fork_versions_max, expected.items, manifest },
        );
        return error.ForkVersionsOutOfSync;
    }
}

// Returns the offending function name if `line` declares a camelCase function,
// otherwise null. A function is camelCase if its name starts with a lowercase
// letter and contains any uppercase letter. PascalCase names (starting with an
// uppercase letter) are allowed.
fn find_camel_case_fn(line: []const u8) ?[]const u8 {
    var rest = mem.trimLeft(u8, line, " \t");
    if (mem.startsWith(u8, rest, "pub ")) {
        rest = mem.trimLeft(u8, rest["pub ".len..], " \t");
    }
    if (!mem.startsWith(u8, rest, "fn ")) return null;
    rest = mem.trimLeft(u8, rest["fn ".len..], " \t");

    var name_end: usize = 0;
    while (name_end < rest.len) : (name_end += 1) {
        const c = rest[name_end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
    }
    if (name_end == 0) return null;
    const name = rest[0..name_end];

    if (std.ascii.isUpper(name[0])) return null;
    for (name) |c| {
        if (std.ascii.isUpper(c)) return name;
    }
    return null;
}

test "find_camel_case_fn" {
    try std.testing.expectEqualStrings(
        "fooBar",
        find_camel_case_fn("fn fooBar() void {}").?,
    );
    try std.testing.expectEqualStrings(
        "validateShopifyRelease",
        find_camel_case_fn("pub fn validateShopifyRelease(") orelse return error.MissedMatch,
    );
    try std.testing.expectEqualStrings(
        "nextShopifyN",
        find_camel_case_fn("    pub fn nextShopifyN(") orelse return error.MissedMatch,
    );

    try std.testing.expect(find_camel_case_fn("fn snake_case() void {}") == null);
    try std.testing.expect(find_camel_case_fn("pub fn check_shopify_release(") == null);
    try std.testing.expect(find_camel_case_fn("pub fn ReplicaType(comptime T: type) type") == null);
    try std.testing.expect(find_camel_case_fn("// pub fn fooBar() — comment") == null);
    try std.testing.expect(find_camel_case_fn("const x = something();") == null);
    try std.testing.expect(find_camel_case_fn("") == null);
    try std.testing.expect(find_camel_case_fn("fn ") == null);
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

    const dir = std.fs.path.dirname(path) orelse "";
    if (mem.endsWith(u8, dir, "/tests") or mem.endsWith(u8, dir, "/src/test")) return true;
    if (mem.startsWith(u8, basename, "test.")) return true;

    return false;
}
