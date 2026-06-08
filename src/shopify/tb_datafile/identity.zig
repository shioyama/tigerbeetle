//! Read and validate TigerBeetle datafile identity.

const std = @import("std");
const assert = std.debug.assert;

const vsr = @import("vsr");
const constants = vsr.constants;
const SuperBlockHeader = vsr.superblock.SuperBlockHeader;
const SuperBlockQuorums = vsr.superblock.Quorums;

pub const Identity = struct {
    cluster: u128,
    replica: u8,
    replica_count: u8,
    replica_id: u128,
    view: u32,
    log_view: u32,
    commit_max: u64,
    checkpoint_op: u64,
    release_format: vsr.Release,
    sequence: u64,
    flags: u64,
};

pub const Expected = struct {
    cluster: ?u128 = null,
    replica: ?u8 = null,
    replica_count: ?u8 = null,
    flags: ?u64 = null,
};

pub const Mismatch = union(enum) {
    cluster: struct { expected: u128, actual: u128 },
    replica: struct { expected: u8, actual: u8 },
    replica_count: struct { expected: u8, actual: u8 },
    flags: struct { expected: u64, actual: u64 },
};

pub fn read(path: []const u8) !Identity {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return read_from_fd(file.handle);
}

pub fn read_from_fd(fd: std.posix.fd_t) !Identity {
    var headers: [constants.superblock_copies]SuperBlockHeader align(constants.sector_size) =
        undefined;

    for (&headers, 0..) |*header, copy| {
        const buffer = std.mem.asBytes(header);
        const offset = vsr.superblock.superblock_copy_size * @as(u64, copy);
        var read_so_far: usize = 0;
        while (read_so_far < buffer.len) {
            const n = try std.posix.pread(fd, buffer[read_so_far..], offset + read_so_far);
            if (n == 0) return error.ShortRead;
            read_so_far += n;
        }
    }

    var quorums = SuperBlockQuorums{};
    const quorum = try quorums.working(&headers, .open);
    assert(quorum.valid);

    return identity_from_superblock(quorum.header.*);
}

pub fn identity_from_superblock(header: SuperBlockHeader) !Identity {
    if (header.version != vsr.superblock.SuperBlockVersion) {
        return error.IncompatibleSuperBlockVersion;
    }
    if (header.vsr_state.replica_id == 0) return error.InvalidReplicaId;
    if (!vsr.valid_members(&header.vsr_state.members)) return error.InvalidMembers;

    const replica = vsr.member_index(
        &header.vsr_state.members,
        header.vsr_state.replica_id,
    ) orelse return error.ReplicaIdNotFound;

    return .{
        .cluster = header.cluster,
        .replica = replica,
        .replica_count = header.vsr_state.replica_count,
        .replica_id = header.vsr_state.replica_id,
        .view = header.vsr_state.view,
        .log_view = header.vsr_state.log_view,
        .commit_max = header.vsr_state.commit_max,
        .checkpoint_op = header.vsr_state.checkpoint.header.op,
        .release_format = header.release_format,
        .sequence = header.sequence,
        .flags = header.flags,
    };
}

pub fn validate(identity: Identity, expected: Expected) ?Mismatch {
    if (expected.cluster) |cluster| {
        if (identity.cluster != cluster) {
            return .{ .cluster = .{ .expected = cluster, .actual = identity.cluster } };
        }
    }
    if (expected.replica) |replica| {
        if (identity.replica != replica) {
            return .{ .replica = .{ .expected = replica, .actual = identity.replica } };
        }
    }
    if (expected.replica_count) |replica_count| {
        if (identity.replica_count != replica_count) {
            return .{ .replica_count = .{
                .expected = replica_count,
                .actual = identity.replica_count,
            } };
        }
    }
    if (expected.flags) |flags| {
        if (identity.flags != flags) {
            return .{ .flags = .{ .expected = flags, .actual = identity.flags } };
        }
    }
    return null;
}

pub fn print_human(writer: anytype, identity: Identity) !void {
    try writer.print(
        "cluster={}\n" ++
            "replica={}\n" ++
            "replica_count={}\n" ++
            "replica_id={}\n" ++
            "view={}\n" ++
            "log_view={}\n" ++
            "commit_max={}\n" ++
            "checkpoint_op={}\n" ++
            "release_format={}\n" ++
            "sequence={}\n" ++
            "flags={}\n",
        .{
            identity.cluster,
            identity.replica,
            identity.replica_count,
            identity.replica_id,
            identity.view,
            identity.log_view,
            identity.commit_max,
            identity.checkpoint_op,
            identity.release_format,
            identity.sequence,
            identity.flags,
        },
    );
}

pub fn print_json(writer: anytype, identity: Identity) !void {
    try writer.print(
        "{{" ++
            "\"cluster\":{}," ++
            "\"replica\":{}," ++
            "\"replica_count\":{}," ++
            "\"replica_id\":{}," ++
            "\"view\":{}," ++
            "\"log_view\":{}," ++
            "\"commit_max\":{}," ++
            "\"checkpoint_op\":{}," ++
            "\"release_format\":\"{}\"," ++
            "\"sequence\":{}," ++
            "\"flags\":{}" ++
            "}}\n",
        .{
            identity.cluster,
            identity.replica,
            identity.replica_count,
            identity.replica_id,
            identity.view,
            identity.log_view,
            identity.commit_max,
            identity.checkpoint_op,
            identity.release_format,
            identity.sequence,
            identity.flags,
        },
    );
}

pub fn format_mismatch(writer: anytype, mismatch: Mismatch) !void {
    switch (mismatch) {
        .cluster => |value| try writer.print(
            "cluster mismatch: expected={}, actual={}\n",
            .{ value.expected, value.actual },
        ),
        .replica => |value| try writer.print(
            "replica mismatch: expected={}, actual={}\n",
            .{ value.expected, value.actual },
        ),
        .replica_count => |value| try writer.print(
            "replica_count mismatch: expected={}, actual={}\n",
            .{ value.expected, value.actual },
        ),
        .flags => |value| try writer.print(
            "flags mismatch: expected={}, actual={}\n",
            .{ value.expected, value.actual },
        ),
    }
}

fn make_superblock(cluster: u128, replica: u8, replica_count: u8) SuperBlockHeader {
    var header = std.mem.zeroes(SuperBlockHeader);
    const members = vsr.root_members(cluster);
    assert(replica < members.len);

    header.cluster = cluster;
    header.version = vsr.superblock.SuperBlockVersion;
    header.release_format = vsr.Release.minimum;
    header.sequence = 7;
    header.vsr_state.members = members;
    header.vsr_state.replica_id = members[replica];
    header.vsr_state.replica_count = replica_count;
    header.vsr_state.view = 2;
    header.vsr_state.log_view = 2;
    header.vsr_state.commit_max = 10;
    header.vsr_state.checkpoint.header.op = 8;
    header.flags = 0;
    return header;
}

test "identity from superblock" {
    const identity = try identity_from_superblock(make_superblock(123, 2, 6));

    try std.testing.expectEqual(@as(u128, 123), identity.cluster);
    try std.testing.expectEqual(@as(u8, 2), identity.replica);
    try std.testing.expectEqual(@as(u8, 6), identity.replica_count);
    try std.testing.expectEqual(@as(u32, 2), identity.view);
    try std.testing.expectEqual(@as(u64, 10), identity.commit_max);
    try std.testing.expectEqual(@as(u64, 8), identity.checkpoint_op);
    try std.testing.expectEqual(@as(u64, 0), identity.flags);
}

test "validate identity" {
    const actual = try identity_from_superblock(make_superblock(123, 2, 6));

    try std.testing.expectEqual(@as(?Mismatch, null), validate(actual, .{
        .cluster = 123,
        .replica = 2,
        .replica_count = 6,
        .flags = 0,
    }));

    const mismatch = validate(actual, .{ .replica = 3 }).?;
    try std.testing.expectEqual(@as(u8, 3), mismatch.replica.expected);
    try std.testing.expectEqual(@as(u8, 2), mismatch.replica.actual);

    var flagged = actual;
    flagged.flags = 1;
    const flags_mismatch = validate(flagged, .{ .flags = 0 }).?;
    try std.testing.expectEqual(@as(u64, 0), flags_mismatch.flags.expected);
    try std.testing.expectEqual(@as(u64, 1), flags_mismatch.flags.actual);
}

fn write_superblock_copies(file: std.fs.File, header_base: SuperBlockHeader) !void {
    var copy: u8 = 0;
    while (copy < constants.superblock_copies) : (copy += 1) {
        var header = header_base;
        header.copy = copy;
        const offset = vsr.superblock.superblock_copy_size * @as(u64, copy);
        try file.pwriteAll(std.mem.asBytes(&header), offset);
    }
}

test "read rejects incompatible superblock version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("datafile", .{ .read = true });
    defer file.close();

    var header = make_superblock(123, 2, 6);
    header.version = vsr.superblock.SuperBlockVersion + 1;
    header.checksum = header.calculate_checksum();
    try write_superblock_copies(file, header);

    try std.testing.expectError(error.IncompatibleSuperBlockVersion, read_from_fd(file.handle));
    const superblock_header = identity_from_superblock(header);
    try std.testing.expectError(error.IncompatibleSuperBlockVersion, superblock_header);
}

test "identity validates member fields before member_index" {
    var header = make_superblock(123, 2, 6);

    header.vsr_state.replica_id = 0;
    try std.testing.expectError(error.InvalidReplicaId, identity_from_superblock(header));

    header = make_superblock(123, 2, 6);
    header.vsr_state.members[0] = 0;
    try std.testing.expectError(error.InvalidMembers, identity_from_superblock(header));
}
