# Shopify Changelog

Changes made in this fork, organized by release.
Commit messages for Shopify patches are prefixed with `[shopify]`.

## TigerBeetle (unreleased)

### Patches

- [#173](https://github.com/shop/tigerbeetle/pull/173)

  Shorten the initial clock synchronization window after clean upgrade restarts
  from two seconds to 500ms, gated by the existing clean-upgrade checkpoint flag.
  This targets the largest observed contributor to client-visible upgrade
  downtime while preserving the normal steady-state synchronization window.

- [#178](https://github.com/shop/tigerbeetle/pull/178)

  Use a dedicated 100ms clean-upgrade bootstrap ping timeout until the first
  clock epoch synchronizes, then return to the steady-state `ping_timeout`.
  This lets the reduced clean-upgrade synchronization window gate availability
  instead of waiting on the normal 1s ping cadence. Rename the override env var
  to `TB_DISABLE_CLEAN_UPGRADE_FAST_PATHS` to match the broader flag semantics.

### Fixes

- [#174](https://github.com/shop/tigerbeetle/pull/174)

  Update Shopify fork parsing helpers for upstream's `stdx.parse_int` API while
  keeping build-script-only code independent from runtime Zig modules.

### Tooling

- [#192](https://github.com/shop/tigerbeetle/pull/192)

  Prompt for explicit confirmation before creating a Shopify release branch from
  a non-`main` HEAD, making intentional branch-based releases clear while
  keeping the release preparation flow available outside `main`.

- [#187](https://github.com/shop/tigerbeetle/pull/187)

  Skip PR-branch commit-history tidy checks on `shopify/upstream-X.Y.Z`
  branches. Upstream imports can now include Shopify-authored upstream commits,
  so branch convention is a clearer upstream boundary than author email alone.

- [#173](https://github.com/shop/tigerbeetle/pull/173)

  Limit long-function tidy checks to fork-owned source so Shopify patches do not
  split upstream functions solely for fork hygiene.

## TigerBeetle 0.17.5-shopify1

Released: 2026-06-16

### Patches

- [#169](https://github.com/shop/tigerbeetle/pull/169)

  Allocate the grid cache backing blocks without Zig's eager undefined-memory
  fill. Large `--cache-grid` values previously touched the full cache during
  startup and re-exec, adding ~20s to upgrades with Shopify's production cache
  size; grid block validity is tracked separately by cache metadata and
  checksums.

### Fixes

- [#160](https://github.com/shop/tigerbeetle/pull/160)

  Update Shopify fork code to use `stdx.Shell` following upstream move.

## TigerBeetle 0.17.4-shopify1

Released: 2026-06-11

### Patches

- [#158](https://github.com/shop/tigerbeetle/pull/158)

  Stop shadow replicas as soon as they see source-cluster upgrade prepares, so
  rollback datafiles do not retain a replayable upgrade bar that would make a
  restarted shadow cluster try to execute the upgraded release. Add integration
  coverage for restarting shadow datafiles after source-cluster in-place upgrade.

- [#161](https://github.com/shop/tigerbeetle/pull/161)

  Skip repair writes for shadowed upgrade prepares that are already stale or
  known locally. Stale upgrade prepares should not spuriously stop a shadower,
  but `on_repair()` may persist prepares, and rollback shadowers must not retain
  source-cluster upgrade operations.

## TigerBeetle 0.17.3-shopify1

Released: 2026-06-09

### Patches

- [#97](https://github.com/shop/tigerbeetle/pull/97)

  Skip WAL integrity checks on upgrade when the prior binary performed a clean
  checkpoint. Gated by `SuperBlockHeader.flag_clean_upgrade_next_recovery` (bit 63),
  which the upgrading binary sets in its final checkpoint only when the local
  WAL has no dirty, faulty, or in-flight writes. The new binary clears the flag
  durably during startup recovery before returning to service. Cuts post-upgrade
  unavailability from several seconds to ~500ms. Set
  `TB_DISABLE_CLEAN_UPGRADE_FAST_PATHS=1` to suppress the flag write
  when upgrading to a binary that doesn't understand it (e.g. upstream, which
  asserts `flags == 0`).

- [#151](https://github.com/shop/tigerbeetle/pull/151)

  Reject duplicate replica addresses during address parsing. Tighten Shopify
  shadow topology validation by requiring shadow listen addresses to match the
  datafile replica count and to not overlap the source cluster addresses. Add
  explicit `--shadower-count` bounds checks so invalid standby-slot topology is
  rejected during CLI parsing.

### Tooling

- [#154](https://github.com/shop/tigerbeetle/pull/154)

  Split the Buildkite integration-test lane into parallel `upgrade` and
  `integration` CI modes. The upgrade shard runs the slow in-place upgrade test,
  while the integration shard runs the remaining integration tests through the
  existing stderr-filtered `zig build ci -- integration` wrapper.

- [#155](https://github.com/shop/tigerbeetle/pull/155)

  Teach `tidy shopify fork` to reject newly added `SHOPIFY-CHANGELOG.md`
  entries unless they are placed under the `(unreleased)` release header, while
  allowing release PRs to finalize that header without moving entries.

## TigerBeetle 0.17.2-shopify2

Released: 2026-06-08

### Tooling

- [#150](https://github.com/shop/tigerbeetle/pull/150)

  Add `tb-datafile`, a Shopify helper binary for inspecting and validating a
  datafile's superblock identity. The tool reports cluster, replica,
  replica-count, checkpoint, release, and flags fields, and can fail closed when
  expected values do not match. Wire `test:tb-snapshot` to build the
  `tb-snapshot` binary before running its tests, matching `test:tb-datafile`.

- [#147](https://github.com/shop/tigerbeetle/pull/147)

  Keep the split Buildkite unit-test step compatible with `tidy shopify fork` by
  running `zig build check` before `test:unit`, which populates the server
  closure manifest the versioning guard reads from `.zig-cache/h`. Stop wiring
  the tb-snapshot test artifact into `test:unit:build`; those tests still run
  through `test:tb-snapshot`.

## TigerBeetle 0.17.2-shopify1

Released: 2026-06-01

### Patches

- [#109](https://github.com/shop/tigerbeetle/pull/109)

  Shadower shutdown-on-upgrade. At an upgrade bar, a shadower no longer advances
  `checkpoint.release`; instead it shuts down after durably checkpointing the
  suppressed release advance, or before state-syncing to an upgraded checkpoint.
  Operators can then restart the datafile explicitly as its own rollback cluster
  if the upgrade needs to be rolled back.

### Tooling

- [#145](https://github.com/shop/tigerbeetle/pull/145),
  [#146](https://github.com/shop/tigerbeetle/pull/146)

  Route the Buildkite integration-test step through a dedicated
  `zig build ci -- integration` mode. The wrapper keeps verbose custom test
  runner progress visible while filtering expected Vortex and TigerBeetle child
  process stderr noise on successful runs; failures retain full stderr context.
  The integration upgrade/recover harness also gets a longer post-disruption
  drain/recover window so slower Buildkite workers do not fail while the
  cluster is still making progress.

- [#141](https://github.com/shop/tigerbeetle/pull/141)

  Add `SHOPIFY_DEBUG_RELEASE=N` support to the `tigerbeetle-publish-package`
  pipeline. Manual release-branch builds with the variable set now publish a
  `<version>~debugN` `.deb` containing the x86_64 Linux Debug-mode server
  binary, while keeping the binary's release stamp at the base fork version so
  it can be used for diagnostic repros without changing cluster version
  semantics.

- [#125](https://github.com/shop/tigerbeetle/pull/125)

  Swap in a custom `.mode = .simple` test runner (`src/shopify/test_runner.zig`)
  on every `zig build test` artifact (stdx, unit, integration, tb-snapshot) so
  the build system stops gluing test failures onto the per-step error format.
  Default output is one dot per pass with a break-out `name... FAIL` line on
  failure; `VERBOSE=1` switches to one line per test. Pass/skip/fail markers
  are colorized when stderr is a terminal; `COLOR=1` / `COLOR=0` overrides
  auto-detection.

- [#125](https://github.com/shop/tigerbeetle/pull/125)

  Add a `test:tb-snapshot` build step and split CI into three parallel
  Buildkite test steps. `./zig/zig build test:unit` no longer runs
  tb-snapshot; use `./zig/zig build test:tb-snapshot` (or `test` for
  everything).

- [#126](https://github.com/shop/tigerbeetle/pull/126)

  `upstream-merge` no longer errors on finalize when run from a linked
  worktree, where `.git` is a file and the state-file delete returns
  `NotDir` instead of `FileNotFound`.

- [#126](https://github.com/shop/tigerbeetle/pull/126)

  Honor upstream's `--no-changelog` flag for fork release builds: skip
  SHOPIFY-CHANGELOG.md validation and `.deb` artifact assembly. Lets the
  upstream-merge validation build pass before the fork changelog catches up.

- [#132](https://github.com/shop/tigerbeetle/pull/132),
  [#134](https://github.com/shop/tigerbeetle/pull/134)

  Append upstream `CHANGELOG.md` release notes to the `shopify-release` PR body
  when cutting `-shopify1` for a new upstream base. The notes use the same body
  text that `upstream-merge` pre-fills, separated from fork notes by a
  horizontal rule, and are omitted from later same-base fork releases.

- [#139](https://github.com/shop/tigerbeetle/pull/139)

  Handle upstream-only fork releases when `SHOPIFY-CHANGELOG.md` has no
  `(unreleased)` section. `shopify-release` now creates a date-only entry for
  the first `-shopify1` on a new upstream base, exits cleanly when the base
  already has a fork release, and validates the generated changelog before
  pushing.

## TigerBeetle 0.17.1-shopify2

Released: 2026-05-21

### Tooling

- [#105](https://github.com/shop/tigerbeetle/pull/105)

  Add `tidy shopify fork` Check 6: refuse Shopify-authored commits that touch
  files in the server binary's `@import` closure while the latest released fork
  triple still matches upstream's latest. The closure is unioned across every
  `.zig-cache/h/*.txt` manifest rooted at `src/tigerbeetle/main.zig`, so any
  file the server actually compiles in — including `src/clients/c/` — is
  caught, and pure fork tooling (anything not transitively imported from
  main.zig) passes. Catches the piggy-back rule that previously lived in
  reviewer attention. Bypass per-commit with `skip-versioning-check` for the
  hotfix path. Release PRs (`release/*` branches) are exempt.

- [#112](https://github.com/shop/tigerbeetle/pull/112)

  Dedup the fork-versions manifest, `release_history()`, and the `Bump
  fork-versions` workflow by `X.Y.Z` base — keep the latest `-shopifyN`
  per patch line. Same-base bumps share wire versions and can't occupy
  distinct vortex slots; bundling the highest `N` captures any hotfix
  that landed server code on `-shopifyN>1`.

- [#112](https://github.com/shop/tigerbeetle/pull/112),
  [#115](https://github.com/shop/tigerbeetle/pull/115)

  Add `SHOPIFY_PRERELEASE=N` for publishing prerelease builds. Manually
  triggering the publish pipeline with the env var builds
  `X.Y.Z-shopifyN~rcN` from the release PR's changelog; the `.deb` filename
  and `DEBIAN/control` Version carry `~rcN`, the binary stamp doesn't.
  Prereleases share the eventual final's version and must not mix in the
  same cluster. The publish step's `if:` regex is tightened so only
  canonical `X.Y.Z-shopifyN` tag pushes (or env-var builds) trigger it.

## TigerBeetle 0.17.1-shopify1

Released: 2026-05-19

### Patches

- [#74](https://github.com/shop/tigerbeetle/pull/74)

  Add `--shadow=<addresses>` and `--shadower-count=N` for cluster shadowing.
  A shadow replica connects to a running cluster as a standby to sync its
  state; the shadowed cluster reserves inbound standby slots without outbound
  addresses. Includes single-node and multi-replica integration tests.

### Fixes

- [#107](https://github.com/shop/tigerbeetle/pull/107)

  Port `tb-snapshot` to the new `stdx.Flags.parse` API (upstream renamed
  `stdx.flags(...)`). The install-only artifact slipped through `zig build test`
  in the 0.17.1 merge. Also run `Validate release build` on `shopify/upstream-*`
  branches so the next upstream merge catches similar regressions before main.

## TigerBeetle 0.17.0-shopify3

Released: 2026-05-18

### Tooling

- [#92](https://github.com/shop/tigerbeetle/pull/92)

  Rename the fork release subcommand from `shopify` to `shopify-release` for
  symmetry with `upstream-merge` and to make the verb explicit. Invoked via
  `zig build scripts -- shopify-release`.

- [#95](https://github.com/shop/tigerbeetle/pull/95)

  `upstream-merge` now opens the GitHub compare page in the browser (matching
  the `shopify-release` release script) instead of calling `gh pr create`,
  letting the author review and edit the PR before submitting.

- [#98](https://github.com/shop/tigerbeetle/pull/98),
  [#99](https://github.com/shop/tigerbeetle/pull/99)

  Auto-tag fork releases from two new GitHub Actions workflows. `auto-tag.yml`
  fires when a `release/X.Y.Z-shopifyN` PR merges into `main`; verifies the
  branch version matches the top `## TigerBeetle ...` header in
  `SHOPIFY-CHANGELOG.md`, pushes the tag, and creates a GitHub Release whose
  body is the matching changelog section. The tag push triggers the
  shopify-build publish pipeline in parallel. `bump-fork-versions.yml` chains
  off auto-tag's completion (via `workflow_run`, since GITHUB_TOKEN-driven
  tag pushes don't fire `push: tags`) and opens an `auto/bump-fork-versions-<version>`
  PR updating `.shopify-build/fork-versions.txt` so vortex's multi-version
  slots can include the new tag. Merging that PR is the human gate on
  "Cloudsmith publish succeeded" — tidy check 5 fails any other PR opened in
  the meantime, surfacing the signal. Lives in GH Actions rather than
  shopify-build because the latter is read-only on the repo.

## TigerBeetle 0.17.0-shopify2

Released: 2026-05-13

### CI

- [#88](https://github.com/shop/tigerbeetle/pull/88)

  Add `VALIDATE_RELEASE_BUILD` env var to force-run the `Validate release
  build` step outside `release/*` branches. When truthy (`1`, `true`, `yes`),
  the release script rewrites the `(unreleased)` header in
  `SHOPIFY-CHANGELOG.md` in place with the synthesized next version + today's
  date so the rest of the build exercises the real release path. The rewrite
  is workspace-only; nothing is committed.

### Tooling

- [#90](https://github.com/shop/tigerbeetle/pull/90)

  `extract_shopify_previous_version` now walks past prior fork entries whose
  upstream triple matches the top entry's, so a `0.17.0-shopifyN+1` release
  falls through to the upstream-derived previous (e.g. `0.16.78`) instead of
  picking `0.17.0-shopifyN`, which would collide on `Release.value`.

- [#87](https://github.com/shop/tigerbeetle/pull/87)

  Fix `tb-snapshot` in `--shopify` release builds being stamped with
  `client_release=65535.0.0` and rejected by real clusters as
  `client_release_too_high`. `build_artifacts` was re-invoking
  `zig build tb-snapshot` without `-Dconfig-release`, overwriting the
  correctly-stamped binary produced by the preceding `build_tigerbeetle_target`
  run. Drop the redundant rebuild and copy the already-correct binary
  from `zig-out/bin/tb-snapshot` into the deb staging dir. Also add a
  `--version` flag to `tb-snapshot` and assert in `build_artifacts` that
  both staged binaries report `TigerBeetle version <shopify_version>`
  before building the `.deb`.

- [#86](https://github.com/shop/tigerbeetle/pull/86)

  Add `zig build scripts -- upstream-merge` to merge the next upstream tag into a
  `shopify/upstream-X.Y.Z` branch and open a PR with the verbatim CHANGELOG.md
  section as the body. Resume after manual conflict resolution with `--continue`.
  Tidy's `[shopify]` prefix and changelog rules now filter on `@shopify.com`
  author so upstream commits brought in by the merge don't trip the check.

- [#84](https://github.com/shop/tigerbeetle/pull/84)

  In `--shopify` release builds, derive the multiversion bundling target from
  the second `## TigerBeetle X.Y.Z-shopifyN` header in `SHOPIFY-CHANGELOG.md`
  so `tag_multiversion` is fork-form (e.g. `0.17.0-shopify1`). `fetch_release`
  resolves it from `.fork-bins/`. Falls through to the upstream-derived
  previous on the first fork release for a new upstream base.

### CI

- [#83](https://github.com/shop/tigerbeetle/pull/83)

  Stage `X.Y.Z-shopifyN` tigerbeetle binaries from Cloudsmith into `.fork-bins/`
  in CI so vortex's multi-version slots can include fork releases. `fetch_release()`
  reads from `.fork-bins/` for fork tags; `fetch_vortex_driver_zig()` strips
  `-shopifyN` and reuses the upstream driver. A new `tidy shopify fork` Check 5
  keeps `.shopify-build/fork-versions.txt` in sync with the four most recent
  `-shopify*` tags reachable from `HEAD^`.

## TigerBeetle 0.17.0-shopify1

Released: 2026-05-08

### Tooling

- [#79](https://github.com/shop/tigerbeetle/pull/79)

  Surface the fork suffix in `tigerbeetle version` output. `build.zig` parses
  `SHOPIFY-CHANGELOG.md` (via `src/shopify/changelog_parse.zig`) and injects
  the suffix into `constants.semver.pre` through `vsr_options`. Released
  builds render as `0.17.0-shopify1+<sha>`; dev builds with an `(unreleased)`
  section render as `0.17.0-unreleased+<sha>`. Vortex's supervisor strips the
  new pre-release segment before passing the triple to `Release.parse`.

- [#60](https://github.com/shop/tigerbeetle/pull/60)

  Add `tb-snapshot`, a tool for rewriting TigerBeetle data file snapshots
  (superblock and WAL) for use in blue-green upgrades and operational recovery.
  Source lives at `src/shopify/tb_snapshot/`, built via `zig build tb-snapshot`
  and installed by default. Tests run as part of `zig build test`. Shipped in
  the fork's `.deb` package alongside `tigerbeetle`.

### CI

- [#76](https://github.com/shop/tigerbeetle/pull/76)

  Fix publish pipeline crash with `FileBusy` on `zig-out/dist`. Buildkite
  pre-mounts the artifact collection directory before the container starts;
  the upstream release script then calls `deleteTree("zig-out/dist")` and
  hits `EBUSY` on the mountpoint. Moved shopify artifact output from
  `zig-out/dist/shopify/` to `zig-out/shopify-dist/` so upstream's cleanup
  never touches the mounted path.

- [#72](https://github.com/shop/tigerbeetle/pull/72)

  Add a `skip-changelog-check` commit-message marker that exempts a commit's
  own non-test `src/` changes from the `tidy shopify fork` changelog-update
  check. Per-commit attribution — a marked commit does not suppress the
  check for other commits in the same PR.

- [#56](https://github.com/shop/tigerbeetle/pull/56)

  Add the fork release pipeline: a `.shopify-build/tigerbeetle-publish-package.yml`
  that builds and publishes a `.deb` package to Cloudsmith on `0.*-shopify*`
  branches, a `Validate release build` step on `release/*` branches, and a
  `shopify` subcommand of `zig build scripts` for interactive release preparation.
  The upstream release script gains a `--shopify` flag that triggers fork-specific
  artifact assembly from `src/shopify/release.zig`, and `src/shopify/changelog.zig`
  validates `SHOPIFY-CHANGELOG.md` before each build.

- [#62](https://github.com/shop/tigerbeetle/pull/62)

  Restrict `--shopify` release builds to what the fork actually ships:
  `x86_64-linux` release-mode `tigerbeetle` only, with the vortex driver skipped.
  Avoids the unused upstream target matrix (windows/macos/aarch64 + debug variants)
  during release validation and publish.

- [#62](https://github.com/shop/tigerbeetle/pull/62)

  Slim the go client copied into the `.deb`: ship only the runtime files
  (`go.mod`, `go.sum`, `tb_client.go`, `bindings.go`, `errors.go`, `uint128.go`,
  `native/{native.go,tb_client.h,libtb_client_x86_64-linux.a}`, `LICENSE`)
  instead of the full `zig-out/dist/go/` tree, which dragged in test files and
  four unused native libs (mac/windows/aarch64). Also add an `expected_artifacts`
  postcondition at the end of `build_artifacts` so a missing tigerbeetle binary,
  tb-snapshot binary, go-client native lib, or `.deb` panics during release
  validation rather than silently publishing an incomplete package.

- [#67](https://github.com/shop/tigerbeetle/pull/67)

  Convert fork-only Zig functions in `src/shopify/` from camelCase to snake_case to
  match TigerBeetle's convention (upstream uses snake_case for functions, unlike
  Zig stdlib's camelCase). Renames 14 functions across `changelog.zig` and
  `release.zig` plus their callsite in `src/scripts/release.zig`. Adds a `tidy
  shopify fork` Check 4 that scans every `.zig` file under `src/shopify/` for
  function declarations whose names start lowercase but contain uppercase letters,
  so the rule enforces itself on future PRs. PascalCase type-returning functions
  are still allowed.
