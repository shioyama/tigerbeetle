//! VOPR workload for testing piecemeal backfills.
//!
//! Creates accounts (live, cluster-assigned timestamps), then sends imported transfers
//! (historical timestamps using a monotonically increasing counter starting at 1).
//! Because the cluster watermark advances with each operation, imported transfer timestamps
//! quickly fall below the watermark — exactly the scenario our relaxed regression check enables.
//!
//! Verifies imported transfers via lookup_transfers to confirm they survive view changes
//! and state sync (the key properties that fuzz tests cannot exercise).
//!
//! Does not use the auditor: balance correctness during the backfill window is intentionally
//! unverified (historical balance snapshots are inaccurate by design). Validates only:
//! - create_accounts: ok or exists
//! - create_transfers: no unexpected failures (all imported transfers should commit)
//! - lookup_transfers: all confirmed transfers are found with correct fields
const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const tb = @import("../tigerbeetle.zig");
const vsr = @import("../vsr.zig");

const Account = tb.Account;
const Transfer = tb.Transfer;
const CreateAccountsResult = tb.CreateAccountsResult;
const CreateTransfersResult = tb.CreateTransfersResult;

const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;

const accounts_count: usize = 4;
const transfer_batch_max: usize = 8;
const lookup_batch_max: usize = 8;

/// Cap on confirmed transfers stored for lookup verification.
const confirmed_max: usize = 1024;

const ConfirmedTransfer = struct {
    id: u128,
    debit_account_id: u128,
    credit_account_id: u128,
    amount: u128,
};

pub fn WorkloadType(comptime StateMachine: type) type {
    return struct {
        const Workload = @This();

        const BuildResult = struct {
            operation: StateMachine.Operation,
            size: usize,
        };

        prng: *stdx.PRNG,
        options: Options,

        /// Account IDs for the fixed set of live accounts.
        account_ids: [accounts_count]u128,
        /// True once create_accounts has been sent at least once.
        accounts_sent: bool = false,
        /// True once the create_accounts reply has been received.
        accounts_confirmed: bool = false,

        /// Monotonically increasing counter for imported transfer IDs.
        next_transfer_id: u128 = 1,
        /// Monotonically increasing counter for imported transfer timestamps.
        /// These start small and quickly fall below the growing cluster watermark,
        /// triggering the regression check that our patch removes.
        next_historical_ts: u64 = 1,

        /// Confirmed imports for lookup verification.
        confirmed: std.ArrayListUnmanaged(ConfirmedTransfer),

        /// Request/reply counters for done().
        requests_sent: usize = 0,
        replies_received: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            prng: *stdx.PRNG,
            options: Options,
        ) !Workload {
            var confirmed = std.ArrayListUnmanaged(ConfirmedTransfer){};
            errdefer confirmed.deinit(allocator);
            try confirmed.ensureTotalCapacity(allocator, confirmed_max);

            var account_ids: [accounts_count]u128 = undefined;
            for (&account_ids, 0..) |*id, i| {
                id.* = @intCast(i + 1);
            }

            return Workload{
                .prng = prng,
                .options = options,
                .account_ids = account_ids,
                .confirmed = confirmed,
            };
        }

        pub fn deinit(workload: *Workload, allocator: std.mem.Allocator) void {
            workload.confirmed.deinit(allocator);
        }

        pub fn done(workload: *const Workload) bool {
            return workload.requests_sent == workload.replies_received;
        }

        pub fn build_request(
            workload: *Workload,
            client_index: usize,
            body: []align(@alignOf(vsr.Header)) u8,
        ) BuildResult {
            _ = client_index;
            workload.requests_sent += 1;

            if (!workload.accounts_sent) {
                workload.accounts_sent = true;
                return workload.build_create_accounts(body);
            }

            if (!workload.accounts_confirmed) {
                // Resend create_accounts until confirmed — idempotent, returns exists.
                return workload.build_create_accounts(body);
            }

            if (workload.confirmed.items.len > 0 and
                workload.prng.chance(stdx.PRNG.ratio(1, 3)))
            {
                return workload.build_lookup_transfers(body);
            }
            return workload.build_create_transfers(body);
        }

        pub fn on_reply(
            workload: *Workload,
            client_index: usize,
            operation: StateMachine.Operation,
            timestamp: u64,
            request_body: []align(@alignOf(vsr.Header)) const u8,
            reply_body: []align(@alignOf(vsr.Header)) const u8,
        ) void {
            _ = client_index;
            _ = timestamp;

            workload.replies_received += 1;
            assert(workload.replies_received <= workload.requests_sent);

            switch (operation) {
                .create_accounts => workload.on_create_accounts(reply_body),
                .create_transfers => workload.on_create_transfers(request_body, reply_body),
                .lookup_transfers => workload.on_lookup_transfers(request_body, reply_body),
                else => {},
            }
        }

        pub fn on_pulse(
            workload: *Workload,
            operation: StateMachine.Operation,
            timestamp: u64,
        ) void {
            _ = workload;
            _ = operation;
            _ = timestamp;
        }

        fn build_create_accounts(
            workload: *Workload,
            body: []align(@alignOf(vsr.Header)) u8,
        ) BuildResult {
            const operation = StateMachine.Operation.create_accounts;
            var encoder = MultiBatchEncoder.init(
                body[0..workload.options.batch_size_limit],
                .{ .element_size = @sizeOf(Account) },
            );
            const writable = encoder.writable().?;
            assert(writable.len >= accounts_count * @sizeOf(Account));
            const accounts = stdx.bytes_as_slice(.inexact, Account, writable);
            for (0..accounts_count) |i| {
                accounts[i] = .{
                    .id = workload.account_ids[i],
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
                    .flags = .{},
                    .timestamp = 0,
                };
            }
            encoder.add(@intCast(accounts_count * @sizeOf(Account)));
            return .{ .operation = operation, .size = encoder.finish() };
        }

        fn build_create_transfers(
            workload: *Workload,
            body: []align(@alignOf(vsr.Header)) u8,
        ) BuildResult {
            const operation = StateMachine.Operation.create_transfers;
            const count = workload.prng.int_inclusive(usize, transfer_batch_max - 1) + 1;
            var encoder = MultiBatchEncoder.init(
                body[0..workload.options.batch_size_limit],
                .{ .element_size = @sizeOf(Transfer) },
            );
            const writable = encoder.writable().?;
            assert(writable.len >= count * @sizeOf(Transfer));
            const transfers = stdx.bytes_as_slice(.inexact, Transfer, writable);
            for (0..count) |i| {
                const dr_idx = workload.prng.int_inclusive(usize, accounts_count - 1);
                var cr_idx = workload.prng.int_inclusive(usize, accounts_count - 1);
                while (cr_idx == dr_idx) {
                    cr_idx = workload.prng.int_inclusive(usize, accounts_count - 1);
                }
                transfers[i] = .{
                    .id = workload.next_transfer_id,
                    .debit_account_id = workload.account_ids[dr_idx],
                    .credit_account_id = workload.account_ids[cr_idx],
                    .amount = workload.prng.int_inclusive(u128, 99) + 1,
                    .pending_id = 0,
                    .user_data_128 = 0,
                    .user_data_64 = 0,
                    .user_data_32 = 0,
                    .timeout = 0,
                    .ledger = 1,
                    .code = 1,
                    .flags = .{ .imported = true },
                    .timestamp = workload.next_historical_ts,
                };
                workload.next_transfer_id += 1;
                workload.next_historical_ts += 1;
            }
            encoder.add(@intCast(count * @sizeOf(Transfer)));
            return .{ .operation = operation, .size = encoder.finish() };
        }

        fn build_lookup_transfers(
            workload: *Workload,
            body: []align(@alignOf(vsr.Header)) u8,
        ) BuildResult {
            const operation = StateMachine.Operation.lookup_transfers;
            const available = workload.confirmed.items.len;
            assert(available > 0);
            const max_count = @min(lookup_batch_max, available);
            const count = workload.prng.int_inclusive(usize, max_count - 1) + 1;
            const start = workload.prng.int_inclusive(usize, available - count);
            var encoder = MultiBatchEncoder.init(
                body[0..workload.options.batch_size_limit],
                .{ .element_size = @sizeOf(u128) },
            );
            const writable = encoder.writable().?;
            assert(writable.len >= count * @sizeOf(u128));
            const ids = stdx.bytes_as_slice(.inexact, u128, writable);
            for (0..count) |i| {
                ids[i] = workload.confirmed.items[start + i].id;
            }
            encoder.add(@intCast(count * @sizeOf(u128)));
            return .{ .operation = operation, .size = encoder.finish() };
        }

        fn on_create_accounts(
            workload: *Workload,
            reply_body: []align(@alignOf(vsr.Header)) const u8,
        ) void {
            workload.accounts_confirmed = true;
            var decoder = MultiBatchDecoder.init(
                reply_body,
                .{ .element_size = @sizeOf(CreateAccountsResult) },
            ) catch return;
            while (decoder.pop()) |batch| {
                const results = stdx.bytes_as_slice(.inexact, CreateAccountsResult, batch);
                for (results) |r| {
                    assert(r.result == .ok or r.result == .exists);
                }
            }
        }

        fn on_create_transfers(
            workload: *Workload,
            request_body: []align(@alignOf(vsr.Header)) const u8,
            reply_body: []align(@alignOf(vsr.Header)) const u8,
        ) void {
            var req_decoder = MultiBatchDecoder.init(
                request_body,
                .{ .element_size = @sizeOf(Transfer) },
            ) catch return;
            var rep_decoder = MultiBatchDecoder.init(
                reply_body,
                .{ .element_size = @sizeOf(CreateTransfersResult) },
            ) catch return;

            const req_batch = req_decoder.pop() orelse return;
            const rep_batch = rep_decoder.pop() orelse return;

            const batch_transfers = stdx.bytes_as_slice(.inexact, Transfer, req_batch);
            const failures = stdx.bytes_as_slice(.inexact, CreateTransfersResult, rep_batch);

            // Failures are reported by index within the batch. Any index not in failures succeeded.
            var fail_pos: usize = 0;
            for (batch_transfers, 0..) |t, i| {
                if (fail_pos < failures.len and failures[fail_pos].index == @as(u32, @intCast(i))) {
                    // Failed — our patch should never return the regression error for non-pending
                    // imports, but allow .exists for idempotent retries.
                    assert(failures[fail_pos].result == .exists);
                    fail_pos += 1;
                } else {
                    if (workload.confirmed.items.len < confirmed_max) {
                        workload.confirmed.appendAssumeCapacity(.{
                            .id = t.id,
                            .debit_account_id = t.debit_account_id,
                            .credit_account_id = t.credit_account_id,
                            .amount = t.amount,
                        });
                    }
                }
            }
        }

        fn on_lookup_transfers(
            workload: *Workload,
            request_body: []align(@alignOf(vsr.Header)) const u8,
            reply_body: []align(@alignOf(vsr.Header)) const u8,
        ) void {
            var req_decoder = MultiBatchDecoder.init(
                request_body,
                .{ .element_size = @sizeOf(u128) },
            ) catch return;
            var rep_decoder = MultiBatchDecoder.init(
                reply_body,
                .{ .element_size = @sizeOf(Transfer) },
            ) catch return;

            const req_batch = req_decoder.pop() orelse return;
            const rep_batch = rep_decoder.pop() orelse return;

            const ids = stdx.bytes_as_slice(.inexact, u128, req_batch);
            const found = stdx.bytes_as_slice(.inexact, Transfer, rep_batch);

            // All confirmed transfers we look up must be found.
            assert(found.len == ids.len);
            for (found, ids) |f, id| {
                var expected: ?ConfirmedTransfer = null;
                for (workload.confirmed.items) |c| {
                    if (c.id == id) {
                        expected = c;
                        break;
                    }
                }
                assert(expected != null);
                assert(f.id == expected.?.id);
                assert(f.amount == expected.?.amount);
                assert(f.debit_account_id == expected.?.debit_account_id);
                assert(f.credit_account_id == expected.?.credit_account_id);
            }
        }

        pub const Options = struct {
            batch_size_limit: u32,

            pub fn generate(
                prng: *stdx.PRNG,
                options: struct {
                    batch_size_limit: u32,
                    multi_batch_per_request_limit: u32,
                    client_count: usize,
                    in_flight_max: usize,
                },
            ) Options {
                _ = prng;
                return .{ .batch_size_limit = options.batch_size_limit };
            }
        };
    };
}
