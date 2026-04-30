# CLAUDE.md

This repo is Shopify's fork of [tigerbeetle/tigerbeetle](https://github.com/tigerbeetle/tigerbeetle). We track upstream closely and re-apply a small set of Shopify patches on top.

## Guiding principle: minimize divergence

Every fork-specific line is a potential rebase conflict. When making fork changes, prefer options in this order:

1. **Add new files in fork-only locations** (`.shopify-build/`, `SHOPIFY-CHANGELOG.md`, `src/shopify/`). Zero rebase cost.
2. **Add new code alongside upstream** — new functions, new early-return guards stacked on top of upstream ones. Upstream lines are untouched.
3. **Modify upstream lines** only when (1) and (2) can't express what's needed. Keep the modification as small as possible and mark it inline with `// [shopify]`.

Corollaries:
- When simplifying an upstream feature (e.g., disabling a language client we don't ship), leave unused upstream code in place rather than deleting it. Unused code rebases cleanly; deleted code doesn't.
- Prefer a new helper function over inlining logic into an existing upstream function.
- Prefer a new test skip line stacked above upstream's skip over mutating upstream's skip condition.

## Conventions enforced by tidy

`src/tidy.zig`'s `tidy shopify fork` check runs on PR branches and enforces:

- **Commit prefix**: every commit on the PR branch must start with `[shopify]`.
- **Changelog**: if any non-test `src/` file changes, `SHOPIFY-CHANGELOG.md` must be updated in the same PR.

## Building and testing

Use `./zig/zig` — the system `zig` is usually a newer version that won't build this repo. Run `./zig/zig build test -- <filter>` to scope tests by name (e.g. `./zig/zig build test -- tidy` runs the fork tidy checks); omit the filter for the full suite. `./zig/zig build check` is a fast compile-only check.

## In-code markers

Fork-specific lines inside upstream files are marked with `// [shopify]`. Examples:
- Test skip guards in `src/integration_tests.zig`
- Extension exceptions in `src/tidy.zig`
- Grouped additions get one `// [shopify]` header rather than a marker on every line

Keep markers visible in diffs — don't bury them in surrounding refactors.

## Fork-only paths

- `.shopify-build/` — Buildkite CI pipeline, scripts, `VERSION` marker
- `SHOPIFY-CHANGELOG.md` — fork release notes, organized per fork release
- `src/shopify/` — fork-specific Zig source (e.g., `shopify/tidy.zig`, `shopify/changelog.zig`, `shopify/release.zig`, `shopify/tb_snapshot/`). New fork logic goes here rather than as an upstream-file modification. Subdirectories are used to group related sources for fork-only tools — see `shopify/tb_snapshot/` for the canonical example.

## Tags and versioning

- Fork releases are tagged `X.Y.Z-shopifyN` (e.g., `0.17.0-shopify1`).
- `build.zig`'s `release_history` reads tags via `git tag --merged HEAD^` to populate vortex's multi-version upgrade slots. CI provides tags via `.shopify-build/fetch-upstream-tags.sh`, which currently pins a list of upstream tags and will switch to fork tags once the first `0.17.0-shopifyN` ships.

## SHOPIFY-CHANGELOG.md structure

Entries are grouped by fork release, with each patch linked to its PR and describing: what changed, why, upstream-compatibility notes. See existing entries for the format.
