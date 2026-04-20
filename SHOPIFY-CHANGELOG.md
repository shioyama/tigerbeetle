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
