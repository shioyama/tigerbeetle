const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const Shell = @import("../shell.zig");

const Release = @import("../multiversion.zig").Release;
const ReleaseTriple = @import("../multiversion.zig").ReleaseTriple;

const MiB = stdx.MiB;

const log = std.log;

const changelog_bytes_max = 10 * MiB;

pub fn main(shell: *Shell, gpa: std.mem.Allocator) !void {
    _ = gpa;

    const date_time = stdx.InstantUnix.now().date_time();
    const today = try shell.fmt(
        "{:0>4}-{:0>2}-{:0>2}",
        .{ date_time.year, date_time.month, date_time.day },
    );

    try shell.exec("git fetch origin --quiet", .{});
    try shell.exec("git switch --create release-{today} origin/main", .{ .today = today });

    const merges = try shell.exec_stdout(
        \\git log --merges --first-parent origin/release..origin/main
    , .{});

    const changelog_current = try shell.project_root.readFileAlloc(
        shell.arena.allocator(),
        "./CHANGELOG.md",
        changelog_bytes_max,
    );

    var changelog_new = std.ArrayList(u8).init(shell.arena.allocator());
    try format_changelog(changelog_new.writer(), .{
        .changelog_current = changelog_current,
        .merges = merges,
        .today = today,
    });

    try shell.project_root.writeFile(.{ .sub_path = "CHANGELOG.md", .data = changelog_new.items });

    log.info("don't forget to update ./CHANGELOG.md", .{});
}

fn format_changelog(buffer: std.ArrayList(u8).Writer, options: struct {
    changelog_current: []const u8,
    merges: []const u8,
    today: []const u8,
}) !void {
    if (std.mem.indexOf(u8, options.changelog_current, options.today) != null) {
        return error.ChangelogAlreadyUpdated;
    }

    var it = ChangelogIterator.init(options.changelog_current);
    const last_changelog_entry = it.next_changelog().?;

    try buffer.print(
        \\# Changelog
        \\
        \\Subscribe to the [tracking issue #2231](https://github.com/tigerbeetle/tigerbeetle/issues/2231)
        \\to receive notifications about breaking changes!
        \\
        \\
    , .{});

    if (last_changelog_entry.release) |release| {
        const release_next = Release.from(.{
            .major = release.triple().major,
            .minor = release.triple().minor,
            .patch = release.triple().patch + 1,
        });
        try buffer.print("## TigerBeetle {}\n\n", .{release_next});
    } else {
        try buffer.print("## TigerBeetle (unreleased)\n\n", .{});
    }
    try buffer.print("Released: {s}\n\n", .{options.today});

    var merges_left = options.merges;
    for (0..128) |_| {
        const merge = try format_changelog_cut_single_merge(&merges_left) orelse break;

        try buffer.print(
            \\- [#{d}](https://github.com/tigerbeetle/tigerbeetle/pull/{d})
            \\
            \\  {s}
            \\
            \\
        , .{ merge.pr, merge.pr, merge.summary });
    } else @panic("suspiciously many PRs merged");
    assert(std.mem.indexOf(u8, merges_left, "commit") == null);

    try buffer.print(
        \\
        \\### Safety And Performance
        \\
        \\-
        \\
        \\### Features
        \\
        \\-
        \\
        \\### Internals
        \\
        \\-
        \\
        \\### TigerTracks 🎧
        \\
        \\- []()
        \\
        \\
    , .{});

    try buffer.writeAll(it.all_entries);
}

fn format_changelog_cut_single_merge(merges_left: *[]const u8) !?struct {
    pr: u16,
    summary: []const u8,
} {
    errdefer {
        log.err("failed to parse:\n{s}", .{merges_left.*});
    }

    // This is what we are parsing here:
    //
    //    commit 02650cd67da855609cc41196e0d6f639b870ccf5
    //    Merge: b7c2fcda 4bb433ce
    //    Author: protty <45520026+kprotty@users.noreply.github.com>
    //    Date:   Fri Feb 9 18:37:04 2024 +0000
    //
    //    Merge pull request #1523 from tigerbeetle/king/client-uid
    //
    //    Client: add ULID helper functions

    _, merges_left.* = stdx.cut(merges_left.*, "Merge pull request #") orelse return null;

    const pr_string, merges_left.* = stdx.cut(merges_left.*, " from ") orelse
        return error.ParseMergeLog;
    const pr = try std.fmt.parseInt(u16, pr_string, 10);

    _, merges_left.* = stdx.cut(merges_left.*, "\n    \n    ") orelse return error.ParseMergeLog;

    const summary, merges_left.* = stdx.cut(merges_left.*, "\n") orelse return error.ParseMergeLog;

    return .{ .pr = pr, .summary = summary };
}

pub const ChangelogIterator = struct {
    const Entry = struct {
        release: ?Release,
        text_full: []const u8,
        text_body: []const u8,
    };

    // Immutable suffix of the changelog, used to prepend a new entry in front.
    all_entries: []const u8,

    // Mutable suffix of what's yet to be iterated.
    rest: []const u8,

    release_previous_iteration: ?Release = null,

    pub fn init(changelog: []const u8) ChangelogIterator {
        var rest = stdx.cut_prefix(changelog, "# Changelog\n\n").?;
        const start_index = std.mem.indexOf(u8, rest, "##").?;
        assert(rest[start_index - 1] == '\n');
        rest = rest[start_index..];
        assert(std.mem.startsWith(u8, rest, "## TigerBeetle"));

        return .{
            .all_entries = rest,
            .rest = rest,
        };
    }

    pub fn next_changelog(it: *ChangelogIterator) ?Entry {
        if (it.done()) return null;
        assert(std.mem.startsWith(u8, it.rest, "## TigerBeetle"));
        const entry_end_index = std.mem.indexOf(u8, it.rest[2..], "\n\n## ").? + 2;
        const text_full = it.rest[0 .. entry_end_index + 1];
        it.rest = it.rest[entry_end_index + 2 ..];
        const entry = parse_entry(text_full);

        if (it.release_previous_iteration != null and entry.release != null) {
            // The changelog is ordered from newest to oldest, and that's how it's iterated. The
            // current iteration's release is thus expected to be less than the previous iteration's
            // release.
            assert(Release.less_than({}, entry.release.?, it.release_previous_iteration.?));
        }
        if (entry.release != null) {
            it.release_previous_iteration = entry.release;
        }

        return entry;
    }

    fn done(it: *const ChangelogIterator) bool {
        // First old-style release.
        return std.mem.startsWith(u8, it.rest, "## 2024-08-05");
    }

    fn parse_entry(text_full: []const u8) Entry {
        assert(std.mem.startsWith(u8, text_full, "## TigerBeetle"));
        assert(std.mem.endsWith(u8, text_full, "\n"));
        assert(!std.mem.endsWith(u8, text_full, "\n\n"));

        const first_line, var body = stdx.cut(text_full, "\n").?;
        const release = if (std.mem.eql(u8, first_line, "## TigerBeetle (unreleased)"))
            null
        else
            Release.parse(stdx.cut_prefix(first_line, "## TigerBeetle ").?) catch
                @panic("invalid changelog");

        body = stdx.cut_prefix(body, "\nReleased:").?;
        _, body = stdx.cut(body, "\n").?;
        return .{ .release = release, .text_full = text_full, .text_body = body };
    }
};

test ChangelogIterator {
    const changelog =
        \\# Changelog
        \\
        \\Some preamble here
        \\
        \\## TigerBeetle 1.2.3
        \\
        \\Released: 2024-10-23
        \\
        \\This is the start of the changelog.
        \\
        \\### Features
        \\
        \\- a cool PR
        \\
        \\## TigerBeetle 1.2.2
        \\
        \\Released: 2024-10-16
        \\
        \\ The beginning.
        \\
        \\## 2024-08-05 (prehistory)
        \\
        \\
    ;

    var it = ChangelogIterator.init(changelog);

    var entry = it.next_changelog().?;
    try std.testing.expectEqual(entry.release.?.triple(), ReleaseTriple{
        .major = 1,
        .minor = 2,
        .patch = 3,
    });
    try std.testing.expectEqualStrings(entry.text_full,
        \\## TigerBeetle 1.2.3
        \\
        \\Released: 2024-10-23
        \\
        \\This is the start of the changelog.
        \\
        \\### Features
        \\
        \\- a cool PR
        \\
    );
    try std.testing.expectEqualStrings(entry.text_body,
        \\
        \\This is the start of the changelog.
        \\
        \\### Features
        \\
        \\- a cool PR
        \\
    );

    entry = it.next_changelog().?;
    try std.testing.expectEqual(entry.release.?.triple(), ReleaseTriple{
        .major = 1,
        .minor = 2,
        .patch = 2,
    });

    try std.testing.expectEqual(it.next_changelog(), null);
}

test "current changelog" {
    const allocator = std.testing.allocator;

    const changelog_text = try std.fs.cwd().readFileAlloc(
        allocator,
        "./CHANGELOG.md",
        changelog_bytes_max,
    );
    defer allocator.free(changelog_text);

    var it = ChangelogIterator.init(changelog_text);
    while (it.next_changelog()) |_| {}
}

// [shopify] Validate SHOPIFY-CHANGELOG.md for release readiness
// and check that the release tag base matches CHANGELOG.md.
pub fn validateShopifyRelease(
    shell: *Shell,
    release_version: []const u8,
) !void {
    const allocator = shell.arena.allocator();

    const shopify_text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    checkShopifyChangelog(shopify_text, release_version) catch |err| {
        switch (err) {
            error.UnreleasedChangelog => log.err(
                "SHOPIFY-CHANGELOG.md has an unreleased entry",
                .{},
            ),
            error.MissingChangelogEntry => log.err(
                "no entry in SHOPIFY-CHANGELOG.md for {s}",
                .{release_version},
            ),
            error.MissingReleaseDate => log.err(
                "SHOPIFY-CHANGELOG.md entry for {s} is missing a \"Released:\" date",
                .{release_version},
            ),
            error.VersionExceedsRelease => log.err(
                "SHOPIFY-CHANGELOG.md has a version exceeding {s}",
                .{release_version},
            ),
            error.InvalidVersion => log.err(
                "SHOPIFY-CHANGELOG.md has an unparseable version",
                .{},
            ),
        }
        return err;
    };
    log.info("SHOPIFY-CHANGELOG.md release check passed", .{});

    const upstream_text = try shell.project_root.readFileAlloc(
        allocator,
        "CHANGELOG.md",
        changelog_bytes_max,
    );
    var it = ChangelogIterator.init(upstream_text);
    const upstream_release = while (it.next_changelog()) |entry| {
        if (entry.release != null) break entry.release.?;
    } else {
        log.err("no release found in CHANGELOG.md", .{});
        return error.MissingChangelogEntry;
    };
    const upstream_version = try shell.fmt(
        "{[major]}.{[minor]}.{[patch]}",
        upstream_release.triple(),
    );
    checkShopifyReleaseBase(release_version, upstream_version) catch {
        log.err(
            "release base version does not match CHANGELOG.md version \"{s}\"",
            .{upstream_version},
        );
        return error.VersionMismatch;
    };
    log.info("release base version matches CHANGELOG.md", .{});
}

fn checkShopifyChangelog(
    text: []const u8,
    release_version: []const u8,
) error{
    UnreleasedChangelog,
    MissingChangelogEntry,
    MissingReleaseDate,
    VersionExceedsRelease,
    InvalidVersion,
}!void {
    const release_ord = parseShopifyVersion(release_version) orelse
        return error.InvalidVersion;

    var has_match = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## ")) continue;

        if (std.mem.indexOf(u8, line, "unreleased") != null) {
            return error.UnreleasedChangelog;
        }

        const version_string = stdx.cut_prefix(
            line,
            "## TigerBeetle ",
        ) orelse continue;

        if (std.mem.eql(u8, version_string, release_version)) {
            // Check for a "Released:" line after the header.
            const has_date = while (lines.next()) |next_line| {
                if (next_line.len == 0) continue;
                break std.mem.startsWith(u8, next_line, "Released:");
            } else false;
            if (!has_date) return error.MissingReleaseDate;
            has_match = true;
            continue;
        }

        const entry_ord = parseShopifyVersion(version_string) orelse
            return error.InvalidVersion;
        if (entry_ord > release_ord) {
            return error.VersionExceedsRelease;
        }
    }

    if (!has_match) return error.MissingChangelogEntry;
}

// Parses "X.Y.Z-shopifyN" into a comparable u64.
pub fn parseShopifyVersion(version: []const u8) ?u64 {
    const base, const suffix = stdx.cut(version, "-shopify") orelse
        return null;
    const triple = ReleaseTriple.parse(base) catch return null;
    const n = std.fmt.parseUnsigned(u16, suffix, 10) catch
        return null;
    // Pack into u64: major(16) | minor(8) | patch(8) | n(16)
    return @as(u64, triple.major) << 32 |
        @as(u64, triple.minor) << 24 |
        @as(u64, triple.patch) << 16 |
        @as(u64, n);
}

// [shopify] Check that a release version's base matches the upstream CHANGELOG version.
pub fn checkShopifyReleaseBase(
    release_version: []const u8,
    changelog_version: []const u8,
) error{VersionMismatch}!void {
    const base, _ = stdx.cut(release_version, "-shopify") orelse return;
    if (!std.mem.eql(u8, base, changelog_version)) {
        return error.VersionMismatch;
    }
}

test "shopify changelog" {
    const allocator = std.testing.allocator;

    const text = try std.fs.cwd().readFileAlloc(
        allocator,
        "./SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    defer allocator.free(text);

    // Verify at least one ## TigerBeetle header exists.
    try std.testing.expect(
        std.mem.indexOf(u8, text, "## TigerBeetle ") != null,
    );
}

test "shopify changelog release validation" {
    const valid =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
        \\
        \\### Patches
        \\
        \\- some change
        \\
        \\## TigerBeetle 0.16.78-shopify2
        \\
        \\Released: 2026-04-14
        \\
        \\### Patches
        \\
        \\- another change
    ;

    // Matching version passes (highest version in changelog).
    try checkShopifyChangelog(valid, "0.16.78-shopify3");

    // Matching version but a newer entry exists — fails.
    try std.testing.expectError(
        error.VersionExceedsRelease,
        checkShopifyChangelog(valid, "0.16.78-shopify2"),
    );

    // Missing version fails.
    try std.testing.expectError(
        error.MissingChangelogEntry,
        checkShopifyChangelog(valid, "0.16.78-shopify4"),
    );

    // Version exceeds release fails.
    try std.testing.expectError(
        error.VersionExceedsRelease,
        checkShopifyChangelog(valid, "0.16.78-shopify1"),
    );

    // Unreleased entry fails.
    const with_unreleased =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- wip
        \\
        \\## TigerBeetle 0.16.78-shopify2
        \\
        \\Released: 2026-04-14
    ;

    try std.testing.expectError(
        error.UnreleasedChangelog,
        checkShopifyChangelog(with_unreleased, "0.16.78-shopify3"),
    );

    // Missing release date fails.
    const no_date =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\### Patches
        \\
        \\- some change
    ;

    try std.testing.expectError(
        error.MissingReleaseDate,
        checkShopifyChangelog(no_date, "0.16.78-shopify3"),
    );
}

test "shopify release base version check" {
    // Base matches upstream — passes.
    try checkShopifyReleaseBase("0.16.78-shopify3", "0.16.78");

    // Base doesn't match upstream — fails.
    try std.testing.expectError(
        error.VersionMismatch,
        checkShopifyReleaseBase("0.16.79-shopify1", "0.16.78"),
    );

    // Non-shopify version — no-op (passes).
    try checkShopifyReleaseBase("0.16.78", "0.16.78");
}
