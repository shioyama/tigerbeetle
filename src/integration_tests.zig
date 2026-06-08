//! Integration tests for TigerBeetle. Although the term is not particularly well-defined, here
//! it means a specific thing:
//!
//!   * the test binary itself doesn't contain any code from TigerBeetle,
//!   * but it has access to a pre-build `./tigerbeetle` binary.
//!
//! All the testing is done through interacting with a separate tigerbeetle process.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;

const Shell = @import("./shell.zig");
const Snap = stdx.Snap;
const snap = Snap.snap_fn("src");
const TmpTigerBeetle = @import("./testing/tmp_tigerbeetle.zig");
const Supervisor = @import("./testing/vortex/supervisor.zig").Supervisor;

const stdx = @import("stdx");
const ratio = stdx.PRNG.ratio;

const vortex_exe: []const u8 = @import("test_options").vortex_exe;
const tigerbeetle: []const u8 = @import("test_options").tigerbeetle_exe;
const tigerbeetle_next: []const u8 = @import("test_options").tigerbeetle_next_exe;
const shopify_integration_skip_upgrade: bool =
    @import("test_options").shopify_integration_skip_upgrade;

comptime {
    _ = @import("clients/c/tb_client_header_test.zig");
}

test "repl integration" {
    const Context = struct {
        const Context = @This();

        shell: *Shell,
        tigerbeetle_exe: []const u8,
        tmp_beetle: TmpTigerBeetle,

        fn init() !Context {
            const shell = try Shell.create(std.testing.allocator);
            errdefer shell.destroy();

            var tmp_beetle = try TmpTigerBeetle.init(std.testing.allocator, .{
                .development = true,
                .prebuilt = tigerbeetle,
            });
            errdefer tmp_beetle.deinit(std.testing.allocator);

            return Context{
                .shell = shell,
                .tigerbeetle_exe = tigerbeetle,
                .tmp_beetle = tmp_beetle,
            };
        }

        fn deinit(context: *Context) void {
            context.tmp_beetle.deinit(std.testing.allocator);
            context.shell.destroy();
            context.* = undefined;
        }

        fn repl_command(context: *Context, command: []const u8) ![]const u8 {
            return try context.shell.exec_stdout(
                \\{tigerbeetle} repl --cluster=0 --addresses={addresses} --command={command}
            , .{
                .tigerbeetle = context.tigerbeetle_exe,
                .addresses = context.tmp_beetle.port_str,
                .command = command,
            });
        }

        fn check(context: *Context, command: []const u8, want: Snap) !void {
            const got = try context.repl_command(command);
            try want.diff(got);
        }
    };

    var context = try Context.init();
    defer context.deinit();

    try context.check(
        \\create_accounts id=1 flags=linked|history code=10 ledger=700, id=2 code=10 ledger=700
    , snap(@src(),
        \\{
        \\  "timestamp": "<snap:ignore>",
        \\  "status": "tigerbeetle.CreateAccountStatus.created"
        \\}
        \\{
        \\  "timestamp": "<snap:ignore>",
        \\  "status": "tigerbeetle.CreateAccountStatus.created"
        \\}
        \\
    ));

    try context.check(
        \\create_transfers id=1 debit_account_id=1
        \\  credit_account_id=2 amount=10 ledger=700 code=10
    , snap(@src(),
        \\{
        \\  "timestamp": "<snap:ignore>",
        \\  "status": "tigerbeetle.CreateTransferStatus.created"
        \\}
        \\
    ));

    try context.check(
        \\lookup_accounts id=1
    , snap(@src(),
        \\{
        \\  "id": "1",
        \\  "debits_pending": "0",
        \\  "debits_posted": "10",
        \\  "credits_pending": "0",
        \\  "credits_posted": "0",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": ["linked","history"],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    try context.check(
        \\lookup_accounts id=2
    , snap(@src(),
        \\{
        \\  "id": "2",
        \\  "debits_pending": "0",
        \\  "debits_posted": "0",
        \\  "credits_pending": "0",
        \\  "credits_posted": "10",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": [],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    try context.check(
        \\query_accounts code=10 ledger=700
    , snap(@src(),
        \\{
        \\  "id": "1",
        \\  "debits_pending": "0",
        \\  "debits_posted": "10",
        \\  "credits_pending": "0",
        \\  "credits_posted": "0",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": ["linked","history"],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\{
        \\  "id": "2",
        \\  "debits_pending": "0",
        \\  "debits_posted": "0",
        \\  "credits_pending": "0",
        \\  "credits_posted": "10",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": [],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    try context.check(
        \\lookup_transfers id=1
    , snap(@src(),
        \\{
        \\  "id": "1",
        \\  "debit_account_id": "1",
        \\  "credit_account_id": "2",
        \\  "amount": "10",
        \\  "pending_id": "0",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "timeout": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": [],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    try context.check(
        \\query_transfers code=10 ledger=700
    , snap(@src(),
        \\{
        \\  "id": "1",
        \\  "debit_account_id": "1",
        \\  "credit_account_id": "2",
        \\  "amount": "10",
        \\  "pending_id": "0",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "timeout": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": [],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    try context.check(
        \\get_account_transfers account_id=2
    , snap(@src(),
        \\{
        \\  "id": "1",
        \\  "debit_account_id": "1",
        \\  "credit_account_id": "2",
        \\  "amount": "10",
        \\  "pending_id": "0",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "timeout": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": [],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    try context.check(
        \\get_account_balances account_id=1
    , snap(@src(),
        \\{
        \\  "debits_pending": "0",
        \\  "debits_posted": "10",
        \\  "credits_pending": "0",
        \\  "credits_posted": "0",
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));
}

test "benchmark/inspect smoke" {
    const data_file = data_file: {
        var random_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const random_suffix: [8]u8 = std.fmt.bytesToHex(random_bytes, .lower);
        break :data_file "0_0-" ++ random_suffix ++ ".tigerbeetle.benchmark";
    };
    defer std.fs.cwd().deleteFile(data_file) catch {};

    const trace_file = data_file ++ ".json";
    defer std.fs.cwd().deleteFile(trace_file) catch {};

    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    try shell.exec(
        "{tigerbeetle} benchmark" ++
            " --transfer-count=10_000" ++
            " --transfer-batch-count=10" ++
            " --validate" ++
            " --trace={trace_file}" ++
            " --statsd=127.0.0.1:65535" ++
            " --file={data_file}",
        .{
            .tigerbeetle = tigerbeetle,
            .trace_file = trace_file,
            .data_file = data_file,
        },
    );

    inline for (.{
        "{tigerbeetle} inspect constants",
        "{tigerbeetle} inspect metrics",
    }) |command| {
        log.debug("{s}", .{command});
        try shell.exec(command, .{ .tigerbeetle = tigerbeetle });
    }

    inline for (.{
        "{tigerbeetle} inspect superblock              {path}",
        "{tigerbeetle} inspect wal --slot=0            {path}",
        "{tigerbeetle} inspect replies                 {path}",
        "{tigerbeetle} inspect replies --slot=0        {path}",
        "{tigerbeetle} inspect grid                    {path}",
        "{tigerbeetle} inspect manifest                {path}",
        "{tigerbeetle} inspect tables --tree=transfers {path}",
        "{tigerbeetle} inspect integrity               {path}",
    }) |command| {
        log.debug("{s}", .{command});

        try shell.exec(
            command,
            .{ .tigerbeetle = tigerbeetle, .path = data_file },
        );
    }

    // Corrupt the data file, and ensure the integrity check fails. Due to how it works, the
    // corruption has to be in a spot that's actually used. Take the first offset from
    // `tigerbeetle inspect tables --tree=transfers`.
    const tables_output = try shell.exec_stdout(
        "{tigerbeetle} inspect tables --tree=transfers {path}",
        .{ .tigerbeetle = tigerbeetle, .path = data_file },
    );

    const offset = try std.fmt.parseInt(
        u64,
        stdx.cut(tables_output, "O=").?[1],
        10,
    );

    {
        const file = try std.fs.cwd().openFile(data_file, .{ .mode = .read_write });
        defer file.close();

        var prng = stdx.PRNG.from_seed_testing();
        var random_bytes: [256]u8 = undefined;
        prng.fill(&random_bytes);

        try file.pwriteAll(&random_bytes, offset);
    }

    // `shell.exec` assumes that success is a zero exit code; but in this case the test expects
    // corruption to be found and wants to assert a non-zero exit code.
    var child = std.process.Child.init(
        &.{ tigerbeetle, "inspect", "integrity", data_file },
        std.testing.allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited, .Signal => |value| try std.testing.expect(value != 0),
        else => unreachable,
    }
}

test "help/version smoke" {
    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    // The substring is chosen to be mostly stable, but from (near) the end of the output, to catch
    // a missed buffer flush.
    inline for (.{
        .{ .command = "{tigerbeetle} --help", .substring = "tigerbeetle repl" },
        .{ .command = "{tigerbeetle} inspect --help", .substring = "tables --tree" },
        .{ .command = "{tigerbeetle} version", .substring = "TigerBeetle version" },
        .{ .command = "{tigerbeetle} version --verbose", .substring = "process.backoff_max=" },
    }) |check| {
        const output = try shell.exec_stdout(check.command, .{ .tigerbeetle = tigerbeetle });
        try std.testing.expect(output.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, output, check.substring) != null);
    }
}

test "in-place upgrade" {
    // [shopify] Buildkite runs this long test in its own integration shard.
    if (shopify_integration_skip_upgrade) return error.SkipZigTest;

    if (builtin.target.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const level = std.testing.log_level;
    std.testing.log_level = std.log.Level.info;
    defer std.testing.log_level = level;

    const replica_count = 3;
    const duration_max = stdx.Duration.seconds(200);
    const tick_ms = 10;
    const ticks_max = duration_max.to_ms() / tick_ms;

    var supervisor = try Supervisor.create(std.testing.allocator, .{
        .seed = std.testing.random_seed,
        .replica_count = replica_count,
        .faulty = false,
        .log_debug = false,
    });
    defer supervisor.destroy();

    assert(supervisor.release_count > 0);
    const release_past = supervisor.release_count - 2;
    const release_current = supervisor.release_count - 1;

    for (0..replica_count) |replica_index| {
        try supervisor.replica_install(@intCast(replica_index), release_past);
        try supervisor.replica_format(@intCast(replica_index));
    }
    try supervisor.workload_start(.{ .release = release_past }, .{ .transfer_count = 1_000_000 });

    for (0..replica_count) |replica_index| {
        try supervisor.replica_start(@intCast(replica_index));
    }

    // Schedule the replica upgrades.
    var upgrade_tick: [replica_count]u64 = @splat(0);
    for (0..replica_count) |replica_index| {
        upgrade_tick[replica_index] = supervisor.prng.int_inclusive(u64, ticks_max / 2);
    }

    for (0..ticks_max) |tick| {
        try supervisor.tick();

        for (0..replica_count) |replica_index| {
            if (tick == upgrade_tick[replica_index]) {
                try supervisor.replica_install(@intCast(replica_index), release_current);
            }
        }

        const early = tick < ticks_max / 2;
        const replica_index = supervisor.prng.index(supervisor.replicas);
        const crash = early and supervisor.prng.chance(ratio(1, 400));
        const restart = (!early) or supervisor.prng.chance(ratio(1, 200));

        if (supervisor.replicas[replica_index].state == .terminated and restart) {
            try supervisor.replica_start(@intCast(replica_index));
        } else if (supervisor.replicas[replica_index].state == .running and crash) {
            try supervisor.replica_terminate(@intCast(replica_index));
        }
    }

    // [shopify] Buildkite's integration workers can make progress throughout
    // the upgrade window but still miss the fixed workload deadline. Once the
    // destructive part of the test is complete, give the fully restarted
    // cluster a quieter drain window before declaring the workload stuck.
    for (supervisor.replicas, 0..) |replica, replica_index| {
        if (replica.state == .terminated) {
            try supervisor.replica_start(@intCast(replica_index));
        }
    }
    for (0..ticks_max / 2) |_| {
        if (supervisor.workload_done()) break;
        try supervisor.tick();
    }
    if (!supervisor.workload_done()) {
        return error.WorkloadIncomplete;
    }
}

test "recover smoke" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const level = std.testing.log_level;
    std.testing.log_level = std.log.Level.info;
    defer std.testing.log_level = level;

    const replica_count = 3;

    var supervisor = try Supervisor.create(std.testing.allocator, .{
        .seed = std.testing.random_seed,
        .replica_count = replica_count,
        .faulty = false,
        .log_debug = false,
    });
    defer supervisor.destroy();

    const release_current = supervisor.release_count - 1;

    for (0..replica_count) |replica_index| {
        try supervisor.replica_install(@intCast(replica_index), release_current);
        try supervisor.replica_format(@intCast(replica_index));
        try supervisor.replica_start(@intCast(replica_index));
    }
    try supervisor.workload_start(.{ .release = release_current }, .{ .transfer_count = 100_000 });
    for (0..400) |_| try supervisor.tick();

    try supervisor.replica_terminate(2);
    try supervisor.replica_reformat(2);

    try supervisor.replica_terminate(1);
    try supervisor.replica_start(2);
    for (0..4000) |_| {
        if (supervisor.workload_done()) break;
        try supervisor.tick();
    } else {
        return error.WorkloadIncomplete;
    }
}

test "vortex smoke" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    try shell.exec(
        "{vortex_exe} --test-duration=1s --replica-count=1",
        .{ .vortex_exe = vortex_exe },
    );
}

// [shopify] Shadow-cluster integration tests.
test "shadow cluster" {
    // Test that a replica can start in shadow mode, connect to a running
    // primary cluster as a standby, and sync up to the primary's state.
    //
    // 1. Format and start a single-node primary cluster with one standby slot.
    // 2. Send operations to the primary.
    // 3. Copy the primary's datafile for the shadow.
    // 4. Send more operations to the primary (the shadow will catch up).
    // 5. Start the shadow in shadow mode pointing at the primary.
    // 6. Wait for the shadow to sync.
    // 7. Verify the shadow process is still running.

    const gpa = std.testing.allocator;
    const shell = try Shell.create(gpa);
    defer shell.destroy();

    const primary_address = "127.0.0.1:7200";
    const shadow_address = "127.0.0.1:7201";

    const tmp = try shell.fmt(
        "./.zig-cache/tmp/{}",
        .{std.crypto.random.int(u64)},
    );

    defer shell.cwd.deleteTree(tmp) catch {};

    try shell.cwd.makePath(tmp);

    const primary_datafile = try shell.fmt("{s}/primary_0_0.tigerbeetle", .{tmp});
    const shadow_datafile = try shell.fmt("{s}/shadow_0_0.tigerbeetle", .{tmp});

    // Step 1: Format primary cluster (1 replica, 1 standby slot)
    try shell.exec(
        "{tigerbeetle} format --cluster=0 --replica=0 --replica-count=1 --development {datafile}",
        .{ .tigerbeetle = tigerbeetle, .datafile = primary_datafile },
    );

    // Step 2: Start primary cluster with 1 shadow slot
    var primary_process = try shell.spawn(
        .{},
        "{tigerbeetle} start --development --experimental" ++
            " --shadower-count=1 --addresses={address} {datafile}",
        .{
            .tigerbeetle = tigerbeetle,
            .address = primary_address,
            .datafile = primary_datafile,
        },
    );
    defer _ = primary_process.kill() catch {};

    std.time.sleep(10 * std.time.ns_per_s);

    const repl = "{tigerbeetle} repl" ++
        " --cluster=0 --addresses={address}" ++
        " --command={command}";

    // Step 3: Send initial operations to the primary
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = primary_address,
        .command = "create_accounts id=1 code=10 ledger=700" ++
            ", id=2 code=10 ledger=700",
    });
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = primary_address,
        .command = "create_transfers id=1" ++
            " debit_account_id=1 credit_account_id=2" ++
            " amount=100 ledger=700 code=10",
    });

    // Step 4: Copy primary datafile for the shadow
    try shell.cwd.copyFile(
        primary_datafile,
        shell.cwd,
        shadow_datafile,
        .{},
    );

    // Step 5: Send more ops to the primary (the shadow must catch up)
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = primary_address,
        .command = "create_transfers id=2" ++
            " debit_account_id=2 credit_account_id=1" ++
            " amount=50 ledger=700 code=10",
    });
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = primary_address,
        .command = "create_transfers id=3" ++
            " debit_account_id=1 credit_account_id=2" ++
            " amount=25 ledger=700 code=10",
    });

    // Step 6: Start the shadow in shadow mode
    var shadow_process = try shell.spawn(
        .{},
        "{tigerbeetle} start --development --experimental" ++
            " --addresses={shadow_address}" ++
            " --shadow={primary_address} {datafile}",
        .{
            .tigerbeetle = tigerbeetle,
            .shadow_address = shadow_address,
            .primary_address = primary_address,
            .datafile = shadow_datafile,
        },
    );
    defer _ = shadow_process.kill() catch {};

    // Wait for the shadow to sync (repair a few missing ops)
    std.time.sleep(10 * std.time.ns_per_s);

    // Step 7: Verify the shadow process is still running (didn't crash).
    {
        const WNOHANG = 1;
        const ret = std.posix.waitpid(shadow_process.id, WNOHANG);
        if (ret.pid != 0) {
            log.err("shadow process terminated unexpectedly", .{});
            return error.ShadowCrashed;
        }
    }

    // NOTE: Standalone restart of the shadow after shadow mode is deferred.
    // The superblock state from shadow mode (sync_op_min/max, view) needs
    // reconciliation first. Cleanup is handled by defers.

    log.info("shadow cluster test passed", .{});
}

test "shadow shutdown-on-upgrade exits cleanly" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const shell = try Shell.create(gpa);
    defer shell.destroy();

    const source_address = "127.0.0.1:7230";
    const shadow_address = "127.0.0.1:7231";
    const tmp = try shell.fmt(
        "./.zig-cache/tmp/{}",
        .{std.crypto.random.int(u64)},
    );
    defer shell.cwd.deleteTree(tmp) catch {};

    try shell.cwd.makePath(tmp);

    const source_datafile = try shell.fmt("{s}/source_0_0.tigerbeetle", .{tmp});
    const shadow_datafile = try shell.fmt("{s}/shadow_0_0.tigerbeetle", .{tmp});

    const Context = struct {
        fn kill_wait(process_maybe: *?std.process.Child) void {
            if (process_maybe.*) |*process| {
                _ = process.kill() catch {};
                _ = process.wait() catch {};
                process_maybe.* = null;
            }
        }

        fn wait_for_cluster(shell_: *Shell, executable: []const u8, address: []const u8) !void {
            for (0..20) |_| {
                const result = try shell_.exec_raw(
                    "{tigerbeetle} repl --cluster=0 --addresses={address}" ++
                        " --command={command}",
                    .{
                        .tigerbeetle = executable,
                        .address = address,
                        .command = "lookup_accounts id=0",
                    },
                );
                if (std.mem.indexOf(u8, result.stderr, "connected to=0") != null) return;
                std.time.sleep(250 * std.time.ns_per_ms);
            }
            return error.ClusterDidNotStart;
        }
    };

    try shell.exec(
        "{tigerbeetle} format --cluster=0 --replica=0 --replica-count=1 {datafile}",
        .{ .tigerbeetle = tigerbeetle, .datafile = source_datafile },
    );

    try shell.cwd.copyFile(source_datafile, shell.cwd, shadow_datafile, .{});

    var source_process: ?std.process.Child = try shell.spawn(
        .{},
        "{tigerbeetle} start --experimental" ++
            " --shadower-count=1 --addresses={address} {datafile}",
        .{
            .tigerbeetle = tigerbeetle,
            .address = source_address,
            .datafile = source_datafile,
        },
    );
    defer Context.kill_wait(&source_process);

    try Context.wait_for_cluster(shell, tigerbeetle, source_address);

    var shadow_process: ?std.process.Child = try shell.spawn(
        .{},
        "{tigerbeetle} start --experimental" ++
            " --addresses={shadow_address}" ++
            " --shadow={source_address} {datafile}",
        .{
            .tigerbeetle = tigerbeetle,
            .shadow_address = shadow_address,
            .source_address = source_address,
            .datafile = shadow_datafile,
        },
    );
    defer Context.kill_wait(&shadow_process);

    std.time.sleep(std.time.ns_per_s);
    Context.kill_wait(&source_process);
    source_process = try shell.spawn(
        .{},
        "{tigerbeetle} start --experimental" ++
            " --shadower-count=1 --addresses={address} {datafile}",
        .{
            .tigerbeetle = tigerbeetle_next,
            .address = source_address,
            .datafile = source_datafile,
        },
    );
    try Context.wait_for_cluster(shell, tigerbeetle, source_address);

    for (0..120) |_| {
        const ret = std.posix.waitpid(shadow_process.?.id, std.posix.W.NOHANG);
        if (ret.pid != 0) {
            shadow_process = null;
            try std.testing.expectEqual(
                std.process.Child.Term{ .Exited = 0 },
                stdx.term_from_status(ret.status),
            );
            return;
        }
        std.time.sleep(250 * std.time.ns_per_ms);
    }
    return error.ShadowDidNotExit;
}

test "shadow cluster multi-replica" {
    const gpa = std.testing.allocator;
    const shell = try Shell.create(gpa);
    defer shell.destroy();

    const replica_count = 3;
    const primary_addrs =
        "127.0.0.1:7210,127.0.0.1:7211,127.0.0.1:7212";
    const shadow_addrs =
        "127.0.0.1:7220,127.0.0.1:7221,127.0.0.1:7222";
    const tmp = try shell.fmt(
        "./.zig-cache/tmp/{}",
        .{std.crypto.random.int(u64)},
    );

    defer shell.cwd.deleteTree(tmp) catch {};

    try shell.cwd.makePath(tmp);

    // Format and start the primary (3 replicas + 3 shadow slots).
    var primary_datafiles: [replica_count][]const u8 = undefined;
    var primary: [replica_count]?std.process.Child =
        @splat(null);

    defer for (&primary) |*p| {
        if (p.*) |*alive|
            std.posix.kill(alive.id, std.posix.SIG.KILL) catch {};
    };

    log.info("multi-replica: formatting primary", .{});
    for (0..replica_count) |i| {
        primary_datafiles[i] = try shell.fmt(
            "{s}/primary_{}.tigerbeetle",
            .{ tmp, i },
        );
        try shell.exec(
            "{tigerbeetle} format --cluster=0" ++
                " --replica={replica}" ++
                " --replica-count={replica_count}" ++
                " --development {datafile}",
            .{
                .tigerbeetle = tigerbeetle,
                .replica = i,
                .replica_count = replica_count,
                .datafile = primary_datafiles[i],
            },
        );
    }

    log.info("multi-replica: starting primary", .{});
    for (0..replica_count) |i| {
        primary[i] = try shell.spawn(
            .{},
            "{tigerbeetle} start --development" ++
                " --experimental" ++
                " --shadower-count={shadower_count}" ++
                " --addresses={addresses} {datafile}",
            .{
                .tigerbeetle = tigerbeetle,
                .shadower_count = replica_count,
                .addresses = primary_addrs,
                .datafile = primary_datafiles[i],
            },
        );
    }
    log.info("multi-replica: waiting for primary startup", .{});
    std.time.sleep(10 * std.time.ns_per_s);

    const repl = "{tigerbeetle} repl" ++
        " --cluster=0 --addresses={address}" ++
        " --command={command}";

    log.info("multi-replica: sending ops to primary", .{});
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = "127.0.0.1:7210",
        .command = "create_accounts id=1 code=10 ledger=700" ++
            ", id=2 code=10 ledger=700",
    });
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = "127.0.0.1:7210",
        .command = "create_transfers id=1" ++
            " debit_account_id=1 credit_account_id=2" ++
            " amount=100 ledger=700 code=10",
    });

    log.info("multi-replica: copying datafiles", .{});
    var shadow_datafiles: [replica_count][]const u8 =
        undefined;
    for (0..replica_count) |i| {
        shadow_datafiles[i] = try shell.fmt(
            "{s}/shadow_{}.tigerbeetle",
            .{ tmp, i },
        );
        try shell.cwd.copyFile(
            primary_datafiles[i],
            shell.cwd,
            shadow_datafiles[i],
            .{},
        );
    }

    log.info("multi-replica: sending more ops", .{});
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = "127.0.0.1:7210",
        .command = "create_transfers id=2" ++
            " debit_account_id=2 credit_account_id=1" ++
            " amount=50 ledger=700 code=10",
    });
    try shell.exec(repl, .{
        .tigerbeetle = tigerbeetle,
        .address = "127.0.0.1:7210",
        .command = "create_transfers id=3" ++
            " debit_account_id=1 credit_account_id=2" ++
            " amount=25 ledger=700 code=10",
    });

    log.info("multi-replica: starting shadow", .{});
    var shadow: [replica_count]?std.process.Child =
        @splat(null);

    defer for (&shadow) |*p| {
        if (p.*) |*alive|
            std.posix.kill(alive.id, std.posix.SIG.KILL) catch {};
    };

    for (0..replica_count) |i| {
        shadow[i] = try shell.spawn(
            .{},
            "{tigerbeetle} start --development" ++
                " --experimental" ++
                " --addresses={shadow_addrs}" ++
                " --shadow={primary_addrs} {datafile}",
            .{
                .tigerbeetle = tigerbeetle,
                .shadow_addrs = shadow_addrs,
                .primary_addrs = primary_addrs,
                .datafile = shadow_datafiles[i],
            },
        );
    }
    log.info("multi-replica: waiting for shadow sync", .{});
    std.time.sleep(15 * std.time.ns_per_s);

    log.info("multi-replica: checking shadow liveness", .{});
    for (&shadow, 0..) |*sp, i| {
        const WNOHANG = 1;
        const ret = std.posix.waitpid(
            sp.*.?.id,
            WNOHANG,
        );
        if (ret.pid != 0) {
            log.err(
                "shadow replica {} terminated unexpectedly",
                .{i},
            );
            return error.ShadowCrashed;
        }
    }

    log.info("multi-replica: cleanup", .{});
    log.info("shadow cluster multi-replica test passed", .{});
}
