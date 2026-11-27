# skill

源码在 `skills/`，用子目录分组；本目录放说明文档。

| skill | 用途 | 来源 | 说明 |
| --- | --- | --- | --- |
| `npx-skills` | 用 `npx skills` 安装 skill，并解析其依赖 | 自建 | [agent/npx-skills.md](agent/npx-skills.md) |
| `agents-draft` | 把已加载的指令文件放进草稿箱，确认后一次性写入 | 自建 | [agent/agents-draft.md](agent/agents-draft.md) |
| `git-commit` | 按 Conventional Commits 生成提交信息 | 分叉 · awesome-copilot | [workflow/git-commit.md](workflow/git-commit.md) |
| `rebase-merge` | 功能分支 rebase 到主分支后快进合入 | 自建 | [workflow/rebase-merge.md](workflow/rebase-merge.md) |
| `grilling` | 反复追问，压测方案与决策；常配合 mattpocock 其他 skill 使用 | 分叉 · mattpocock/skills | [mattpocock.md](mattpocock.md) |

## 维护约定

- 一个 skill 目录只放 `SKILL.md` 和它的运行资产（`scripts/`、`references/`）；来源、改动、许可证等说明放 `docs/skills/<分类>/<name>.md`。
- `docs/skills/` 下的说明文档用中文；`SKILL.md` 的语言按这个 skill 自己的约定，不随 docs，并保持单语。
- 写法按 [skill-format.md](skill-format.md)，安装与分发按 [npx-skills-cli.md](npx-skills-cli.md)。
- 分叉 skill 记录来源仓库、分叉 commit 和许可证；不主动跟随来源更新。
- 需要多语言版本时，同一 skill 按语言拆成独立目录分发；目录格式待定。
- 安装副本只住 `.agents/skills/`，可整体重建，不入库。
