#!/usr/bin/env bash
# Run the bats suite for rebase-merge.
#
# JOBS defaults to 3. GNU parallel or rush is used when available; otherwise the
# suite falls back to serial execution. Pass extra bats arguments before the
# suite path, for example: tests/run.sh --filter 'diverged'.
#
# Bats lookup order: BATS_BIN, then the local devDependency, then npx.

set -euo pipefail

cd "$(dirname "$0")/.."

jobs=${JOBS:-3}
if ! [[ "$jobs" =~ ^[0-9]+$ ]] || [ "$jobs" -lt 1 ]; then
  printf 'JOBS must be a positive integer, got %s\n' "$jobs" >&2
  exit 2
fi

suites=(tests/rebase-merge)

# Fixtures get their own directory: an explicit TMPDIR is used as given, otherwise
# each run creates a throwaway one under the system temp root.
created=""
if [ -z "${TMPDIR:-}" ]; then
  TMPDIR=$(mktemp -d)
  export TMPDIR
  created=1
else
  mkdir -p "$TMPDIR" 2>/dev/null || true
fi

if [ ! -w "$TMPDIR" ]; then
  printf 'TMPDIR %s is not writable\n' "$TMPDIR" >&2
  exit 2
fi

# Clean up a created directory only on success, so a failing run leaves its
# fixtures behind for inspection.
if [ -n "$created" ]; then
  trap 'status=$?; if [ "$status" -eq 0 ]; then rm -rf "$TMPDIR"; else printf "fixtures kept: %s\n" "$TMPDIR" >&2; fi' EXIT
fi

parallel_bin=""
if command -v parallel >/dev/null 2>&1; then
  parallel_bin=parallel
elif command -v rush >/dev/null 2>&1; then
  parallel_bin=rush
fi

if [ "$jobs" -gt 1 ] && [ -z "$parallel_bin" ]; then
  printf 'GNU parallel or rush not found; running serially\n' >&2
  jobs=1
fi

if [ -n "${BATS_BIN:-}" ]; then
  bats=("$BATS_BIN")
elif [ -x node_modules/.bin/bats ]; then
  bats=(node_modules/.bin/bats)
else
  # Keep in step with the "bats" devDependency in package.json.
  bats=(npx --yes bats@1.13.0)
fi

if [ "$jobs" -gt 1 ]; then
  "${bats[@]}" --jobs "$jobs" --parallel-binary-name "$parallel_bin" "$@" "${suites[@]}"
else
  "${bats[@]}" "$@" "${suites[@]}"
fi
