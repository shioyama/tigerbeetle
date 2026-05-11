//! Shopify fork changelog validation helpers.
//!
//! The fork maintains its own `SHOPIFY-CHANGELOG.md` alongside upstream's
//! `CHANGELOG.md`. These helpers read the latest fork release version
//! (`X.Y.Z-shopifyN`) and validate that the changelog is in a releasable state
//! before we build a `.deb` package.

const std = @import("std");
const log = std.log;
const stdx = @import("stdx");

const Shell = @import("../shell.zig");
const ChangelogIterator = @import("../scripts/changelog.zig").ChangelogIterator;
const ReleaseTriple = @import("../multiversion.zig").ReleaseTriple;
const changelog_parse = @import("./changelog_parse.zig");
const extract_shopify_latest_version = changelog_parse.extract_shopify_latest_version;

const changelog_bytes_max = 10 * stdx.MiB;

// Read the latest release version (`X.Y.Z-shopifyN`) from SHOPIFY-CHANGELOG.md
// (the top `## TigerBeetle ...` header). Fails if the top entry is marked
// unreleased, so the release script refuses to build a fork release from a
// changelog that hasn't been finalized.
pub fn shopify_latest_version(shell: *Shell) ![]const u8 {
    const allocator = shell.arena.allocator();
    const text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    return extract_shopify_latest_version(text) catch |err| {
        switch (err) {
            error.UnreleasedChangelog => log.err(
                "SHOPIFY-CHANGELOG.md has an unreleased entry",
                .{},
            ),
            error.MissingChangelogEntry => log.err(
                "no `## TigerBeetle <version>` header found in SHOPIFY-CHANGELOG.md",
                .{},
            ),
        }
        return err;
    };
}

// Return the fork release immediately preceding the one being cut (the second
// `## TigerBeetle ...` header in SHOPIFY-CHANGELOG.md). Returns `null` when no
// prior fork release exists, so the caller can fall back to the
// upstream-derived previous (first fork release on a new upstream base).
pub fn shopify_previous_version(shell: *Shell) !?[]const u8 {
    const allocator = shell.arena.allocator();
    const text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    return changelog_parse.extract_shopify_previous_version(text) catch |err| switch (err) {
        error.NoPreviousRelease => null,
        else => err,
    };
}

// Validate SHOPIFY-CHANGELOG.md for release readiness and check that the
// release tag base matches CHANGELOG.md.
pub fn validate_shopify_release(
    shell: *Shell,
    release_version: []const u8,
) !void {
    const allocator = shell.arena.allocator();

    const shopify_text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    check_shopify_changelog(shopify_text, release_version) catch |err| {
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
    check_shopify_release_base(release_version, upstream_version) catch {
        log.err(
            "release base version does not match CHANGELOG.md version \"{s}\"",
            .{upstream_version},
        );
        return error.VersionMismatch;
    };
    log.info("release base version matches CHANGELOG.md", .{});
}

fn check_shopify_changelog(
    text: []const u8,
    release_version: []const u8,
) error{
    UnreleasedChangelog,
    MissingChangelogEntry,
    MissingReleaseDate,
    VersionExceedsRelease,
    InvalidVersion,
}!void {
    const release_ord = parse_shopify_version(release_version) orelse
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
            const has_date = while (lines.next()) |next_line| {
                if (next_line.len == 0) continue;
                break std.mem.startsWith(u8, next_line, "Released:");
            } else false;
            if (!has_date) return error.MissingReleaseDate;
            has_match = true;
            continue;
        }

        const entry_ord = parse_shopify_version(version_string) orelse
            return error.InvalidVersion;
        if (entry_ord > release_ord) {
            return error.VersionExceedsRelease;
        }
    }

    if (!has_match) return error.MissingChangelogEntry;
}

// Validate that every entry in `SHOPIFY-CHANGELOG.md` is well-formed:
//   1. each entry (a `- ` bullet at column 0) appears under a `### ` section
//      header within a `## TigerBeetle ...` release;
//   2. each entry's first line carries a fork-PR link of the form
//      `](https://github.com/shop/tigerbeetle/pull/...)`, optionally followed
//      by additional indented `[#N](...)` lines for multi-PR entries;
//   3. the bullet is followed by a blank line before the description, and
//      continuation lines are indented with at least two spaces, so the
//      markdown renderer attaches them to the list item.
//
// The check is intentionally light — it does not enforce which sections exist,
// nor does it parse the link target beyond looking for the URL prefix.
pub fn validate_shopify_changelog_structure(shell: *Shell) !void {
    const allocator = shell.arena.allocator();
    const text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    check_shopify_entries(text) catch |err| {
        switch (err) {
            error.EntryWithoutSection => log.err(
                "SHOPIFY-CHANGELOG.md has an entry that is not under a `### ` section",
                .{},
            ),
            error.EntryWithoutPRLink => log.err(
                "SHOPIFY-CHANGELOG.md has an entry without a " ++
                    "`](https://github.com/shop/tigerbeetle/pull/...)` link",
                .{},
            ),
            error.EntryMissingBlankAfterBullet => log.err(
                "SHOPIFY-CHANGELOG.md has an entry whose `- ` bullet is not " ++
                    "followed by a blank line before its description",
                .{},
            ),
            error.EntryDescriptionNotIndented => log.err(
                "SHOPIFY-CHANGELOG.md has an entry description that is not " ++
                    "indented two spaces under its `- ` bullet",
                .{},
            ),
        }
        return err;
    };
}

const fork_pr_link_prefix = "](https://github.com/shop/tigerbeetle/pull/";
const entry_continuation_indent = "  ";
const pr_link_continuation_prefix = "  [#";

fn check_shopify_entries(text: []const u8) error{
    EntryWithoutSection,
    EntryWithoutPRLink,
    EntryMissingBlankAfterBullet,
    EntryDescriptionNotIndented,
}!void {
    var release_open = false;
    var section_open = false;
    var entry_open = false;
    var entry_just_opened = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## ")) {
            release_open = true;
            section_open = false;
            entry_open = false;
            entry_just_opened = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "### ")) {
            if (release_open) section_open = true;
            entry_open = false;
            entry_just_opened = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "- ")) {
            if (!section_open) return error.EntryWithoutSection;
            if (std.mem.indexOf(u8, line, fork_pr_link_prefix) == null) {
                return error.EntryWithoutPRLink;
            }
            entry_open = true;
            entry_just_opened = true;
            continue;
        }
        if (line.len == 0) {
            entry_just_opened = false;
            continue;
        }
        if (entry_just_opened and
            std.mem.startsWith(u8, line, pr_link_continuation_prefix) and
            std.mem.indexOf(u8, line, fork_pr_link_prefix) != null)
        {
            continue;
        }
        if (entry_just_opened) return error.EntryMissingBlankAfterBullet;
        if (entry_open and
            !std.mem.startsWith(u8, line, entry_continuation_indent))
        {
            return error.EntryDescriptionNotIndented;
        }
    }
}

// Parses "X.Y.Z-shopifyN" into a comparable u64.
pub fn parse_shopify_version(version: []const u8) ?u64 {
    const base, const suffix = stdx.cut(version, "-shopify") orelse
        return null;
    const triple = ReleaseTriple.parse(base) catch return null;
    const n = std.fmt.parseUnsigned(u16, suffix, 10) catch
        return null;
    return @as(u64, triple.major) << 32 |
        @as(u64, triple.minor) << 24 |
        @as(u64, triple.patch) << 16 |
        @as(u64, n);
}

// Check that a release version's base matches the upstream CHANGELOG version.
pub fn check_shopify_release_base(
    release_version: []const u8,
    changelog_version: []const u8,
) error{VersionMismatch}!void {
    const base, _ = stdx.cut(release_version, "-shopify") orelse return;
    if (!std.mem.eql(u8, base, changelog_version)) {
        return error.VersionMismatch;
    }
}

test "shopify latest version extraction" {
    const valid =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
        \\
        \\## TigerBeetle 0.16.78-shopify2
        \\
        \\Released: 2026-04-14
    ;
    try std.testing.expectEqualStrings(
        "0.16.78-shopify3",
        try extract_shopify_latest_version(valid),
    );

    const with_unreleased =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle (unreleased)
        \\
        \\## TigerBeetle 0.16.78-shopify2
    ;
    try std.testing.expectError(
        error.UnreleasedChangelog,
        extract_shopify_latest_version(with_unreleased),
    );

    const no_entries =
        \\# Shopify Changelog
        \\
        \\Some intro text with no version headers.
    ;
    try std.testing.expectError(
        error.MissingChangelogEntry,
        extract_shopify_latest_version(no_entries),
    );

    const skip_unrelated =
        \\# Shopify Changelog
        \\
        \\## Introduction
        \\
        \\## TigerBeetle 0.16.78-shopify3
    ;
    try std.testing.expectEqualStrings(
        "0.16.78-shopify3",
        try extract_shopify_latest_version(skip_unrelated),
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

    try check_shopify_changelog(valid, "0.16.78-shopify3");

    try std.testing.expectError(
        error.VersionExceedsRelease,
        check_shopify_changelog(valid, "0.16.78-shopify2"),
    );

    try std.testing.expectError(
        error.MissingChangelogEntry,
        check_shopify_changelog(valid, "0.16.78-shopify4"),
    );

    try std.testing.expectError(
        error.VersionExceedsRelease,
        check_shopify_changelog(valid, "0.16.78-shopify1"),
    );

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
        check_shopify_changelog(with_unreleased, "0.16.78-shopify3"),
    );

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
        check_shopify_changelog(no_date, "0.16.78-shopify3"),
    );
}

test "shopify changelog structural validation" {
    const valid =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- [#56](https://github.com/shop/tigerbeetle/pull/56)
        \\
        \\  Add the fork release pipeline.
        \\
        \\- [#60](https://github.com/shop/tigerbeetle/pull/60)
        \\
        \\  Add `tb-snapshot`.
    ;
    try check_shopify_entries(valid);

    // Multi-PR entries with indented `[#N](url)` continuation lines mirror
    // upstream's CHANGELOG.md format.
    const valid_multi_pr =
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- [#56](https://github.com/shop/tigerbeetle/pull/56),
        \\  [#57](https://github.com/shop/tigerbeetle/pull/57),
        \\  [#58](https://github.com/shop/tigerbeetle/pull/58)
        \\
        \\  A change spanning multiple PRs.
    ;
    try check_shopify_entries(valid_multi_pr);

    // Multi-line entries with indented continuation are fine — only column-0
    // `- ` lines are entries.
    const valid_multiline =
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- [#56](https://github.com/shop/tigerbeetle/pull/56)
        \\
        \\  First paragraph.
        \\
        \\  - a sub-bullet that is indented and not an entry
        \\
        \\  Second paragraph.
    ;
    try check_shopify_entries(valid_multiline);

    const without_link =
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- A change with no PR link.
    ;
    try std.testing.expectError(
        error.EntryWithoutPRLink,
        check_shopify_entries(without_link),
    );

    // Links to PRs on other repositories are not accepted
    // changelog.
    const invalid_link =
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- [#3258](https://github.com/tigerbeetle/tigerbeetle/pull/3258)
        \\
        \\  Some change.
    ;
    try std.testing.expectError(
        error.EntryWithoutPRLink,
        check_shopify_entries(invalid_link),
    );

    const without_section =
        \\## TigerBeetle (unreleased)
        \\
        \\- [#56](https://github.com/shop/tigerbeetle/pull/56)
        \\
        \\  No section header above this entry.
    ;
    try std.testing.expectError(
        error.EntryWithoutSection,
        check_shopify_entries(without_section),
    );

    // A description paragraph at column 0 is not part of the list item under
    // CommonMark; the validator must catch this.
    const without_indent =
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- [#56](https://github.com/shop/tigerbeetle/pull/56)
        \\
        \\Add the fork release pipeline.
        \\
        \\- [#60](https://github.com/shop/tigerbeetle/pull/60)
        \\
        \\  Add `tb-snapshot`.
    ;
    try std.testing.expectError(
        error.EntryDescriptionNotIndented,
        check_shopify_entries(without_indent),
    );

    // A description glued directly to the bullet collapses into the link
    // paragraph; the validator must catch this.
    const without_blank =
        \\## TigerBeetle (unreleased)
        \\
        \\### Patches
        \\
        \\- [#56](https://github.com/shop/tigerbeetle/pull/56)
        \\  Add the fork release pipeline.
    ;
    try std.testing.expectError(
        error.EntryMissingBlankAfterBullet,
        check_shopify_entries(without_blank),
    );

    // A section header before any release header doesn't open a section.
    const section_outside_release =
        \\# Shopify Changelog
        \\
        \\### Stray Section
        \\
        \\- [#56](https://github.com/shop/tigerbeetle/pull/56)
        \\
        \\  Entry under a section that isn't inside a release.
    ;
    try std.testing.expectError(
        error.EntryWithoutSection,
        check_shopify_entries(section_outside_release),
    );
}

test "shopify release base version check" {
    try check_shopify_release_base("0.16.78-shopify3", "0.16.78");

    try std.testing.expectError(
        error.VersionMismatch,
        check_shopify_release_base("0.16.79-shopify1", "0.16.78"),
    );

    try check_shopify_release_base("0.16.78", "0.16.78");
}
