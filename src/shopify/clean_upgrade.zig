//! Runtime lever for the clean-upgrade startup fast paths.
//!
//! The fork normally sets `SuperBlockHeader.flag_clean_upgrade_next_recovery` in the trigger
//! checkpoint written immediately before exec'ing into a new release, so the new binary can take
//! clean-upgrade startup fast paths such as fast WAL recovery (header ring only, ~500ms) instead of
//! full body validation (~seconds of unavailability).
//!
//! `TB_DISABLE_CLEAN_UPGRADE_FAST_PATHS=1` suppresses that flag write. Intended for the rare case
//! of upgrading to a binary that does not understand the flag (e.g. upstream TigerBeetle, which
//! asserts `superblock.flags == 0`).
//!
//! Read once at replica init; the static allocator forbids per-checkpoint allocation.

const std = @import("std");

pub const env_var = "TB_DISABLE_CLEAN_UPGRADE_FAST_PATHS";

pub fn enabled_from_env(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, env_var) catch return true;
    defer allocator.free(value);

    return enabled_from_value(value);
}

pub fn enabled_from_value(value: []const u8) bool {
    return !std.mem.eql(u8, value, "1");
}

test "enabled_from_value: '1' disables" {
    try std.testing.expectEqual(false, enabled_from_value("1"));
}

test "enabled_from_value: other values leave enabled" {
    try std.testing.expectEqual(true, enabled_from_value(""));
    try std.testing.expectEqual(true, enabled_from_value("0"));
    try std.testing.expectEqual(true, enabled_from_value("true"));
    try std.testing.expectEqual(true, enabled_from_value("11"));
    try std.testing.expectEqual(true, enabled_from_value(" 1"));
}
