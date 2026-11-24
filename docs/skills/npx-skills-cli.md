# npx skills：安装与分发

> 本文只讲 `npx skills`（vercel-labs/skills）这个 CLI：装在哪、怎么分发、实测行为。skill 源码在 `skills/`，非源码的说明文档在 `docs/skills/`；`SKILL.md` 的写法见 [skill-format.md](skill-format.md)。

## 为什么源码与安装位置分离

一个目录原本要同时表达三件事：运行时是否生效、所有权与来源、分发范围。三者正交，靠目录外形表达不了：

- 源码与安装副本同名同形，无法区分；安装会静默覆盖源码。
- 要支持「外部 skill 只装本项目」时，安装位置会进一步混杂来源。
- 靠提交白名单隔离副本时，gitignore 又会掩盖意外副本，需要额外维护非 git 检查。

所以源码只住 `skills/`，安装位置只放可重建的安装副本，本仓库像下游一样安装自己。

备选方案与取舍：

- 源码留在安装位置：即时生效，但要白名单 + 非 git 检查，且分不清「要分发的」和「只在本项目用的」。
- 源码在 `skills/` + 手动 junction：每台机器要 setup，链接能否被各 harness 正常发现未验证。
- 双份源码：必然漂移。

## 源码与安装位置

- **源码唯一**：每个 skill 只有一份可编辑的源码，在 `skills/` 下入库。
- **安装位置可重建**：`.agents/skills/` 里的一切都是安装副本，删掉后重新安装即可恢复；`.agents/skills/`、`.claude/skills/` 由安装器生成，整目录忽略。
- **本仓库也安装自己**：`npx skills add ./skills -s <name> -a codex`，只产生 `.agents/skills/<name>`；不加 `-a` 会同时铺到多个 agent 位置。
- **默认 `-a codex`**：Codex 的项目级/全局路径是 `.agents/skills` / `~/.agents/skills`。这两个位置同时被 OpenCode、VS Code Copilot 等 harness 读取，所以它是一条跨 harness 的共享路径，不是「只给 Codex 装」；指定它还能避免同时铺到 `.claude/skills` 等其它位置。
- **`skills-lock.json` 入库**：它是 CLI 的安装记录（来源 + hash），用于新机恢复与查来源；不是安装位置的不变式。安装位置允许手工目录与外部 skill 的项目级安装，检查只报告「非 CLI 安装」，不阻断。
- **本地安装指定源为 `./skills`**：CLI 只在 `skills/` 内扫描，安装位置的内容不会进入发现范围；指定仓库根（`.`）才会扫到安装位置。分发仍只走 git URL。

## 分发

- **可见性由 `metadata.internal` 控制**：frontmatter 写 `metadata.internal: true` 时，`-l` 看不到该 skill，`-s '*'` 也会跳过；去掉该字段即可被发现。写不写由作者按这个 skill 是否适合外部分发决定，仓库不设默认值。
- **范围只由 frontmatter 表达**：登记不记范围；查当前可分发列表用 `npx skills add ./skills -l`。
- **下游契约**：`npx skills add <git-url> -s '<name>' -a codex`，记录安装时的 commit。`-s` 必须；`-s '*'` 与批量安装不受支持。
- **下游分发不用 local 源**：`update` 对 local 源是 no-op；local 只用于本仓库自装与一次性验证。
- `metadata.internal` 不是访问控制：知道名字的 `-s <name>` 仍能装，硬边界只能靠独立仓库。

## 安装方式

建议用 `npx-skills` skill 让 agent 安装相关 skills，该 skill 需用户手动调用：`npx skills` CLI 不解析 skill 的依赖，`npx-skills` skill 会指导 agent 解析并安装依赖。`npx-skills` 本身建议装到用户级：

```bash
npx skills add https://github.com/FossenWang/agent-toolkit -s 'npx-skills' -a codex -g
```

## CLI 行为

跨项目复制 skill 靠 `npx skills`：源仓库里的 skill 容器目录（官方约定的一组目录，含 `skills/`、`.agents/skills/` 等）会被递归扫描（深度 3，`skills/<分组>/<name>/SKILL.md` 可被发现）；容器目录不是必需的。

装到 agent 目录的是独立副本，不是对源仓库目录的 live link：改了源码，要重跑 `add` 才落到安装副本。CLI 原样复制整个 skill 目录，skill 目录里手工维护的附加文件会一并带上；所以 `SKILL.md` 之外的说明文档不要放进去，放 `docs/skills/`。

实测补充（`skills@1.7.4`，2026-10-23）：

- project-scope 安装会写仓库根 `skills-lock.json`（`source` / `sourceType` / `computedHash`）；不加 `-a` 时还会生成 `.claude/skills/<name>` junction，`-a codex` 只写 `.agents/skills`。
- 重装会覆盖安装副本并更新 hash，副本内容随之更新。
- 源码与安装位置同名时输出 `Found 1 skill`，装到下游的是源码内容；这是扫描顺序，不是保证，所以仍要「合入后重装」。
- 安装位置内独有目录会被 `add <仓库根> -l` 列出；`add ./skills -l` 只扫 `skills/`，列不到安装位置。lock 里的 `source` 会记为 `./skills`。

CLI 升级后，上文的实测结论可能失效，按当时版本重新验证并更新本文。
