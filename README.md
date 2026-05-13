# tigerbeetle (Shopify fork)

Shopify's fork of [tigerbeetle/tigerbeetle](https://github.com/tigerbeetle/tigerbeetle). We track upstream closely and re-apply a small set of Shopify patches on top. For TigerBeetle itself, read the upstream [docs](https://docs.tigerbeetle.com). This README only covers what's fork-specific.

## Where fork code lives

| Path | What it holds |
| --- | --- |
| `src/shopify/` | Fork-specific Zig source. `tidy.zig`, `changelog.zig`, `release.zig`, plus tools like `tb_snapshot/`. New fork logic goes here. |
| `.shopify-build/` | Buildkite pipelines (`tigerbeetle.yml`, `tigerbeetle-publish-package.yml`), fetch scripts, the `VERSION` marker, and `fork-versions.txt`. |
| `SHOPIFY-CHANGELOG.md` | Fork release notes, grouped per fork release. |
| `// [shopify]` markers | In-line annotations on fork modifications to upstream files. |

## Building and testing

Use the bundled `./zig/zig` binary. Run `./zig/download.sh` to fetch it.

Main commands:

```console
$ ./zig/zig build                           # build tigerbeetle
$ ./zig/zig build test                      # run the full suite
$ ./zig/zig build test -- tidy              # scope by name (e.g. the fork tidy checks)
$ ./zig/zig build check                     # fast compile-only check
$ ./zig/zig build tb-snapshot               # build the fork-only snapshot tool
$ ./zig/zig build scripts -- shopify        # open a PR to publish a fork version
$ ./zig/zig build scripts -- upstream-merge # merge next upstream version into `main`
```

There are two Shopify Build pipelines for the fork:

1. `.shopify-build/tigerbeetle.yml`: tests and linters, runs on all pull requests.
2. `.shopify-build/tigerbeetle-publish-package.yml`: publish pipeline, runs on tags matching `0.*-shopify*` (see below).

## Guiding principles

### Minimize code divergence from upstream

Every line that diverges from upstream is a potential rebase conflict the next time we merge a release. When you need to make a fork change, prefer (in order):

1. **A new file in a fork-only path** (`src/shopify/`, `.shopify-build/`, `SHOPIFY-CHANGELOG.md`). Zero rebase cost.
2. **Code stacked alongside upstream** — a new helper, a new early-return guard above upstream's logic. Upstream lines are untouched.
3. **An upstream-line modification**, only when (1) and (2) can't express what's needed. Mark it inline with `// [shopify]` so it's visible in diffs.

Corollary: when we disable an upstream feature, leave the unused code in place rather than deleting it. Unused code rebases cleanly.

### No modifications to on-disk file format

Anything that changes the superblock, WAL, or grid layout introduces divergence from upstream's storage engine and risks unexpected breakage on upstream changes.

## Conventions

### Shopify Changelog

We maintain a separate, fork-only changelog, `SHOPIFY-CHANGELOG.md`, which mirrors upstream's `CHANGELOG.md`. Entries are grouped per fork release; each entry leads with a fork-PR link followed by a short paragraph describing the change, why it was made, and any upstream-compatibility notes.

```markdown
## TigerBeetle (unreleased)

### Patches

- [#NNN](https://github.com/shop/tigerbeetle/pull/NNN)

  One paragraph describing the change. Wrap at ~90 chars.
```

### Linting and checks

`src/shopify/tidy.zig` enforces these checks on every PR branch:

1. **Commit prefix.** Every commit authored by `@shopify.com` must start with `[shopify]`. Upstream-authored commits brought in by an `upstream-merge` PR are exempt.
2. **Changelog updated.** If a Shopify-authored commit touches a non-test `src/` file, `SHOPIFY-CHANGELOG.md` must be updated in the same PR. A `skip-changelog-check` marker in a commit message exempts that commit only.
3. **Well-formed changelog.** Enforces `SHOPIFY-CHANGELOG.md` format described in the previous section.
4. **snake_case in `src/shopify/`.** Match TigerBeetle's convention, not Zig stdlib's camelCase. PascalCase type-returning functions are allowed.
5. **`fork-versions.txt` in sync.** The manifest lists the four most recent `-shopify*` tags reachable from `HEAD^`. CI uses it to stage fork binaries for vortex's multi-version slots.

## Versioning and releases

Fork tags are `X.Y.Z-shopifyN` (e.g. `0.17.0-shopify2`). There are two flavors, distinguished by whether the `X.Y.Z` portion advances or not:

- **Same-`X.Y.Z` fork bump** (e.g. `0.17.0-shopify1` → `0.17.0-shopify2`) for client- or tooling-only changes — `src/shopify/tb_snapshot/`, Go client patches, build scripts.
- **Server-touching bump** must piggy-back on an upstream `X.Y.Z` bump (e.g. `0.17.0-shopify3` → `0.17.1-shopify1`). The upstream wire format has no slot for the `shopifyN` fork counter, so two builds with the same `X.Y.Z` are indistinguishable to the multiversion loader, which prevents the standard TigerBeetle upgrade path.

If you're not sure which kind your change is: anything that runs inside `tigerbeetle start` (replica, VSR, storage, state machine) is server-touching. Anything that runs as a separate binary or only ships in clients is not.

### Cutting a fork release

```console
$ ./zig/zig build scripts -- shopify
```

The script reads `SHOPIFY-CHANGELOG.md` and `CHANGELOG.md`, computes the next `X.Y.Z-shopifyN`, prompts to confirm, then creates a `release/X.Y.Z-shopifyN` branch, finalizes the `(unreleased)` section in `SHOPIFY-CHANGELOG.md`, commits, pushes, and opens a PR.

After merging, *you must create a release (with a new tag of the form `X.Y.Z-shopifyN`) to trigger the publish pipeline*. Doing so will build and publish the new version to Cloudsmith. Create the release via the Github release page, pasting in the changelog entry from `SHOPIFY-CHANGELOG.md` (there is no automation for this).

### Validating release-pipeline changes off-branch

The `Validate release build` step in `.shopify-build/tigerbeetle.yml` only runs on `release/*` branches by default. To exercise it on a feature branch (when modifying `src/shopify/release.zig`, `src/scripts/release.zig`, or `.shopify-build/`), set `VALIDATE_RELEASE_BUILD=1` from the Buildkite build. The release script will rewrite the `(unreleased)` header in `SHOPIFY-CHANGELOG.md` in place and exercise the release path.

## Merging upstream releases

Per-tag upstream merges are automated:

```console
$ ./zig/zig build scripts -- upstream-merge
```

The script picks the next upstream tag, creates a `shopify/upstream-X.Y.Z` branch, performs the merge, auto-resolves conflicts in fork-owned paths, and opens a PR including the `CHANGELOG.md` section for that tag.

If non-fork-owned conflicts remain, the script writes `.git/SHOPIFY_UPSTREAM_MERGE` and exits with resume instructions. Resolve the conflicts, `git commit` (the prepared `[shopify] Merge upstream X.Y.Z` subject survives via `.git/MERGE_MSG`), and re-run with `--continue`.

## Other packaged tools

### tb-snapshot

`tb-snapshot` is the fork's primary operational tool. It rewrites a TigerBeetle data file (superblock + WAL) so it can be used as the seed for a new cluster, or staged into an existing cluster as a fresh replica — the building block for our blue-green upgrades and disaster recovery. Source lives at `src/shopify/tb_snapshot/`. It ships in the `.deb` alongside `tigerbeetle` and is stamped with the same `X.Y.Z-shopifyN` version so a cluster-issued client release check accepts it. Run `tb-snapshot --help` for the full CLI.

## Monitoring

- [TigerBeetle Cluster Monitoring](https://observe.shopify.io/goto/eflx5zifwdd6oe?orgId=1)
- [Ledger Service](https://observe.shopify.io/goto/bflx64lmrbklcc?orgId=1)

## Resources

- [ShopifyFRS/fintech-foundations](https://github.com/ShopifyFRS/fintech-foundations): the Ledger Service that runs against this fork in production.
- [CLAUDE.md](./CLAUDE.md): fork conventions for AI assistants.
- [SHOPIFY-CHANGELOG.md](./SHOPIFY-CHANGELOG.md): what we've changed and why.
- [Cloudsmith package registry](https://cloudsmith.io/~shopify/repos/public/packages/detail/deb/tigerbeetle/): published `.deb` artifacts for each fork release.
- Upstream [docs](https://docs.tigerbeetle.com): everything not fork-specific.
