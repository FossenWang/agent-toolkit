#!/usr/bin/env bash
# Fast-flow orchestrator for the rebase-merge skill.
#
# Usage: fast-flow.sh [--main <M>] [--feature <F>] [--check] [--no-ff] [--stop-after-rebase] [--test-command <cmd>] (see --help).
# It resolves missing branch names, creates temporary worktrees for branches that
# are not checked out, runs preflight, rebases if needed, runs the requested tests
# only for the diverged relation (the only case that rewrites F), then merges with
# ff-only or no-ff using the verified feature SHA. synced, behind-main, and
# ahead-of-main do not change commits and do not run tests.
# With --stop-after-rebase it stops after rebase/tests without merging.
# Temporary worktrees created or reused by this run are removed after status=done
# unless --keep-worktree is given; blocked/needs-ai/failed runs keep them for
# continuation. With --check it prints the preflight plan and exits without
# creating worktrees or changing branches. needs-ai is terminal for this script:
# it never resumes, retries, pushes, or deletes branches; the skill continues
# manually from the handoff.
#
# Exit codes:
#   0  done
#   1  failed (merge)
#   2  needs input (preflight) or needs AI (conflict, tests)
#   3  usage error

set -u
set -o pipefail

PROG=${0##*/}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MAIN=""
FEATURE=""
TEST_COMMAND=""
MAIN_WT_ARG=""
FEATURE_WT_ARG=""
MODE="ff-only"
STOP_AFTER_REBASE=0
CHECK_ONLY=0
KEEP_WORKTREE=0
DO_FETCH=1
OUT=""
TMP_DIR=""
WT_ROOT=""
RELATION=""
MAIN_WT=""
FEATURE_WT=""
MAIN_WT_TEMP="no"
FEATURE_WT_TEMP="no"
MAIN_WT_CREATED="no"
FEATURE_WT_CREATED="no"
MAIN_TIP=""
FEATURE_TIP=""
F_VERIFIED=""
MAIN_STATE=""
FEATURE_STATE=""
MAIN_UPSTREAM=""
MAIN_UPSTREAM_STATE=""
FEATURE_UPSTREAM=""
FEATURE_PUSH=""
FEATURE_REWRITTEN=""
REBASE_DONE="no"
MERGE_DONE="no"
TESTS_STATE="skipped"
WORKTREE_ERROR=""
TEMP_WT_CLEANED="n/a"
CLEANUP_ERROR=""
QUESTION=""
OPTIONS=""
HANDOFF=""
PRE_RC=""
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}

usage() {
  cat <<EOF
Usage: $PROG [--main <M>] [--feature <F>] [--check] [--no-ff] [--stop-after-rebase] [--keep-worktree] [--test-command <cmd>] [--no-fetch]

Fast-flow orchestrator for rebase-merge. Missing branch names default to the
main worktree's branch and the current branch. Missing worktrees are created
under a temporary directory. Runs preflight, rebases if needed, runs the test
command only for the diverged relation (the only case that rewrites F), then merges
with ff-only or no-ff using the verified feature SHA. synced, behind-main, and
ahead-of-main do not change commits and do not run tests. Stops on conflicts,
test failures, or preflight blockers; needs-ai is terminal, and the skill
continues manually. Temporary worktrees created or reused by this run are
removed after status=done unless --keep-worktree is given. Never pushes, deletes
branches, or resolves conflicts.

Options:
  --main <branch>         Main branch (default: main worktree's branch)
  --feature <branch>      Feature branch (default: current branch)
  --check                 Run preflight only, print the plan, and exit
                          (prints stop_after_rebase=yes when that flag is set)
  --no-ff                 Merge with a merge commit (default: ff-only)
  --stop-after-rebase     Rebase if needed, run tests, then stop without merging
                          (--no-ff is ignored with a warning)
  --keep-worktree         Keep temporary worktrees created by this run
  --main-worktree <path>  Create/use this worktree for the main branch
  --feature-worktree <path> Create/use this worktree for the feature branch
  --test-command <cmd>    Command to run after a diverged rebase rewrites F
                          (other relations skip tests)
  --no-fetch              Do not run git fetch during the first preflight
  --fetch                 Run git fetch during the first preflight (default)
  -h, --help              Show this help

Stages: preflight / rebase / tests / merge / done
Status: done / blocked / needs-ai / failed
Tests: passed / failed / dirty / skipped / not-run
Merge: no / ff-only / no-ff / skipped
Temp worktrees: cleaned=yes|no|partial|n/a
Exit: 0 done, 1 failed, 2 blocked/needs-ai, 3 usage error.
EOF
}

emit() {
  OUT="${OUT}$1=$2"$'\n'
}

one_line() {
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ -n "$WT_ROOT" ] && [ -d "$WT_ROOT" ]; then
    rmdir "$WT_ROOT" 2>/dev/null || true
  fi
}

trap cleanup EXIT

remove_temp_worktree() {
  local label=$1 path=$2 temp=no err_file
  case "$label" in
    main) temp=$MAIN_WT_TEMP ;;
    feature) temp=$FEATURE_WT_TEMP ;;
  esac
  [ "$temp" = "yes" ] || return 0
  [ -n "$path" ] && [ -d "$path" ] || return 0

  case "$PWD/" in
    "$path"/*)
      CLEANUP_ERROR="${CLEANUP_ERROR:+$CLEANUP_ERROR; }cannot remove $label worktree at $path: current directory is inside it"
      return 1
      ;;
  esac

  err_file=""
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    err_file="$TMP_DIR/cleanup-$label.err"
  fi
  if [ -n "$err_file" ]; then
    if ! git worktree remove "$path" >/dev/null 2>"$err_file"; then
      CLEANUP_ERROR="${CLEANUP_ERROR:+$CLEANUP_ERROR; }cannot remove $label worktree at $path: $(one_line "$(cat "$err_file" 2>/dev/null)")"
      return 1
    fi
  elif ! git worktree remove "$path" >/dev/null 2>&1; then
    CLEANUP_ERROR="${CLEANUP_ERROR:+$CLEANUP_ERROR; }cannot remove $label worktree at $path"
    return 1
  fi
  return 0
}

cleanup_temp_worktrees() {
  local total=0 failed=0
  if [ "$KEEP_WORKTREE" -eq 1 ]; then
    if [ "$MAIN_WT_TEMP" = "yes" ] || [ "$FEATURE_WT_TEMP" = "yes" ]; then
      TEMP_WT_CLEANED="no"
    fi
    return 0
  fi

  if [ "$MAIN_WT_TEMP" = "yes" ] && [ -d "$MAIN_WT" ]; then
    total=$((total + 1))
    remove_temp_worktree main "$MAIN_WT" || failed=$((failed + 1))
  fi
  if [ "$FEATURE_WT_TEMP" = "yes" ] && [ -d "$FEATURE_WT" ]; then
    total=$((total + 1))
    remove_temp_worktree feature "$FEATURE_WT" || failed=$((failed + 1))
  fi

  if [ "$total" -eq 0 ]; then
    TEMP_WT_CLEANED="n/a"
  elif [ "$failed" -eq 0 ]; then
    TEMP_WT_CLEANED="yes"
  elif [ "$failed" -eq "$total" ]; then
    TEMP_WT_CLEANED="no"
  else
    TEMP_WT_CLEANED="partial"
  fi

  if [ -n "$WT_ROOT" ] && [ -d "$WT_ROOT" ]; then
    rmdir "$WT_ROOT" 2>/dev/null || true
  fi
}

current_tip() {
  git rev-parse --verify "$1^{commit}" 2>/dev/null || true
}

finish_status() {
  local status=$1 stage=$2 code=$3 message=${4:-} mt ft temp option
  mt=$(current_tip "$MAIN")
  ft=$(current_tip "$FEATURE")
  [ -n "$mt" ] || mt=${MAIN_TIP:-n/a}
  [ -n "$ft" ] || ft=${FEATURE_TIP:-n/a}

  if [ "$status" = "done" ]; then
    cleanup_temp_worktrees
  elif [ "$MAIN_WT_TEMP" = "yes" ] || [ "$FEATURE_WT_TEMP" = "yes" ]; then
    TEMP_WT_CLEANED="no"
  fi

  temp=none
  if [ "$MAIN_WT_TEMP" = "yes" ] && [ "$FEATURE_WT_TEMP" = "yes" ]; then
    temp=both
  elif [ "$MAIN_WT_TEMP" = "yes" ]; then
    temp=main
  elif [ "$FEATURE_WT_TEMP" = "yes" ]; then
    temp=feature
  fi

  emit "main_branch" "$MAIN"
  emit "feature_branch" "$FEATURE"
  emit "relation" "${RELATION:-n/a}"
  emit "main_tip" "$mt"
  emit "feature_tip" "$ft"
  emit "main_worktree" "${MAIN_WT:-n/a}"
  emit "feature_worktree" "${FEATURE_WT:-n/a}"
  emit "main_worktree_temp" "$MAIN_WT_TEMP"
  emit "feature_worktree_temp" "$FEATURE_WT_TEMP"
  emit "main_worktree_created" "$MAIN_WT_CREATED"
  emit "feature_worktree_created" "$FEATURE_WT_CREATED"
  emit "temp_worktree" "$temp"
  emit "temp_worktree_root" "${WT_ROOT:-none}"
  emit "temp_worktree_cleaned" "$TEMP_WT_CLEANED"
  [ -n "$CLEANUP_ERROR" ] && emit "temp_worktree_cleanup_error" "$(one_line "$CLEANUP_ERROR")"
  emit "feature_verified" "${F_VERIFIED:-n/a}"
  emit "rebase" "$REBASE_DONE"
  emit "tests" "$TESTS_STATE"
  emit "merge" "$MERGE_DONE"
  emit "main_upstream" "${MAIN_UPSTREAM:-n/a}"
  emit "feature_upstream" "${FEATURE_UPSTREAM:-n/a}"
  emit "feature_push" "${FEATURE_PUSH:-n/a}"
  emit "feature_rewritten" "${FEATURE_REWRITTEN:-n/a}"
  emit "status" "$status"
  emit "stage" "$stage"
  [ -n "$message" ] && emit "message" "$(one_line "$message")"
  [ -n "${HANDOFF:-}" ] && emit "handoff" "$(one_line "$HANDOFF")"
  [ -n "${QUESTION:-}" ] && emit "question" "$(one_line "$QUESTION")"
  if [ -n "${OPTIONS:-}" ]; then
    while IFS= read -r option; do
      [ -n "$option" ] && emit "option" "$(one_line "$option")"
    done <<< "$OPTIONS"
  fi
  emit "exit" "$code"
  printf '%s' "$OUT"
  exit "$code"
}

fatal() {
  local message=$1 code=${2:-3}
  printf '%s: %s\n' "$PROG" "$message" >&2
  finish_status "failed" "usage" "$code" "$message"
}

preflight_get() {
  sed -n "s/^$1=//p" "$TMP_DIR/preflight.out" | tail -1
}

load_preflight() {
  if [ -z "$MAIN" ]; then
    MAIN=$(preflight_get main_branch)
  fi
  if [ -z "$FEATURE" ]; then
    FEATURE=$(preflight_get feature_branch)
  fi
  MAIN_WT=$(preflight_get main_worktree)
  FEATURE_WT=$(preflight_get feature_worktree)
  MAIN_TIP=$(preflight_get main_tip)
  FEATURE_TIP=$(preflight_get feature_tip)
  RELATION=$(preflight_get relation)
  MAIN_STATE=$(preflight_get main_worktree_state)
  FEATURE_STATE=$(preflight_get feature_worktree_state)
  MAIN_UPSTREAM=$(preflight_get main_upstream)
  MAIN_UPSTREAM_STATE=$(preflight_get main_upstream_state)
  FEATURE_UPSTREAM=$(preflight_get feature_upstream)
  FEATURE_PUSH=$(preflight_get feature_push)
  FEATURE_REWRITTEN=$(preflight_get feature_rewritten)
  if [ -n "$MAIN_WT" ]; then
    set_worktree main "$MAIN_WT"
  fi
  if [ -n "$FEATURE_WT" ]; then
    set_worktree feature "$FEATURE_WT"
  fi
}

run_preflight() {
  local fetch_flag=$1
  if [ -n "$MAIN" ] && [ -n "$FEATURE" ]; then
    bash "$SCRIPT_DIR/preflight.sh" --main "$MAIN" --feature "$FEATURE" "$fetch_flag" \
      >"$TMP_DIR/preflight.out" 2>"$TMP_DIR/preflight.err"
  elif [ -n "$MAIN" ]; then
    bash "$SCRIPT_DIR/preflight.sh" --main "$MAIN" "$fetch_flag" \
      >"$TMP_DIR/preflight.out" 2>"$TMP_DIR/preflight.err"
  elif [ -n "$FEATURE" ]; then
    bash "$SCRIPT_DIR/preflight.sh" --feature "$FEATURE" "$fetch_flag" \
      >"$TMP_DIR/preflight.out" 2>"$TMP_DIR/preflight.err"
  else
    bash "$SCRIPT_DIR/preflight.sh" "$fetch_flag" \
      >"$TMP_DIR/preflight.out" 2>"$TMP_DIR/preflight.err"
  fi
  PRE_RC=$?
}

print_preflight() {
  printf '%s\n' "# preflight:" >&2
  cat "$TMP_DIR/preflight.out" >&2
  if [ -s "$TMP_DIR/preflight.err" ]; then
    cat "$TMP_DIR/preflight.err" >&2
  fi
}

preflight_blocker_reason() {
  local value
  value=$(preflight_get main_worktree_state)
  [ "$value" = "prunable" ] && { printf 'main worktree path is missing; run git worktree prune or recreate it'; return 0; }
  value=$(preflight_get feature_worktree_state)
  [ "$value" = "prunable" ] && { printf 'feature worktree path is missing; run git worktree prune or recreate it'; return 0; }
  value=$(preflight_get main_clean)
  [ "$value" = "no" ] && { printf 'main worktree is dirty'; return 0; }
  [ "$value" = "unknown" ] && { printf 'main worktree is unreadable'; return 0; }
  value=$(preflight_get feature_clean)
  [ "$value" = "no" ] && { printf 'feature worktree is dirty'; return 0; }
  [ "$value" = "unknown" ] && { printf 'feature worktree is unreadable'; return 0; }
  value=$(preflight_get main_in_progress)
  { [ -n "$value" ] && [ "$value" != "none" ] && [ "$value" != "n/a" ]; } && { printf 'main worktree has %s in progress' "$value"; return 0; }
  value=$(preflight_get feature_in_progress)
  { [ -n "$value" ] && [ "$value" != "none" ] && [ "$value" != "n/a" ]; } && { printf 'feature worktree has %s in progress' "$value"; return 0; }
  value=$(preflight_get main_upstream_state)
  [ "$value" = "diverged" ] && { printf 'main diverged from its upstream'; return 0; }
  value=$(preflight_get feature_upstream_state)
  if [ "$value" = "local-behind" ] || [ "$value" = "diverged" ]; then
    printf 'feature is %s relative to its upstream' "$value"
    return 0
  fi
  if [ -z "$(preflight_get merge_base)" ]; then
    printf 'no merge base; histories are unrelated'
    return 0
  fi
  return 1
}

preflight_block_reason() {
  preflight_blocker_reason && return 0
  printf 'preflight blocked; inspect the preflight output'
}

worktree_for_branch() {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree / { w = substr($0, 10) }
    /^branch / { if ($0 == "branch " b) { print w; exit } }
  '
}

is_temp_path() {
  case "$1" in
    "$TMP_BASE"/rebase-merge.*) return 0 ;;
    *) return 1 ;;
  esac
}

set_worktree() {
  local label=$1 path=$2 root
  if is_temp_path "$path"; then
    root=${path%/*}
    [ -n "$WT_ROOT" ] || WT_ROOT=$root
    if [ "$label" = "main" ]; then MAIN_WT_TEMP=yes; else FEATURE_WT_TEMP=yes; fi
  else
    if [ "$label" = "main" ]; then MAIN_WT_TEMP=no; else FEATURE_WT_TEMP=no; fi
  fi
  if [ "$label" = "main" ]; then
    MAIN_WT=$path
  else
    FEATURE_WT=$path
  fi
}

prepare_worktree() {
  local path=$1 branch=$2 label=$3 existing current err
  if [ -n "$path" ]; then
    case "$path" in
      /*) ;;
      *) path="$PWD/$path" ;;
    esac
  fi
  existing=$(worktree_for_branch "$branch")
  if [ -n "$existing" ]; then
    if [ -d "$existing" ]; then
      set_worktree "$label" "$existing"
      return 0
    fi
    WORKTREE_ERROR="$label worktree path is missing: $existing; run git worktree prune or recreate it"
    return 1
  fi
  if [ -z "$path" ]; then
    if [ -z "$WT_ROOT" ]; then
      WT_ROOT=$(mktemp -d "$TMP_BASE/rebase-merge.XXXXXX") || {
        WORKTREE_ERROR="cannot create temporary worktree root under $TMP_BASE"
        return 1
      }
    fi
    path="$WT_ROOT/$label"
  fi
  if [ -e "$path" ]; then
    current=$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || true)
    if [ "$current" != "$branch" ]; then
      WORKTREE_ERROR="$label path exists but is on '${current:-unknown}', expected '$branch': $path"
      return 1
    fi
    set_worktree "$label" "$path"
    return 0
  fi
  mkdir -p "$(dirname "$path")" 2>/dev/null || {
    WORKTREE_ERROR="cannot create parent directory for $label worktree: $path"
    return 1
  }
  if ! err=$(git worktree add "$path" "$branch" 2>&1); then
    WORKTREE_ERROR="cannot create $label worktree at $path for $branch: $err"
    return 1
  fi
  if [ "$label" = "main" ]; then MAIN_WT_CREATED=yes; else FEATURE_WT_CREATED=yes; fi
  set_worktree "$label" "$path"
  return 0
}

run_tests() {
  [ -n "$TEST_COMMAND" ] || return 0
  if ! ( cd "$FEATURE_WT" && bash -c "$TEST_COMMAND" ) >"$TMP_DIR/tests.out" 2>"$TMP_DIR/tests.err"; then
    cat "$TMP_DIR/tests.out" >&2
    cat "$TMP_DIR/tests.err" >&2
    TESTS_STATE="failed"
    HANDOFF="fix the failing tests in $FEATURE_WT and commit, rerun the tests, then merge/stop manually; do not rerun $PROG for this rewritten branch"
    finish_status "needs-ai" "tests" 2 "tests failed; continue on the feature branch"
  fi
  TRACKED_DIRTY=$(git -C "$FEATURE_WT" status --porcelain --untracked-files=no 2>/dev/null)
  if [ -n "$TRACKED_DIRTY" ]; then
    printf '%s\n' "$TRACKED_DIRTY" >&2
    TESTS_STATE="dirty"
    HANDOFF="commit or clean the tracked changes in $FEATURE_WT, then merge/stop manually; do not rerun $PROG for this rewritten branch"
    finish_status "needs-ai" "tests" 2 "tests left tracked changes; commit or clean before merge"
  fi
  TESTS_STATE="passed"
  F_VERIFIED=$(current_tip "$FEATURE")
  [ -n "$F_VERIFIED" ] || finish_status "failed" "tests" 1 "cannot resolve feature tip after tests"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --main)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      MAIN=$2
      shift 2
      ;;
    --feature)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      FEATURE=$2
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --no-ff)
      MODE="no-ff"
      shift
      ;;
    --stop-after-rebase)
      STOP_AFTER_REBASE=1
      shift
      ;;
    --keep-worktree)
      KEEP_WORKTREE=1
      shift
      ;;
    --main-worktree)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      MAIN_WT_ARG=$2
      shift 2
      ;;
    --feature-worktree)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      FEATURE_WT_ARG=$2
      shift 2
      ;;
    --test-command)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      TEST_COMMAND=$2
      shift 2
      ;;
    --no-fetch)
      DO_FETCH=0
      shift
      ;;
    --fetch)
      DO_FETCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fatal "unknown option: $1" 3
      ;;
  esac
done

if [ "$STOP_AFTER_REBASE" -eq 1 ] && [ "$MODE" = "no-ff" ]; then
  printf '%s: --no-ff ignored with --stop-after-rebase\n' "$PROG" >&2
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  fatal "not a git repository" 3
fi

TMP_DIR=$(mktemp -d "$TMP_BASE/rebase-merge-fast-flow.XXXXXX") || fatal "cannot create temporary directory" 3

# First pass: resolve branch defaults and find out which worktrees are missing.
if [ "$DO_FETCH" -eq 1 ]; then
  run_preflight --fetch
else
  run_preflight --no-fetch
fi
if [ "$PRE_RC" -eq 3 ]; then
  fatal "preflight usage error" 3
fi
if [ "$PRE_RC" -gt 3 ]; then
  print_preflight
  finish_status "failed" "preflight" 1 "preflight failed to run (exit=$PRE_RC)"
fi
if [ "$CHECK_ONLY" -eq 1 ]; then
  printf 'check=yes\n'
  [ "$STOP_AFTER_REBASE" -eq 1 ] && printf 'stop_after_rebase=yes\n'
  cat "$TMP_DIR/preflight.out"
  if [ -s "$TMP_DIR/preflight.err" ]; then
    cat "$TMP_DIR/preflight.err" >&2
  fi
  exit "$PRE_RC"
fi
if [ "$(preflight_get fetch)" = "failed" ]; then
  print_preflight
  QUESTION="git fetch failed; fix the remote and rerun $PROG"
  HANDOFF="ask the user to fix the remote, then rerun"
  finish_status "blocked" "preflight" 2 "git fetch failed"
fi
PF_ERROR=$(preflight_get error)
if [ -n "$PF_ERROR" ]; then
  print_preflight
  QUESTION=$PF_ERROR
  HANDOFF="resolve the reported branch error, then rerun $PROG with --main/--feature"
  finish_status "blocked" "preflight" 2 "$PF_ERROR"
fi
load_preflight
if [ -z "$MAIN" ] || [ -z "$FEATURE" ]; then
  print_preflight
  QUESTION="cannot resolve main/feature branch; pass --main and/or --feature"
  OPTIONS="provide --main <branch>"$'\n'"provide --feature <branch>"$'\n'"stop"
  HANDOFF="ask the user for the missing branch, then rerun $PROG with --main/--feature"
  finish_status "blocked" "preflight" 2 "branch unresolved"
fi

# Stop before creating any worktree if preflight already reports a blocker that
# a temporary worktree cannot fix.
if REASON=$(preflight_blocker_reason); then
  print_preflight
  QUESTION=$REASON
  HANDOFF="resolve the reported blocker, then rerun $PROG with the same arguments and worktree paths"
  finish_status "blocked" "preflight" 2 "$REASON"
fi

# Nothing to rebase or merge; no worktree needed unless main must be fast-forwarded.
if [ "$RELATION" = "synced" ] && [ "$MAIN_UPSTREAM_STATE" != "fast-forward" ]; then
  TESTS_STATE="not-run"
  finish_status "done" "done" 0
fi

# Fill in missing worktrees. A branch that is not checked out gets a temporary
# worktree under TMP_BASE; an explicit --*-worktree path is used as given.
if ! prepare_worktree "$MAIN_WT_ARG" "$MAIN" "main"; then
  print_preflight
  QUESTION=$WORKTREE_ERROR
  HANDOFF="resolve the worktree issue, then rerun $PROG with --main-worktree/--feature-worktree"
  finish_status "blocked" "preflight" 2 "$WORKTREE_ERROR"
fi
if ! prepare_worktree "$FEATURE_WT_ARG" "$FEATURE" "feature"; then
  print_preflight
  QUESTION=$WORKTREE_ERROR
  HANDOFF="resolve the worktree issue, then rerun $PROG with --main-worktree/--feature-worktree"
  finish_status "blocked" "preflight" 2 "$WORKTREE_ERROR"
fi

# Second pass: plan against the prepared worktrees. No second fetch.
run_preflight --no-fetch
if [ "$PRE_RC" -eq 3 ]; then
  fatal "preflight usage error" 3
fi
if [ "$PRE_RC" -gt 3 ]; then
  print_preflight
  finish_status "failed" "preflight" 1 "preflight failed to run (exit=$PRE_RC)"
fi
PF_ERROR=$(preflight_get error)
if [ -n "$PF_ERROR" ]; then
  print_preflight
  QUESTION=$PF_ERROR
  HANDOFF="resolve the reported preflight error, then rerun $PROG"
  finish_status "blocked" "preflight" 2 "$PF_ERROR"
fi
if [ "$PRE_RC" -ne 0 ]; then
  print_preflight
  load_preflight
  QUESTION=$(preflight_block_reason)
  HANDOFF="resolve the reported blocker, then rerun $PROG with the same arguments and worktree paths"
  finish_status "blocked" "preflight" 2 "preflight exit=$PRE_RC"
fi
load_preflight

if [ "$MAIN_UPSTREAM_STATE" = "fast-forward" ]; then
  if [ "$MAIN_STATE" != "existing" ] || [ -z "$MAIN_WT" ]; then
    print_preflight
    QUESTION="main worktree is missing; pass --main-worktree or let fast-flow create one"
    HANDOFF="resolve the main worktree, then rerun $PROG"
    finish_status "blocked" "preflight" 2 "main worktree missing"
  fi
  if ! git -C "$MAIN_WT" merge --ff-only "$MAIN_UPSTREAM" >"$TMP_DIR/ff.out" 2>"$TMP_DIR/ff.err"; then
    cat "$TMP_DIR/ff.err" >&2
    finish_status "failed" "preflight" 1 "fast-forward main failed"
  fi
  # Refresh the plan only; no second fetch.
  run_preflight --no-fetch
  if [ "$PRE_RC" -eq 3 ]; then
    fatal "preflight usage error" 3
  fi
  if [ "$PRE_RC" -gt 3 ]; then
    print_preflight
    finish_status "failed" "preflight" 1 "preflight failed to run (exit=$PRE_RC)"
  fi
  if [ "$PRE_RC" -ne 0 ]; then
    print_preflight
    load_preflight
    QUESTION=$(preflight_block_reason)
    HANDOFF="resolve the reported blocker, then rerun $PROG with the same arguments and worktree paths"
    finish_status "blocked" "preflight" 2 "preflight exit=$PRE_RC after main fast-forward"
  fi
  load_preflight
fi

if [ -z "$FEATURE_WT" ] || [ "$FEATURE_STATE" != "existing" ]; then
  QUESTION="feature worktree is missing; pass --feature-worktree or let fast-flow create one"
  HANDOFF="resolve the feature worktree, then rerun $PROG"
  finish_status "blocked" "preflight" 2 "feature worktree missing"
fi

if [ "$RELATION" != "synced" ] && \
   { [ -z "$MAIN_WT" ] || [ "$MAIN_STATE" != "existing" ]; }; then
  QUESTION="main worktree is missing; pass --main-worktree or let fast-flow create one"
  HANDOFF="resolve the main worktree, then rerun $PROG"
  finish_status "blocked" "preflight" 2 "main worktree missing"
fi

if [ "$RELATION" = "synced" ]; then
  TESTS_STATE="not-run"
  finish_status "done" "done" 0
fi

if [ "$RELATION" = "ahead-of-main" ]; then
  TESTS_STATE="not-run"
  F_VERIFIED=$(current_tip "$FEATURE")
  [ -n "$F_VERIFIED" ] || finish_status "failed" "preflight" 1 "cannot resolve feature tip"
  if [ "$STOP_AFTER_REBASE" -eq 1 ]; then
    MERGE_DONE="skipped"
    finish_status "done" "done" 0
  fi
fi

if [ "$RELATION" = "behind-main" ] || [ "$RELATION" = "diverged" ]; then
  REBASE_DONE="yes"
  if ! git -C "$FEATURE_WT" rebase "$MAIN" >"$TMP_DIR/rebase.out" 2>"$TMP_DIR/rebase.err"; then
    cat "$TMP_DIR/rebase.err" >&2
    git -C "$FEATURE_WT" status --short >&2 2>/dev/null || true
    print_preflight
    TESTS_STATE="not-run"
    HANDOFF="resolve the rebase conflict in $FEATURE_WT, continue the rebase, then run tests and merge/stop manually; do not rerun $PROG for this rewritten branch"
    finish_status "needs-ai" "rebase" 2 "rebase stopped; resolve the conflict or abort"
  fi
  F_VERIFIED=$(current_tip "$FEATURE")
  [ -n "$F_VERIFIED" ] || finish_status "failed" "rebase" 1 "cannot resolve feature tip after rebase"

  FEATURE_ONLY=$(git rev-list --count "$MAIN..$FEATURE")

  if [ "$RELATION" = "behind-main" ]; then
    if [ "$FEATURE_ONLY" -ne 0 ]; then
      finish_status "needs-ai" "rebase" 2 "behind-main produced feature commits; re-check the plan"
    fi
    TESTS_STATE="not-run"
    finish_status "done" "done" 0
  fi
  if [ "$FEATURE_ONLY" -eq 0 ]; then
    TESTS_STATE="not-run"
    finish_status "done" "done" 0
  fi

  if [ "$STOP_AFTER_REBASE" -eq 1 ]; then
    run_tests
    MERGE_DONE="skipped"
    finish_status "done" "done" 0
  fi
fi

# ahead-of-main and diverged reach here. Only diverged rewrites the feature
# commits and needs tests; ahead-of-main does not change commits.
if [ "$RELATION" = "diverged" ]; then
  run_tests
fi

if [ "$MODE" = "no-ff" ]; then
  if ! git -C "$MAIN_WT" merge --no-ff --no-edit "$F_VERIFIED" >"$TMP_DIR/merge.out" 2>"$TMP_DIR/merge.err"; then
    cat "$TMP_DIR/merge.err" >&2
    finish_status "failed" "merge" 1 "no-ff merge failed"
  fi
else
  if ! git -C "$MAIN_WT" merge --ff-only "$F_VERIFIED" >"$TMP_DIR/merge.out" 2>"$TMP_DIR/merge.err"; then
    cat "$TMP_DIR/merge.err" >&2
    finish_status "failed" "merge" 1 "ff-only merge failed"
  fi
fi
MERGE_DONE="$MODE"

finish_status "done" "done" 0
