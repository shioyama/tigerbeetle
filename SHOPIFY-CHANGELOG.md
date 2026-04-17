# Shopify Changelog

Changes made in this fork, organized by release.
Commit messages for Shopify patches are prefixed with `[shopify]`.

## TigerBeetle 0.16.78-shopify4

Released: 2026-04-17

### CI

- Check that the release date is present in the changelog entry
- Check that base version matches the latest upstream version

### Packaging

- Removed redundant `-Dgit-commit` from build commands (`build.zig` defaults
  to `git rev-parse HEAD`)
- Go client tarball now only includes `x86_64-linux` native lib and Go source
  files, saving ~21MB
- Added `shopify-release` script (`zig build scripts -- shopify-release`) that
  automates version detection, changelog update, branch creation, and PR opening.
  A Shopify Build step runs a dry-run release build on `release/*` branches.
- Fixed release script to strip `release/` prefix from branch name before
  changelog validation.

## TigerBeetle 0.16.78-shopify3

Released: 2026-04-15

### Packaging

- Publish pipeline now builds Go client and includes it in the Cloudsmith deb
  package under `/usr/share/tigerbeetle/go-client/`. Build steps for
  TigerBeetle, Go client, and tb-snapshot run in parallel.

- Fork convention checks (commit prefixes, changelog validation) moved from
  bash scripts to Zig tidy tests and `changelog.zig`. Release readiness check
  moved to `release.zig`.

- Renamed `PATCHES.md` to `SHOPIFY-CHANGELOG.md` with version-centric format
  matching upstream `CHANGELOG.md`.

## TigerBeetle 0.16.78-shopify2

Released: 2026-04-14

### Patches

- [shopify/shadow-cluster](https://github.com/shop/tigerbeetle/pull/17)

  Adds shadow mode for blue-green cluster management. A green cluster connects to a running blue
  cluster as standbys, syncing all committed prepares. Blue reserves shadow slots with
  `--shadower-count=N`; green connects with `--shadow=<blue addresses>`. The connection direction
  is reversed from standard standby mode (green initiates connections to blue, since blue doesn't
  know green's addresses upfront).

  Green runs the old version while shadowing (via multiversion exec) and upgrades at cutover.
  Includes integration tests for single-node and multi-replica shadow sync.

## TigerBeetle 0.16.77-shopify1

Released: 2026-03-21

### Patches

- [shopify/piecemeal-backfills](https://github.com/shopify-playground/tigerbeetle/pull/9)

  Enables piecemeal (non-monotonic) backfills into a live TigerBeetle cluster by relaxing the
  imported timestamp regression check. Non-pending, non-balancing imported transfers no longer
  require monotonically increasing timestamps. Pending imported transfers retain their checks
  (new error codes: `imported_pending_timestamp_must_not_regress`,
  `imported_pending_timestamp_must_postdate_debit_account`,
  `imported_pending_timestamp_must_postdate_credit_account`).

  Adds four new `TransferFlags` (`enable_history_debit`, `enable_history_credit`,
  `enable_balance_limit_debit`, `enable_balance_limit_credit`) that upgrade an account's flags
  as a side effect of posting a pending transfer, enabling live data migration for accounts.

  Includes backfill fuzzer (`src/backfill_fuzz.zig`), VOPR backfill workload
  (`src/testing/backfill_workload.zig`), and expanded state machine tests.

- [shopify/zero-downtime-upgrades](https://github.com/shopify-playground/tigerbeetle/pull/7)

  Implements a fast WAL recovery path (`recover_fast`) that skips WAL body integrity checks when
  a replica restarts as part of a version upgrade. On upgrade, the superblock sets
  `flag_wal_skip_next_open`; on the next open, the journal reads only WAL headers (256 KiB) rather
  than the full WAL body. Eliminates the WAL recovery I/O cost on upgrade restarts.

  `flag_wal_skip_next_open` uses bit 0 of the pre-existing `SuperBlockHeader.flags: u64` field
  (previously always zero). This does not change the on-disk format. If upstream TigerBeetle
  assigns meaning to this bit in the future, this patch will need to be updated -- though since
  the flag is only set and cleared during an upgrade transition, adapting to any upstream usage
  should be straightforward.

### Packaging

- shopify/release-x86-linux-only

  Minimal changes to the release script (`src/scripts/release.zig`) for Shopify Build. Upstream
  code is preserved wherever possible to minimize merge conflicts. Changes from upstream:

  - `build()` hardcodes active languages to zig + go via a local `LanguageSet`. Removes vortex
    driver build from the zig block.
  - `build_tigerbeetle()` builds only x86_64-linux (no debug variants, no other targets).
  - `build_go()` replaces `git ls-files` with `shell.find` directory walk.
  - `CLIArgs` adds required `--timestamp <unix_seconds>` (replaces `git_commit_timestamp`),
    removes `devhub` and `publish`.
  - All unused upstream functions (other language builds, all publish functions) are retained as
    dead code.
