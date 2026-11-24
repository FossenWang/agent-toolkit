#!/usr/bin/env bash
# Read-only preflight for the rebase-merge skill.
#
# Input: --main/--feature/--no-fetch/--max-commits (see --help).
# Output: key=value lines on stdout. Main groups: main_*/feature_* (branch,
# worktree, cleanliness, upstream state), commits_*/merge_base/relation,
# feature_rewritten/feature_push, current_*/temp_worktree_needed, *_commit
# subjects, exit.
# Exit codes:
#   0  ready to proceed
#   1  blocked (dirty worktree, unfinished operation, feature behind upstream,
#      main diverged, fetch failed)
#   2  needs user input (branch/worktree unresolved)
#   3  usage error

set -u
set -o pipefail

PROG=${0##*/}
MAIN_BRANCH=""
FEATURE_BRANCH=""
DO_FETCH=1
MAX_COMMITS=50
NEED_USER=0
BLOCKED=0
EXIT_CODE=""
OUT=""

usage() {
  cat <<EOF
Usage: $PROG [options]

Read-only preflight for the rebase-merge skill.

Inputs:
  -m, --main <branch>       Main branch (default: main worktree's branch)
  -f, --feature <branch>    Feature branch (default: current branch)
      --no-fetch            Do not run git fetch
      --fetch               Run git fetch --all --prune (default)
      --max-commits <n>     Max commit titles per side (default: 50)
  -h, --help                Show this help

Output:
  key=value lines on stdout. Main groups:
    fetch                   ok / skipped / no-remotes / failed
    main_* / feature_*      branch, worktree, cleanliness, upstream state
    main_upstream_state     no-upstream / up-to-date / local-ahead / fast-forward / diverged
    feature_upstream_state  no-upstream / up-to-date / local-ahead / local-behind / diverged
    merge_base, commits_*   relationship and counts
    relation                synced / behind-main / ahead-of-main / diverged
    feature_rewritten       yes / no
    feature_push            upstream-blocked / create-upstream / normal / force-with-lease
    feature_commits_on_any_remote  yes / no
    current_*               branch role and whether current worktree will change
    temp_worktree_needed    main / feature / both / none
    *_commit=               commit subjects (newest first)
    exit=                   final exit code

Exit: 0 ready, 1 blocked, 2 needs user input, 3 usage error.
EOF
}

emit() {
  OUT="${OUT}$1=$2"$'\n'
}

emit_comment() {
  OUT="${OUT}$1"$'\n'
}

finish() {
  local code
  if [ -n "$EXIT_CODE" ]; then
    code=$EXIT_CODE
  elif [ "$NEED_USER" -eq 1 ]; then
    code=2
  elif [ "$BLOCKED" -eq 1 ]; then
    code=1
  else
    code=0
  fi
  emit "exit" "$code"
  printf '%s' "$OUT"
  exit "$code"
}

fatal() {
  local message=$1 code=${2:-2}
  printf '%s: %s\n' "$PROG" "$message" >&2
  emit "error" "$message"
  EXIT_CODE=$code
  finish
}

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--main)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      MAIN_BRANCH=$2
      shift 2
      ;;
    -f|--feature)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      FEATURE_BRANCH=$2
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
    --max-commits)
      [ $# -ge 2 ] || fatal "missing value for $1" 3
      MAX_COMMITS=$2
      case "$MAX_COMMITS" in
        ''|*[!0-9]*) fatal "invalid --max-commits: $MAX_COMMITS" 3 ;;
      esac
      shift 2
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

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  fatal "not a git repository" 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || \
  fatal "not inside a worktree (bare repository?)" 2

# --- worktree inventory -----------------------------------------------------

WT_RECORDS=""
WT_MAIN_PATH=""
WT_MAIN_BRANCH=""
WT_PATH=""
WT_BRANCH=""

flush_worktree() {
  if [ -n "$WT_PATH" ]; then
    if [ -z "$WT_MAIN_PATH" ]; then
      WT_MAIN_PATH=$WT_PATH
      WT_MAIN_BRANCH=$WT_BRANCH
    fi
    WT_RECORDS="${WT_RECORDS}${WT_PATH}"$'\t'"${WT_BRANCH}"$'\n'
    WT_PATH=""
    WT_BRANCH=""
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    worktree\ *) WT_PATH=${line#worktree } ;;
    branch\ refs/heads/*) WT_BRANCH=${line#branch refs/heads/} ;;
    "") flush_worktree ;;
  esac
done < <(git worktree list --porcelain)
flush_worktree

worktree_for_branch() {
  local want=$1 path branch
  while IFS=$'\t' read -r path branch; do
    [ -n "$path" ] || continue
    if [ "$branch" = "$want" ]; then
      printf '%s' "$path"
      return 0
    fi
  done <<< "$WT_RECORDS"
  return 1
}

is_local_branch() {
  git show-ref --verify --quiet "refs/heads/$1"
}

upstream_of() {
  git rev-parse --abbrev-ref --symbolic-full-name "$1@{u}" 2>/dev/null || true
}

ahead_behind() {
  # $1 = branch, $2 = upstream; prints "<ahead> <behind>"
  git rev-list --left-right --count "$1...$2" 2>/dev/null || printf '0 0'
}

# --- arguments and branches -------------------------------------------------

if [ -z "$MAIN_BRANCH" ]; then
  MAIN_BRANCH=$WT_MAIN_BRANCH
fi
if [ -z "$MAIN_BRANCH" ]; then
  fatal "main branch unresolved: main worktree is detached; pass --main" 2
fi

if [ -z "$FEATURE_BRANCH" ]; then
  FEATURE_BRANCH=$(git branch --show-current 2>/dev/null || true)
fi
if [ -z "$FEATURE_BRANCH" ]; then
  fatal "feature branch unresolved: current HEAD is detached; pass --feature" 2
fi
if [ "$MAIN_BRANCH" = "$FEATURE_BRANCH" ]; then
  fatal "main and feature are the same branch: $MAIN_BRANCH" 2
fi

is_local_branch "$MAIN_BRANCH" || fatal "main branch is not local: $MAIN_BRANCH" 2
is_local_branch "$FEATURE_BRANCH" || fatal "feature branch is not local: $FEATURE_BRANCH" 2

MAIN_TIP=$(git rev-parse "$MAIN_BRANCH")
FEATURE_TIP=$(git rev-parse "$FEATURE_BRANCH")
MAIN_WT=$(worktree_for_branch "$MAIN_BRANCH" || true)
FEATURE_WT=$(worktree_for_branch "$FEATURE_BRANCH" || true)

MAIN_WT_STATE=missing
if [ -n "$MAIN_WT" ]; then
  if [ -d "$MAIN_WT" ]; then
    MAIN_WT_STATE=existing
  else
    MAIN_WT_STATE=prunable
  fi
fi

FEATURE_WT_STATE=missing
if [ -n "$FEATURE_WT" ]; then
  if [ -d "$FEATURE_WT" ]; then
    FEATURE_WT_STATE=existing
  else
    FEATURE_WT_STATE=prunable
  fi
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)
CURRENT_WT=$(git rev-parse --show-toplevel 2>/dev/null || true)

emit "main_branch" "$MAIN_BRANCH"
emit "main_tip" "$MAIN_TIP"
emit "main_worktree" "$MAIN_WT"
emit "main_worktree_state" "$MAIN_WT_STATE"
emit "feature_branch" "$FEATURE_BRANCH"
emit "feature_tip" "$FEATURE_TIP"
emit "feature_worktree" "$FEATURE_WT"
emit "feature_worktree_state" "$FEATURE_WT_STATE"
emit "current_branch" "$CURRENT_BRANCH"
emit "current_worktree" "$CURRENT_WT"
emit "repo_root" "$REPO_ROOT"

if [ "$FEATURE_WT_STATE" = missing ]; then
  NEED_USER=1
  emit_comment "# feature worktree is missing; create one or pass a checked-out branch"
elif [ "$FEATURE_WT_STATE" = prunable ]; then
  NEED_USER=1
  emit_comment "# feature worktree path is missing; run git worktree prune or recreate it"
fi

if [ "$MAIN_WT_STATE" = prunable ]; then
  NEED_USER=1
  emit_comment "# main worktree path is missing; run git worktree prune or recreate it"
fi

TEMP_WORKTREE=""
if [ "$MAIN_WT_STATE" = missing ]; then
  TEMP_WORKTREE=main
fi
if [ "$FEATURE_WT_STATE" = missing ]; then
  if [ -n "$TEMP_WORKTREE" ]; then
    TEMP_WORKTREE=both
  else
    TEMP_WORKTREE=feature
  fi
fi
emit "temp_worktree_needed" "${TEMP_WORKTREE:-none}"

# --- fetch ------------------------------------------------------------------

if [ "$DO_FETCH" -eq 1 ]; then
  REMOTES=$(git remote 2>/dev/null || true)
  if [ -z "$REMOTES" ]; then
    emit "fetch" "no-remotes"
  elif git fetch --all --prune --no-tags >&2; then
    emit "fetch" "ok"
  else
    emit "fetch" "failed"
    printf '%s: git fetch failed\n' "$PROG" >&2
    BLOCKED=1
  fi
else
  emit "fetch" "skipped"
fi

# --- cleanliness and unfinished operations ---------------------------------

check_worktree() {
  local path=$1 label=$2 status count op marker marker_path
  if [ ! -d "$path" ]; then
    emit "${label}_clean" "n/a"
    emit "${label}_dirty_count" "n/a"
    emit "${label}_in_progress" "n/a"
    return 1
  fi

  status=$(git -C "$path" status --porcelain 2>/dev/null) || {
    emit "${label}_clean" "unknown"
    emit "${label}_dirty_count" "unknown"
    emit "${label}_in_progress" "unknown"
    return 1
  }

  if [ -n "$status" ]; then
    count=$(printf '%s\n' "$status" | wc -l | tr -d ' ')
    emit "${label}_clean" "no"
    emit "${label}_dirty_count" "$count"
  else
    emit "${label}_clean" "yes"
    emit "${label}_dirty_count" "0"
  fi

  op=""
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD sequencer; do
    marker_path=$(git -C "$path" rev-parse --git-path "$marker" 2>/dev/null) || continue
    [ -n "$marker_path" ] || continue
    if [ -e "$marker_path" ] || [ -e "$path/$marker_path" ]; then
      case "$marker" in
        rebase-merge|rebase-apply) op=rebase ;;
        MERGE_HEAD) op=merge ;;
        CHERRY_PICK_HEAD) op=cherry-pick ;;
        REVERT_HEAD) op=revert ;;
        sequencer) op=sequencer ;;
        *) op=$marker ;;
      esac
      break
    fi
  done

  if [ -n "$op" ]; then
    emit "${label}_in_progress" "$op"
  else
    emit "${label}_in_progress" "none"
  fi

  if [ -n "$status" ] || [ -n "$op" ]; then
    return 1
  fi
  return 0
}

if [ "$MAIN_WT_STATE" = existing ]; then
  check_worktree "$MAIN_WT" "main" || BLOCKED=1
else
  emit "main_clean" "n/a"
  emit "main_dirty_count" "n/a"
  emit "main_in_progress" "n/a"
fi

if [ "$FEATURE_WT_STATE" = existing ]; then
  check_worktree "$FEATURE_WT" "feature" || BLOCKED=1
else
  emit "feature_clean" "n/a"
  emit "feature_dirty_count" "n/a"
  emit "feature_in_progress" "n/a"
fi

# --- upstream state ---------------------------------------------------------

MAIN_UPSTREAM=$(upstream_of "$MAIN_BRANCH")
MAIN_AHEAD=0
MAIN_BEHIND=0
MAIN_UPSTREAM_STATE=no-upstream
MAIN_NEEDS_FF=no
if [ -n "$MAIN_UPSTREAM" ]; then
  read -r MAIN_AHEAD MAIN_BEHIND <<< "$(ahead_behind "$MAIN_BRANCH" "$MAIN_UPSTREAM")"
  if [ "$MAIN_BEHIND" -gt 0 ] && [ "$MAIN_AHEAD" -gt 0 ]; then
    MAIN_UPSTREAM_STATE=diverged
    BLOCKED=1
  elif [ "$MAIN_BEHIND" -gt 0 ]; then
    MAIN_UPSTREAM_STATE=fast-forward
    MAIN_NEEDS_FF=yes
  elif [ "$MAIN_AHEAD" -gt 0 ]; then
    MAIN_UPSTREAM_STATE=local-ahead
  else
    MAIN_UPSTREAM_STATE=up-to-date
  fi
fi
emit "main_upstream" "${MAIN_UPSTREAM:-none}"
emit "main_upstream_ahead" "$MAIN_AHEAD"
emit "main_upstream_behind" "$MAIN_BEHIND"
emit "main_upstream_state" "$MAIN_UPSTREAM_STATE"
if [ "$MAIN_NEEDS_FF" = "yes" ]; then
  emit_comment "# main is behind upstream; fast-forward and re-run before trusting counts"
fi

FEATURE_UPSTREAM=$(upstream_of "$FEATURE_BRANCH")
FEATURE_AHEAD=0
FEATURE_BEHIND=0
FEATURE_UPSTREAM_STATE=no-upstream
if [ -n "$FEATURE_UPSTREAM" ]; then
  read -r FEATURE_AHEAD FEATURE_BEHIND <<< "$(ahead_behind "$FEATURE_BRANCH" "$FEATURE_UPSTREAM")"
  if [ "$FEATURE_BEHIND" -gt 0 ] && [ "$FEATURE_AHEAD" -gt 0 ]; then
    FEATURE_UPSTREAM_STATE=diverged
    BLOCKED=1
  elif [ "$FEATURE_BEHIND" -gt 0 ]; then
    FEATURE_UPSTREAM_STATE=local-behind
    BLOCKED=1
  elif [ "$FEATURE_AHEAD" -gt 0 ]; then
    FEATURE_UPSTREAM_STATE=local-ahead
  else
    FEATURE_UPSTREAM_STATE=up-to-date
  fi
fi
emit "feature_upstream" "${FEATURE_UPSTREAM:-none}"
emit "feature_upstream_ahead" "$FEATURE_AHEAD"
emit "feature_upstream_behind" "$FEATURE_BEHIND"
emit "feature_upstream_state" "$FEATURE_UPSTREAM_STATE"

FEATURE_UPSTREAM_IN_MAIN=no
if [ -n "$FEATURE_UPSTREAM" ] && git merge-base --is-ancestor "$FEATURE_UPSTREAM" "$MAIN_BRANCH" 2>/dev/null; then
  FEATURE_UPSTREAM_IN_MAIN=yes
fi

# --- branch relationships ---------------------------------------------------

MAIN_ONLY=$(git rev-list --count "$FEATURE_BRANCH..$MAIN_BRANCH")
FEATURE_ONLY=$(git rev-list --count "$MAIN_BRANCH..$FEATURE_BRANCH")
MERGE_BASE=$(git merge-base "$MAIN_BRANCH" "$FEATURE_BRANCH" 2>/dev/null) || true
if [ -z "$MERGE_BASE" ]; then
  emit "merge_base" ""
  BLOCKED=1
  emit_comment "# no merge base; histories are unrelated"
else
  emit "merge_base" "$MERGE_BASE"
fi

emit "commits_main_only" "$MAIN_ONLY"
emit "commits_feature_only" "$FEATURE_ONLY"

if [ "$MAIN_ONLY" -eq 0 ] && [ "$FEATURE_ONLY" -eq 0 ]; then
  RELATION=synced
elif [ "$MAIN_ONLY" -gt 0 ] && [ "$FEATURE_ONLY" -eq 0 ]; then
  RELATION=behind-main
elif [ "$MAIN_ONLY" -eq 0 ] && [ "$FEATURE_ONLY" -gt 0 ]; then
  RELATION=ahead-of-main
else
  RELATION=diverged
fi
emit "relation" "$RELATION"

if [ "$RELATION" = "diverged" ]; then
  FEATURE_REWRITTEN=yes
else
  FEATURE_REWRITTEN=no
fi
emit "feature_rewritten" "$FEATURE_REWRITTEN"

case "$FEATURE_UPSTREAM_STATE" in
  local-behind|diverged)
    FEATURE_PUSH=upstream-blocked
    ;;
  no-upstream)
    FEATURE_PUSH=create-upstream
    ;;
  *)
    if [ "$FEATURE_REWRITTEN" = "no" ] || [ "$FEATURE_UPSTREAM_IN_MAIN" = "yes" ]; then
      FEATURE_PUSH=normal
    else
      FEATURE_PUSH=force-with-lease
    fi
    ;;
esac
emit "feature_push" "$FEATURE_PUSH"

# Commits present on any remote are informational: they are not necessarily on
# the feature branch's own upstream. The push action above uses the upstream,
# not this flag.
FEATURE_NOT_ON_REMOTE=$(git rev-list --count "$MAIN_BRANCH..$FEATURE_BRANCH" --not --remotes)
if [ "$FEATURE_ONLY" -gt "$FEATURE_NOT_ON_REMOTE" ]; then
  emit "feature_commits_on_any_remote" "yes"
else
  emit "feature_commits_on_any_remote" "no"
fi

# --- current worktree impact ------------------------------------------------

CURRENT_ROLE=other
if [ "$CURRENT_BRANCH" = "$FEATURE_BRANCH" ]; then
  CURRENT_ROLE=feature
elif [ "$CURRENT_BRANCH" = "$MAIN_BRANCH" ]; then
  CURRENT_ROLE=main
fi
emit "current_branch_role" "$CURRENT_ROLE"

CURRENT_CHANGE=no
case "$RELATION" in
  behind-main)
    if [ "$CURRENT_ROLE" = "feature" ]; then
      CURRENT_CHANGE=yes
    fi
    ;;
  ahead-of-main)
    if [ "$CURRENT_ROLE" = "main" ]; then
      CURRENT_CHANGE=yes
    fi
    ;;
  diverged)
    if [ "$CURRENT_ROLE" = "feature" ] || [ "$CURRENT_ROLE" = "main" ]; then
      CURRENT_CHANGE=yes
    fi
    ;;
esac
if [ "$CURRENT_ROLE" = "main" ] && [ "$MAIN_NEEDS_FF" = "yes" ]; then
  CURRENT_CHANGE=yes
fi
emit "current_worktree_change" "$CURRENT_CHANGE"

# --- commit titles for the report ------------------------------------------

emit_titles() {
  local label=$1 range=$2 total=$3 titles subject n=0
  [ "$total" -gt 0 ] || return 0
  titles=$(git --no-pager log --format=%s "$range" -- 2>/dev/null || true)
  [ -n "$titles" ] || return 0
  while IFS= read -r subject; do
    n=$((n + 1))
    if [ "$n" -gt "$MAX_COMMITS" ]; then
      break
    fi
    emit "${label}_commit" "$subject"
  done <<< "$titles"
  if [ "$total" -gt "$MAX_COMMITS" ]; then
    emit "${label}_commit_omitted" "$((total - MAX_COMMITS))"
  fi
}

emit_titles "main_only" "$FEATURE_BRANCH..$MAIN_BRANCH" "$MAIN_ONLY"
emit_titles "feature_only" "$MAIN_BRANCH..$FEATURE_BRANCH" "$FEATURE_ONLY"
if [ -n "$MERGE_BASE" ]; then
  emit "base_commit" "$(git --no-pager log -1 --format=%s "$MERGE_BASE" -- 2>/dev/null || true)"
fi

finish
