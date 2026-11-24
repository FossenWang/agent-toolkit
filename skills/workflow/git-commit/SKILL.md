---
name: git-commit
description: 'Use when the user wants to commit changes or types "/commit". Writes Conventional Commits messages from the diff; not for message-only requests or history changes.'
license: MIT
---

# Git Commit with Conventional Commits

## Message Format

```text
<type>(<scope>): <summary>

<body>

<footer>
```

- The scope, the body, and the footer are optional. Without a scope, write `<type>: <summary>`.
- Write the summary in the imperative mood: "add", not "added" or "adds".
- Keep the first line at 72 characters or less. Do not put a period at the end.
- In the body, tell what changed and why. Separate paragraphs with a blank line.
- Write each footer as `Token: value`, for example `Refs: #456` or `Closes: #123`. Use `-` for spaces in a token.

## Types

Conventional Commits defines only `feat` and `fix`. The other types come from the Angular convention ([`@commitlint/config-conventional`](https://github.com/conventional-changelog/commitlint/tree/master/%40commitlint/config-conventional)). If the repository has its own list, use that list.

| Type       | Use it for                                     |
| ---------- | ---------------------------------------------- |
| `feat`     | A new feature                                  |
| `fix`      | A bug fix                                      |
| `docs`     | Documentation only                             |
| `style`    | Formatting only, with no change to the logic   |
| `refactor` | A code change that is not a feature or a fix   |
| `perf`     | A performance improvement                      |
| `test`     | New or changed tests                           |
| `build`    | The build system or the dependencies           |
| `ci`       | The CI configuration                           |
| `chore`    | Other maintenance                              |
| `revert`   | A revert of an earlier commit                  |

## Breaking Changes

Put `!` before the colon, or add a `BREAKING CHANGE:` footer. Write the token in uppercase. `BREAKING-CHANGE:` is also correct.

```text
feat(api)!: remove the v1 endpoints

BREAKING CHANGE: Clients must use the v2 endpoints.
```

## Workflow

### 1. Read the repository rules

Find the commit rules before you write a message:

- A commitlint configuration, for example `commitlint.config.js` or `.commitlintrc.json`.
- `CONTRIBUTING.md`.
- The recent messages: `git log --oneline -10`.

If a repository rule is different from this skill, use the repository rule.

### 2. Examine the changes

Inspect staged and unstaged changes, including untracked files. If there are no changes, check whether a merge is in progress; if so, continue so the merge commit can be created. Otherwise, tell the user. Do not make an empty commit.

### 3. Stage the files

Run Git commands from the repository root. Before unstaging or splitting, check for an operation in progress (merge, cherry-pick, revert, rebase, or `git am`) or any unmerged file, including conflicts without a ref such as after a stash pop. If one exists, **do not unstage and do not split the commit**: the index holds the operation result; unstaging can drop the other side's changes or delete conflict entries. Stop for rebase/`git am`; for merge/cherry-pick/revert, stage only resolved files after confirming they have no leftover conflict markers (run `git diff --check` and clear what it reports), and ask the user about binary or structural conflicts. Show other edited files and stage only the paths the user confirms.

Otherwise, put one logical change in each commit. If the staged files contain more than one change, unstage the files of the other changes, then stage the files for this change.

- Quote globs so the shell does not expand them before Git sees them.
- Put `--` before paths so filenames starting with `-` are not read as options.
- Do not use `git add -p` or `git add -i`; they wait for input from a person.
- After you resolve a merge conflict, stage the resolved files explicitly.
- Review the staged file list. Do not commit secrets, for example `.env` files, `credentials.json`, or private keys.

### 4. Commit

If a merge, cherry-pick, or revert is in progress, run `git commit --no-edit` so Git uses the prepared message; do not write a new one.

Otherwise, get the type, the scope, and the summary from the diff and write the message in the format above.

For a long message, use a message file.

### 5. Make sure that the commit is correct

Confirm that the new commit contains only the intended files. Leave unrelated changes in the working tree as they are; do not stash, discard, or commit them.

## Safety Rules

- Do not change Git configuration or bypass hooks (for example with `--no-verify`) unless the user tells you to.
- If a hook fails, fix the problem, stage the files again, and commit again. Do not amend, because it changes the previous commit.
- Do not rewrite history, push, or force push unless the user tells you to.
