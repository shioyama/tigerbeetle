//! Shadow-mode setup.
//!
//! In shadow mode, a replica connects to a running cluster as a standby to
//! sync its state. The wire identity is overridden to a standby index
//! (`replica_count + own_index`) while the superblock identity is preserved.
//! This module extracts the derivation logic that wires `--shadow` /
//! `--shadower-count` into the message bus and replica options, so
//! `command_start` doesn't carry fork-only setup inline.

const std = @import("std");
const assert = std.debug.assert;

const vsr = @import("vsr");
const constants = vsr.constants;

const Address = std.net.Address;

pub const Setup = struct {
    /// True when shadow mode is enabled (`--shadow` was passed).
    is_shadower: bool,
    /// Addresses the bus connects out to. In shadow mode this is the
    /// shadowed cluster's addresses; otherwise the local `--addresses` values.
    addresses: []const Address,
    /// Total node count: `addresses.len + shadower_count`.
    node_count: u8,
    /// Inbound standby slots without outbound addresses.
    shadower_count: u8,
    /// Listen-address override; non-null only in shadow mode.
    listen_address: ?Address,
};

const SuperBlockInfo = struct {
    member_index: u8,
    replica_count: u8,
};

pub fn setup(
    gpa: std.mem.Allocator,
    own_addresses: []const Address,
    shadow_addresses: ?[]const Address,
    shadower_count: u8,
    storage_fd: std.posix.fd_t,
) Setup {
    const info: ?SuperBlockInfo = if (shadow_addresses != null)
        read_superblock_info(gpa, storage_fd)
    else
        null;
    return decide(own_addresses, shadow_addresses, shadower_count, info);
}

fn decide(
    own_addresses: []const Address,
    shadow_addresses: ?[]const Address,
    shadower_count: u8,
    info: ?SuperBlockInfo,
) Setup {
    if (shadow_addresses) |shadow| {
        const sb = info.?;
        const slot_count: u8 = @intCast(shadow.len);
        if (slot_count != sb.replica_count) {
            vsr.fatal(
                .cli,
                "--shadow: address count ({}) must equal local datafile " ++
                    "replica_count ({})",
                .{ slot_count, sb.replica_count },
            );
        }
        if (sb.member_index >= own_addresses.len) {
            vsr.fatal(
                .cli,
                "--shadow: --addresses count ({}) is too small for local " ++
                    "datafile member index ({})",
                .{ own_addresses.len, sb.member_index },
            );
        }
        return .{
            .is_shadower = true,
            .addresses = shadow,
            .node_count = @intCast(shadow.len + slot_count),
            .shadower_count = slot_count,
            .listen_address = own_addresses[sb.member_index],
        };
    }
    return .{
        .is_shadower = false,
        .addresses = own_addresses,
        .node_count = @intCast(own_addresses.len + shadower_count),
        .shadower_count = shadower_count,
        .listen_address = null,
    };
}

/// Read every superblock copy from disk and pick the working header via the
/// upstream quorum logic (`Quorums.working(.open)`), then return this replica's
/// member index and the cluster's replica_count. Mirrors what
/// `src/vsr/superblock.zig` does on the open path. We can't reuse the
/// `SuperBlock` type itself because it's coupled to an async `Storage`
/// instance that the caller hasn't wired into the IO loop yet.
fn read_superblock_info(gpa: std.mem.Allocator, storage_fd: std.posix.fd_t) SuperBlockInfo {
    const SuperBlockHeader = vsr.superblock.SuperBlockHeader;

    const headers = gpa.alignedAlloc(
        SuperBlockHeader,
        constants.sector_size,
        constants.superblock_copies,
    ) catch |err| vsr.fatal(
        .cli,
        "shadow: failed to allocate superblock buffer: {s}",
        .{@errorName(err)},
    );
    defer gpa.free(headers);

    for (headers, 0..) |*header, copy| {
        const buf = std.mem.asBytes(header);
        const offset = vsr.superblock.superblock_copy_size * @as(u64, copy);
        var read_so_far: usize = 0;
        while (read_so_far < buf.len) {
            const n = std.posix.pread(
                storage_fd,
                buf[read_so_far..],
                offset + read_so_far,
            ) catch |err| vsr.fatal(
                .cli,
                "shadow: failed to read superblock copy {}: {s}",
                .{ copy, @errorName(err) },
            );
            if (n == 0) vsr.fatal(
                .cli,
                "shadow: short read on superblock copy {}",
                .{copy},
            );
            read_so_far += n;
        }
    }

    var quorums: vsr.superblock.Quorums = .{};
    const quorum = quorums.working(headers, .open) catch |err| vsr.fatal(
        .cli,
        "shadow: superblock quorum read failed: {s}",
        .{@errorName(err)},
    );

    const member_index = vsr.member_index(
        &quorum.header.vsr_state.members,
        quorum.header.vsr_state.replica_id,
    ) orelse vsr.fatal(
        .cli,
        "shadow: own replica_id not found in superblock members",
        .{},
    );

    return .{
        .member_index = member_index,
        .replica_count = quorum.header.vsr_state.replica_count,
    };
}

test "shadow decide: --shadow" {
    const own = try parse_addresses_test(1, "127.0.0.1:7000");
    const shadow = try parse_addresses_test(1, "127.0.0.1:8000");
    const out = decide(&own, &shadow, 0, .{
        .member_index = 0,
        .replica_count = 1,
    });
    try std.testing.expectEqual(true, out.is_shadower);
    try std.testing.expectEqual(@as(u8, 2), out.node_count);
    try std.testing.expectEqual(@as(u8, 1), out.shadower_count);
    try std.testing.expect(out.listen_address != null);
    try std.testing.expectEqual(shadow[0].in.sa.port, out.addresses[0].in.sa.port);
}

test "shadow decide: no --shadow ignores superblock" {
    const own = try parse_addresses_test(1, "127.0.0.1:7000");
    const out = decide(&own, null, 2, null);
    try std.testing.expectEqual(false, out.is_shadower);
    try std.testing.expectEqual(@as(u8, 3), out.node_count);
    try std.testing.expectEqual(@as(u8, 2), out.shadower_count);
    try std.testing.expect(out.listen_address == null);
}

fn parse_addresses_test(comptime count: usize, raw: []const u8) ![count]Address {
    var buf: [count]Address = undefined;
    const parsed = try vsr.parse_addresses(raw, &buf);
    assert(parsed.len == count);
    return buf;
}
