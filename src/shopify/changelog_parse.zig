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

/// Returns the first released `## TigerBeetle X.Y.Z-shopifyN` version string in the
/// changelog. Skips a leading `(unreleased)` header — different from
/// `extract_shopify_latest_version`, which errors on it. Used by `upstream-merge`
/// to recover the current upstream base from the most recent fork tag.
pub fn extract_shopify_latest_released_version(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## TigerBeetle ")) continue;
        const version = line["## TigerBeetle ".len..];
        if (std.mem.indexOf(u8, version, "unreleased") != null) continue;
        return version;
    }
    return null;
}

/// Returns the most recent prior fork release whose upstream triple differs
/// from the top entry's. Same-triple entries are skipped to avoid colliding
/// on `Release.value` in the multiversion loader. `error.NoPreviousRelease`
/// means the caller should fall back to `CHANGELOG.md`'s upstream-derived
/// previous.
pub fn extract_shopify_previous_version(text: []const u8) error{
    UnreleasedChangelog,
    MissingChangelogEntry,
    NoPreviousRelease,
}![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var current_triple: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## ")) continue;
        if (std.mem.indexOf(u8, line, "unreleased") != null) {
            return error.UnreleasedChangelog;
        }
        if (!std.mem.startsWith(u8, line, "## TigerBeetle ")) continue;
        const version = line["## TigerBeetle ".len..];
        const dash_idx = std.mem.indexOf(u8, version, "-shopify") orelse continue;
        const triple = version[0..dash_idx];
        if (current_triple) |cur| {
            if (!std.mem.eql(u8, cur, triple)) return version;
        } else {
            current_triple = triple;
        }
    }
    if (current_triple == null) return error.MissingChangelogEntry;
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

test extract_shopify_latest_released_version {
    try std.testing.expectEqualStrings(
        "0.17.0-shopify1",
        extract_shopify_latest_released_version(
            \\# Shopify Changelog
            \\
            \\## TigerBeetle (unreleased)
            \\
            \\### Tooling
            \\
            \\- a change
            \\
            \\## TigerBeetle 0.17.0-shopify1
            \\
            \\Released: 2026-05-08
        ).?,
    );

    try std.testing.expectEqualStrings(
        "0.16.78-shopify4",
        extract_shopify_latest_released_version(
            \\## TigerBeetle 0.16.78-shopify4
            \\
            \\Released: 2026-04-16
            \\
            \\## TigerBeetle 0.16.78-shopify3
        ).?,
    );

    try std.testing.expect(extract_shopify_latest_released_version("") == null);
    try std.testing.expect(extract_shopify_latest_released_version(
        \\## TigerBeetle (unreleased)
        \\
        \\- a change
    ) == null);
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

    // Same-triple prior entry is skipped: `0.17.0-shopify2` can't bundle
    // `0.17.0-shopify1` because they collide on `Release.value`.
    try std.testing.expectError(error.NoPreviousRelease, extract_shopify_previous_version(
        \\## TigerBeetle 0.17.0-shopify2
        \\
        \\## TigerBeetle 0.17.0-shopify1
    ));

    // Walks past same-triple entries to reach a different-triple prior.
    try std.testing.expectEqualStrings(
        "0.17.0-shopify1",
        try extract_shopify_previous_version(
            \\## TigerBeetle 0.17.1-shopify2
            \\
            \\## TigerBeetle 0.17.1-shopify1
            \\
            \\## TigerBeetle 0.17.0-shopify1
        ),
    );

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
