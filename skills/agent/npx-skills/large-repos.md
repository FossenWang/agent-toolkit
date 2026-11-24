# Large repositories

`npx skills add` clones the whole repository (`git clone --depth 1`) before it looks for `SKILL.md`. On a large repository or a slow link to GitHub, that clone stalls even when one skill directory is all you need.

`scripts/add-sparse.sh`, next to this skill's `SKILL.md`, runs the install through a temporary `PATH` git wrapper: the clone becomes partial (`--filter=blob:none --sparse`), only the given directories are checked out, and the wrapper is removed on exit. The CLI still receives the GitHub URL, so `skills-lock.json` keeps the real source.

Use it when the repository is large, the clone stalls, or the source URL already points at a subdirectory. It needs Linux/macOS, git 2.25+, and a server that supports partial clone.

```bash
scripts/add-sparse.sh \
  --source 'https://github.com/github/awesome-copilot/tree/main/skills/git-commit' \
  --sparse skills/git-commit \
  --skill git-commit \
  --mirror 'https://ghfast.top/https://github.com/'
```

- `--source`: the formats accepted by `npx skills add`; pass the URL with `/tree/<ref>/<path>` so the ref is preserved.
- `--sparse`: repo-relative directory holding the skill's `SKILL.md`; repeat for several paths. Skip `-l` in this flow: it clones the repository too and would see only the sparse paths.
- `--mirror`: optional transport prefix, passed to git as `-c url.<prefix>.insteadOf=https://github.com/` for the whole install, including the lazy blob fetches inside the temporary clone. It never reaches the lock. Keep it environment-specific; one prefix was verified on 2026-10-28 with `skills@1.7.4`: `https://ghfast.top/https://github.com/`.
- `--agent` defaults to `codex`, project scope by default; add `-g` for user-level.
- `--dry-run` prints the resolved command; `--timeout-ms` defaults to 600000.

Done when `npx skills list` shows the skill, `<install location>/<name>/SKILL.md` exists, and the lock entry records `sourceType: github` with the GitHub source.

## Limits

- Tied to the current CLI clone shape (`git clone` with the target directory as the last argument). If a CLI upgrade changes it, rerun without the script.
- `--sparse` and `--skill` are independent inputs; both must match the source.
- Mirror availability is outside your control; a failure there is a transport failure, not an install result.
- Shell wrapper only; Windows is not covered.
