# Shopify Patches

This file inventories all active Shopify patches carried in this fork.
Each entry records the patch name, the branch it lives on, the source PR, and its status.

Commit messages for Shopify patches are prefixed with `[shopify]`.
Use `git log --grep='\[shopify\]'` to list all patch commits.

## shopify/piecemeal-backfills

**Source:** shopify-playground/tigerbeetle#9
**Status:** active

Enables piecemeal (non-monotonic) backfills into a live TigerBeetle cluster by relaxing the imported timestamp regression check. Non-pending, non-balancing imported transfers no longer require monotonically increasing timestamps. Pending imported transfers retain their checks (new error codes: `imported_pending_timestamp_must_not_regress`, `imported_pending_timestamp_must_postdate_debit_account`, `imported_pending_timestamp_must_postdate_credit_account`).

Adds four new `TransferFlags` (`enable_history_debit`, `enable_history_credit`, `enable_balance_limit_debit`, `enable_balance_limit_credit`) that upgrade an account's flags as a side effect of posting a pending transfer, enabling live data migration for accounts.

Includes backfill fuzzer (`src/backfill_fuzz.zig`), VOPR backfill workload (`src/testing/backfill_workload.zig`), and expanded state machine tests.

## shopify/zero-downtime-upgrades

**Source:** shopify-playground/tigerbeetle#7
**Status:** active

Implements a fast WAL recovery path (`recover_fast`) that skips WAL body integrity checks when a replica restarts as part of a version upgrade. On upgrade, the superblock sets `flag_wal_skip_next_open`; on the next open, the journal reads only WAL headers (256 KiB) rather than the full WAL body. Eliminates the WAL recovery I/O cost on upgrade restarts.

`flag_wal_skip_next_open` uses bit 0 of the pre-existing `SuperBlockHeader.flags: u64` field (previously always zero). This does not change the on-disk format. If upstream TigerBeetle assigns meaning to this bit in the future, this patch will need to be updated — though since the flag is only set and cleared during an upgrade transition, adapting to any upstream usage should be straightforward.
