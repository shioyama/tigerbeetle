#!/bin/sh
# Fetches a pinned list of upstream TigerBeetle release tags so that
# build.zig's `release_history` (which calls `git tag --merged HEAD^`)
# has enough recent tags to populate vortex's multi-version upgrade slots.
#
# We pin an explicit list rather than fetching all upstream tags so that
# once the fork ships its first 0.17.0 release and starts cutting its own
# tags, this script can be replaced with a fork-only fetch without pulling
# in upstream releases whose upgrade paths no longer apply to the fork.
set -eu

git fetch https://github.com/tigerbeetle/tigerbeetle.git \
  refs/tags/0.17.0:refs/tags/0.17.0 \
  refs/tags/0.16.78:refs/tags/0.16.78 \
  refs/tags/0.16.75:refs/tags/0.16.75 \
  refs/tags/0.16.74:refs/tags/0.16.74 \
  refs/tags/0.16.73:refs/tags/0.16.73
