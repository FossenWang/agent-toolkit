---
name: rebase-merge
description: "Land a feature branch on the main branch: rebase F onto M, then merge."
disable-model-invocation: true
---

# Rebase Before Merge

Move feature branch F onto main branch M. Conflicts are resolved on F; M only receives the merge, either ff-only or no-ff.

## Rules

- M and F are local branches. F may already be published; M is never rewritten. One M/F pair per run.
- **Single writer.** While `fast-flow.sh` runs, this flow owns the repository, the M/F branches, and their worktrees. Do not start any other write operation in parallel.
- No MRs, no multiple targets, no stacked-branch splitting, no install/lock side effects.
- Never force M. Rewriting a published F uses `--force-with-lease --force-if-includes`. Never `-D`.
- No stashing inside the flow, no `--autostash`, and never use a stash to get past the dirty-worktree preflight. If the user asks for one, run it as a separate step before or after the flow, report it, and stop if the restore conflicts; keep the stash and never drop it automatically. It plays no part in flow decisions.
- Conflicts are resolved only on F. M just receives the merge; never leave a conflict scene on M.
- Whenever the user must choose or confirm, use the current harness's question tool. Per decision point:
  - `status=blocked`: single choice, using the script's `question` / `option` fields.
  - A conflict needs a decision: single choice with 2–3 options; put the recommendation first and label it.
  - Wrap-up actions: multi-select, filtered by the state in section 5.
  - "Other" confirmation: single choice, execute or cancel.

## Workflow

### 1. Fast path

Start by running `fast-flow.sh`. Translate what the user explicitly specified — branch, merge mode, execution boundary, known test command — into flags (for example "land on develop" → `--main develop`, `no-ff` → `--no-ff`, "rebase only, no merge" → `--stop-after-rebase`, known test command → `--test-command "<cmd>"`). Do not run Git commands or explore the repository first; the script checks everything, so read its output and route from there.

```bash
bash "<skill-dir>/scripts/fast-flow.sh" \
  [--main <M>] \
  [--feature <F>] \
  [--check] \
  [--no-ff] \
  [--stop-after-rebase] \
  [--keep-worktree] \
  [--main-worktree "<M-worktree>"] \
  [--feature-worktree "<F-worktree>"] \
  [--test-command "<test command>"]
```

#### Flags

- `--main` / `--feature`: default to the main worktree's current branch and the current branch; pass another local branch when the user asks for one.
- `--no-ff`: keep one merge commit that can be reverted as a unit (default is ff-only).
- `--stop-after-rebase`: stop after the rebase/tests without merging. With `--no-ff`, `--no-ff` is ignored and a warning goes to stderr.
- `--keep-worktree`: keep the temporary worktrees this run created, for inspection or follow-up work; by default they are cleaned after `status=done`.
- `--test-command`: runs only after a `diverged` rebase rewrote F. Omit it when no suitable command exists.
- `--check`: preflight only, no worktree. Use it only when the user explicitly asks to see the plan. `exit=1/2` means the preflight is blocked or has a gap, not that the run failed; report the plan and do not route on `status` / `stage`.
- M/F not checked out and no worktree path given: the script creates a temporary worktree. On a `blocked` rerun, pass the paths back with `--main-worktree` / `--feature-worktree` to reuse the same state.
- Other options (such as `--no-fetch`) are covered by `--help`.

#### Output

- `relation`: how F relates to M by commits — `synced` / `behind-main` / `ahead-of-main` / `diverged`.
- `status` / `stage`: route with the table below.
- `question` / `option`: the question for the user and the available choices.
- `handoff` / `message`: the next action for the agent / a one-line summary.
- Worktree fields: used later by conflicts, tests, merge, wrap-up, and cleanup.
- `temp_worktree_cleaned`: `yes` / `no` / `partial` / `n/a`. `no` or `partial` means a temporary worktree from this run still exists; `temp_worktree_cleanup_error` gives the reason.
- `tests`: `passed` / `failed` / `dirty` / `skipped` (no command passed) / `not-run` (this relation does not run tests).

Route on `status` / `stage`:

| status | stage | Action |
| --- | --- | --- |
| `done` | `done` | Go to wrap-up (section 5). |
| `blocked` | `preflight` | Hand `question` / `option` to the user; act on the answer (add flags, commit or clean a worktree, stash outside the flow when the user asks, or fix the upstream), then rerun. |
| `needs-ai` | `rebase` | Resolve the conflict in `feature_worktree` (section 2); when done, continue per the last item of section 2 into section 3/4. |
| `needs-ai` | `tests` | Fix and commit in `feature_worktree` (section 3); when done, continue per section 3 into section 4 or stop. |
| `failed` | any | Report `message` and the state, then stop (keep temporary worktrees for diagnosis). |

If a `blocked` run is abandoned, report the temporary worktree paths the script created (if any) and clean up only the temporary worktrees this flow created, per section 5. Do not merge and do not delete branches.

`needs-ai` is the handoff. `fast-flow.sh` covers the happy path; the skill takes it from there: conflicts (section 2), tests (section 3), manual merge or stop (section 4), push/delete/cleanup (section 5).

### 2. Resolve conflicts

`fast-flow.sh` never resolves conflicts; it leaves the rebase in place in `feature_worktree`, and section 2 takes over at `needs-ai` with `stage=rebase`.

In `<F-worktree>`:

- Index sides: `:1:` base, `:2:` ours (M), `:3:` theirs (F).
- Additive changes (both sides add at the same anchor): keep both, order them by surrounding context, stage, and continue.
- Competing edits, delete/rename, binary, generated files, anything uncertain: use the question tool with 2–3 options and a recommendation; put the state and the reason in `question` or the option descriptions; put the recommendation first and label it.
- Abort only to give up. Before taking one side, confirm no valid content is lost. If undecided, stay in the F worktree.
- After resolving, mark the conflict resolved and continue the rebase. Then run tests (section 3), then merge (section 4) or stop in stop mode. Wrap-up uses the worktree paths and `feature_push` from the first run's output.

### 3. Verify and fix tests

Section 3 takes over at `needs-ai` with `stage=tests` (`tests=failed` / `tests=dirty`). `fast-flow.sh` never fixes tests.

- Fix in `feature_worktree` with new commits; do not amend the original commits.
- Rerun the known test command in the F worktree. Continue only when it passes and the worktree has no tracked changes.
- With no test command, skip the tests and report explicitly that they are unverified; the user decides whether to continue.
- Uncommitted tracked changes never enter F's commits, so they cannot be carried into the merge.
- Do not commit untracked files. If one blocks cleanup, explain first, then remove it.
- If the original intent was to merge, merge by hand per section 4; in stop mode, skip the merge.
- Run these tests after a conflict resolution too. Before merging, the post-rebase result is the one that counts.

### 4. Merge by hand

Section 4 takes over when the run needs a merge; skip it when the original intent was rebase only (stop mode).

- Confirm M is an ancestor of F. If not, M has moved: stop; to continue, rebase F onto the new M, test again, then merge.
- In the M worktree, merge with the mode chosen for this run.
- On failure, stop. Do not retry and do not fall back to a plain merge.

### 5. Wrap up

`fast-flow.sh` never pushes and never deletes branches. It cleans the temporary worktrees it created when `status=done`; all other wrap-up belongs to this section.

Report the run first: steps taken (including `relation` and whether it stopped), whether the rebase rewrote F, conflict handling, test result, merge mode (if any) and M's SHA, temporary worktrees (if any, including `temp_worktree_cleaned`), any user-requested stash and where it lives / whether it was restored, and the current upstream state of M and F plus `feature_push`.

For a manual continuation after `needs-ai`, reuse the worktree paths, `feature_push`, `feature_rewritten`, and `temp_worktree` from the first run's output; read the current tips again with `git rev-parse`. The script already cleaned the temporary worktrees it created on `status=done`; for a manual continuation, a stopped `blocked` run, or leftovers after stop mode, handle them under "clean temporary worktrees" below.

Then present the available actions with the current harness's multi-select question tool and execute only what the user selects; the body reports results only. Offer Git actions only; business follow-ups go under "Other". When nothing applies, report and finish without forcing a question.

- **Push M**: offer when M has unpushed commits or no upstream. Push from the M worktree if it exists, otherwise `git push <remote> <M>`. On failure, stop; never force; do not continue cleanup.
- **Push F**: do not offer when `feature_push=upstream-blocked` — fix the upstream first. Otherwise offer when F has unpushed commits or no upstream. Push from the F worktree; if that worktree is gone, `git push <remote> <F>`. `create-upstream` sets the upstream (remote chosen by the user); `force-with-lease` uses `--force-with-lease --force-if-includes` (say in the description that it rewrites the remote F); `normal` is a plain push. On failure, stop.
- **Delete the F worktree**: offer only when this run actually merged F into M (script `merge=ff-only` / `no-ff`, or a completed manual merge in section 4), and the F worktree exists, is not the main worktree, and is not a temporary worktree. Use `git worktree remove` without `--force`; if the cwd is inside it, move out first or tell the user. On failure, keep it and report. Temporary F worktrees are handled by "clean temporary worktrees".
- **Delete the F branch**: offer only when this run actually merged F into M (script `merge=ff-only` / `no-ff`, or a completed manual merge in section 4), and a read-only check confirms F is contained in M. Use `git branch -d`; if F is still checked out, release the checkout first. If Git refuses, stop; never `-D`.
- **Clean temporary worktrees**: offer when the script created or reused one this run and it still exists (`temp_worktree_cleaned=no` / `partial`), or when it remains after a manual `needs-ai` continuation and the user did not pass `--keep-worktree`. Remove only paths with `main_worktree_temp=yes` / `feature_worktree_temp=yes` that still exist, with `git worktree remove` and without `--force`. If the cwd is inside one, or removal fails, keep it and report. Once all temporary worktrees are gone, `rmdir` `temp_worktree_root` only if it is empty. Clean only what this flow created.
- **Other**: propose first; execute only after the user gives a command and confirms it. On failure, report and stop cleanup.

Run the actions in this order: push M → push F → delete/clean → other. Stop at the first failure, skip the remaining cleanup, and list every temporary worktree still present in the report.

There is no "delete the M worktree" option: the main worktree is never deleted; the script cleans temporary M worktrees it created on `status=done`; existing linked M worktrees belong to the user and go through "Other".

After a manual continuation (`needs-ai`), if temporary worktrees created by the script still exist, wrap-up must offer "clean temporary worktrees"; if not selected, keep them and report them — never leave them behind silently. `--keep-worktree` is an explicit keep: report it, but do not offer cleanup.
