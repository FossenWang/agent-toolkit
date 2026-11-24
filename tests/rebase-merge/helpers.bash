# Shared helpers for the rebase-merge bats suite.
#
# The suite is black-box: every case builds a real Git sandbox and invokes the
# scripts the same way a user would. No Git commands are mocked.

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/workflow/rebase-merge" && pwd)
PREFLIGHT="$SKILL_DIR/scripts/preflight.sh"
FAST_FLOW="$SKILL_DIR/scripts/fast-flow.sh"

prepare_env() { # tmpdir
  # Keep the host's Git config, hooks, and identity out of the fixtures.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test
  export GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test
  export GIT_COMMITTER_EMAIL=test@example.com
  export GIT_TERMINAL_PROMPT=0
  export HOME="$1/home"
  export TMPDIR="$1/tmp"
  mkdir -p "$HOME" "$TMPDIR"
}

build_base_fixture() {
  # One template per .bats file: main is the untouched baseline, develop is M.
  BASE_REPO="$BATS_FILE_TMPDIR/base-repo"
  prepare_env "$BATS_FILE_TMPDIR"
  init_repo "$BASE_REPO"
  cd "$BASE_REPO"
  commit_file README.md "base readme" "base readme"
  commit_file app.txt "base app" "base app"
  git switch -qc develop
  commit_file develop.txt "develop base" "develop base"
}

setup_sandbox() {
  prepare_env "$BATS_TEST_TMPDIR"
  BASE_REPO="${BASE_REPO:-$BATS_FILE_TMPDIR/base-repo}"
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX"
  cp -a "$BASE_REPO" "$SANDBOX/repo"
  cd "$SANDBOX"
}

init_repo() {
  git init -q -b main "$1"
}

init_remote() {
  git init -q --bare "$SANDBOX/remote.git"
  git -C "$SANDBOX/remote.git" symbolic-ref HEAD refs/heads/develop
  git -C "$SANDBOX/repo" remote add origin "$SANDBOX/remote.git"
}

commit_file() { # file content message
  local file=$1 content=$2 message=$3
  printf '%s\n' "$content" >"$file"
  git add "$file"
  git commit -q -m "$message"
}

commit_file_in() { # repo file content message
  local repo=$1 file=$2 content=$3 message=$4
  printf '%s\n' "$content" >"$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -q -m "$message"
}

build_relation_repo() { # synced | behind-main | ahead-of-main | diverged
  local relation=$1
  cd "$SANDBOX/repo"
  git switch -q develop
  git switch -qc feature
  case "$relation" in
    ahead-of-main|diverged) commit_file feature.txt feature feature ;;
  esac

  git switch -q develop
  case "$relation" in
    behind-main|diverged) commit_file develop.txt "develop extra" "develop extra" ;;
  esac
}

build_conflict_repo() {
  cd "$SANDBOX/repo"
  git switch -q develop
  git switch -qc feature
  commit_file shared.txt feature feature

  git switch -q develop
  commit_file shared.txt develop develop
}

add_feature_worktree() {
  git -C "$SANDBOX/repo" worktree add -q "$SANDBOX/feature-wt" feature
}

push_branch() { # branch
  git -C "$SANDBOX/repo" push -q -u origin "$1"
}

clone_remote() {
  git clone -q "$SANDBOX/remote.git" "$SANDBOX/other"
}

advance_remote_branch() { # branch file content message
  local branch=$1 file=$2 content=$3 message=$4
  clone_remote
  git -C "$SANDBOX/other" switch -q "$branch"
  commit_file_in "$SANDBOX/other" "$file" "$content" "$message"
  git -C "$SANDBOX/other" push -q origin "$branch"
}

tip() { # rev
  git -C "$SANDBOX/repo" rev-parse "$1"
}

worktree_count() {
  git -C "$SANDBOX/repo" worktree list --porcelain | grep -c '^worktree '
}

marker_path() { # worktree path, marker name
  local path=$1 marker=$2 marker_path
  marker_path=$(git -C "$path" rev-parse --git-path "$marker")
  case "$marker_path" in
    /*) printf '%s' "$marker_path" ;;
    *) printf '%s/%s' "$path" "$marker_path" ;;
  esac
}

rebase_in_progress() { # worktree path
  [ -d "$(marker_path "$1" rebase-merge)" ] || [ -d "$(marker_path "$1" rebase-apply)" ]
}

run_preflight() {
  run bash "$PREFLIGHT" "$@"
}

run_fast_flow() {
  # Every fast-flow fixture uses the same branch names. Passing them explicitly
  # also covers the common case where the current branch is the main worktree's branch.
  run bash "$FAST_FLOW" --main develop --feature feature "$@"
}

field() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p" | tail -n 1
}

field_all() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p"
}

field_count() {
  local count
  count=$(printf '%s\n' "$output" | grep -c "^$1=" || true)
  printf '%s' "$count"
}

assert_field() {
  local key=$1 want=$2 got
  got=$(field "$key")
  if [ "$got" != "$want" ]; then
    printf 'expected %s=%s, got %s\n' "$key" "$want" "${got:-<missing>}" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

assert_exit() {
  local want=$1
  if [ "$status" -ne "$want" ]; then
    printf 'expected exit=%s, got %s\n' "$want" "$status" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}
