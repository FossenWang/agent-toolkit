# Agent Skill 通用写法

> 本文是 `SKILL.md` 写作规范的唯一出处。目标：一份 `SKILL.md` 同时被 **OpenCode** 与 **VS Code Copilot** 发现并触发。只写两家都支持、且都有实际作用的部分；任何一家的专属字段都不使用。

## 1. 放在哪里

安装位置（agent 运行时扫描的目录）：

| 场景 | 路径 |
| --- | --- |
| 项目级 | `<项目根>/.agents/skills/<name>/SKILL.md` |
| 用户级 | `~/.agents/skills/<name>/SKILL.md` |

- **必须是一层目录 + `SKILL.md`**：`<root>/<name>/SKILL.md`。不要用单文件 `.md`，不要做多级分组——Copilot 只扫直接子目录，不递归。
- **源码与安装位置分开**：源码住 `skills/`（可带分类子目录），由 `npx skills` 复制成安装位置的一层目录；分类只属于源码，不进安装位置。详见 [npx-skills-cli.md](npx-skills-cli.md)。
- **一个 skill 只放一份**：不要按 harness 复制两份，两个 harness 读同一个目录。
- 其他路径（`.opencode/skills/`、`.github/skills/`、`.claude/skills/`）只有各自读取，不属于通用写法。

## 2. frontmatter

```markdown
---
name: skill-name
description: 做什么；何时使用；覆盖哪些触发关键词。不超过 1024 字符。
---
```

| 字段 | 必需 | 约束 |
| --- | --- | --- |
| `name` | 是 | 等于目录名、等于调用名；小写字母/数字/连字符，`^[a-z0-9]+(-[a-z0-9]+)*$`，≤64 |
| `description` | 是 | ≤1024 字符；写清「做什么 + 何时用」，关键词前置 |
| `disable-model-invocation` | 否 | `true` 表示只允许手动调用；三家都认，但不在 Agent Skills 标准里，非必要不写 |

- **不要写** `allowed-tools`、`disallowed-tools`、`when_to_use`、`hooks`、`paths`、`model`、`context`、`agent`、`background`、`arguments`、`user-invocable`——这些只在部分 harness 生效，写了最多被忽略。
- `license`、`compatibility`、`metadata` 可写，但不改变行为，不要靠它们实现逻辑。
- 本仓库的 `metadata.internal: true` 是 `npx skills` 的分发开关，与 harness 行为无关；它不属于这里的通用集。

### 判断「何时用」写得够不够

- **标准是能否让模型理解用户意图，不是覆盖多少同义词。** 不列举候选说法、不堆关键词：模型做的是语义匹配，理解力越强，显式枚举越没必要，也越容易在用户换个说法时失效。
- **不要凭字面判断一句话有没有效。** `处理 GitLab 日常事务，包括 CI、Issue、Milestone…` 看上去像同义反复，实测能稳定触发；反过来，写得「很具体」的枚举也可能照样漏。
- **验证靠实践**：在真实会话里用目标说法试，稳定触发即达标，不追求覆盖率。改 `description` 前先有一个失败样本，改完用同一个样本复测；没有失败样本就不要改。
- manual-only 的 skill（`disable-model-invocation: true`）不存在自动触发问题，只需保证菜单里那一行读得懂。

### 调用权限与 skill 间依赖

- `disable-model-invocation: true` 表示该 skill 不进模型的可用列表，只能手动调用。模型若调用一个不在列表里的 skill，各 harness 没有统一行为。
- **一个 skill 的正文要求加载另一个 skill 时，被加载的那个必须允许模型调用**；否则模型看不到它，只能依赖各 harness 的非标准兜底。

## 3. 目录结构

```text
<name>/
├── SKILL.md          # 必需：流程、判断、边界
├── scripts/          # 可选：确定性逻辑、重复操作
└── references/       # 可选：按需阅读的长文档
```

**何时拆文件**：正文接近 500 行；同一流程有多个领域变体（各占一个 reference）；有需要精确执行、不宜让模型现写的步骤（放 `scripts/`）。

`SKILL.md` 之外的说明文档（来源、改动、许可证、维护记录）不要放进 skill 目录，放 `docs/skills/`；skill 目录会被原样复制到安装位置。

## 4. 正文怎么写

- 用祈使句写**判断、边界、易错点**；不复述模型已掌握的常识。
- 给「步骤 + 一个可运行示例 + 失败时怎么办」，比堆规则更容易被正确执行。

### 写判断，不写通用命令

模型已掌握、且不承载策略或安全边界的命令（常规 Git / shell 操作）不列具体命令与参数，让模型按当前环境生成。

**判据**：删掉这条命令，模型是否仍能可靠完成同一动作？

- 能，且命令没有固定范围、交互方式或禁止项 → 删。
- 不能，或命令本身固定了策略/安全边界 → 保留，并说明它约束什么。

**该删的例子**：`git-commit` 只写「进行中操作时不要 unstage、结构冲突问用户」，不列检测命令。

**该留的例子**：

- `git log --oneline -10` 的 `-10` 是仓库选定的查看范围（Git 没有默认值）
- `git commit --no-edit` 避免打开编辑器
- 禁止 `git add -p` / `git add -i`，因为它们等待交互输入
- `--` 路径分隔符，避免以 `-` 开头的文件名被当成选项
- 项目脚本入口与专用 CLI 的非显然参数：脚本的 flag、`glab issue note -m` 的 `-m`

### 其余约定

- 引用附属文件时写**相对 `SKILL.md` 的路径**，并说明「什么情况下读哪个」；只写「详见 references/」不够。
- 目标 ≤500 行；超了就按上面的规则拆分，而不是压缩信息。
- 正文语言不影响触发；`description` 才是模型选择的主要依据。
- 语言选择按仓库约定：中文优先；原文是英文的内容保持英文，不翻译。

## 5. 自检清单

- [ ] 路径为 `<root>/<name>/SKILL.md`，只有一层目录
- [ ] `name` == 目录名，小写 kebab，无大写/下划线/中文
- [ ] `description` 同时包含「做什么」和「何时用」，≤1024 字符
- [ ] 没有出现任何 harness 专属字段
- [ ] 附属文件用相对路径引用，且写明了何时读
- [ ] 在 OpenCode 与 VS Code（`/` 菜单，需开启 `chat.useAgentSkills`）各验证一次
