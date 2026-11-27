# npx skills：安装与分发

> 只讲 `npx skills`（vercel-labs/skills）这个 CLI：装在哪、怎么装、怎么分发。skill 源码在 `skills/`，说明文档在 `docs/skills/`；`SKILL.md` 的写法见 [skill-format.md](skill-format.md)。

## 为什么源码与安装位置分离

一个目录原本要同时表达三件事：运行时是否生效、所有权与来源、分发范围。三者正交，靠目录外形表达不了：

- 源码与安装副本同名同形，无法区分，安装会静默覆盖源码。
- 安装位置会混杂不同来源的 skill。
- 用提交白名单隔离副本，又会被 gitignore 掩盖，需要额外维护非 git 检查。

所以源码只住 `skills/`，安装位置只放可重建的副本，本仓库像下游一样安装自己。

备选方案：源码留在安装位置（要白名单 + 非 git 检查）；手动 junction（每台机器 setup，且 harness 能否发现未验证）；双份源码（必然漂移）。

## 位置与约定

| 用途 | 位置 |
| --- | --- |
| 源码，唯一可编辑 | `skills/<分组>/<name>/`，入库 |
| 安装副本 | `~/.agents/skills/<name>/`，可重建，不入库 |

- **本仓库的 skill 都按全局安装**：命令里始终带 `-g`。不加会装到当前项目的 `.agents/skills`，这些 skill 是跨项目复用的工具，不按项目级使用。
- **默认 `-a codex`**：`~/.agents/skills` 同时被 OpenCode、VS Code Copilot 等 harness 读取，是跨 harness 的共享路径，不是「只给 Codex 装」；指定它还能避免铺到 `.claude/skills` 等其它位置。
- **全局安装不写 `skills-lock.json`**：lock 只出现在项目级安装里，仓库不需要它。
- **本地源用 `./skills`**：CLI 只在 `skills/` 内扫描；指定仓库根（`.`）才会扫到安装位置。

## 安装

查看仓库里可安装的 skill：

```sh
npx skills add FossenWang/agent-toolkit --list
```

安装单个，或多个：

```sh
npx skills add FossenWang/agent-toolkit -s '<name>' -a codex -g
npx skills add FossenWang/agent-toolkit -s agents-draft -s git-commit -a codex -g
```

本机从源码装全部 skill：

```sh
npx skills add ./skills \
  -s agents-draft -s npx-skills -s git-commit -s rebase-merge -s grilling \
  -a codex -g
```

- `FossenWang/agent-toolkit` 是 git shorthand，完整 URL 也可以。
- `-s` 必须，安装时记录对应 commit；名字先用 `--list` 确认。
- 多个 `-s` 可以一次装多个。
- 依赖解析交给 `npx-skills` skill：CLI 不解析 skill 之间的依赖。

## 分发

- **可见性由 `metadata.internal` 控制**：写 `true` 时 `--list` 看不到，也装不上；去掉字段即可被发现。写不写由作者决定，仓库不设默认值。
- **范围只由 frontmatter 表达**：登记不记范围；查当前可分发列表用 `npx skills add FossenWang/agent-toolkit --list`。
- **下游分发不用 local 源**：`update` 对 local 源是 no-op；local 只用于自装和一次性验证。
- **`metadata.internal` 不是访问控制**：知道名字仍能 `-s <name>` 装，硬边界只能靠独立仓库。

## CLI 行为

- 源仓库的容器目录（`skills/`、`.agents/skills/` 等）会被递归扫描，深度 3，`skills/<分组>/<name>/SKILL.md` 可被发现；容器目录不是必需的。
- 装到 agent 目录的是独立副本，不是 live link：改源码要重跑 `add`。CLI 原样复制整个目录，所以 `SKILL.md` 之外的说明文档不要放进去，放 `docs/skills/`。
- 重装会覆盖安装副本并更新 hash。
- 不加 `-g` 时安装到项目级，并写 `skills-lock.json`；不加 `-a` 时还会生成 `.claude/skills/<name>`，`-a codex` 只写 `.agents/skills`。
- 源码与安装位置同名时，装到下游的是源码内容；这是扫描顺序，不是保证，所以合入后要重装。
- 安装位置独有的目录会被 `add <仓库根> --list` 列出；`add ./skills --list` 只扫 `skills/`，列不到安装位置。
