//! Fork-specific extensions, parallel to upstream's `src/stdx/stdx.zig`.

const std = @import("std");

pub fn truthy(val: ?[]const u8) bool {
    const v = val orelse return false;
    if (std.mem.eql(u8, v, "1")) return true;
    if (std.ascii.eqlIgnoreCase(v, "true")) return true;
    if (std.ascii.eqlIgnoreCase(v, "yes")) return true;
    return false;
}

pub fn read_yes(allocator: std.mem.Allocator, reader: anytype) !bool {
    const answer = reader.readUntilDelimiterAlloc(allocator, '\n', 256) catch |err| switch (err) {
        error.EndOfStream => return true,
        else => return err,
    };
    defer allocator.free(answer);

    return answer.len == 0 or answer[0] == 'Y' or answer[0] == 'y';
}

/// Parses the `SHOPIFY_PRERELEASE` env var value as the RC number for a
/// prerelease build. Returns `null` when the env var is unset or empty (i.e.
/// not a prerelease). Errors when the env var is set but isn't a non-negative
/// integer. Callers append `~rc{N}` to the changelog-derived version.
pub fn prerelease_rc_n(env_value: ?[]const u8) !?u16 {
    return numbered_release_suffix(env_value, error.InvalidPrerelease);
}

/// Parses the `SHOPIFY_DEBUG_RELEASE` env var value as the debug build number.
/// Returns `null` when the env var is unset or empty. Errors when the env var
/// is set but isn't a non-negative integer. Callers append `~debug{N}` to the
/// changelog-derived version.
pub fn debug_release_n(env_value: ?[]const u8) !?u16 {
    return numbered_release_suffix(env_value, error.InvalidDebugRelease);
}

fn numbered_release_suffix(env_value: ?[]const u8, parse_error: anyerror) !?u16 {
    const raw = env_value orelse return null;
    if (raw.len == 0) return null;
    return std.fmt.parseUnsigned(u16, raw, 10) catch parse_error;
}

pub const ForkReleaseTag = struct { base: []const u8, n: u16 };

/// Parses a canonical `X.Y.Z-shopifyN` tag string. Returns `null` for anything
/// else — ad-hoc suffixes (rc/snapshot), bare `X.Y.Z`, malformed components.
/// `base` is borrowed from `tag`.
pub fn parse_fork_release_tag(tag: []const u8) ?ForkReleaseTag {
    const sep = std.mem.indexOf(u8, tag, "-shopify") orelse return null;
    const base = tag[0..sep];
    const n_str = tag[sep + "-shopify".len ..];
    const n = std.fmt.parseUnsigned(u16, n_str, 10) catch return null;

    var parts = std.mem.splitScalar(u8, base, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 3) return null;
        _ = std.fmt.parseUnsigned(u32, part, 10) catch return null;
    }
    if (count != 3) return null;
    return .{ .base = base, .n = n };
}

/// Returns true iff `tag` is a canonical fork release tag — `X.Y.Z-shopifyN`.
pub fn is_fork_release_tag(tag: []const u8) bool {
    return parse_fork_release_tag(tag) != null;
}

/// Percent-encode `input` for use in a URL query parameter value, leaving
/// only the unreserved set per RFC 3986 untouched.
pub fn query_percent_encode(writer: anytype, input: []const u8) !void {
    try std.Uri.Component.percentEncode(writer, input, is_query_unreserved);
}

fn is_query_unreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

test prerelease_rc_n {
    try std.testing.expectEqual(@as(?u16, null), try prerelease_rc_n(null));
    try std.testing.expectEqual(@as(?u16, null), try prerelease_rc_n(""));
    try std.testing.expectEqual(@as(?u16, 1), (try prerelease_rc_n("1")).?);
    try std.testing.expectEqual(@as(?u16, 42), (try prerelease_rc_n("42")).?);
    try std.testing.expectEqual(@as(?u16, 0), (try prerelease_rc_n("0")).?);
    try std.testing.expectError(error.InvalidPrerelease, prerelease_rc_n("rc1"));
    try std.testing.expectError(error.InvalidPrerelease, prerelease_rc_n("1.2"));
    try std.testing.expectError(error.InvalidPrerelease, prerelease_rc_n("-1"));
    try std.testing.expectError(error.InvalidPrerelease, prerelease_rc_n("abc"));
}

test is_fork_release_tag {
    try std.testing.expect(is_fork_release_tag("0.17.1-shopify1"));
    try std.testing.expect(is_fork_release_tag("0.16.78-shopify42"));
    try std.testing.expect(is_fork_release_tag("10.20.30-shopify0"));

    try std.testing.expect(!is_fork_release_tag(""));
    try std.testing.expect(!is_fork_release_tag("0.17.1"));
    try std.testing.expect(!is_fork_release_tag("0.17.1-shopify"));
    try std.testing.expect(!is_fork_release_tag("0.17.1-shopify1-rc1"));
    try std.testing.expect(!is_fork_release_tag("0.17.1-shopifyN"));
    try std.testing.expect(!is_fork_release_tag("0.17-shopify1"));
    try std.testing.expect(!is_fork_release_tag("0.17.1.2-shopify1"));
    try std.testing.expect(!is_fork_release_tag("v0.17.1-shopify1"));
    try std.testing.expect(!is_fork_release_tag("0.17.x-shopify1"));
    try std.testing.expect(!is_fork_release_tag("-shopify1"));
}

test read_yes {
    var empty = std.io.fixedBufferStream("");
    try std.testing.expect(try read_yes(std.testing.allocator, empty.reader()));

    var default_yes = std.io.fixedBufferStream("\n");
    try std.testing.expect(try read_yes(std.testing.allocator, default_yes.reader()));

    var explicit_yes = std.io.fixedBufferStream("Y\n");
    try std.testing.expect(try read_yes(std.testing.allocator, explicit_yes.reader()));

    var explicit_lower_yes = std.io.fixedBufferStream("y\n");
    try std.testing.expect(try read_yes(std.testing.allocator, explicit_lower_yes.reader()));

    var no = std.io.fixedBufferStream("n\n");
    try std.testing.expect(!try read_yes(std.testing.allocator, no.reader()));
}

test truthy {
    try std.testing.expect(truthy("1"));
    try std.testing.expect(truthy("true"));
    try std.testing.expect(truthy("True"));
    try std.testing.expect(truthy("TRUE"));
    try std.testing.expect(truthy("yes"));
    try std.testing.expect(truthy("YES"));
    try std.testing.expect(!truthy("0"));
    try std.testing.expect(!truthy("false"));
    try std.testing.expect(!truthy("no"));
    try std.testing.expect(!truthy(""));
    try std.testing.expect(!truthy(null));
}

test query_percent_encode {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try query_percent_encode(buf.writer(), "Release 0.16.78-shopify4");
    try std.testing.expectEqualStrings("Release%200.16.78-shopify4", buf.items);

    buf.clearRetainingCapacity();
    try query_percent_encode(buf.writer(), "### Patches\n\n- a change");
    try std.testing.expectEqualStrings("%23%23%23%20Patches%0A%0A-%20a%20change", buf.items);
}
