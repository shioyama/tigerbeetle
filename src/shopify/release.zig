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

const ChangelogIterator = @import("../scripts/changelog.zig").ChangelogIterator;
const shopify_changelog = @import("./changelog.zig");
const shopify_github = @import("./github.zig");
const shopify_stdx = @import("./stdx.zig");

const changelog_bytes_max = 10 * stdx.MiB;
const unreleased_header = "## TigerBeetle (unreleased)";

const ReleasePrep = struct {
    shopify_text: []const u8,
    upstream_changelog_body: []const u8,
    base_version: []const u8,
    version: []const u8,
    has_unreleased: bool,
    next_n: u16,
};

fn read_release_prep(shell: *stdx.Shell) !ReleasePrep {
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
    const upstream_changelog = while (upstream_it.next_changelog()) |entry| {
        if (entry.release) |release| break .{
            .release = release,
            .body = entry.text_body,
        };
    } else {
        log.err("no release found in CHANGELOG.md", .{});
        return error.MissingUpstreamRelease;
    };
    const base_version = try shell.fmt(
        "{[major]}.{[minor]}.{[patch]}",
        upstream_changelog.release.triple(),
    );

    const next_n = next_shopify_n(shopify_text, base_version);
    const version = try shell.fmt("{s}-shopify{}", .{ base_version, next_n });

    return .{
        .shopify_text = shopify_text,
        .upstream_changelog_body = upstream_changelog.body,
        .base_version = base_version,
        .version = version,
        .has_unreleased = std.mem.indexOf(u8, shopify_text, unreleased_header) != null,
        .next_n = next_n,
    };
}

fn write_release_changelog(
    shell: *stdx.Shell,
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

/// Rewrite the fork changelog into the same shape a release branch would carry,
/// without committing.
pub fn prepare_validation_release(shell: *stdx.Shell) !void {
    const prep = try read_release_prep(shell);
    const shopify_text = if (prep.has_unreleased)
        prep.shopify_text
    else if (prep.next_n == 1) blk: {
        log.info(
            "SHOPIFY-CHANGELOG.md has no unreleased section; " ++
                "synthesizing date-only release entry",
            .{},
        );
        break :blk try insert_empty_unreleased_section(
            shell.arena.allocator(),
            prep.shopify_text,
        );
    } else {
        log.info("SHOPIFY-CHANGELOG.md has no unreleased section; skipping rewrite", .{});
        return;
    };
    _ = try write_release_changelog(shell, shopify_text, prep.version);
    log.info("SHOPIFY-CHANGELOG.md finalized in-place as {s}", .{prep.version});
}

pub fn main(shell: *stdx.Shell, gpa: std.mem.Allocator) !void {
    _ = gpa;

    const allocator = shell.arena.allocator();

    const prep = try read_release_prep(shell);
    const version = prep.version;
    const shopify_text = (try prepare_shopify_text_for_release(allocator, prep)) orelse return;
    const current_branch = std.mem.trim(
        u8,
        try shell.exec_stdout("git rev-parse --abbrev-ref HEAD", .{}),
        " \r\n\t",
    );
    if (!std.mem.eql(u8, current_branch, "main") and
        !try confirm_non_main_branch(allocator, current_branch)) return;
    if (!try confirm_release(allocator, version)) return;

    const branch = try shell.fmt("release/{s}", .{version});
    try shell.exec("git fetch origin --quiet", .{});
    try shell.exec("git switch --create {branch} HEAD", .{ .branch = branch });

    const updated_text = try write_release_changelog(shell, shopify_text, version);

    try shopify_changelog.validate_shopify_release(shell, version);
    try shopify_changelog.validate_shopify_changelog_structure(shell);

    const commit_msg = try shell.fmt("[shopify] Release {s}", .{version});
    try shell.exec("git add SHOPIFY-CHANGELOG.md", .{});
    try shell.exec("git commit -m {commit_msg}", .{ .commit_msg = commit_msg });
    try shell.exec("git push -u origin {branch}", .{ .branch = branch });

    const changelog_body = extract_changelog_body(updated_text, version);
    // Same-base `-shopifyN>1` releases already carried the upstream notes in
    // `-shopify1`; keep hotfix PR bodies focused on fork-only changes.
    const upstream_changelog_body: ?[]const u8 = if (prep.next_n == 1)
        prep.upstream_changelog_body
    else
        null;
    const pr_body = try compose_release_pr_body(
        shell,
        version,
        changelog_body,
        prep.base_version,
        upstream_changelog_body,
    );

    const pr_title = try shell.fmt("Release {s}", .{version});
    try shopify_github.open_pr_compare(shell, allocator, branch, pr_title, pr_body);
}

fn prepare_shopify_text_for_release(
    allocator: std.mem.Allocator,
    prep: ReleasePrep,
) !?[]const u8 {
    if (prep.has_unreleased) return prep.shopify_text;

    const stdout = std.io.getStdOut().writer();
    if (prep.next_n > 1) {
        try stdout.print(
            "SHOPIFY-CHANGELOG.md has no unreleased section and upstream " ++
                "{s} already has a fork release; nothing to release.\n",
            .{prep.base_version},
        );
        return null;
    }

    try stdout.print(
        "No unreleased section in SHOPIFY-CHANGELOG.md.\n" ++
            "This is the first release on upstream {s}; " ++
            "creating a date-only changelog entry.\n",
        .{prep.base_version},
    );

    return try insert_empty_unreleased_section(allocator, prep.shopify_text);
}

fn confirm_non_main_branch(allocator: std.mem.Allocator, branch: []const u8) !bool {
    return confirm(
        allocator,
        "You are on branch '{s}', not 'main'.\n" ++
            "The release branch will be created from the current HEAD.\n" ++
            "Release from this branch? [Y/n] ",
        .{branch},
    );
}

fn confirm_release(allocator: std.mem.Allocator, version: []const u8) !bool {
    return confirm(
        allocator,
        "Next release version: {s}\nProceed? [Y/n] ",
        .{version},
    );
}

fn confirm(
    allocator: std.mem.Allocator,
    comptime prompt: []const u8,
    args: anytype,
) !bool {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(prompt, args);
    const stdin = std.io.getStdIn().reader();
    const confirmed = try shopify_stdx.read_yes(allocator, stdin);
    if (!confirmed) try stdout.print("Aborted.\n", .{});
    return confirmed;
}

fn compose_release_pr_body(
    shell: *stdx.Shell,
    version: []const u8,
    changelog_body: []const u8,
    base_version: []const u8,
    upstream_changelog_body: ?[]const u8,
) ![]const u8 {
    const pr_body = try shell.fmt(
        "## Release candidates\n\n" ++
            "To publish a release candidate from this branch before merging, " ++
            "[open the `tigerbeetle-publish-package` build form]" ++
            "(https://buildkite.com/shopify/tigerbeetle-publish-package/builds" ++
            "?branch=release%2F{s}&env=SHOPIFY_PRERELEASE=1&message=RC+for+{s}#new) " ++
            "and adjust `SHOPIFY_PRERELEASE` to the next RC number (start at `1`, " ++
            "increment to come after any prior RC already published). The build " ++
            "publishes `{s}~rcN.deb` to Cloudsmith.\n\n" ++
            "## Debug builds\n\n" ++
            "To publish a debug-symbol build from this branch, " ++
            "[open the `tigerbeetle-publish-package` build form]" ++
            "(https://buildkite.com/shopify/tigerbeetle-publish-package/builds" ++
            "?branch=release%2F{s}&env=SHOPIFY_DEBUG_RELEASE=1&message=Debug+build+for+{s}#new) " ++
            "and adjust `SHOPIFY_DEBUG_RELEASE` to the next debug build number " ++
            "(start at `1`, increment to come after any prior debug build already " ++
            "published). The build publishes `{s}~debugN.deb` to Cloudsmith.\n\n" ++
            "---\n\n{s}",
        .{ version, version, version, version, version, version, changelog_body },
    );

    return if (upstream_changelog_body) |body|
        append_upstream_changelog_body(
            shell.arena.allocator(),
            pr_body,
            base_version,
            body,
        )
    else
        pr_body;
}

fn append_upstream_changelog_body(
    allocator: std.mem.Allocator,
    pr_body: []const u8,
    base_version: []const u8,
    upstream_changelog_body: []const u8,
) ![]const u8 {
    const trimmed_body = std.mem.trim(u8, upstream_changelog_body, "\r\n");
    if (trimmed_body.len == 0) return pr_body;

    return std.mem.concat(allocator, u8, &.{
        pr_body,
        "\n\n---\n\n## Upstream TigerBeetle ",
        base_version,
        "\n\n",
        trimmed_body,
    });
}

/// Build the Shopify fork artifacts (the `.deb` package). Called from
/// `scripts/release.zig` after upstream's per-language build has populated
/// `zig-out/dist/tigerbeetle/` and `zig-out/dist/go/`.
pub fn build_artifacts(
    shell: *stdx.Shell,
    shopify_version: []const u8,
) !void {
    var section = try shell.open_section("build shopify artifacts");
    defer section.close();

    const debug_build = std.mem.indexOf(u8, shopify_version, "~debug") != null;
    const tigerbeetle_zip = if (debug_build)
        "zig-out/dist/tigerbeetle/tigerbeetle-x86_64-linux-debug.zip"
    else
        "zig-out/dist/tigerbeetle/tigerbeetle-x86_64-linux.zip";

    // Preconditions: upstream builds must have produced these.
    try shell.project_root.access(tigerbeetle_zip, .{});
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
            tigerbeetle_zip,
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
    // binary, so stage Shopify helper binaries alongside it in usr/bin/. The
    // preceding `build_tigerbeetle_target` run already produced them stamped
    // with the correct release triples via the default install step.
    inline for (.{ "tb-snapshot", "tb-datafile" }) |helper| {
        try stdx.Shell.copy_path(
            shell.project_root,
            try shell.fmt("zig-out/bin/{s}", .{helper}),
            bin_dir,
            helper,
        );
        const helper_bin = try bin_dir.openFile(helper, .{});
        defer helper_bin.close();

        try helper_bin.chmod(0o755);
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

    // Prerelease/debug builds tag the .deb with `~rc{N}`/`~debug{N}` but leave
    // the binary stamp at the changelog's base version, so strip the suffix
    // before checking.
    const stamped_version = if (std.mem.indexOfScalar(u8, shopify_version, '~')) |idx|
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
        try shell.fmt("{s}/usr/bin/tb-datafile", .{pkg_dir}),
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

/// Asserts staged binaries report `TigerBeetle version <shopify_version>...`
/// and match each other byte-for-byte.
fn assert_release_version(
    shell: *stdx.Shell,
    pkg_dir: []const u8,
    shopify_version: []const u8,
) !void {
    const tigerbeetle_bin = try shell.fmt("{s}/usr/bin/tigerbeetle", .{pkg_dir});
    const tigerbeetle_version = try shell.exec_stdout("{bin} version", .{
        .bin = tigerbeetle_bin,
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

    inline for (.{ "tb-snapshot", "tb-datafile" }) |helper| {
        const helper_bin = try shell.fmt("{s}/usr/bin/{s}", .{ pkg_dir, helper });
        const helper_version = try shell.exec_stdout("{bin} --version", .{
            .bin = helper_bin,
        });

        if (!std.mem.startsWith(u8, helper_version, expected_prefix)) {
            std.debug.panic(
                "{s} binary stamped with the wrong release: " ++
                    "expected prefix '{s}', got '{s}'",
                .{ helper, expected_prefix, helper_version },
            );
        }
        if (!std.mem.eql(u8, tigerbeetle_version, helper_version)) {
            std.debug.panic(
                "tigerbeetle and {s} stamped with different releases: " ++
                    "tigerbeetle='{s}', {s}='{s}'",
                .{ helper, tigerbeetle_version, helper, helper_version },
            );
        }
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

        const n = stdx.parse_int(u16, suffix, .{}) catch continue;
        if (n > highest_n) highest_n = n;
    }
    return highest_n + 1;
}

/// Upstream-only releases still need a fork version header for binary stamping.
fn insert_empty_unreleased_section(
    allocator: std.mem.Allocator,
    shopify_text: []const u8,
) ![]u8 {
    const insert_pos = std.mem.indexOf(u8, shopify_text, "\n## TigerBeetle ") orelse {
        log.err("SHOPIFY-CHANGELOG.md has no version entries", .{});
        return error.MalformedChangelog;
    };
    return std.mem.concat(allocator, u8, &.{
        shopify_text[0..insert_pos],
        "\n" ++ unreleased_header ++ "\n\n",
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

test "append_upstream_changelog_body" {
    const upstream_body =
        \\### Features
        \\
        \\- [#1234](https://github.com/tigerbeetle/tigerbeetle/pull/1234)
        \\
        \\  Upstream change.
        \\
    ;
    const result = try append_upstream_changelog_body(
        std.testing.allocator,
        "fork release body",
        "0.17.2",
        upstream_body,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\fork release body
        \\
        \\---
        \\
        \\## Upstream TigerBeetle 0.17.2
        \\
        \\### Features
        \\
        \\- [#1234](https://github.com/tigerbeetle/tigerbeetle/pull/1234)
        \\
        \\  Upstream change.
    , result);

    const unchanged = try append_upstream_changelog_body(
        std.testing.allocator,
        "fork release body",
        "0.17.2",
        "\n\n",
    );
    try std.testing.expectEqualStrings("fork release body", unchanged);
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

test "insert_empty_unreleased_section" {
    const text =
        \\# Shopify Changelog
        \\
        \\Changes made in this fork, organized by release.
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    ;

    const result = try insert_empty_unreleased_section(std.testing.allocator, text);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\# Shopify Changelog
        \\
        \\Changes made in this fork, organized by release.
        \\
        \\## TigerBeetle (unreleased)
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

    const empty =
        \\# Shopify Changelog
        \\
        \\## TigerBeetle (unreleased)
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    ;
    const empty_result = try update_changelog_for_release(
        std.testing.allocator,
        empty,
        "0.16.79-shopify1",
        "2026-04-22",
    );
    defer std.testing.allocator.free(empty_result);

    try std.testing.expectEqualStrings(
        \\# Shopify Changelog
        \\
        \\## TigerBeetle 0.16.79-shopify1
        \\
        \\Released: 2026-04-22
        \\
        \\## TigerBeetle 0.16.78-shopify3
        \\
        \\Released: 2026-04-15
    , empty_result);
}
