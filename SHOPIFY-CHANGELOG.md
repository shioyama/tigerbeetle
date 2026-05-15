# Shopify Changelog

Changes made in this fork, organized by release.
Commit messages for Shopify patches are prefixed with `[shopify]`.

## TigerBeetle (unreleased)

### Tooling

- [#92](https://github.com/shop/tigerbeetle/pull/92)

  Rename the fork release subcommand from `shopify` to `shopify-release` for
  symmetry with `upstream-merge` and to make the verb explicit. Invoked via
  `zig build scripts -- shopify-release`.

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
