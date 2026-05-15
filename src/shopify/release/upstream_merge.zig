//! `zig build scripts -- upstream-merge` — merge the next upstream TigerBeetle tag
//! into a fork branch and open the GitHub compare page pre-filled with the verbatim
//! CHANGELOG.md section for that tag, so the author can review and submit the PR.
//!
//! Tag selection: the latest released `X.Y.Z-shopifyN` in SHOPIFY-CHANGELOG.md gives
//! the current upstream base `X.Y.Z`. The next tag to merge is `X.Y.(Z+1)` if upstream
//! has shipped it, otherwise `X.(Y+1).0`.
//!
//! Conflict handling: paths listed in `fork_owned_paths` are auto-resolved as
//! "use HEAD's version" — directory entries (trailing `/`) match by prefix, the
//! rest by exact path. If the only conflicts are in fork-owned paths, the merge
//! is committed and the PR opens normally. Otherwise the in-progress tag is
//! written to `.git/SHOPIFY_UPSTREAM_MERGE` and the user resolves the remaining
//! conflicts, runs `git commit` (the default subject `[shopify] Merge upstream
//! X.Y.Z` from `-m` is preserved through `git commit` without `--amend`), and
//! re-runs with `--continue`.

const std = @import("std");
const log = std.log;
const stdx = @import("stdx");

const Shell = @import("../../shell.zig");
const changelog_parse = @import("../changelog_parse.zig");
const shopify_github = @import("../github.zig");
const upstream_changelog = @import("../../scripts/changelog.zig");
const Release = @import("../../multiversion.zig").Release;

const upstream_url = "https://github.com/tigerbeetle/tigerbeetle.git";
const state_file = ".git/SHOPIFY_UPSTREAM_MERGE";
const changelog_bytes_max = 10 * stdx.MiB;

/// Paths the fork controls outright — conflicts here always resolve to HEAD's
/// version (or to deletion, if HEAD doesn't have the path). Trailing `/` matches
/// every path under the directory; otherwise the entry is an exact path.
const fork_owned_paths = [_][]const u8{
    ".github/workflows/",
    "README.md",
};

pub const CLIArgs = struct {
    @"continue": bool = false,
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, args: CLIArgs) !void {
    _ = gpa;
    const allocator = shell.arena.allocator();

    if (args.@"continue") return finalize_from_state(shell, allocator);

    if (shell.file_exists(state_file)) {
        const raw = try shell.project_root.readFileAlloc(allocator, state_file, 64);
        const tag = std.mem.trim(u8, raw, " \r\n\t");
        log.err(
            "an upstream merge for {s} is in progress; resolve conflicts and re-run " ++
                "with --continue (or remove {s} to start over)",
            .{ tag, state_file },
        );
        return error.MergeInProgress;
    }

    const shopify_text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );

    const latest = changelog_parse.extract_shopify_latest_released_version(shopify_text) orelse {
        log.err("no released fork version found in SHOPIFY-CHANGELOG.md", .{});
        return error.NoReleasedForkVersion;
    };

    const base = strip_shopify_suffix(latest) orelse {
        log.err("latest fork version `{s}` is not in `X.Y.Z-shopifyN` form", .{latest});
        return error.MalformedForkVersion;
    };

    const triple = parse_triple(base) orelse {
        log.err("could not parse `{s}` as X.Y.Z", .{base});
        return error.MalformedForkVersion;
    };

    const target = try resolve_next_upstream_tag(shell, allocator, triple);
    log.info("merging upstream {s} into fork", .{target});

    try shell.exec("git fetch origin --quiet", .{});
    try shell.exec(
        "git fetch {url} refs/tags/{tag}:refs/tags/{tag}",
        .{ .url = upstream_url, .tag = target },
    );

    const branch = try shell.fmt("shopify/upstream-{s}", .{target});
    try shell.exec("git switch --create {branch} origin/main", .{ .branch = branch });

    const merge_msg = try shell.fmt("[shopify] Merge upstream {s}", .{target});
    const merge_result = try shell.exec_raw(
        "git merge --no-ff -m {msg} {tag}",
        .{ .msg = merge_msg, .tag = target },
    );

    switch (merge_result.term) {
        .Exited => |code| if (code != 0) {
            const remaining = try auto_resolve_fork_owned_conflicts(shell);
            if (remaining > 0) {
                try shell.project_root.writeFile(.{
                    .sub_path = state_file,
                    .data = try shell.fmt("{s}\n", .{target}),
                });
                const stdout = std.io.getStdOut().writer();
                try stdout.print(
                    \\
                    \\Merge conflict.
                    \\
                    \\Resolve the conflicts, then:
                    \\  git add <resolved-paths>
                    \\  git commit       # keeps the default subject "[shopify] Merge upstream {s}"
                    \\
                    \\When done, re-run:
                    \\  zig build scripts -- upstream-merge --continue
                    \\
                , .{target});
                return error.MergeConflict;
            }
            try shell.exec("git commit --no-edit", .{});
        },
        else => return error.MergeFailed,
    }

    try finalize(shell, allocator, target, branch);
}

/// Walks unmerged paths after a failed `git merge`, auto-resolving any that fall
/// under `fork_owned_paths` as "keep HEAD's version." Returns the count of
/// conflicts that remain (i.e. are not fork-owned) and must be resolved by hand.
fn auto_resolve_fork_owned_conflicts(shell: *Shell) !u32 {
    const unmerged = try shell.exec_stdout(
        "git diff --name-only --diff-filter=U",
        .{},
    );
    var resolved: u32 = 0;
    var remaining: u32 = 0;
    var lines = std.mem.splitScalar(u8, unmerged, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        if (!is_fork_owned(path)) {
            remaining += 1;
            continue;
        }
        try resolve_as_ours(shell, path);
        resolved += 1;
    }
    if (resolved > 0) {
        log.info("auto-resolved {d} conflict(s) in fork-owned paths", .{resolved});
    }
    return remaining;
}

fn is_fork_owned(path: []const u8) bool {
    for (fork_owned_paths) |entry| {
        if (std.mem.endsWith(u8, entry, "/")) {
            if (std.mem.startsWith(u8, path, entry)) return true;
        } else if (std.mem.eql(u8, path, entry)) return true;
    }
    return false;
}

/// Resolves a single unmerged path by collapsing it to HEAD's version. If HEAD
/// has the path, check it out and stage it; if HEAD doesn't (we deleted it),
/// `git rm` so the deletion stands.
fn resolve_as_ours(shell: *Shell, path: []const u8) !void {
    const head_entry = try shell.exec_stdout(
        "git ls-tree HEAD -- {path}",
        .{ .path = path },
    );
    if (std.mem.trim(u8, head_entry, " \r\n\t").len > 0) {
        try shell.exec("git checkout HEAD -- {path}", .{ .path = path });
        try shell.exec("git add {path}", .{ .path = path });
    } else {
        try shell.exec("git rm {path}", .{ .path = path });
    }
}

fn finalize_from_state(shell: *Shell, allocator: std.mem.Allocator) !void {
    if (!shell.file_exists(state_file)) {
        log.err("--continue used but no merge is in progress (missing {s})", .{state_file});
        return error.NoMergeInProgress;
    }

    const raw = try shell.project_root.readFileAlloc(allocator, state_file, 64);
    const target = std.mem.trim(u8, raw, " \r\n\t");

    if (shell.file_exists(".git/MERGE_HEAD")) {
        log.err("merge is not yet committed (resolve conflicts and `git commit` first)", .{});
        return error.MergeNotCommitted;
    }

    const expected_branch = try shell.fmt("shopify/upstream-{s}", .{target});
    const current_branch = std.mem.trim(
        u8,
        try shell.exec_stdout("git rev-parse --abbrev-ref HEAD", .{}),
        " \r\n\t",
    );
    if (!std.mem.eql(u8, current_branch, expected_branch)) {
        log.err(
            "expected branch {s}, but HEAD is {s}",
            .{ expected_branch, current_branch },
        );
        return error.WrongBranch;
    }

    try finalize(shell, allocator, target, expected_branch);
}

fn finalize(
    shell: *Shell,
    allocator: std.mem.Allocator,
    target: []const u8,
    branch: []const u8,
) !void {
    try shell.exec("git push -u origin {branch}", .{ .branch = branch });

    const changelog_text = try shell.project_root.readFileAlloc(
        allocator,
        "CHANGELOG.md",
        changelog_bytes_max,
    );

    const target_release = try Release.parse(target);
    var it = upstream_changelog.ChangelogIterator.init(changelog_text);
    const body = while (it.next_changelog()) |entry| {
        if (entry.release) |release| {
            if (release.value == target_release.value) break entry.text_body;
        }
    } else "";
    if (body.len == 0) {
        log.warn(
            "no CHANGELOG.md entry found for {s}; opening PR with an empty body",
            .{target},
        );
    }

    const pr_title = try shell.fmt("Merge upstream {s}", .{target});
    try shopify_github.open_pr_compare(shell, allocator, branch, pr_title, body);

    shell.project_root.deleteFile(state_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn strip_shopify_suffix(version: []const u8) ?[]const u8 {
    const dash = std.mem.indexOfScalar(u8, version, '-') orelse return null;
    if (!std.mem.startsWith(u8, version[dash + 1 ..], "shopify")) return null;
    return version[0..dash];
}

const Triple = struct { major: u32, minor: u32, patch: u32 };

fn parse_triple(s: []const u8) ?Triple {
    var it = std.mem.splitScalar(u8, s, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const patch_s = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{
        .major = std.fmt.parseUnsigned(u32, major_s, 10) catch return null,
        .minor = std.fmt.parseUnsigned(u32, minor_s, 10) catch return null,
        .patch = std.fmt.parseUnsigned(u32, patch_s, 10) catch return null,
    };
}

/// Probe upstream for the next tag — `X.Y.(Z+1)` first, then `X.(Y+1).0`.
/// Errors if neither exists; a major bump is treated as out-of-scope.
fn resolve_next_upstream_tag(
    shell: *Shell,
    allocator: std.mem.Allocator,
    base: Triple,
) ![]const u8 {
    const next_patch = try std.fmt.allocPrint(
        allocator,
        "{d}.{d}.{d}",
        .{ base.major, base.minor, base.patch + 1 },
    );
    if (try upstream_tag_exists(shell, next_patch)) return next_patch;

    const next_minor = try std.fmt.allocPrint(
        allocator,
        "{d}.{d}.0",
        .{ base.major, base.minor + 1 },
    );
    if (try upstream_tag_exists(shell, next_minor)) return next_minor;

    log.err(
        "neither upstream tag {s} nor {s} exists — nothing to merge",
        .{ next_patch, next_minor },
    );
    return error.NoNextUpstreamTag;
}

fn upstream_tag_exists(shell: *Shell, tag: []const u8) !bool {
    const output = try shell.exec_stdout(
        "git ls-remote {url} refs/tags/{tag}",
        .{ .url = upstream_url, .tag = tag },
    );
    return output.len > 0;
}

test strip_shopify_suffix {
    try std.testing.expectEqualStrings("0.17.0", strip_shopify_suffix("0.17.0-shopify1").?);
    try std.testing.expectEqualStrings("0.16.78", strip_shopify_suffix("0.16.78-shopify12").?);
    try std.testing.expect(strip_shopify_suffix("0.17.0") == null);
    try std.testing.expect(strip_shopify_suffix("0.17.0-rc1") == null);
}

test is_fork_owned {
    try std.testing.expect(is_fork_owned(".github/workflows/ci.yml"));
    try std.testing.expect(is_fork_owned(".github/workflows/release/build.yml"));
    try std.testing.expect(is_fork_owned("README.md"));

    try std.testing.expect(!is_fork_owned(".github/CODEOWNERS"));
    try std.testing.expect(!is_fork_owned("README.md.bak"));
    try std.testing.expect(!is_fork_owned("src/main.zig"));
    try std.testing.expect(!is_fork_owned(""));
}

test parse_triple {
    const v = parse_triple("0.17.4").?;
    try std.testing.expectEqual(@as(u32, 0), v.major);
    try std.testing.expectEqual(@as(u32, 17), v.minor);
    try std.testing.expectEqual(@as(u32, 4), v.patch);

    try std.testing.expect(parse_triple("0.17") == null);
    try std.testing.expect(parse_triple("0.17.0.1") == null);
    try std.testing.expect(parse_triple("abc") == null);
    try std.testing.expect(parse_triple("") == null);
}
