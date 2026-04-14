#!/usr/bin/env bash
set -euo pipefail

RELEASE_VERSION="${BUILDKITE_BRANCH:-}"

if [[ -z "$RELEASE_VERSION" ]]; then
  echo "BUILDKITE_BRANCH not set, skipping release readiness check."
  exit 0
fi

has_match=false
while IFS= read -r version_line; do
  version=$(echo "$version_line" | sed 's/\*\*Version:\*\* *//')

  if [[ "$version" == "unreleased" ]]; then
    echo "ERROR: PATCHES.md contains an unreleased entry."
    grep -B5 '^\*\*Version:\*\* unreleased' PATCHES.md | grep '^## shopify/' | sed 's/^/  /'
    exit 1
  fi

  if [[ "$version" == "$RELEASE_VERSION" ]]; then
    has_match=true
  fi

  if [[ "$(printf '%s\n%s\n' "$RELEASE_VERSION" "$version" | sort -V | tail -1)" != "$RELEASE_VERSION" ]]; then
    echo "ERROR: Patch version '$version' exceeds release version '$RELEASE_VERSION'."
    exit 1
  fi
done < <(grep '^\*\*Version:\*\*' PATCHES.md)

if [[ "$has_match" != true ]]; then
  echo "ERROR: No patch in PATCHES.md matches release version '$RELEASE_VERSION'."
  exit 1
fi

echo "Release readiness check passed."
