#!/bin/sh
# Downloads and caches fork-tagged tigerbeetle binaries that vortex's
# multi-version upgrade slots need at HEAD. For each tag listed in
# fork-versions.txt, fetches the matching `.deb` from Cloudsmith's `public`
# repo (configured at container build via tigerbeetle.yml's `apt:` block) and
# writes .fork-bins/<tag>/tigerbeetle. build.zig's fetch_release() finds the
# binary at this path for X.Y.Z-shopifyN tags; without it, the iterator falls
# back to upstream tags only.
#
# The Cloudsmith `public` repo is private but uses a static token committed
# in `gcp-chef`'s base apt setup — see:
#   github.com/ShopifyRestricted/gcp-chef/cookbooks/base/recipes/apt.rb
#
# Idempotent: if .fork-bins/<tag>/tigerbeetle already exists (cache hit), the
# download is skipped.
#
# `apt-get update` is required at step time: shopify-build's apt layer wipes
# /var/lib/apt/lists/* after the container is built, so by the time this
# script runs in a step, apt has no package index.
set -eu

mkdir -p .fork-bins

# Refresh apt indexes only if there is at least one fork tag we'd actually fetch
# and that tag isn't already cached.
need_update=0
while IFS= read -r tag || [ -n "$tag" ]; do
    case "$tag" in
        ''|\#*) continue ;;
        *-shopify*)
            if [ ! -f ".fork-bins/$tag/tigerbeetle" ]; then
                need_update=1
                break
            fi
            ;;
    esac
done < .shopify-build/fork-versions.txt

if [ "$need_update" = 1 ]; then
    apt-get update -qq
fi

while IFS= read -r tag || [ -n "$tag" ]; do
    case "$tag" in
        ''|\#*) continue ;;
        *-shopify*) ;;
        *)
            echo "Refusing to fetch non-fork tag '$tag' from Cloudsmith." >&2
            exit 1 ;;
    esac

    out=".fork-bins/$tag/tigerbeetle"
    if [ -f "$out" ]; then
        echo "Fork binary $tag already cached, skipping."
        continue
    fi

    echo "Downloading fork binary $tag..."
    work=".fork-bins-tmp/$tag"
    rm -rf "$work"
    mkdir -p "$work"
    (
        cd "$work"
        apt-get -o APT::Sandbox::User=root download "tigerbeetle=$tag"
        dpkg-deb -x "tigerbeetle_${tag}_amd64.deb" extracted
    )
    mkdir -p ".fork-bins/$tag"
    cp "$work/extracted/usr/bin/tigerbeetle" "$out"
    rm -rf "$work"
done < .shopify-build/fork-versions.txt

rmdir .fork-bins-tmp 2>/dev/null || true
