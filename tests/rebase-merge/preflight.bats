#!/usr/bin/env bats
# Behavioral tests for scripts/preflight.sh.

load helpers

setup_file() {
  build_base_fixture
}

setup() {
  setup_sandbox
}

@test "help exits 0 and prints usage" {
  run_preflight --help
  assert_exit 0
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown option exits 3" {
  run_preflight --wat
  assert_exit 3
  assert_field error "unknown option: --wat"
  assert_field exit 3
}

@test "outside a git repository exits 2" {
  cd "$BATS_TEST_TMPDIR"
  run_preflight --no-fetch
  assert_exit 2
  assert_field error "not a git repository"
}

@test "develop and feature the same exits 2" {
  build_relation_repo synced
  add_feature_worktree

  run_preflight --main develop --feature develop --no-fetch
  assert_exit 2
  assert_field error "main and feature are the same branch: develop"
}

@test "missing local feature branch exits 2" {
  build_relation_repo synced

  run_preflight --main develop --feature nope --no-fetch
  assert_exit 2
  assert_field error "feature branch is not local: nope"
}

@test "synced: no commits on either side" {
  build_relation_repo synced
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field relation synced
  assert_field commits_main_only 0
  assert_field commits_feature_only 0
  assert_field feature_rewritten no
  assert_field feature_push create-upstream
  assert_field temp_worktree_needed none
  assert_field main_worktree_state existing
  assert_field feature_worktree_state existing
  assert_field current_branch_role feature
  assert_field current_worktree_change no
}

@test "behind-main: develop has commits, feature has none" {
  build_relation_repo behind-main
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field relation behind-main
  assert_field commits_main_only 1
  assert_field commits_feature_only 0
  assert_field feature_rewritten no
  assert_field current_branch_role feature
  assert_field current_worktree_change yes
}

@test "ahead-of-main: feature has commits, develop has none" {
  build_relation_repo ahead-of-main
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field relation ahead-of-main
  assert_field commits_main_only 0
  assert_field commits_feature_only 1
  assert_field feature_rewritten no
  assert_field current_branch_role feature
  assert_field current_worktree_change no
}

@test "diverged: feature is marked rewritten" {
  build_relation_repo diverged
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field relation diverged
  assert_field commits_main_only 1
  assert_field commits_feature_only 1
  assert_field feature_rewritten yes
  assert_field feature_push create-upstream
  assert_field current_branch_role feature
  assert_field current_worktree_change yes
}

@test "missing feature worktree asks for input" {
  build_relation_repo diverged

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 2
  assert_field feature_worktree_state missing
  assert_field temp_worktree_needed feature
}

@test "prunable feature worktree asks for input" {
  build_relation_repo diverged
  add_feature_worktree
  rm -rf "$SANDBOX/feature-wt"

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 2
  assert_field feature_worktree_state prunable
  assert_field temp_worktree_needed none
  [[ "$output" == *"feature worktree path is missing"* ]]
}

@test "dirty feature worktree blocks" {
  build_relation_repo diverged
  add_feature_worktree
  printf 'dirty\n' >>"$SANDBOX/feature-wt/feature.txt"

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 1
  assert_field main_clean yes
  assert_field feature_clean no
  assert_field feature_dirty_count 1
  assert_field feature_in_progress none
}

@test "rebase in progress blocks" {
  build_relation_repo diverged
  add_feature_worktree
  mkdir -p "$(marker_path "$SANDBOX/feature-wt" rebase-merge)"

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 1
  assert_field feature_clean yes
  assert_field feature_in_progress rebase
}

@test "merge in progress blocks" {
  build_relation_repo diverged
  add_feature_worktree
  touch "$(marker_path "$SANDBOX/feature-wt" MERGE_HEAD)"

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 1
  assert_field feature_in_progress merge
}

@test "no remotes: fetch is skipped and feature has no upstream" {
  build_relation_repo ahead-of-main
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight
  assert_exit 0
  assert_field fetch no-remotes
  assert_field main_upstream none
  assert_field feature_upstream none
  assert_field feature_upstream_state no-upstream
  assert_field feature_push create-upstream
}

@test "develop is behind upstream: fast-forward state" {
  build_relation_repo synced
  add_feature_worktree
  init_remote
  push_branch develop
  advance_remote_branch develop develop.txt remote remote
  git -C "$SANDBOX/repo" fetch -q origin

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 0
  assert_field main_upstream_state fast-forward
  assert_field main_upstream_behind 1
  assert_field current_branch_role main
  assert_field current_worktree_change yes
}

@test "develop diverged from upstream blocks" {
  build_relation_repo synced
  add_feature_worktree
  init_remote
  push_branch develop
  advance_remote_branch develop develop.txt remote remote
  commit_file local.txt local local
  git -C "$SANDBOX/repo" fetch -q origin

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 1
  assert_field main_upstream_state diverged
}

@test "feature behind its upstream blocks" {
  build_relation_repo ahead-of-main
  init_remote
  push_branch develop
  push_branch feature
  advance_remote_branch feature feature.txt remote-feature remote-feature
  git -C "$SANDBOX/repo" fetch -q origin
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 1
  assert_field feature_upstream_state local-behind
  assert_field feature_push upstream-blocked
}

@test "feature diverged from its upstream blocks" {
  build_relation_repo ahead-of-main
  init_remote
  push_branch develop
  push_branch feature
  advance_remote_branch feature feature.txt remote-feature remote-feature

  git -C "$SANDBOX/repo" switch -q feature
  commit_file local.txt local local
  git -C "$SANDBOX/repo" switch -q develop
  git -C "$SANDBOX/repo" fetch -q origin
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 1
  assert_field feature_upstream_state diverged
  assert_field feature_push upstream-blocked
}

@test "rewritten feature with up-to-date upstream uses force-with-lease" {
  build_relation_repo diverged
  init_remote
  push_branch develop
  push_branch feature
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field relation diverged
  assert_field feature_rewritten yes
  assert_field feature_upstream_state up-to-date
  assert_field feature_push force-with-lease
}

@test "feature upstream already in develop uses normal push" {
  cd "$SANDBOX/repo"
  git switch -q develop
  git switch -qc feature
  commit_file feature.txt feature feature
  init_remote
  push_branch feature

  git switch -q develop
  git merge -q --ff-only origin/feature
  commit_file develop.txt develop develop

  git switch -q feature
  commit_file local.txt local local
  git switch -q develop
  git fetch -q origin
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field relation diverged
  assert_field feature_rewritten yes
  assert_field feature_push normal
}

@test "feature ahead of its upstream uses normal push" {
  build_relation_repo ahead-of-main
  init_remote
  push_branch develop
  push_branch feature

  git -C "$SANDBOX/repo" switch -q feature
  commit_file local.txt local local
  git -C "$SANDBOX/repo" switch -q develop
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field relation ahead-of-main
  assert_field feature_upstream_state local-ahead
  assert_field feature_rewritten no
  assert_field feature_push normal
}

@test "commit titles are capped by --max-commits" {
  cd "$SANDBOX/repo"
  git switch -q develop
  git switch -qc feature
  commit_file f1.txt f1 f1
  commit_file f2.txt f2 f2
  commit_file f3.txt f3 f3

  git switch -q develop
  commit_file m1.txt m1 m1
  commit_file m2.txt m2 m2

  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --max-commits 1 --no-fetch
  assert_exit 0
  assert_field relation diverged
  assert_field feature_only_commit_omitted 2
  assert_field main_only_commit_omitted 1
  [ "$(field_count feature_only_commit)" -eq 1 ]
  [ "$(field_count main_only_commit)" -eq 1 ]
  [ "$(field_all feature_only_commit | head -n 1)" = f3 ]
  [ "$(field_all main_only_commit | head -n 1)" = m2 ]
}

@test "current worktree outside both branches changes nothing" {
  build_relation_repo diverged
  add_feature_worktree
  git -C "$SANDBOX/repo" worktree add -q -b other "$SANDBOX/other-wt" main
  cd "$SANDBOX/other-wt"

  run_preflight --main develop --feature feature --no-fetch
  assert_exit 0
  assert_field current_branch_role other
  assert_field current_worktree_change no
}

@test "fetch failure blocks" {
  build_relation_repo diverged
  add_feature_worktree
  git -C "$SANDBOX/repo" remote add origin "$SANDBOX/missing.git"

  run_preflight --main develop --feature feature
  assert_exit 1
  assert_field fetch failed
}

@test "feature commits on any remote is reported" {
  build_relation_repo diverged
  add_feature_worktree
  cd "$SANDBOX/feature-wt"

  run_preflight --no-fetch
  assert_exit 0
  assert_field feature_commits_on_any_remote no

  init_remote
  push_branch feature
  run_preflight --no-fetch
  assert_exit 0
  assert_field feature_commits_on_any_remote yes
}
