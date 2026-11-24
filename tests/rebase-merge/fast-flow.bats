#!/usr/bin/env bats
# Behavioral tests for scripts/fast-flow.sh.

load helpers

setup_file() {
  build_base_fixture
}

setup() {
  setup_sandbox
}

@test "help exits 0 and prints usage" {
  run_fast_flow --help
  assert_exit 0
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown option exits 3" {
  run_fast_flow --wat
  assert_exit 3
  assert_field status failed
  assert_field stage usage
  assert_field message "unknown option: --wat"
  assert_field exit 3
}

@test "synced: finishes without creating a worktree" {
  build_relation_repo synced
  before=$(worktree_count)

  run_fast_flow --no-fetch
  assert_exit 0
  assert_field status done
  assert_field stage done
  assert_field relation synced
  assert_field tests not-run
  assert_field merge no
  assert_field temp_worktree none
  assert_field temp_worktree_cleaned n/a
  [ "$(worktree_count)" -eq "$before" ]
}

@test "behind-main: rebases feature and does not merge" {
  build_relation_repo behind-main
  develop_before=$(tip develop)

  run_fast_flow --no-fetch
  assert_exit 0
  assert_field status done
  assert_field stage done
  assert_field relation behind-main
  assert_field rebase yes
  assert_field tests not-run
  assert_field merge no
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" = "$develop_before" ]
}

@test "ahead-of-main: ff-only merges without running tests" {
  build_relation_repo ahead-of-main
  feature_before=$(tip feature)

  run_fast_flow --no-fetch
  assert_exit 0
  assert_field status done
  assert_field stage done
  assert_field relation ahead-of-main
  assert_field rebase no
  assert_field tests not-run
  assert_field merge ff-only
  [ "$(tip feature)" = "$feature_before" ]
  [ "$(tip develop)" = "$feature_before" ]
}

@test "ahead-of-main: missing main worktree is created temporarily" {
  cd "$SANDBOX/repo"
  git switch -q develop
  git switch -qc feature
  commit_file feature.txt feature feature
  feature_before=$(tip feature)

  run_fast_flow --no-fetch
  assert_exit 0
  assert_field status done
  assert_field relation ahead-of-main
  assert_field main_worktree_temp yes
  assert_field main_worktree_created yes
  assert_field feature_worktree_temp no
  assert_field temp_worktree main
  assert_field temp_worktree_cleaned yes
  [[ "$(field main_worktree)" == "$TMPDIR"/rebase-merge.* ]]
  [ ! -e "$(field main_worktree)" ]
  [ ! -e "$(field temp_worktree_root)" ]
  [ "$(tip develop)" = "$feature_before" ]
}

@test "keep-worktree: done keeps the temporary worktree" {
  cd "$SANDBOX/repo"
  git switch -q develop
  git switch -qc feature
  commit_file feature.txt feature feature

  run_fast_flow --no-fetch --keep-worktree
  assert_exit 0
  assert_field status done
  assert_field temp_worktree main
  assert_field temp_worktree_cleaned no
  [ -d "$(field main_worktree)" ]
  [ -d "$(field temp_worktree_root)" ]
}

@test "synced: cleans a temporary worktree left by a previous run" {
  build_relation_repo ahead-of-main

  run_fast_flow --no-fetch --keep-worktree
  assert_exit 0
  assert_field status done
  assert_field temp_worktree feature
  leftover=$(field feature_worktree)
  [ -d "$leftover" ]

  run_fast_flow --no-fetch
  assert_exit 0
  assert_field status done
  assert_field relation synced
  assert_field temp_worktree feature
  assert_field temp_worktree_cleaned yes
  [ ! -e "$leftover" ]
}

@test "diverged: rebase then tests then ff-only merge" {
  build_relation_repo diverged
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --no-fetch \
    --test-command "touch '$SANDBOX/tests-ran'"
  assert_exit 0
  assert_field status done
  assert_field stage done
  assert_field relation diverged
  assert_field rebase yes
  assert_field tests passed
  assert_field merge ff-only
  assert_field temp_worktree feature
  assert_field feature_worktree_temp yes
  assert_field feature_worktree_created yes
  assert_field temp_worktree_cleaned yes
  [[ "$(field feature_worktree)" == "$TMPDIR"/rebase-merge.* ]]
  [ ! -e "$(field feature_worktree)" ]
  [ ! -e "$(field temp_worktree_root)" ]
  [ -f "$SANDBOX/tests-ran" ]
  [ "$(tip develop)" != "$develop_before" ]
  [ "$(tip feature)" != "$feature_before" ]
  [ "$(tip develop)" = "$(tip feature)" ]
}

@test "diverged without a test command reports tests skipped" {
  build_relation_repo diverged

  run_fast_flow --no-fetch
  assert_exit 0
  assert_field status done
  assert_field relation diverged
  assert_field tests skipped
  assert_field merge ff-only
}

@test "diverged: temporary main and feature worktrees are both cleaned on success" {
  build_relation_repo diverged
  cd "$SANDBOX/repo"
  git switch -q main

  run_fast_flow --no-fetch
  assert_exit 0
  assert_field status done
  assert_field relation diverged
  assert_field temp_worktree both
  assert_field main_worktree_created yes
  assert_field feature_worktree_created yes
  assert_field temp_worktree_cleaned yes
  [ ! -e "$(field main_worktree)" ]
  [ ! -e "$(field feature_worktree)" ]
  [ ! -e "$(field temp_worktree_root)" ]
  [ "$(tip develop)" = "$(tip feature)" ]
}

@test "diverged: failing tests stop before merge" {
  build_relation_repo diverged
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --no-fetch --test-command false
  assert_exit 2
  assert_field status needs-ai
  assert_field stage tests
  assert_field relation diverged
  assert_field rebase yes
  assert_field tests failed
  assert_field merge no
  assert_field temp_worktree_cleaned no
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" != "$feature_before" ]
  [ -d "$(field feature_worktree)" ]
  [[ "$(field handoff)" == *"fix the failing tests"* ]]
}

@test "diverged: tests leaving tracked changes stop before merge" {
  build_relation_repo diverged
  develop_before=$(tip develop)

  run_fast_flow --no-fetch --test-command 'echo dirty >> feature.txt'
  assert_exit 2
  assert_field status needs-ai
  assert_field stage tests
  assert_field tests dirty
  assert_field merge no
  [ "$(tip develop)" = "$develop_before" ]
  [ -n "$(git -C "$(field feature_worktree)" status --porcelain --untracked-files=no)" ]
}

@test "diverged: cleanup failure keeps the temporary worktree and reports why" {
  build_relation_repo diverged

  run_fast_flow --no-fetch --test-command "touch leftover"
  assert_exit 0
  assert_field status done
  assert_field temp_worktree feature
  assert_field temp_worktree_cleaned no
  [[ "$(field temp_worktree_cleanup_error)" == *"cannot remove feature worktree"* ]]
  [ -e "$(field feature_worktree)/leftover" ]
}

@test "diverged: rebase conflict hands off and preserves the worktree" {
  build_conflict_repo
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --no-fetch
  assert_exit 2
  assert_field status needs-ai
  assert_field stage rebase
  assert_field relation diverged
  assert_field rebase yes
  assert_field tests not-run
  assert_field merge no
  assert_field temp_worktree_cleaned no
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" = "$feature_before" ]
  [ -d "$(field feature_worktree)" ]
  rebase_in_progress "$(field feature_worktree)"
}

@test "stop-after-rebase: diverged rebases and tests but never merges" {
  build_relation_repo diverged
  develop_before=$(tip develop)

  run_fast_flow --no-fetch --stop-after-rebase \
    --test-command "touch '$SANDBOX/tests-ran'"
  assert_exit 0
  assert_field status done
  assert_field stage done
  assert_field relation diverged
  assert_field rebase yes
  assert_field tests passed
  assert_field merge skipped
  assert_field temp_worktree_cleaned yes
  [ -f "$SANDBOX/tests-ran" ]
  [ "$(tip develop)" = "$develop_before" ]
}

@test "stop-after-rebase: ahead-of-main does not merge or test" {
  build_relation_repo ahead-of-main
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --no-fetch --stop-after-rebase
  assert_exit 0
  assert_field status done
  assert_field relation ahead-of-main
  assert_field tests not-run
  assert_field merge skipped
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" = "$feature_before" ]
}

@test "stop-after-rebase: behind-main rebases and reports merge=no" {
  build_relation_repo behind-main
  develop_before=$(tip develop)

  run_fast_flow --no-fetch --stop-after-rebase
  assert_exit 0
  assert_field status done
  assert_field relation behind-main
  assert_field rebase yes
  assert_field tests not-run
  assert_field merge no
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" = "$develop_before" ]
}

@test "no-ff: ahead-of-main creates a merge commit with the expected parents" {
  build_relation_repo ahead-of-main
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --no-fetch --no-ff
  assert_exit 0
  assert_field status done
  assert_field merge no-ff
  [ "$(tip develop)" != "$develop_before" ]

  read -r merge_commit parent1 parent2 <<<"$(git -C "$SANDBOX/repo" rev-list --parents -n 1 develop)"
  [ -n "$merge_commit" ]
  [ "$parent1" = "$develop_before" ]
  [ "$parent2" = "$feature_before" ]
}

@test "check: prints the plan and changes nothing" {
  build_relation_repo diverged
  add_feature_worktree
  before_count=$(worktree_count)
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --check --no-fetch
  assert_exit 0
  assert_field check yes
  assert_field relation diverged
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" = "$feature_before" ]
  [ "$(worktree_count)" -eq "$before_count" ]
}

@test "check: missing feature worktree is reported without creating it" {
  build_relation_repo diverged
  before_count=$(worktree_count)

  run_fast_flow --check --no-fetch
  assert_exit 2
  assert_field check yes
  assert_field feature_worktree_state missing
  [ "$(worktree_count)" -eq "$before_count" ]
}

@test "explicit feature worktree is reused and not marked temporary" {
  build_relation_repo diverged
  add_feature_worktree

  run_fast_flow --no-fetch --feature-worktree "$SANDBOX/feature-wt"
  assert_exit 0
  assert_field status done
  assert_field feature_worktree "$SANDBOX/feature-wt"
  assert_field feature_worktree_temp no
  assert_field feature_worktree_created no
  assert_field temp_worktree none
  assert_field temp_worktree_cleaned n/a
  [ "$(tip develop)" = "$(tip feature)" ]
}

@test "fetch failure blocks before touching branches" {
  build_relation_repo diverged
  add_feature_worktree
  git -C "$SANDBOX/repo" remote add origin "$SANDBOX/missing.git"
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --main develop --feature feature
  assert_exit 2
  assert_field status blocked
  assert_field stage preflight
  assert_field message "git fetch failed"
  [[ "$(field question)" == *"git fetch failed"* ]]
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" = "$feature_before" ]
}

@test "missing feature branch blocks with a question" {
  build_relation_repo synced

  run_fast_flow --feature nope --no-fetch
  assert_exit 2
  assert_field status blocked
  assert_field stage preflight
  [[ "$(field question)" == *"feature branch is not local: nope"* ]]
}

@test "dirty feature worktree blocks before rebase" {
  build_relation_repo diverged
  add_feature_worktree
  printf 'dirty\n' >>"$SANDBOX/feature-wt/feature.txt"
  develop_before=$(tip develop)
  feature_before=$(tip feature)

  run_fast_flow --main develop --feature feature --no-fetch
  assert_exit 2
  assert_field status blocked
  assert_field stage preflight
  [[ "$(field question)" == *"feature worktree is dirty"* ]]
  [ "$(tip develop)" = "$develop_before" ]
  [ "$(tip feature)" = "$feature_before" ]
}

@test "develop behind upstream is fast-forwarded before the flow" {
  build_relation_repo synced
  init_remote
  push_branch develop
  advance_remote_branch develop develop.txt remote remote
  remote_develop=$(git -C "$SANDBOX/remote.git" rev-parse develop)

  run_fast_flow --main develop --feature feature
  assert_exit 0
  assert_field status done
  assert_field relation behind-main
  assert_field rebase yes
  assert_field tests not-run
  assert_field merge no
  [ "$(tip develop)" = "$remote_develop" ]
  [ "$(tip feature)" = "$remote_develop" ]
}

@test "stop-after-rebase ignores no-ff with a warning" {
  build_relation_repo ahead-of-main

  run_fast_flow --no-fetch --stop-after-rebase --no-ff
  assert_exit 0
  assert_field merge skipped
  [[ "$output" == *"--no-ff ignored with --stop-after-rebase"* ]]
}
