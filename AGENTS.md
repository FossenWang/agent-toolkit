# AGENTS.md

## 维护方式
- AI 不直接修改本文件；需要更新时，用 `agents-draft` skill 走草稿、审阅、写回。

## 项目简介
- agent-toolkit：公开合集，收通用的 agent 工具，包括 skill 与 OpenCode 插件。
- 只收可复用的部分，不依赖特定机器、内网或模型账号。

## 操作边界
- **可自主执行**：不连外部服务、不写全局状态的只读操作。
  - 读代码、文档与日志，搜索代码。
  - 跑测试 `bun run test`。
  - 向 `agent/*` 和 `feature/*` 分支提交与推送。
- **必须先取得用户确认**：须先说明意图并取得确认后再执行。
  - 安装或升级依赖：`bun install`、`npx skills add`。
  - 写本机全局状态：`~/.config/opencode/`、`~/.agents/skills/`。
  - 提交和推送 `develop` 分支、发布 tag 或 release。
- **禁止 Agent 执行**：不允许 Agent 执行危险操作，只能人工执行。
  - 删除数据等不可逆操作。
  - 在 `main` 分支上开发，提交，推送。

## 仓库索引
- `skills/`：skill 源码，用子目录分组；文档与维护约定见 `docs/skills/README.md`。
- `opencode/plugins/`：OpenCode 插件源码，一个插件一个目录；文档与维护约定见 `docs/opencode/plugins/README.md`。
- `tests/`：bats 与插件测试，约定见 `docs/tests.md`。
- `docs/git-workflow.md` 记录分支模型、Actions 合并流程与发版规则，处理 git 相关事务时必须遵守该文档的约定。
- `local/`：本地调研与计划，不入库。

## 语言约定
- 默认情况下，文档、注释、提交信息用中文。
- 英文内容作为可选增量，可以后续再补，不需要同步双语内容。
- 常用的专业术语可以直接用英文，如 agent、skill 等。
- 原文是英文的内容保持英文，不翻译；既有英文内容不追溯。
- 文件名、目录名、代码标识符用英文，不用中文路径。

## 本地个人规则
加载文件 `AGENTS.local.md`，缺失时提示用户可在此文件中提供虚拟环境位置和环境变量取值等规则。
