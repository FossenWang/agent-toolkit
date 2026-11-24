#!/usr/bin/env bash
# Run the bats suite for rebase-merge.
#
# JOBS defaults to 3. GNU parallel or rush is used when available; otherwise the
# suite falls back to serial execution. Pass extra bats arguments before the
# suite path, for example: tests/run.sh --filter 'diverged'.
#
# Set BATS_BIN to use an already-installed bats instead of npx.

set -euo pipefail

cd "$(dirname "$0")/.."

jobs=${JOBS:-3}
if ! [[ "$jobs" =~ ^[0-9]+$ ]] || [ "$jobs" -lt 1 ]; then
  printf 'JOBS must be a positive integer, got %s\n' "$jobs" >&2
  exit 2
fi

suites=(tests/rebase-merge)

# Keep test fixtures out of the real /tmp root and away from user data.
export TMPDIR="${TMPDIR:-/tmp/opencode}"
mkdir -p "$TMPDIR"

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
else
  bats=(npx --yes "bats@$(cat tests/bats-version)")
fi

if [ "$jobs" -gt 1 ]; then
  exec "${bats[@]}" --jobs "$jobs" --parallel-binary-name "$parallel_bin" "$@" "${suites[@]}"
else
  exec "${bats[@]}" "$@" "${suites[@]}"
fi
