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
