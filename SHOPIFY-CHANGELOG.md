# Shopify Changelog

Changes made in this fork, organized by release.
Commit messages for Shopify patches are prefixed with `[shopify]`.

## TigerBeetle (unreleased)

### Patches

- Add the fork release pipeline: a `.shopify-build/tigerbeetle-publish-package.yml`
  that builds and publishes a `.deb` package to Cloudsmith on `0.*-shopify*` branches,
  a `Validate release build` step on `release/*` branches, and a `shopify` subcommand
  of `zig build scripts` for interactive release preparation. The upstream release
  script gains a `--shopify` flag that triggers fork-specific artifact assembly
  from `src/shopify/release.zig`, and `src/shopify/changelog.zig` validates
  `SHOPIFY-CHANGELOG.md` before each build.
- Add `tb-snapshot`, a tool for rewriting TigerBeetle data file snapshots
  (superblock and WAL) for use in blue-green upgrades and operational recovery.
  Source lives at `src/shopify/tb_snapshot/`, built via `zig build tb-snapshot`
  and installed by default. Tests run as part of `zig build test`. Shipped in
  the fork's `.deb` package alongside `tigerbeetle`.
- Restrict `--shopify` release builds to what the fork actually ships:
  `x86_64-linux` release-mode `tigerbeetle` only, with the vortex driver skipped.
  Avoids the unused upstream target matrix (windows/macos/aarch64 + debug variants)
  during release validation and publish.
