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

/// Returns the newest prior fork release whose upstream triple is lower than
/// the top entry's. Same-triple entries are skipped because the multiversion
/// loader would see two builds with the same version number. Higher triples are
/// skipped so backport releases can coexist with newer entries in the changelog.
/// `error.NoPreviousRelease` means the caller should fall back to
/// `CHANGELOG.md`'s upstream-derived previous.
pub fn extract_shopify_previous_version(text: []const u8) error{
    UnreleasedChangelog,
    MissingChangelogEntry,
    NoPreviousRelease,
}![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var current: ?ForkVersion = null;
    var best: ?ForkVersion = null;
    var best_version: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## ")) continue;
        if (std.mem.indexOf(u8, line, "unreleased") != null) {
            return error.UnreleasedChangelog;
        }
        if (!std.mem.startsWith(u8, line, "## TigerBeetle ")) continue;
        const version = line["## TigerBeetle ".len..];
        const parsed = parse_fork_version(version) orelse continue;
        if (current) |cur| {
            if (!triple_less_than(parsed.triple, cur.triple)) continue;
            if (best == null or best.?.ord < parsed.ord) {
                best = parsed;
                best_version = version;
            }
        } else {
            current = parsed;
        }
    }
    if (current == null) return error.MissingChangelogEntry;
    return best_version orelse error.NoPreviousRelease;
}

const ForkVersion = struct {
    triple: [3]u32,
    ord: u64,
};

/// Parses "X.Y.Z-shopifyN" into a comparable u64.
pub fn parse_shopify_version(version: []const u8) ?u64 {
    const parsed = parse_fork_version(version) orelse return null;
    return parsed.ord;
}

fn parse_fork_version(version: []const u8) ?ForkVersion {
    const dash_idx = std.mem.indexOf(u8, version, "-shopify") orelse return null;
    const n = parse_decimal(u16, version[dash_idx + "-shopify".len ..]) orelse
        return null;

    var triple: [3]u32 = undefined;
    var parts = std.mem.splitScalar(u8, version[0..dash_idx], '.');
    for (&triple) |*part_out| {
        const part = parts.next() orelse return null;
        part_out.* = parse_decimal(u32, part) orelse return null;
    }
    if (parts.next() != null) return null;

    return .{
        .triple = triple,
        .ord = @as(u64, triple[0]) << 32 |
            @as(u64, triple[1]) << 24 |
            @as(u64, triple[2]) << 16 |
            @as(u64, n),
    };
}

fn parse_decimal(comptime Int: type, text: []const u8) ?Int {
    if (text.len == 0) return null;
    var value: Int = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = std.math.mul(Int, value, 10) catch return null;
        value = std.math.add(Int, value, @intCast(c - '0')) catch return null;
    }
    return value;
}

fn triple_less_than(a: [3]u32, b: [3]u32) bool {
    for (a, b) |a_part, b_part| {
        if (a_part != b_part) return a_part < b_part;
    }
    return false;
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
    // `0.17.0-shopify1` because they would carry the same version number.
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

    // Backport release: newer changelog entries must not be selected as the
    // multiversion target, even if they appear before the true prior base.
    try std.testing.expectEqualStrings(
        "0.17.3-shopify2",
        try extract_shopify_previous_version(
            \\## TigerBeetle 0.17.4-shopify2
            \\
            \\## TigerBeetle 0.17.6-shopify1
            \\
            \\## TigerBeetle 0.17.5-shopify2
            \\
            \\## TigerBeetle 0.17.4-shopify1
            \\
            \\## TigerBeetle 0.17.3-shopify2
            \\
            \\## TigerBeetle 0.17.3-shopify1
        ),
    );

    try std.testing.expectError(error.MissingChangelogEntry, extract_shopify_previous_version(""));
}

test parse_shopify_version {
    try std.testing.expectEqual(
        @as(u64, 0x0000_0000_1104_0002),
        parse_shopify_version("0.17.4-shopify2").?,
    );
    try std.testing.expect(parse_shopify_version("0.17.4") == null);
    try std.testing.expect(parse_shopify_version("0.17.4-shopify") == null);
    try std.testing.expect(parse_shopify_version("0.17.4-shopify2-rc1") == null);
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
