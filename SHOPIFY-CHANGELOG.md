# Shopify Changelog

Changes made in this fork, organized by release.
Commit messages for Shopify patches are prefixed with `[shopify]`.

## TigerBeetle (unreleased)

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
