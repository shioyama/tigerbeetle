#!/bin/sh
# Fetches a pinned list of upstream TigerBeetle release tags so that
# build.zig's `release_history` has enough recent upstream tags to populate
# vortex's multi-version upgrade slots after manifest-listed fork tags are
# exhausted. The four tags below fill the iterator's four slots; in ReleaseSafe
# Linux, only the most recent (0.16.78) is wired into vortex_options as the
# upgrade-from binary. Fork tags come from `.shopify-build/fork-versions.txt`,
# so the list here is upstream-only.
set -eu

git fetch https://github.com/tigerbeetle/tigerbeetle.git \
  refs/tags/0.16.78:refs/tags/0.16.78 \
  refs/tags/0.16.77:refs/tags/0.16.77 \
  refs/tags/0.16.76:refs/tags/0.16.76 \
  refs/tags/0.16.75:refs/tags/0.16.75
