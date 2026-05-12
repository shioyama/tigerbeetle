//! Pure parsers over SHOPIFY-CHANGELOG.md text. Stdlib-only so this file can
//! be `@import`ed from `build.zig` at build time without dragging in project
//! modules like `Shell` or `multiversion`.

const std = @import("std");

pub fn extract_shopify_latest_version(text: []const u8) error{
    UnreleasedChangelog,
    MissingChangelogEntry,
}![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## ")) continue;
        if (std.mem.indexOf(u8, line, "unreleased") != null) {
            return error.UnreleasedChangelog;
        }
        if (!std.mem.startsWith(u8, line, "## TigerBeetle ")) continue;
        return line["## TigerBeetle ".len..];
    }
    return error.MissingChangelogEntry;
}

/// Returns the second `## TigerBeetle X.Y.Z-shopifyN` header in the changelog,
/// i.e. the fork release immediately preceding the one being cut. Used by the
/// release script to pick the multiversion bundling target.
pub fn extract_shopify_previous_version(text: []const u8) error{
    UnreleasedChangelog,
    MissingChangelogEntry,
    NoPreviousRelease,
}![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen_current = false;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## ")) continue;
        if (std.mem.indexOf(u8, line, "unreleased") != null) {
            return error.UnreleasedChangelog;
        }
        if (!std.mem.startsWith(u8, line, "## TigerBeetle ")) continue;
        if (!seen_current) {
            seen_current = true;
            continue;
        }
        return line["## TigerBeetle ".len..];
    }
    if (!seen_current) return error.MissingChangelogEntry;
    return error.NoPreviousRelease;
}

/// Returns the fork suffix for embedding in `constants.semver.pre`:
/// - `"shopifyN"` for a released entry at the top of the changelog
/// - `"unreleased"` when the top entry is `## TigerBeetle (unreleased)`
/// - `""` if no `## TigerBeetle ...` header is found (e.g. upstream trees
///   that lack the file)
pub fn extract_fork_version(text: []const u8) []const u8 {
    const version = extract_shopify_latest_version(text) catch |err| switch (err) {
        error.UnreleasedChangelog => return "unreleased",
        error.MissingChangelogEntry => return "",
    };
    const dash = std.mem.indexOfScalar(u8, version, '-') orelse return "";
    return version[dash + 1 ..];
}

test "extract_shopify_previous_version" {
    try std.testing.expectEqualStrings(
        "0.17.0-shopify1",
        try extract_shopify_previous_version(
            \\# Shopify Changelog
            \\
            \\## TigerBeetle 0.17.1-shopify1
            \\
            \\Released: 2026-05-11
            \\
            \\## TigerBeetle 0.17.0-shopify1
            \\
            \\Released: 2026-04-15
        ),
    );

    // Skipping over an `(unreleased)` top header is not supported: the release
    // script finalizes the changelog before the build runs.
    try std.testing.expectError(error.UnreleasedChangelog, extract_shopify_previous_version(
        \\## TigerBeetle (unreleased)
        \\
        \\## TigerBeetle 0.17.0-shopify1
    ));

    try std.testing.expectError(error.NoPreviousRelease, extract_shopify_previous_version(
        \\## TigerBeetle 0.17.0-shopify1
        \\
        \\Released: 2026-04-15
    ));

    try std.testing.expectError(error.MissingChangelogEntry, extract_shopify_previous_version(""));
}

test "extract_fork_version" {
    try std.testing.expectEqualStrings(
        "shopify1",
        extract_fork_version("## TigerBeetle 0.17.0-shopify1"),
    );
    try std.testing.expectEqualStrings(
        "unreleased",
        extract_fork_version(
            \\## TigerBeetle (unreleased)
            \\## TigerBeetle 0.17.0-shopify1
        ),
    );
    try std.testing.expectEqualStrings(
        "unreleased",
        extract_fork_version("## TigerBeetle (unreleased)"),
    );
    try std.testing.expectEqualStrings("", extract_fork_version(""));
}
