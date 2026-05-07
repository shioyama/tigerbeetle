//! Shopify fork release helpers.
//!
//! - `main`: interactive release prep script invoked via
//!   `zig build scripts -- shopify-release`. Determines the next version
//!   from SHOPIFY-CHANGELOG.md + CHANGELOG.md, creates a release branch,
//!   updates the changelog, and opens a pre-filled PR.
//! - `build_artifacts`: called from `scripts/release.zig` when `--shopify`
//!   is set. Assembles the `.deb` package from artifacts produced by the
//!   preceding upstream build.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const stdx = @import("stdx");

const Shell = @import("../shell.zig");
const ChangelogIterator = @import("../scripts/changelog.zig").ChangelogIterator;
const shopify_changelog = @import("./changelog.zig");

const changelog_bytes_max = 10 * stdx.MiB;
const unreleased_header = "## TigerBeetle (unreleased)";

pub fn main(shell: *Shell, gpa: std.mem.Allocator) !void {
    _ = gpa;

    const allocator = shell.arena.allocator();

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

    var upstream_it = ChangelogIterator.init(upstream_text);
    const upstream_release = while (upstream_it.next_changelog()) |entry| {
        if (entry.release != null) break entry.release.?;
    } else {
        log.err("no release found in CHANGELOG.md", .{});
        return error.MissingUpstreamRelease;
    };
    const base_version = try shell.fmt(
        "{[major]}.{[minor]}.{[patch]}",
        upstream_release.triple(),
    );

    const next_n = next_shopify_n(shopify_text, base_version);
    const version = try shell.fmt("{s}-shopify{}", .{ base_version, next_n });

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    const has_unreleased = std.mem.indexOf(u8, shopify_text, unreleased_header) != null;
    if (!has_unreleased) {
        if (next_n > 1) {
            log.err("SHOPIFY-CHANGELOG.md has no unreleased section — nothing to release", .{});
            return error.NoUnreleasedSection;
        }

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

        shopify_text = try insert_upstream_merge_entry(allocator, shopify_text);
    }

    try stdout.print("Next release version: {s}\nProceed? [Y/n] ", .{version});

    const answer = stdin.readUntilDelimiterAlloc(allocator, '\n', 256) catch "";
    if (answer.len > 0 and answer[0] != 'Y' and answer[0] != 'y') {
        try stdout.print("Aborted.\n", .{});
        return;
    }

    const date_time = stdx.InstantUnix.now().date_time();
    const today = try shell.fmt(
        "{:0>4}-{:0>2}-{:0>2}",
        .{ date_time.year, date_time.month, date_time.day },
    );

    const branch = try shell.fmt("release/{s}", .{version});
    try shell.exec("git fetch origin --quiet", .{});
    try shell.exec("git switch --create {branch} origin/main", .{ .branch = branch });

    const updated_text = try update_changelog_for_release(allocator, shopify_text, version, today);
    try shell.project_root.writeFile(.{
        .sub_path = "SHOPIFY-CHANGELOG.md",
        .data = updated_text,
    });

    try shopify_changelog.validate_shopify_release(shell, version);

    const commit_msg = try shell.fmt("[shopify] Release {s}", .{version});
    try shell.exec("git add SHOPIFY-CHANGELOG.md", .{});
    try shell.exec("git commit -m {commit_msg}", .{ .commit_msg = commit_msg });
    try shell.exec("git push -u origin {branch}", .{ .branch = branch });

    const changelog_body = extract_changelog_body(updated_text, version);

    const pr_title = try shell.fmt("Release {s}", .{version});
    var url_buf = std.ArrayList(u8).init(allocator);
    const url_writer = url_buf.writer();
    try url_writer.writeAll("https://github.com/shop/tigerbeetle/compare/main...");
    try query_percent_encode(url_writer, branch);
    try url_writer.writeAll("?expand=1&title=");
    try query_percent_encode(url_writer, pr_title);
    if (changelog_body.len > 0) {
        try url_writer.writeAll("&body=");
        try query_percent_encode(url_writer, changelog_body);
    }
    const url = url_buf.items;

    log.info("opening PR: {s}", .{url});

    switch (builtin.os.tag) {
        .macos => try shell.exec("open {url}", .{ .url = url }),
        .linux => try shell.exec("xdg-open {url}", .{ .url = url }),
        else => {
            try stdout.print("Open this URL to create the PR:\n{s}\n", .{url});
        },
    }
}

/// Build the Shopify fork artifacts (the `.deb` package). Called from
/// `scripts/release.zig` after upstream's per-language build has populated
/// `zig-out/dist/tigerbeetle/` and `zig-out/dist/go/`.
pub fn build_artifacts(
    shell: *Shell,
    shopify_version: []const u8,
) !void {
    var section = try shell.open_section("build shopify artifacts");
    defer section.close();

    // Preconditions: upstream builds must have produced these.
    try shell.project_root.access("zig-out/dist/tigerbeetle/tigerbeetle-x86_64-linux.zip", .{});
    try shell.project_root.access("zig-out/dist/go", .{});

    try shell.project_root.makePath("zig-out/shopify-dist");

    const pkg_dir = try shell.fmt(
        "zig-out/shopify-dist/deb-staging/tigerbeetle_{s}_amd64",
        .{shopify_version},
    );

    try shell.project_root.makePath(try shell.fmt("{s}/DEBIAN", .{pkg_dir}));
    var bin_dir = try shell.project_root.makeOpenPath(
        try shell.fmt("{s}/usr/bin", .{pkg_dir}),
        .{},
    );
    defer bin_dir.close();

    const go_client_dir = try shell.fmt(
        "{s}/usr/share/tigerbeetle/go-client",
        .{pkg_dir},
    );
    try shell.project_root.makePath(go_client_dir);

    const control = try shell.fmt(
        \\Package: tigerbeetle
        \\Version: {s}
        \\Architecture: amd64
        \\Maintainer: Shopify <infrastructure@shopify.com>
        \\Description: TigerBeetle financial transactions database
        \\
    , .{shopify_version});
    try shell.project_root.writeFile(.{
        .sub_path = try shell.fmt("{s}/DEBIAN/control", .{pkg_dir}),
        .data = control,
    });

    {
        const zip_file = try shell.project_root.openFile(
            "zig-out/dist/tigerbeetle/tigerbeetle-x86_64-linux.zip",
            .{},
        );
        defer zip_file.close();

        try std.zip.extract(bin_dir, zip_file.seekableStream(), .{});
        // std.zip.extract doesn't preserve permissions.
        const tigerbeetle_bin = try bin_dir.openFile("tigerbeetle", .{});
        defer tigerbeetle_bin.close();

        try tigerbeetle_bin.chmod(0o755);
    }

    // Upstream's tigerbeetle-x86_64-linux.zip only contains the tigerbeetle
    // binary, so build tb-snapshot separately for the same target and stage it
    // alongside in usr/bin/.
    try shell.exec_zig("build tb-snapshot -Dtarget=x86_64-linux -Drelease=true", .{});
    try Shell.copy_path(
        shell.project_root,
        "zig-out/bin/tb-snapshot",
        bin_dir,
        "tb-snapshot",
    );
    {
        const tb_snapshot_bin = try bin_dir.openFile("tb-snapshot", .{});
        defer tb_snapshot_bin.close();

        try tb_snapshot_bin.chmod(0o755);
    }

    // Slim go-client: x86_64-linux native lib only, plus the Go source files
    // callers actually import. Layered via tar to preserve the `pkg/...`
    // directory structure without one `cp` per entry.
    const go_client_tarball = "zig-out/shopify-dist/go-client.tar.gz";
    try shell.exec(
        \\tar czf {tarball}
        \\    -C src/clients/go
        \\    go.mod go.sum
        \\    tb_client.go bindings.go errors.go uint128.go
        \\    native/native.go native/tb_client.h native/libtb_client_x86_64-linux.a
        \\    LICENSE
    , .{ .tarball = go_client_tarball });
    try shell.exec("tar xzf {tarball} -C {dest}", .{
        .tarball = go_client_tarball,
        .dest = go_client_dir,
    });

    try shell.exec("dpkg-deb --build {staging} zig-out/shopify-dist/", .{
        .staging = pkg_dir,
    });

    // Postcondition: if the build steps above returned successfully, these
    // artifacts must exist. A missing path here means a build step silently
    // dropped its output (e.g. a renamed file, a tar source that vanished),
    // which the `release/*` validate pipeline must catch — publish would
    // otherwise upload an incomplete .deb.
    const expected_artifacts = [_][]const u8{
        try shell.fmt(
            "zig-out/shopify-dist/tigerbeetle_{s}_amd64.deb",
            .{shopify_version},
        ),
        try shell.fmt("{s}/usr/bin/tigerbeetle", .{pkg_dir}),
        try shell.fmt("{s}/usr/bin/tb-snapshot", .{pkg_dir}),
        try shell.fmt(
            "{s}/usr/share/tigerbeetle/go-client/native/libtb_client_x86_64-linux.a",
            .{pkg_dir},
        ),
    };
    for (expected_artifacts) |path| {
        shell.project_root.access(path, .{}) catch |err| {
            std.debug.panic(
                "missing release artifact: {s} ({s})",
                .{ path, @errorName(err) },
            );
        };
    }
}

/// Returns the next shopify suffix number for the given base version.
/// Scans changelog headers like `## TigerBeetle X.Y.Z-shopifyN` and returns N+1
/// for the highest matching N, or 1 if no releases exist for this base.
fn next_shopify_n(shopify_text: []const u8, base_version: []const u8) u16 {
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
fn insert_upstream_merge_entry(allocator: std.mem.Allocator, shopify_text: []const u8) ![]u8 {
    const insert_pos = std.mem.indexOf(u8, shopify_text, "\n## TigerBeetle ") orelse {
        log.err("SHOPIFY-CHANGELOG.md has no version entries", .{});
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
fn update_changelog_for_release(
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
fn extract_changelog_body(text: []const u8, version: []const u8) []const u8 {
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

    const after_header = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return "";
    const body_start = after_header + 1;

    const body_end = if (std.mem.indexOf(u8, text[body_start..], "\n## ")) |rel|
        body_start + rel
    else
        text.len;

    return std.mem.trim(u8, text[body_start..body_end], "\n");
}

fn query_percent_encode(writer: anytype, input: []const u8) !void {
    try std.Uri.Component.percentEncode(writer, input, is_unreserved);
}

fn is_unreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

test "query_percent_encode" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try query_percent_encode(buf.writer(), "Release 0.16.78-shopify4");
    try std.testing.expectEqualStrings("Release%200.16.78-shopify4", buf.items);

    buf.clearRetainingCapacity();
    try query_percent_encode(buf.writer(), "### Patches\n\n- a change");
    try std.testing.expectEqualStrings("%23%23%23%20Patches%0A%0A-%20a%20change", buf.items);
}

test "extract_changelog_body" {
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

    const body = extract_changelog_body(text, "0.16.78-shopify4");
    try std.testing.expectEqualStrings(
        \\Released: 2026-04-16
        \\
        \\### Patches
        \\
        \\- a cool change
    , body);

    try std.testing.expectEqualStrings("", extract_changelog_body(text, "0.16.78-shopify99"));
}

test "next_shopify_n" {
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

    try std.testing.expectEqual(@as(u16, 4), next_shopify_n(text, "0.16.78"));
    try std.testing.expectEqual(@as(u16, 2), next_shopify_n(text, "0.16.77"));
    try std.testing.expectEqual(@as(u16, 1), next_shopify_n(text, "0.16.79"));
}

test "insert_upstream_merge_entry" {
    const text =
        \\# Shopify Changelog
        \\
        \\Changes made in this fork, organized by release.
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    ;

    const result = try insert_upstream_merge_entry(std.testing.allocator, text);
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

test "update_changelog_for_release" {
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

    const result = try update_changelog_for_release(
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
