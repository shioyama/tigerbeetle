// [shopify] Interactive release script.
//
// Automates the Shopify fork release process:
// 1. Determines the next version from SHOPIFY-CHANGELOG.md and CHANGELOG.md
// 2. Confirms the version with the user
// 3. Creates a release branch, updates the changelog, commits, and pushes
// 4. Opens a pre-filled PR in the browser

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const Shell = @import("../shell.zig");
const changelog = @import("./changelog.zig");

const changelog_bytes_max = 10 * stdx.MiB;

const unreleased_header = "## TigerBeetle (unreleased)";

pub fn main(shell: *Shell, gpa: std.mem.Allocator) !void {
    _ = gpa;

    const allocator = shell.arena.allocator();

    // Read both changelogs.
    var shopify_text = try shell.project_root.readFileAlloc(
        allocator,
        "SHOPIFY-CHANGELOG.md",
        changelog_bytes_max,
    );
    const upstream_text = try shell.project_root.readFileAlloc(
        allocator,
        "CHANGELOG.md",
        changelog_bytes_max,
    );

    // Determine the upstream base version from CHANGELOG.md.
    var upstream_it = changelog.ChangelogIterator.init(upstream_text);
    const upstream_release = while (upstream_it.next_changelog()) |entry| {
        if (entry.release != null) break entry.release.?;
    } else {
        std.log.err("no release found in CHANGELOG.md", .{});
        return error.MissingUpstreamRelease;
    };
    const base_version = try shell.fmt(
        "{[major]}.{[minor]}.{[patch]}",
        upstream_release.triple(),
    );

    // Find the highest shopifyN for this base version.
    const next_n = nextShopifyN(shopify_text, base_version);

    const version = try shell.fmt("{s}-shopify{}", .{ base_version, next_n });

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    // Verify there is an unreleased section to release.
    const has_unreleased = std.mem.indexOf(u8, shopify_text, unreleased_header) != null;
    if (!has_unreleased) {
        if (next_n > 1) {
            std.log.err("SHOPIFY-CHANGELOG.md has no unreleased section — nothing to release", .{});
            return error.NoUnreleasedSection;
        }

        // First shopify release on a new upstream version — offer to create an entry.
        try stdout.print(
            "No unreleased section in SHOPIFY-CHANGELOG.md.\n" ++
                "This is the first release on upstream {s}. " ++
                "Add an \"Upstream merge\" entry? [Y/n] ",
            .{base_version},
        );
        const merge_answer = stdin.readUntilDelimiterAlloc(allocator, '\n', 256) catch "";
        if (merge_answer.len > 0 and merge_answer[0] != 'Y' and merge_answer[0] != 'y') {
            try stdout.print("Aborted.\n", .{});
            return;
        }

        shopify_text = try insertUpstreamMergeEntry(allocator, shopify_text);
    }

    // Confirm with the user.
    try stdout.print("Next release version: {s}\nProceed? [Y/n] ", .{version});

    const answer = stdin.readUntilDelimiterAlloc(allocator, '\n', 256) catch "";
    if (answer.len > 0 and answer[0] != 'Y' and answer[0] != 'y') {
        try stdout.print("Aborted.\n", .{});
        return;
    }

    // Today's date for the release.
    const date_time = stdx.InstantUnix.now().date_time();
    const today = try shell.fmt(
        "{:0>4}-{:0>2}-{:0>2}",
        .{ date_time.year, date_time.month, date_time.day },
    );

    // Create the release branch.
    const branch = try shell.fmt("release/{s}", .{version});
    try shell.exec("git fetch origin --quiet", .{});
    try shell.exec("git switch --create {branch} origin/main", .{ .branch = branch });

    // Update SHOPIFY-CHANGELOG.md: replace the unreleased header with the versioned one.
    const updated_text = try updateChangelogForRelease(allocator, shopify_text, version, today);
    try shell.project_root.writeFile(.{
        .sub_path = "SHOPIFY-CHANGELOG.md",
        .data = updated_text,
    });

    // Validate the updated changelog passes release checks.
    try changelog.validateShopifyRelease(shell, version);

    // Commit and push.
    const commit_msg = try shell.fmt("[shopify] Release {s}", .{version});
    try shell.exec("git add SHOPIFY-CHANGELOG.md", .{});
    try shell.exec("git commit -m {commit_msg}", .{ .commit_msg = commit_msg });
    try shell.exec("git push -u origin {branch}", .{ .branch = branch });

    // Extract the changelog body for the PR description.
    const changelog_body = extractChangelogBody(updated_text, version);

    // Open the PR creation page in the browser.
    const pr_title = try shell.fmt("Release {s}", .{version});
    var url_buf = std.ArrayList(u8).init(allocator);
    const url_writer = url_buf.writer();
    try url_writer.writeAll("https://github.com/shop/tigerbeetle/compare/main...");
    try queryPercentEncode(url_writer, branch);
    try url_writer.writeAll("?expand=1&title=");
    try queryPercentEncode(url_writer, pr_title);
    if (changelog_body.len > 0) {
        try url_writer.writeAll("&body=");
        try queryPercentEncode(url_writer, changelog_body);
    }
    const url = url_buf.items;

    std.log.info("opening PR: {s}", .{url});

    switch (builtin.os.tag) {
        .macos => try shell.exec("open {url}", .{ .url = url }),
        .linux => try shell.exec("xdg-open {url}", .{ .url = url }),
        else => {
            try stdout.print("Open this URL to create the PR:\n{s}\n", .{url});
        },
    }
}

/// Returns the next shopify suffix number for the given base version.
/// Scans changelog headers like `## TigerBeetle X.Y.Z-shopifyN` and returns N+1
/// for the highest matching N, or 1 if no releases exist for this base.
fn nextShopifyN(shopify_text: []const u8, base_version: []const u8) u16 {
    var highest_n: u16 = 0;
    var lines = std.mem.splitScalar(u8, shopify_text, '\n');
    while (lines.next()) |line| {
        const version_string = stdx.cut_prefix(line, "## TigerBeetle ") orelse continue;
        if (std.mem.indexOf(u8, version_string, "unreleased") != null) continue;

        const base, const suffix = stdx.cut(version_string, "-shopify") orelse continue;
        if (!std.mem.eql(u8, base, base_version)) continue;

        const n = std.fmt.parseUnsigned(u16, suffix, 10) catch continue;
        if (n > highest_n) highest_n = n;
    }
    return highest_n + 1;
}

/// Inserts an unreleased section with an "Upstream merge" entry before the first
/// version header in the changelog. Used when cutting the first shopify release
/// on a new upstream version.
fn insertUpstreamMergeEntry(allocator: std.mem.Allocator, shopify_text: []const u8) ![]u8 {
    const insert_pos = std.mem.indexOf(u8, shopify_text, "\n## TigerBeetle ") orelse {
        std.log.err("SHOPIFY-CHANGELOG.md has no version entries", .{});
        return error.MalformedChangelog;
    };
    return std.mem.concat(allocator, u8, &.{
        shopify_text[0..insert_pos],
        "\n" ++ unreleased_header ++ "\n\n### Upstream\n\n" ++
            "- Merged upstream TigerBeetle changes\n\n",
        shopify_text[insert_pos + 1 ..],
    });
}

/// Replaces the `(unreleased)` header with a versioned header and release date.
fn updateChangelogForRelease(
    allocator: std.mem.Allocator,
    shopify_text: []const u8,
    version: []const u8,
    today: []const u8,
) ![]const u8 {
    var versioned_header_buf = std.ArrayList(u8).init(allocator);
    defer versioned_header_buf.deinit();

    try versioned_header_buf.writer().print(
        "## TigerBeetle {s}\n\nReleased: {s}",
        .{ version, today },
    );
    return std.mem.replaceOwned(
        u8,
        allocator,
        shopify_text,
        unreleased_header,
        versioned_header_buf.items,
    );
}

/// Extracts the body text of the changelog entry for the given version.
/// Returns the text between the version header and the next `## ` header (or end of file).
fn extractChangelogBody(text: []const u8, version: []const u8) []const u8 {
    // Find the version header line.
    var search: []const u8 = text;
    const header_start = while (search.len > 0) {
        const idx = std.mem.indexOf(u8, search, "## TigerBeetle ") orelse break null;
        const line_end = std.mem.indexOfScalarPos(u8, search, idx, '\n') orelse search.len;
        const header_version = search[idx + "## TigerBeetle ".len .. line_end];
        if (std.mem.eql(u8, header_version, version)) {
            break @as(?usize, idx);
        }
        search = search[line_end + 1 ..];
    } else null;

    const start = header_start orelse return "";

    // Skip past the header line.
    const after_header = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return "";
    const body_start = after_header + 1;

    // Find the next ## header or end of file.
    const body_end = if (std.mem.indexOf(u8, text[body_start..], "\n## ")) |rel|
        body_start + rel
    else
        text.len;

    return std.mem.trim(u8, text[body_start..body_end], "\n");
}

/// Percent-encodes a string for use in a URL query parameter value.
fn queryPercentEncode(writer: anytype, input: []const u8) !void {
    try std.Uri.Component.percentEncode(writer, input, isUnreserved);
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

test "queryPercentEncode" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try queryPercentEncode(buf.writer(), "Release 0.16.78-shopify4");
    try std.testing.expectEqualStrings("Release%200.16.78-shopify4", buf.items);

    buf.clearRetainingCapacity();
    try queryPercentEncode(buf.writer(), "### Patches\n\n- a change");
    try std.testing.expectEqualStrings("%23%23%23%20Patches%0A%0A-%20a%20change", buf.items);
}

test "extractChangelogBody" {
    const text =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle 0.16.78-shopify4
        \\
        \\Released: 2026-04-16
        \\
        \\### Patches
        \\
        \\- a cool change
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    ;

    const body = extractChangelogBody(text, "0.16.78-shopify4");
    try std.testing.expectEqualStrings(
        \\Released: 2026-04-16
        \\
        \\### Patches
        \\
        \\- a cool change
    , body);

    // Missing version returns empty.
    try std.testing.expectEqualStrings("", extractChangelogBody(text, "0.16.78-shopify99"));
}

test "nextShopifyN" {
    const text =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle (unreleased)
        \\
        \\### CI
        \\
        \\- a change
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
        \\
        \\## TigerBeetle 0.16.78-shopify2
        \\
        \\Released: 2026-04-14
        \\
        \\## TigerBeetle 0.16.77-shopify1
        \\
        \\Released: 2026-03-21
    ;

    // Next after shopify3 for the same base.
    try std.testing.expectEqual(@as(u16, 4), nextShopifyN(text, "0.16.78"));

    // Next for old base (shopify1 exists).
    try std.testing.expectEqual(@as(u16, 2), nextShopifyN(text, "0.16.77"));

    // No releases for this base yet.
    try std.testing.expectEqual(@as(u16, 1), nextShopifyN(text, "0.16.79"));
}

test "insertUpstreamMergeEntry" {
    const text =
        \\# Shopify Changelog
        \\
        \\Changes made in this fork, organized by release.
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    ;

    const result = try insertUpstreamMergeEntry(std.testing.allocator, text);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\# Shopify Changelog
        \\
        \\Changes made in this fork, organized by release.
        \\
        \\## TigerBeetle (unreleased)
        \\
        \\### Upstream
        \\
        \\- Merged upstream TigerBeetle changes
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    , result);
}

test "updateChangelogForRelease" {
    const text =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle (unreleased)
        \\
        \\### CI
        \\
        \\- a change
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    ;

    const result = try updateChangelogForRelease(
        std.testing.allocator,
        text,
        "0.16.78-shopify4",
        "2026-04-16",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\# Shopify Changelog
        \\
        \\## TigerBeetle 0.16.78-shopify4
        \\
        \\Released: 2026-04-16
        \\
        \\### CI
        \\
        \\- a change
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    , result);
}
