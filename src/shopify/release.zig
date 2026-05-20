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
const log = std.log;
const stdx = @import("stdx");

const Shell = @import("../shell.zig");
const ChangelogIterator = @import("../scripts/changelog.zig").ChangelogIterator;
const shopify_changelog = @import("./changelog.zig");
const shopify_github = @import("./github.zig");

const changelog_bytes_max = 10 * stdx.MiB;
const unreleased_header = "## TigerBeetle (unreleased)";

const ReleasePrep = struct {
    shopify_text: []const u8,
    base_version: []const u8,
    version: []const u8,
    has_unreleased: bool,
    next_n: u16,
};

fn read_release_prep(shell: *Shell) !ReleasePrep {
    const allocator = shell.arena.allocator();

    const shopify_text = try shell.project_root.readFileAlloc(
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

    return .{
        .shopify_text = shopify_text,
        .base_version = base_version,
        .version = version,
        .has_unreleased = std.mem.indexOf(u8, shopify_text, unreleased_header) != null,
        .next_n = next_n,
    };
}

fn write_release_changelog(
    shell: *Shell,
    shopify_text: []const u8,
    version: []const u8,
) ![]const u8 {
    const allocator = shell.arena.allocator();
    const date_time = stdx.InstantUnix.now().date_time();
    const today = try shell.fmt(
        "{:0>4}-{:0>2}-{:0>2}",
        .{ date_time.year, date_time.month, date_time.day },
    );
    const updated_text = try update_changelog_for_release(
        allocator,
        shopify_text,
        version,
        today,
    );
    try shell.project_root.writeFile(.{
        .sub_path = "SHOPIFY-CHANGELOG.md",
        .data = updated_text,
    });
    return updated_text;
}

/// Rewrite an `(unreleased)` header into a versioned, dated header in place,
/// without committing. No-op if the changelog has no unreleased section.
pub fn prepare_validation_release(shell: *Shell) !void {
    const prep = try read_release_prep(shell);
    if (!prep.has_unreleased) {
        log.info("SHOPIFY-CHANGELOG.md has no unreleased section; skipping rewrite", .{});
        return;
    }
    _ = try write_release_changelog(shell, prep.shopify_text, prep.version);
    log.info("SHOPIFY-CHANGELOG.md finalized in-place as {s}", .{prep.version});
}

pub fn main(shell: *Shell, gpa: std.mem.Allocator) !void {
    _ = gpa;

    const allocator = shell.arena.allocator();

    const prep = try read_release_prep(shell);
    var shopify_text = prep.shopify_text;
    const version = prep.version;

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    if (!prep.has_unreleased) {
        if (prep.next_n > 1) {
            log.err("SHOPIFY-CHANGELOG.md has no unreleased section — nothing to release", .{});
            return error.NoUnreleasedSection;
        }

        try stdout.print(
            "No unreleased section in SHOPIFY-CHANGELOG.md.\n" ++
                "This is the first release on upstream {s}. " ++
                "Add an \"Upstream merge\" entry? [Y/n] ",
            .{prep.base_version},
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

    const branch = try shell.fmt("release/{s}", .{version});
    try shell.exec("git fetch origin --quiet", .{});
    try shell.exec("git switch --create {branch} origin/main", .{ .branch = branch });

    const updated_text = try write_release_changelog(shell, shopify_text, version);

    try shopify_changelog.validate_shopify_release(shell, version);

    const commit_msg = try shell.fmt("[shopify] Release {s}", .{version});
    try shell.exec("git add SHOPIFY-CHANGELOG.md", .{});
    try shell.exec("git commit -m {commit_msg}", .{ .commit_msg = commit_msg });
    try shell.exec("git push -u origin {branch}", .{ .branch = branch });

    const changelog_body = extract_changelog_body(updated_text, version);
    const pr_body = try compose_release_pr_body(shell, version, changelog_body);

    const pr_title = try shell.fmt("Release {s}", .{version});
    try shopify_github.open_pr_compare(shell, allocator, branch, pr_title, pr_body);
}

fn compose_release_pr_body(
    shell: *Shell,
    version: []const u8,
    changelog_body: []const u8,
) ![]const u8 {
    return shell.fmt(
        "## Release candidates\n\n" ++
            "To publish a release candidate from this branch before merging, " ++
            "[open the `tigerbeetle-publish-package` build form]" ++
            "(https://buildkite.com/shopify/tigerbeetle-publish-package/builds" ++
            "?branch=release%2F{s}&env=SHOPIFY_PRERELEASE=1&message=RC+for+{s}#new) " ++
            "and adjust `SHOPIFY_PRERELEASE` to the next RC number (start at `1`, " ++
            "increment to come after any prior RC already published). The build " ++
            "publishes `{s}~rcN.deb` to Cloudsmith.\n\n" ++
            "---\n\n{s}",
        .{ version, version, version, changelog_body },
    );
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
    // binary, so stage tb-snapshot alongside it in usr/bin/. The preceding
    // `build_tigerbeetle_target` run already produced zig-out/bin/tb-snapshot
    // stamped with the correct release triples via the default install step
    // (see src/shopify/tb_snapshot/build.zig).
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

    // Prerelease builds tag the .deb with `~rc{N}` but leave the binary stamp
    // at the changelog's base version, so strip the suffix before checking.
    const stamped_version = if (std.mem.indexOf(u8, shopify_version, "~rc")) |idx|
        shopify_version[0..idx]
    else
        shopify_version;
    try assert_release_version(shell, pkg_dir, stamped_version);

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

/// Asserts both staged binaries report `TigerBeetle version <shopify_version>...`
/// and match each other byte-for-byte.
fn assert_release_version(
    shell: *Shell,
    pkg_dir: []const u8,
    shopify_version: []const u8,
) !void {
    const tigerbeetle_bin = try shell.fmt("{s}/usr/bin/tigerbeetle", .{pkg_dir});
    const tb_snapshot_bin = try shell.fmt("{s}/usr/bin/tb-snapshot", .{pkg_dir});

    const tigerbeetle_version = try shell.exec_stdout("{bin} version", .{
        .bin = tigerbeetle_bin,
    });
    const tb_snapshot_version = try shell.exec_stdout("{bin} --version", .{
        .bin = tb_snapshot_bin,
    });

    const expected_prefix = try shell.fmt(
        "TigerBeetle version {s}",
        .{shopify_version},
    );

    if (!std.mem.startsWith(u8, tigerbeetle_version, expected_prefix)) {
        std.debug.panic(
            "tigerbeetle binary stamped with the wrong release: " ++
                "expected prefix '{s}', got '{s}'",
            .{ expected_prefix, tigerbeetle_version },
        );
    }
    if (!std.mem.startsWith(u8, tb_snapshot_version, expected_prefix)) {
        std.debug.panic(
            "tb-snapshot binary stamped with the wrong release: " ++
                "expected prefix '{s}', got '{s}'",
            .{ expected_prefix, tb_snapshot_version },
        );
    }
    if (!std.mem.eql(u8, tigerbeetle_version, tb_snapshot_version)) {
        std.debug.panic(
            "tigerbeetle and tb-snapshot stamped with different releases: " ++
                "tigerbeetle='{s}', tb-snapshot='{s}'",
            .{ tigerbeetle_version, tb_snapshot_version },
        );
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
