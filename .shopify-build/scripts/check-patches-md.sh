#!/usr/bin/env bash
set -euo pipefail

BASE_BRANCH="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-main}"

# Fetch base branch for comparison (result goes into FETCH_HEAD)
git fetch origin "${BASE_BRANCH}" --depth=1

diff_base() {
  git diff FETCH_HEAD HEAD "$@"
}

# Check that all PR commits have [shopify] prefix
bad_commits=()
while IFS= read -r line; do
  sha="${line%% *}"
  msg="${line#* }"
  if [[ "$msg" != \[shopify\]* ]]; then
    bad_commits+=("$sha $msg")
  fi
done < <(git log --format='%h %s' FETCH_HEAD..HEAD)

if [[ ${#bad_commits[@]} -gt 0 ]]; then
  echo "ERROR: All commits must be prefixed with [shopify]."
  echo ""
  echo "Commits missing the prefix:"
  printf '  %s\n' "${bad_commits[@]}"
  echo ""
  echo "Example: [shopify] Add piecemeal backfill support"
  exit 1
fi

# Test file pathspec exclusions
TEST_EXCLUSIONS=(
  ':(exclude)src/testing/'
  ':(exclude)src/stdx/testing/'
  ':(exclude)*_test.*'
  ':(exclude)*_tests.*'
  ':(exclude)*_fuzz.*'
  ':(exclude)*fuzz_tests.*'
  ':(exclude)*/test.*'
  ':(exclude)*/tests/'
  ':(exclude)*/src/test/'
  ':(exclude)src/tidy.zig'
)

# Get non-test src/ files changed
mapfile -t NON_TEST_FILES < <(diff_base --name-only -- src/ "${TEST_EXCLUSIONS[@]}")

if [[ ${#NON_TEST_FILES[@]} -eq 0 ]]; then
  echo "No non-test src/ files changed, skipping PATCHES.md check."
  exit 0
fi

# Check if PATCHES.md was modified
if ! diff_base --name-only -- PATCHES.md | grep -q .; then
  echo "ERROR: Non-test files changed in src/ but PATCHES.md was not updated."
  echo ""
  echo "Changed non-test src/ files:"
  printf '  %s\n' "${NON_TEST_FILES[@]}"
  echo ""
  echo "Please add or update an entry in PATCHES.md."
  exit 1
fi

# Check for new section headers in the diff
NEW_SECTIONS=$(diff_base -- PATCHES.md \
  | grep '^+## ' \
  | sed 's/^+//' || true)

errors=0

# Validate new sections are at the top in order
if [[ -n "$NEW_SECTIONS" ]]; then
mapfile -t new_headers < <(echo "$NEW_SECTIONS")
mapfile -t top_headers < <(grep '^## shopify/' PATCHES.md | head -"${#new_headers[@]}")
for i in "${!new_headers[@]}"; do
  if [[ "${new_headers[$i]}" != "${top_headers[$i]:-}" ]]; then
    echo "ERROR: New entries must be at the top of PATCHES.md (reverse chronological order)."
    echo "  Expected '${new_headers[$i]}' at position $((i + 1)), found '${top_headers[$i]:-<none>}'."
    errors=1
  fi
done

while IFS= read -r header; do
  # Validate header format
  if ! echo "$header" | grep -qE '^## shopify/[a-z0-9]+(-[a-z0-9]+)*$'; then
    echo "ERROR: Section header does not match expected format '## shopify/<kebab-case-name>'."
    echo "  Got: $header"
    errors=1
    continue
  fi

  # Extract section body (from header to next ## or EOF)
  header_line=$(grep -nF "$header" PATCHES.md | head -1 | cut -d: -f1)
  section_body=$(sed -n "${header_line},\$p" PATCHES.md | tail -n +2 | sed '/^## /,$d')

  # Validate **Status:** line
  if ! echo "$section_body" | grep -q '^\*\*Status:\*\*'; then
    echo "ERROR: Section '$header' is missing a **Status:** line."
    errors=1
  fi

  # Validate **Version:** line
  if ! echo "$section_body" | grep -q '^\*\*Version:\*\*'; then
    echo "ERROR: Section '$header' is missing a **Version:** line."
    errors=1
  fi

  # Validate description exists (non-blank, non-metadata line after the metadata block)
  has_description=false
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \*\** ]] && continue
    has_description=true
    break
  done <<< "$section_body"

  if [[ "$has_description" != true ]]; then
    echo "ERROR: Section '$header' is missing a description."
    errors=1
  fi
done <<< "$NEW_SECTIONS"
fi

# Validate ordering of all entries: unreleased first, then versions in reverse order
prev_version=""
while IFS= read -r version_line; do
  version=$(echo "$version_line" | sed 's/\*\*Version:\*\* *//')
  if [[ -n "$prev_version" ]]; then
    if [[ "$version" == "unreleased" && "$prev_version" != "unreleased" ]]; then
      echo "ERROR: Unreleased entries must come before versioned entries in PATCHES.md."
      errors=1
      break
    fi
    if [[ "$version" != "unreleased" && "$prev_version" != "unreleased" ]]; then
      # Both are concrete versions — check reverse order (prev >= current)
      if [[ "$(printf '%s\n%s\n' "$prev_version" "$version" | sort -V | head -1)" != "$version" ]]; then
        echo "ERROR: Versioned entries must be in reverse chronological order in PATCHES.md."
        echo "  '$prev_version' should come before '$version'."
        errors=1
        break
      fi
    fi
  fi
  prev_version="$version"
done < <(grep '^\*\*Version:\*\*' PATCHES.md)

if [[ "$errors" -gt 0 ]]; then
  exit 1
fi

echo "PATCHES.md check passed."
