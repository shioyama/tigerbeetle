#!/usr/bin/env bash
set -euo pipefail

if grep -q '^\*\*Version:\*\* unreleased' PATCHES.md; then
  echo "ERROR: PATCHES.md contains unreleased entries. Assign versions before publishing."
  echo ""
  echo "Unreleased patches:"
  grep -B5 '^\*\*Version:\*\* unreleased' PATCHES.md | grep '^## shopify/' | sed 's/^/  /'
  exit 1
fi

echo "No unreleased patches found. Check passed."
