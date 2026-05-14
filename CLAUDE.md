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
- **Changelog updated**: if any non-test `src/` file changes, `SHOPIFY-CHANGELOG.md` must be updated in the same PR.
- **Changelog well-formed**: every entry must sit under a `### ` section inside a `## TigerBeetle ...` release header and carry a fork-PR link. See [SHOPIFY-CHANGELOG.md structure](#shopify-changelogmd-structure) below.
- **snake_case functions**: functions in `src/shopify/` use snake_case to match TigerBeetle (not Zig stdlib's camelCase). PascalCase type-returning functions are allowed.

## Building and testing

Use `./zig/zig` — the system `zig` is usually a newer version that won't build this repo. Run `./zig/zig build test -- <filter>` to scope tests by name (e.g. `./zig/zig build test -- tidy` runs the fork tidy checks); omit the filter for the full suite. `./zig/zig build check` is a fast compile-only check.

## In-code markers

Fork-specific lines inside upstream files are marked with `// [shopify]`. Examples:
- Test skip guards in `src/integration_tests.zig`
- Extension exceptions in `src/tidy.zig`
- Grouped additions get one `// [shopify]` header rather than a marker on every line

Keep markers visible in diffs — don't bury them in surrounding refactors.

## Claiming values in shared enums and bitfields

When the fork needs to add a value to a numbering shared with upstream (flag bits, operation codes) pick from the **high end of the type's range and work backwards** (bit 63 down for a `u64`; 255 down for an `enum(u8)`). Upstream conventionally grows from the low end, so working inward from the top maximises the gap before a rebase collides with us.

Touch-points (non-exhaustive):
- `SuperBlockHeader.flags` (`u64`) — fork bits at 63 down.
- `vsr.Operation` (`src/vsr.zig`) and `tb.Operation` (`src/tigerbeetle.zig`), both `enum(u8)` — fork ops at 255 down.
- `AccountFlags`, `TransferFlags`, `AccountFilterFlags`, `QueryFilterFlags` in `src/tigerbeetle.zig` — fork bits at the high end of the `padding` tail.

Re-check each fork-claimed value on every upstream merge.

## Fork-only paths

- `.shopify-build/` — Buildkite CI pipeline, scripts, `VERSION` marker
- `SHOPIFY-CHANGELOG.md` — fork release notes, organized per fork release
- `src/shopify/` — fork-specific Zig source (e.g., `shopify/tidy.zig`, `shopify/changelog.zig`, `shopify/release.zig`, `shopify/tb_snapshot/`). New fork logic goes here rather than as an upstream-file modification. Subdirectories are used to group related sources for fork-only tools — see `shopify/tb_snapshot/` for the canonical example.

## Releasing

Fork releases are tagged `X.Y.Z-shopifyN` (e.g., `0.17.0-shopify1`). There are two kinds, distinguished by whether `Release.value` advances:

- **Server-touching changes** must piggy-back on an upstream `X.Y.Z` bump (e.g., `0.17.1-shopify1`). The upstream wire format has no fork-counter slot, so two builds with the same `X.Y.Z` are indistinguishable to the multiversion loader and cannot coexist in a cluster.
- **Client/tooling-only changes** (e.g., `src/shopify/tb_snapshot/`, client patches) ship as same-`X.Y.Z` `-shopifyN` bumps (e.g., `0.17.0-shopify2`) — a package release with no `Release.value` advance.

The release script picks the multiversion bundling target from `SHOPIFY-CHANGELOG.md` via `extract_shopify_previous_version`, which skips same-`X.Y.Z` prior entries to avoid `Release.value` collisions. When no different-triple prior fork tag exists, it falls back to upstream `CHANGELOG.md`'s previous (e.g., `0.17.0-shopify2` bundles `0.16.78`).

When modifying release code (`src/shopify/release.zig`, `src/scripts/release.zig`, `.shopify-build/`), trigger a Buildkite build with `VALIDATE_RELEASE_BUILD=1` to run the `Validate release build` step on a non-`release/*` branch. The step rewrites `SHOPIFY-CHANGELOG.md`'s `(unreleased)` header in place so the build exercises the real release path.

## SHOPIFY-CHANGELOG.md structure

Entries are grouped per fork release. Each entry leads with a fork-PR link followed by a blank line and a paragraph describing what changed, why, and any upstream-compatibility notes. Mirrors upstream's `CHANGELOG.md` format; checked by `tidy shopify fork` (see [src/shopify/changelog.zig](src/shopify/changelog.zig)).

Canonical shape:

```markdown
## TigerBeetle (unreleased)

### Patches

- [#NNN](https://github.com/shop/tigerbeetle/pull/NNN)

  One paragraph describing the change. Wrap at ~90 chars. Use `code spans`
  for paths and identifiers.
```

Rules the validator enforces (keep your first push green):

- Each `- ` bullet at column 0 is an entry; it must contain `](https://github.com/shop/tigerbeetle/pull/...)` on its first line.
- Every entry must appear under a `### ` section header inside a `## TigerBeetle ...` release.
- The bullet line must be followed by a blank line, and the description paragraph(s) must be indented at least two spaces.
- Section names are not enforced

Chicken-and-egg on PR number: PRs and issues share a counter, so predict the next with `gh api 'repos/shop/tigerbeetle/issues?state=all&per_page=1' --jq '.[0].number'` and add 1. If you guess wrong, amend the link before merge — the validator only requires *some* fork-PR URL, not that it resolves.
