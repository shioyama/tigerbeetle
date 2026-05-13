//! Fork-specific extensions, parallel to upstream's `src/stdx/stdx.zig`.

const std = @import("std");

pub fn truthy(val: ?[]const u8) bool {
    const v = val orelse return false;
    if (std.mem.eql(u8, v, "1")) return true;
    if (std.ascii.eqlIgnoreCase(v, "true")) return true;
    if (std.ascii.eqlIgnoreCase(v, "yes")) return true;
    return false;
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
