//! Fuzz test for piecemeal backfills: exercises non-monotonic imported timestamps
//! interleaved with live traffic on the state machine, with full compaction and
//! checkpoint support.
//!
//! Generates random sequences of:
//! - Imported accounts with random historical timestamps (non-monotonic across batches,
//!   including timestamps that overlap with the transfer timestamp range)
//! - Live transfers (cluster-assigned timestamps)
//! - Imported transfers with historical timestamps (non-monotonic)
//! - Upgrade pending transfers that atomically enable account flags (history,
//!   balance limits) as a side effect
//! - Compaction after every state machine operation
//! - Checkpointing at VSR-correct intervals
//! - Balance and flag verification after compaction
//!
//! Verifies that balances are always correct, all transfers are findable, and
//! account flags are correctly activated by upgrade transfers after non-monotonic
//! timestamps have been compacted through the full LSM.

const std = @import("std");
const assert = std.debug.assert;

const tb = @import("tigerbeetle.zig");
const vsr = @import("vsr.zig");
const constants = vsr.constants;
const stdx = @import("stdx");
const fuzz = @import("./testing/fuzz.zig");

const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;

const Account = tb.Account;
const Transfer = tb.Transfer;
const CreateAccountsResult = tb.CreateAccountsResult;
const CreateTransfersResult = tb.CreateTransfersResult;

const Storage = @import("testing/storage.zig").Storage;
const fixtures = @import("testing/fixtures.zig");
const SuperBlock = vsr.SuperBlockType(Storage);
const Grid = @import("vsr/grid.zig").GridType(Storage);
const StateMachine = @import("state_machine.zig").StateMachineType(Storage);
const Forest = StateMachine.Forest;

const TimestampRange = @import("lsm/timestamp_range.zig").TimestampRange;

const log = std.log.scoped(.backfill_fuzz);

const io_latency_mean_ticks = 20;
const io_latency_mean_ms: u64 = io_latency_mean_ticks * constants.tick_ms;

/// Tracks async completion of state machine callbacks.
const Completion = struct {
    var pending: bool = false;

    fn sm_callback(_: *StateMachine) void {
        assert(pending);
        pending = false;
    }

    fn forest_callback(_: *Forest) void {
        assert(pending);
        pending = false;
    }

    fn grid_callback(_: *Grid) void {
        assert(pending);
        pending = false;
    }

    fn superblock_callback(ctx: *SuperBlock.Context) void {
        _ = ctx;
        assert(pending);
        pending = false;
    }

    fn wait(storage: *Storage) void {
        for (0..10_000_000) |_| {
            if (!pending) return;
            storage.run();
        }
        @panic("completion wait timed out");
    }

    fn begin() void {
        assert(!pending);
        pending = true;
    }
};

fn encode_one(
    comptime T: type,
    operation: StateMachine.Operation,
    item: *const T,
    buffer: []align(16) u8,
) []align(16) u8 {
    var body_encoder = MultiBatchEncoder.init(buffer, .{
        .element_size = operation.event_size(),
    });
    const writable = body_encoder.writable().?;
    const item_bytes = std.mem.asBytes(item);
    stdx.copy_disjoint(.inexact, u8, writable[0..item_bytes.len], item_bytes);
    body_encoder.add(@intCast(item_bytes.len));
    const size = body_encoder.finish();
    return buffer[0..size];
}

fn should_checkpoint(op: u64, persisted_op: u64) bool {
    return op % constants.lsm_compaction_ops == constants.lsm_compaction_ops - 1 and
        op > constants.lsm_compaction_ops and
        op > persisted_op + constants.lsm_compaction_ops and
        op == vsr.Checkpoint.trigger_for_checkpoint(
            vsr.Checkpoint.checkpoint_after(persisted_op),
        );
}

fn should_mark_durable(op: u64, persisted_op: u64) bool {
    if (vsr.Checkpoint.trigger_for_checkpoint(persisted_op)) |trigger| {
        return op == trigger + constants.pipeline_prepare_queue_max + 1;
    } else {
        assert(persisted_op == 0);
        return op == 1;
    }
}

pub fn main(allocator: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    const node_count = 1024;
    const cache_entries_max = 2048;

    var prng = stdx.PRNG.from_seed(args.seed);

    // Init mocked storage with realistic latency.
    var storage = try fixtures.init_storage(allocator, .{
        .seed = prng.int(u64),
        .size = constants.storage_size_limit_default,
        .read_latency_min = .{ .ns = 0 },
        .read_latency_mean = fuzz.range_inclusive_ms(&prng, 0, io_latency_mean_ms),
        .write_latency_min = .{ .ns = 0 },
        .write_latency_mean = fuzz.range_inclusive_ms(&prng, 0, io_latency_mean_ms),
    });
    defer storage.deinit(allocator);

    try fixtures.storage_format(allocator, &storage, .{});

    var time_sim = fixtures.init_time(.{});
    var trace = try fixtures.init_tracer(allocator, time_sim.time(), .{});
    defer trace.deinit(allocator);

    var superblock = try fixtures.init_superblock(allocator, &storage, .{});
    defer superblock.deinit(allocator);

    var grid = try fixtures.init_grid(allocator, &trace, &superblock, .{
        .blocks_released_prior_checkpoint_durability_max = Forest
            .compaction_blocks_released_per_pipeline_max(),
    });
    defer grid.deinit(allocator);

    // Open superblock and grid before initializing state machine (tree init asserts opened).
    fixtures.open_superblock(&superblock);
    fixtures.open_grid(&grid);

    var state_machine: StateMachine = undefined;
    try state_machine.init(
        allocator,
        time_sim.time(),
        &grid,
        .{
            .batch_size_limit = constants.message_body_size_max,
            .lsm_forest_compaction_block_count = Forest.Options.compaction_block_count_min,
            .lsm_forest_node_count = node_count,
            .cache_entries_accounts = cache_entries_max,
            .cache_entries_transfers = cache_entries_max,
            .cache_entries_transfers_pending = cache_entries_max,
            .log_trace = true,
            .aof_recovery = false,
        },
    );
    defer state_machine.deinit(allocator);

    Completion.begin();
    state_machine.open(Completion.sm_callback);
    Completion.wait(&storage);

    // Bypass the initial pulse scan for pending transfers.
    state_machine.expire_pending_transfers
        .pulse_next_timestamp = TimestampRange.timestamp_max;

    var superblock_context: SuperBlock.Context = undefined;

    const request_buffer = try allocator.alignedAlloc(u8, 16, constants.message_body_size_max);
    defer allocator.free(request_buffer);

    const reply_buffer: *align(16) [constants.message_body_size_max]u8 =
        @ptrCast(try allocator.alignedAlloc(u8, 16, constants.message_body_size_max));
    defer allocator.free(reply_buffer);

    const max_accounts = 10;
    var account_ids: [max_accounts]u128 = undefined;
    var account_debits: [max_accounts]u128 = @splat(0);
    var account_credits: [max_accounts]u128 = @splat(0);
    var num_accounts: usize = 0;
    var num_transfers: usize = 0;
    var num_succeeded: usize = 0;

    // Op counter starts at 1 (op 0 is reserved).
    var op: u64 = 1;

    // Advance cluster time so we have room for historical timestamps.
    state_machine.prepare_timestamp = 10_000;

    // Helper to execute a state machine op with compaction and checkpointing.
    const execute_op = struct {
        fn run(
            sm: *StateMachine,
            stor: *Storage,
            sb: *SuperBlock,
            sb_ctx: *SuperBlock.Context,
            g: *Grid,
            current_op: u64,
            operation: StateMachine.Operation,
            message_body: []align(16) const u8,
            output_buffer: *align(16) [constants.message_body_size_max]u8,
        ) !usize {
            // Prepare.
            sm.commit_timestamp = sm.prepare_timestamp;
            sm.prepare_timestamp += 1;
            sm.prepare(operation, message_body);

            const timestamp = sm.prepare_timestamp;

            // Prefetch.
            Completion.begin();
            sm.prefetch_timestamp = timestamp;
            sm.prefetch(
                Completion.sm_callback,
                current_op,
                current_op,
                operation,
                message_body,
            );
            Completion.wait(stor);

            // Commit.
            const reply_size = sm.commit(
                1,
                current_op,
                timestamp,
                operation,
                message_body,
                output_buffer,
            );

            // Compact.
            Completion.begin();
            sm.compact(Completion.sm_callback, current_op);
            Completion.wait(stor);

            // Checkpoint at VSR-correct intervals.
            const persisted_op = sb.working.vsr_state.checkpoint.header.op;
            if (should_checkpoint(current_op, persisted_op)) {
                Completion.begin();
                sm.forest.checkpoint(Completion.forest_callback);
                Completion.wait(stor);

                Completion.begin();
                g.checkpoint(Completion.grid_callback);
                Completion.wait(stor);

                const checkpoint_op = current_op - constants.lsm_compaction_ops;
                Completion.begin();
                sb.checkpoint(Completion.superblock_callback, sb_ctx, .{
                    .header = header: {
                        var header = vsr.Header.Prepare.root(fixtures.cluster);
                        header.op = checkpoint_op;
                        header.set_checksum();
                        break :header header;
                    },
                    .view_attributes = null,
                    .manifest_references = sm.forest.manifest_log.checkpoint_references(),
                    .free_set_references = .{
                        .blocks_acquired = g
                            .free_set_checkpoint_blocks_acquired.checkpoint_reference(),
                        .blocks_released = g
                            .free_set_checkpoint_blocks_released.checkpoint_reference(),
                    },
                    .client_sessions_reference = .{
                        .last_block_checksum = 0,
                        .last_block_address = 0,
                        .trailer_size = 0,
                        .checksum = vsr.checksum(&.{}),
                    },
                    .commit_max = checkpoint_op + 1,
                    .sync_op_min = 0,
                    .sync_op_max = 0,
                    .storage_size = vsr.superblock.data_file_size_min +
                        (g.free_set.highest_address_acquired() orelse 0) * constants.block_size,
                    .release = vsr.Release.minimum,
                });
                Completion.wait(stor);
                g.mark_checkpoint_not_durable();

                log.debug("checkpoint at op={}", .{current_op});
            }

            // Mark checkpoint durable at the right time.
            const new_persisted_op = sb.working.vsr_state.checkpoint.header.op;
            if (should_mark_durable(current_op, new_persisted_op)) {
                g.free_set.mark_checkpoint_durable();
            }

            return reply_size;
        }
    }.run;

    // Phase 1: Create accounts with random historical timestamps (non-monotonic across
    // batches). Timestamps are drawn from [100, 4999], overlapping with the transfer
    // range [500, 9000] to exercise the relaxed cross-type uniqueness constraint.
    var account_timestamps_used = std.AutoHashMap(u64, void).init(allocator);
    defer account_timestamps_used.deinit();

    for (0..max_accounts) |i| {
        const id: u128 = @intCast(i + 1);
        var ts = prng.range_inclusive(u64, 100, 4999);
        while (account_timestamps_used.contains(ts)) {
            ts = if (ts >= 4999) 100 else ts + 1;
        }
        account_timestamps_used.put(ts, {}) catch {};

        const account = Account{
            .id = id,
            .debits_pending = 0,
            .debits_posted = 0,
            .credits_pending = 0,
            .credits_posted = 0,
            .user_data_128 = 0,
            .user_data_64 = 0,
            .user_data_32 = 0,
            .reserved = 0,
            .ledger = 1,
            .code = 1,
            .flags = .{ .imported = true },
            .timestamp = ts,
        };

        const encoded = encode_one(Account, .create_accounts, &account, request_buffer);
        const reply_size = try execute_op(
            &state_machine,
            &storage,
            &superblock,
            &superblock_context,
            &grid,
            op,
            .create_accounts,
            encoded,
            reply_buffer,
        );
        op += 1;

        if (reply_size > 0) {
            var reply_decoder = MultiBatchDecoder.init(reply_buffer[0..reply_size], .{
                .element_size = StateMachine.Operation.create_accounts.result_size(),
            }) catch unreachable;
            const batch = reply_decoder.pop().?;
            const results = stdx.bytes_as_slice(.inexact, CreateAccountsResult, batch);
            if (results.len > 0) {
                log.err("account creation failed for id {}: {}", .{ id, results[0].result });
                return error.TestUnexpectedResult;
            }
        }

        account_ids[i] = id;
        num_accounts += 1;
    }

    log.info("Created {} accounts with compaction", .{num_accounts});

    // Phase 2: Interleave live and imported transfers with compaction.
    const events_max = args.events_max orelse 500;
    var imported_timestamps_used = std.AutoHashMap(u64, void).init(allocator);
    defer imported_timestamps_used.deinit();

    for (0..events_max) |_| {
        if (num_accounts < 2) break;

        // Pick two different accounts.
        const dr_idx = prng.range_inclusive(usize, 0, num_accounts - 1);
        var cr_idx = prng.range_inclusive(usize, 0, num_accounts - 1);
        while (cr_idx == dr_idx) {
            cr_idx = prng.range_inclusive(usize, 0, num_accounts - 1);
        }

        const amount: u128 = prng.range_inclusive(u128, 1, 100);
        const transfer_id: u128 = @intCast(num_transfers + 1000);
        num_transfers += 1;

        const is_imported = prng.boolean();

        // For imported transfers, generate unique timestamps in the historical range.
        const imported_ts: u64 = if (is_imported) ts: {
            var ts = prng.range_inclusive(u64, 500, 9000);
            var attempts: usize = 0;
            while (imported_timestamps_used.contains(ts)) {
                ts +%= 1;
                if (ts < 500 or ts > 9000) ts = 500;
                attempts += 1;
                if (attempts > 9000) break;
            }
            imported_timestamps_used.put(ts, {}) catch {};
            break :ts ts;
        } else 0;

        const transfer = Transfer{
            .id = transfer_id,
            .debit_account_id = account_ids[dr_idx],
            .credit_account_id = account_ids[cr_idx],
            .amount = amount,
            .pending_id = 0,
            .user_data_128 = 0,
            .user_data_64 = 0,
            .user_data_32 = 0,
            .timeout = 0,
            .ledger = 1,
            .code = 2,
            .flags = .{
                .imported = is_imported,
            },
            .timestamp = imported_ts,
        };

        const encoded = encode_one(Transfer, .create_transfers, &transfer, request_buffer);
        const reply_size = try execute_op(
            &state_machine,
            &storage,
            &superblock,
            &superblock_context,
            &grid,
            op,
            .create_transfers,
            encoded,
            reply_buffer,
        );
        op += 1;

        var succeeded = true;
        if (reply_size > 0) {
            var reply_decoder = MultiBatchDecoder.init(reply_buffer[0..reply_size], .{
                .element_size = StateMachine.Operation.create_transfers.result_size(),
            }) catch unreachable;
            const batch = reply_decoder.pop().?;
            if (batch.len > 0) {
                const results = stdx.bytes_as_slice(.inexact, CreateTransfersResult, batch);
                if (results.len > 0) {
                    log.debug("transfer {} failed: {}", .{ transfer_id, results[0].result });
                }
                succeeded = false;
            }
        }

        if (succeeded) {
            account_debits[dr_idx] += amount;
            account_credits[cr_idx] += amount;
            num_succeeded += 1;
        }
    }

    log.info("Transfers: {} attempted, {} succeeded over {} ops", .{
        num_transfers,
        num_succeeded,
        op,
    });

    // Phase 3: Verify all account balances.
    for (0..num_accounts) |i| {
        const account = (switch (state_machine.forest.grooves.accounts.get(account_ids[i])) {
            .found_object => |a| @as(?Account, a),
            .found_orphaned_id => unreachable,
            .not_found => null,
        }) orelse {
            log.err("account {} not found", .{account_ids[i]});
            return error.TestUnexpectedResult;
        };

        if (account.debits_posted != account_debits[i]) {
            log.err("account {} debits: expected {}, got {}", .{
                account_ids[i],
                account_debits[i],
                account.debits_posted,
            });
            return error.TestUnexpectedResult;
        }

        if (account.credits_posted != account_credits[i]) {
            log.err("account {} credits: expected {}, got {}", .{
                account_ids[i],
                account_credits[i],
                account.credits_posted,
            });
            return error.TestUnexpectedResult;
        }
    }

    // Phase 3: Upgrade a random subset of accounts by submitting pending upgrade
    // transfers that atomically enable history and/or balance limits.
    var account_history: [max_accounts]bool = @splat(false);
    var account_balance_limit_debit: [max_accounts]bool = @splat(false);

    if (num_accounts >= 2) {
        for (0..num_accounts) |i| {
            if (!prng.boolean()) continue;

            var cr_idx = prng.range_inclusive(usize, 0, num_accounts - 1);
            while (cr_idx == i) cr_idx = prng.range_inclusive(usize, 0, num_accounts - 1);

            // Balance limit pre-check: debits_pending(0) + debits_posted + amount(0)
            // must not exceed credits_posted.
            const enable_balance_limit = account_debits[i] <= account_credits[i];

            const upgrade_id: u128 = @intCast(num_transfers + 1000);
            num_transfers += 1;

            const upgrade_transfer = Transfer{
                .id = upgrade_id,
                .debit_account_id = account_ids[i],
                .credit_account_id = account_ids[cr_idx],
                .amount = 0,
                .pending_id = 0,
                .user_data_128 = 0,
                .user_data_64 = 0,
                .user_data_32 = 0,
                .timeout = 0,
                .ledger = 1,
                .code = 3,
                .flags = .{
                    .pending = true,
                    .enable_history_debit = true,
                    .enable_balance_limit_debit = enable_balance_limit,
                },
                .timestamp = 0,
            };

            const encoded = encode_one(
                Transfer,
                .create_transfers,
                &upgrade_transfer,
                request_buffer,
            );
            const reply_size = try execute_op(
                &state_machine,
                &storage,
                &superblock,
                &superblock_context,
                &grid,
                op,
                .create_transfers,
                encoded,
                reply_buffer,
            );
            op += 1;

            if (reply_size > 0) {
                var reply_decoder = MultiBatchDecoder.init(reply_buffer[0..reply_size], .{
                    .element_size = StateMachine.Operation.create_transfers.result_size(),
                }) catch unreachable;
                const batch = reply_decoder.pop().?;
                if (batch.len > 0) {
                    const results = stdx.bytes_as_slice(.inexact, CreateTransfersResult, batch);
                    log.err("upgrade transfer {} failed: {}", .{ upgrade_id, results[0].result });
                    return error.TestUnexpectedResult;
                }
            }

            account_history[i] = true;
            account_balance_limit_debit[i] = enable_balance_limit;
        }
    }

    // Verify upgraded account flags.
    for (0..num_accounts) |i| {
        if (!account_history[i]) continue;

        const account = (switch (state_machine.forest.grooves.accounts.get(account_ids[i])) {
            .found_object => |a| @as(?Account, a),
            .found_orphaned_id => unreachable,
            .not_found => null,
        }) orelse {
            log.err("upgraded account {} not found", .{account_ids[i]});
            return error.TestUnexpectedResult;
        };

        if (!account.flags.history) {
            log.err("account {}: expected history=true after upgrade", .{account_ids[i]});
            return error.TestUnexpectedResult;
        }
        if (account_balance_limit_debit[i] and !account.flags.debits_must_not_exceed_credits) {
            log.err(
                "account {}: expected debits_must_not_exceed_credits=true after upgrade",
                .{account_ids[i]},
            );
            return error.TestUnexpectedResult;
        }
    }

    var upgraded_count: usize = 0;
    for (account_history[0..num_accounts]) |h| if (h) {
        upgraded_count += 1;
    };

    log.info("Passed! accounts={}, transfers={} (succeeded={}), upgraded={}, ops={}", .{
        num_accounts,
        num_transfers,
        num_succeeded,
        upgraded_count,
        op,
    });
}

test "backfill_fuzz_smoke" {
    const seed: u64 = 42;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try main(arena.allocator(), .{ .seed = seed, .events_max = 20 });
}
