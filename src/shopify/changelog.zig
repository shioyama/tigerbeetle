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

const changelog_bytes_max = 10 * stdx.MiB;

// Read the latest release version (`X.Y.Z-shopifyN`) from SHOPIFY-CHANGELOG.md
// (the top `## TigerBeetle ...` header). Fails if the top entry is marked
// unreleased, so the release script refuses to build a fork release from a
// changelog that hasn't been finalized.
pub fn shopifyLatestVersion(shell: *Shell) ![]const u8 {
    const allocator = shell.arena.allocator();
    const text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    return extractShopifyLatestVersion(text) catch |err| {
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

fn extractShopifyLatestVersion(text: []const u8) error{
    UnreleasedChangelog,
    MissingChangelogEntry,
}![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## ")) continue;
        if (std.mem.indexOf(u8, line, "unreleased") != null) {
            return error.UnreleasedChangelog;
        }
        return stdx.cut_prefix(line, "## TigerBeetle ") orelse continue;
    }
    return error.MissingChangelogEntry;
}

// Validate SHOPIFY-CHANGELOG.md for release readiness and check that the
// release tag base matches CHANGELOG.md.
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
    return @as(u64, triple.major) << 32 |
        @as(u64, triple.minor) << 24 |
        @as(u64, triple.patch) << 16 |
        @as(u64, n);
}

// Check that a release version's base matches the upstream CHANGELOG version.
pub fn checkShopifyReleaseBase(
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
        try extractShopifyLatestVersion(valid),
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
        extractShopifyLatestVersion(with_unreleased),
    );

    const no_entries =
        \\# Shopify Changelog
        \\
        \\Some intro text with no version headers.
    ;
    try std.testing.expectError(
        error.MissingChangelogEntry,
        extractShopifyLatestVersion(no_entries),
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
        try extractShopifyLatestVersion(skip_unrelated),
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

    try checkShopifyChangelog(valid, "0.16.78-shopify3");

    try std.testing.expectError(
        error.VersionExceedsRelease,
        checkShopifyChangelog(valid, "0.16.78-shopify2"),
    );

    try std.testing.expectError(
        error.MissingChangelogEntry,
        checkShopifyChangelog(valid, "0.16.78-shopify4"),
    );

    try std.testing.expectError(
        error.VersionExceedsRelease,
        checkShopifyChangelog(valid, "0.16.78-shopify1"),
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
        checkShopifyChangelog(with_unreleased, "0.16.78-shopify3"),
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
        checkShopifyChangelog(no_date, "0.16.78-shopify3"),
    );
}

test "shopify release base version check" {
    try checkShopifyReleaseBase("0.16.78-shopify3", "0.16.78");

    try std.testing.expectError(
        error.VersionMismatch,
        checkShopifyReleaseBase("0.16.79-shopify1", "0.16.78"),
    );

    try checkShopifyReleaseBase("0.16.78", "0.16.78");
}
