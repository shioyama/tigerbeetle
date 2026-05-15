//! Fork-specific extensions, parallel to upstream's `src/stdx/stdx.zig`.

const std = @import("std");

pub fn truthy(val: ?[]const u8) bool {
    const v = val orelse return false;
    if (std.mem.eql(u8, v, "1")) return true;
    if (std.ascii.eqlIgnoreCase(v, "true")) return true;
    if (std.ascii.eqlIgnoreCase(v, "yes")) return true;
    return false;
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
