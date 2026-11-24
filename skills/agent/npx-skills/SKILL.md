---
name: npx-skills
description: "Find, evaluate, and install agent skills with the `npx skills` CLI. Use when the user asks to find a skill for a task, search for skills, install or add a skill from a GitHub repository or local path, or check which skills are installed. Covers discovery, recommendation-quality checks, non-interactive installation, large or slow repositories, and verification."
disable-model-invocation: true
---

# npx-skills

`npx skills` (vercel-labs/skills) is the package manager for agent skills. This file is authoritative for `find`, `add`, and `list`: run those directly. Run `npx skills --help` only for subcommands not covered here (e.g. `update`, `remove`, `init`).

## find — discovery

If the user already gave an exact source (`owner/repo`, URL, or path), go straight to `npx skills add <source> -l`. If the user gives only an author or an informal name, resolve it to `owner/repo` first (from context, or with `find`); `add` expects `owner/repo`, not a bare owner. Use `find` when the source is unknown.

`npx skills find "<query>"`: Print matches ranked best-first. Read the first 50 lines; only read further if none match.

Options:
- `--owner <owner>`: Search only repositories from a GitHub owner. The owner must match exactly.

### Recommendation quality

- Install count: prefer 1K+. Under 100 or unknown: say so explicitly.
- Source: official or established organizations first. Unknown authors need stronger evidence.
- Present at most two or three candidates with their trade-offs and let the user choose.
- If nothing matches, say so and offer to do the task directly. Do not recommend a loose match.
- Installing is a side effect: search requests get options, not installations.

## add — installation

`npx skills add <source> -s <skill> -a codex -y`: Install skills.

Source formats:

| Source | Example |
| --- | --- |
| GitHub shorthand | `owner/repo` |
| GitHub URL | `https://github.com/owner/repo` |
| Path inside a repo | `https://github.com/owner/repo/tree/main/skills/<name>` |
| Local path | `./skills` or `C:\path\to\skills` |
| Any git URL | `git@github.com:owner/repo.git` |

Options:
- `-s, --skill <name>`: Skill by frontmatter `name`; repeat for several skills.
- `-a, --agent <agent>`: Target agent directories; default `codex` here.
- `-g, --global`: Install for the user instead of the current project.
- `-y, --yes`: Skip this CLI's confirmation prompts; not npm's `npx --yes`.
- `-l, --list`: List skills in the source without installing. For a git source this still clones, so run it once and read the full output.
- `--all`: Every skill to every agent; only on explicit request.

### Install rules

- Default to `-a codex`: that path is read by OpenCode, VS Code Copilot, Cursor, Gemini CLI, Codex, Cline, and others. Target only what the user asked for; do not fan out.
- Default to project scope; add `-g` only when the user asks for the skill across projects.
- Never install every skill: always pass `-s`, and use `--all` or `-s '*'` only when the user explicitly asks.
- Install dependency skills: the CLI does not resolve skill-to-skill dependencies; it inspects the repository layout, not `SKILL.md` bodies.
- After `add`, confirm the name with `npx skills list` (add `-g` for global) or the directory itself; the `add` output alone is not proof.

### Large repositories

When the repository is large, the clone stalls, or the source URL points into a subdirectory, run `scripts/add-sparse.sh` from this skill's directory instead of `add` directly: see [`large-repos.md`](large-repos.md).

## list — inspection

`npx skills list`: List installed skills.

Options:
- `-g, --global`: List global skills instead of project ones.
- `-a, --agent <agents>`: Filter by specific agents.
- `--json`: Machine-readable output, no ANSI codes.

`list` and `ls` are aliases. A project install also writes `skills-lock.json`; treat that file as CLI-owned and do not hand-edit it.
