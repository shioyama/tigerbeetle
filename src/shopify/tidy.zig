//! Tidy checks for Shopify fork conventions.
//!
//!   1. Every commit on the PR branch authored by `@shopify.com` must be prefixed
//!      with `[shopify]`. Non-Shopify-authored commits (e.g. upstream commits brought
//!      in by an `upstream-merge` PR) are exempt.
//!   2. If any non-test `src/` file changed in a Shopify-authored commit,
//!      `SHOPIFY-CHANGELOG.md` must be updated in the same PR. A commit whose message
//!      contains `skip-changelog-check` exempts its own changes only — other commits
//!      in the PR still trigger the check.
//!   3. `SHOPIFY-CHANGELOG.md` is well-formed — every entry sits under a section
//!      and carries a fork-PR link.
//!   4. Functions in `src/shopify/` use snake_case, matching TigerBeetle's convention
//!      (not Zig stdlib's camelCase). PascalCase type-returning functions are allowed.
//!   5. `.shopify-build/fork-versions.txt` lists the latest `-shopifyN` per
//!      `X.Y.Z` patch line reachable from `HEAD^`, newest first, capped at four
//!      patch lines. Dedup by base avoids burning a vortex slot on a same-base
//!      bump that shares a wire version with its sibling; keeping the highest
//!      `N` means any hotfix code that landed on `-shopifyN>1` is the binary
//!      that gets bundled.
//!   6. When the latest released fork's base version matches upstream's latest
//!      version (i.e. the next fork cut would be a same-`X.Y.Z` `-shopifyN` bump),
//!      Shopify-authored commits on non-`release/*` branches may not touch files in
//!      the server binary's `@import` closure (computed from the build cache, rooted
//!      at `src/tigerbeetle/main.zig`). A commit whose message contains
//!      `skip-versioning-check` exempts its own changes only — for hotfixes that need
//!      to ship server code despite the block.
//!
//! Checks 1, 2, and 6 diff against `BUILDKITE_PULL_REQUEST_BASE_BRANCH` if set, and
//! fall back to `main` otherwise so the checks exercise locally too. Checks 3, 4, and
//! 5 run unconditionally.

const std = @import("std");
const mem = std.mem;

const Shell = @import("../shell.zig");
const shopify_stdx = @import("stdx.zig");
const ChangelogIterator = @import("../scripts/changelog.zig").ChangelogIterator;
const changelog_parse = @import("changelog_parse.zig");
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

    // Check 6: server-touching changes are blocked when the latest released fork
    // base version equals upstream's latest version; in this situation, the next
    // fork cut would match the `X.Y.Z` portion of the full fork version, causing
    // a multiversion upgrade to fail. This condition is cleared on an upstream
    // merge, signaled by a new `## TigerBeetle X.Y.Z` in CHANGELOG.md.
    const server_changes_blocked = try compute_server_changes_blocked(shell);

    // Server `@import` closure, computed from `.zig-cache/h/*.txt` manifests
    // rooted at `src/tigerbeetle/main.zig`. Lazy: only the block check uses it,
    // so we skip the cache walk when server changes aren't blocked.
    var server_closure: std.StringArrayHashMapUnmanaged(void) = .empty;
    if (server_changes_blocked) {
        server_closure = try compute_server_closure(shell);
    }

    // Checks 1, 2, and 6 share a per-commit walk: subject prefix, src/-vs-changelog
    // accounting, and the same-triple server-touching block. All three filter on author
    // email being `@shopify.com`, so an upstream-merge PR doesn't trip on
    // upstream-authored commits brought in via the merge commit.
    {
        const shas = try shell.exec_stdout("git log --format=%H FETCH_HEAD..HEAD", .{});
        var has_bad_commits = false;
        var has_unskipped_src_changes = false;
        var has_versioning_violations = false;
        var changelog_changed = false;
        var sha_lines = mem.splitScalar(u8, shas, '\n');
        while (sha_lines.next()) |sha| {
            if (sha.len == 0) continue;

            // %ae on the first line, raw subject + body (%B) after — one git call.
            const meta = try shell.exec_stdout(
                "git log -1 --format=%ae%n%B {sha}",
                .{ .sha = sha },
            );
            const first_newline = mem.indexOfScalar(u8, meta, '\n') orelse meta.len;
            const author_email = meta[0..first_newline];
            const msg = if (first_newline < meta.len) meta[first_newline + 1 ..] else "";
            const subject_end = mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
            const subject = msg[0..subject_end];
            const short_sha = sha[0..@min(sha.len, 7)];

            const shopify_authored = mem.endsWith(u8, author_email, "@shopify.com");

            // Check 1: [shopify] prefix, only for Shopify-authored commits.
            if (shopify_authored and !mem.startsWith(u8, subject, "[shopify]")) {
                std.debug.print(
                    "{s}: error: commit subject missing `[shopify]` prefix: {s}\n",
                    .{ short_sha, subject },
                );
                has_bad_commits = true;
            }

            // Check 2: src/ vs changelog. `skip-changelog-check` exempts a commit's
            // src/ changes only; other commits in the PR still trigger the check.
            const changelog_skipped = mem.indexOf(u8, msg, "skip-changelog-check") != null;
            if (changelog_skipped) {
                std.debug.print(
                    "{s}: note: skip-changelog-check applied\n",
                    .{short_sha},
                );
            }

            // Check 6 per-commit skip. Independent of `skip-changelog-check` —
            // hotfixes typically still require a changelog entry.
            const versioning_skipped = mem.indexOf(u8, msg, "skip-versioning-check") != null;
            if (server_changes_blocked and versioning_skipped) {
                std.debug.print(
                    "{s}: note: skip-versioning-check applied\n",
                    .{short_sha},
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
                if (!shopify_authored) continue;

                if (!changelog_skipped and
                    mem.startsWith(u8, path, "src/") and
                    !is_test_file(path))
                {
                    has_unskipped_src_changes = true;
                }

                if (server_changes_blocked and
                    !versioning_skipped and
                    server_closure.contains(path))
                {
                    std.debug.print(
                        "{s}: error: server-touching change during same-`X.Y.Z` " ++
                            "fork bump (commit {s})\n",
                        .{ path, short_sha },
                    );
                    has_versioning_violations = true;
                }
            }
        }
        if (has_bad_commits) return error.BadCommitPrefix;
        if (has_unskipped_src_changes and !changelog_changed) {
            std.debug.print(
                "SHOPIFY-CHANGELOG.md: error: must be updated when non-test " ++
                    "`src/` files change\n",
                .{},
            );
            return error.ChangelogNotUpdated;
        }
        if (has_versioning_violations) return error.ServerChangeWithoutTripleBump;
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
                "{s}:{d}: error: function `{s}` should use snake_case\n",
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

// The manifest must equal the latest `-shopifyN` per `X.Y.Z` base reachable
// from `HEAD^`, newest first, capped at `fork_versions_max` patch lines. Keeps
// `.fork-bins/` in sync with what `release_history()` will iterate. Once
// enough fork tags exist to fill every slot, `.shopify-build/fetch-upstream-tags.sh`
// becomes redundant and can be retired.
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
    var seen_bases: std.StringArrayHashMapUnmanaged(void) = .empty;
    var found: u32 = 0;
    var lines = mem.splitScalar(u8, tags_output, '\n');
    while (lines.next()) |tag| {
        if (tag.len == 0) continue;
        const parsed = shopify_stdx.parse_fork_release_tag(tag) orelse continue;
        const gop = try seen_bases.getOrPut(allocator, parsed.base);
        if (gop.found_existing) continue;
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
            "{s}: error: could not read ({s})\n",
            .{ fork_versions_manifest, @errorName(err) },
        );
        return error.ForkVersionsMissing;
    };

    if (!mem.eql(u8, manifest, expected.items)) {
        std.debug.print(
            "{s}: error: out of sync with git tags\n" ++
                "expected (latest -shopifyN per X.Y.Z base reachable from " ++
                "HEAD^, newest first, capped at {d} patch lines):\n" ++
                "{s}" ++
                "got:\n" ++
                "{s}",
            .{ fork_versions_manifest, fork_versions_max, expected.items, manifest },
        );
        return error.ForkVersionsOutOfSync;
    }
}

// Returns true when server-touching changes must be blocked: the next fork release's
// base version would match the `X.Y.Z` portion of the upstream version. Returns
// false in three cases:
//
// - Fork has not yet cut a release.
// - Upstream has moved past the fork's base version (an upstream merge landed on
//   `main` with no fork release on top yet).
// - Current branch starts with `release/` (release PRs intentionally cut the
//   same-base bump).
fn compute_server_changes_blocked(shell: *Shell) !bool {
    const allocator = shell.arena.allocator();

    const shopify_text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        10 * 1024 * 1024,
    );
    const shopify_latest = changelog_parse.extract_shopify_latest_released_version(
        shopify_text,
    ) orelse return false; // no fork release yet — nothing to collide with.

    const dash_idx = mem.indexOf(u8, shopify_latest, "-shopify") orelse return false;
    const shopify_triple = shopify_latest[0..dash_idx];

    const upstream_text = try shell.project_root.readFileAlloc(
        allocator,
        "CHANGELOG.md",
        10 * 1024 * 1024,
    );
    var it = ChangelogIterator.init(upstream_text);
    const upstream_release = while (it.next_changelog()) |entry| {
        if (entry.release) |release| break release;
    } else return false;

    const upstream_triple = try shell.fmt(
        "{[major]}.{[minor]}.{[patch]}",
        upstream_release.triple(),
    );

    if (!mem.eql(u8, shopify_triple, upstream_triple)) return false;

    // Release PRs intentionally cut a same-triple bump; the changelog edit *is*
    // the bump. Detect by the branch name convention used by `shopify-release`
    // and by `.shopify-build/tigerbeetle.yml`'s "Validate release build" step.
    const head_branch = shell.env_get_option("BUILDKITE_BRANCH") orelse blk: {
        const out = shell.exec_stdout("git rev-parse --abbrev-ref HEAD", .{}) catch
            break :blk null;
        break :blk mem.trim(u8, out, " \r\n\t");
    };
    if (head_branch) |name| {
        if (mem.startsWith(u8, name, "release/")) return false;
    }

    return true;
}

// Unions the scope=0 paths across every `.zig-cache/h/*.txt` manifest whose
// first project-source entry is `src/tigerbeetle/main.zig`. Those manifests
// describe a compilation of the server binary (native or cross-compiled), so
// their scope=0 entries are the full `@import` closure rooted at main.zig —
// every `.zig` file that participates in the running server.
//
// Returns `error.ServerCacheMissing` if no main.zig-rooted manifest is found.
// The check that uses this closure only runs during same-triple periods, so
// the caller wires this in lazily: a contributor who hasn't run `./zig/zig
// build` yet only sees the error when the block would actually fire.
fn compute_server_closure(
    shell: *Shell,
) !std.StringArrayHashMapUnmanaged(void) {
    const allocator = shell.arena.allocator();
    var closure: std.StringArrayHashMapUnmanaged(void) = .empty;

    var dir = shell.project_root.openDir(
        ".zig-cache/h",
        .{ .iterate = true },
    ) catch |err| {
        std.debug.print(
            ".zig-cache/h: error: cannot open ({s}); " ++
                "run `./zig/zig build` first to populate the build cache\n",
            .{@errorName(err)},
        );
        return error.ServerCacheMissing;
    };
    defer dir.close();

    var matched: u32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.name, ".txt")) continue;

        const path = try shell.fmt(".zig-cache/h/{s}", .{entry.name});
        const text = shell.project_root.readFileAlloc(
            allocator,
            path,
            16 * 1024 * 1024,
        ) catch continue;

        var lines = mem.splitScalar(u8, text, '\n');
        _ = lines.next(); // version line

        // First scope=0 entry identifies the manifest's root file.
        const root = while (lines.next()) |line| {
            if (scope_zero_path(line)) |p| break p;
        } else continue;
        if (!mem.eql(u8, root, "src/tigerbeetle/main.zig")) continue;
        matched += 1;

        try closure.put(allocator, root, {});
        while (lines.next()) |line| {
            if (scope_zero_path(line)) |p| {
                try closure.put(allocator, p, {});
            }
        }
    }

    if (matched == 0) {
        std.debug.print(
            ".zig-cache/h: error: no `src/tigerbeetle/main.zig`-rooted " ++
                "manifest; run `./zig/zig build` first to populate the " ++
                "build cache\n",
            .{},
        );
        return error.ServerCacheMissing;
    }

    return closure;
}

// Returns the file path of a Zig cache manifest line iff its scope is 0
// (project source). Lines with scope=1 (std lib) or scope=2 (cimport) return
// null. Manifest line shape:
//
//     size mtime_lo mtime_hi hash scope path
fn scope_zero_path(line: []const u8) ?[]const u8 {
    var rest = line;
    var fields_skipped: u8 = 0;
    while (fields_skipped < 4) : (fields_skipped += 1) {
        const space = mem.indexOfScalar(u8, rest, ' ') orelse return null;
        rest = rest[space + 1 ..];
    }
    if (rest.len < 2 or rest[0] != '0' or rest[1] != ' ') return null;
    return rest[2..];
}

test scope_zero_path {
    // scope=0 → returns path.
    try std.testing.expectEqualStrings(
        "src/tigerbeetle/main.zig",
        scope_zero_path(
            "23508 137620192 1778224547289639047 " ++
                "5bb023919b19ba2404482b661d1be292 0 src/tigerbeetle/main.zig",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "src/vsr.zig",
        scope_zero_path(
            "68301 138150829 1778562322608214259 " ++
                "f60e49b59c7ca71f8a133a15462db9db 0 src/vsr.zig",
        ).?,
    );

    // scope=1 (std lib) → null.
    try std.testing.expect(scope_zero_path(
        "7761 123625755 1773279005862360319 " ++
            "3a02bc8b87be9f7d4cb36a97cfe452fd 1 std/std.zig",
    ) == null);

    // scope=2 (cimport) → null.
    try std.testing.expect(scope_zero_path(
        "756 138150968 1778562352032981747 " ++
            "2ebf8df040d198b840bbf9490072927f 2 c/abc/options.zig",
    ) == null);

    // Malformed / header / empty.
    try std.testing.expect(scope_zero_path("0") == null);
    try std.testing.expect(scope_zero_path("") == null);
    try std.testing.expect(scope_zero_path("size mtime_lo") == null);
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
