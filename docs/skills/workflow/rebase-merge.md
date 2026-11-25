# rebase-merge

类型：自建。

把功能分支 F rebase 到主分支 M，再把 M 快进到 F。由用户显式调用（`disable-model-invocation: true`）。

`SKILL.md` 用英文：这个流程的结构本来就是英文思路，git 领域也以英文资料为主。本文是给人看的说明，保持中文。

## 设计要点

- **冲突只在 F 解决**：rebase 改写 F，冲突留在 F 的 worktree；解决后 M 是 F 的祖先，`git merge --ff-only F` 只是快进，不会冲突，也不产生 merge commit。
- **测试只在必要时跑**：只有 `diverged` 会改写 F 的提交，旧测试结果不能代表新 tip；`ahead-of-main`、`behind-main`、`synced` 不引入未验证的新提交，不跑测试。
- **预检判断，脚本编排**：`preflight.sh` 只读检查，`fast-flow.sh` 走正常路径（preflight → rebase → 必要时测试 → 合入/停止）。
- **`needs-ai` 是脚本终点**：冲突、测试失败后由 skill 在现有 worktree 手动继续；不重跑脚本，也不提供 resume 参数。
- **单写者假设**：从脚本启动到合入/停止完成，M/F 分支和 worktree 由本流程独占；并发修改只有 Git 的拒绝兜底，没有额外加锁。
- **边界**：一次一个 M/F；不做 MR、多目标、stack 拆分；脚本不 push、不删分支，收尾按用户勾选执行。

## 依赖

- bash、git
- 测试：bats 1.13.0（仓库根 `package.json` 的 devDependency，`bun install` 后即可用）

## 测试

```sh
bun run test:bats    # 只跑本 skill 的 bats 套件
bun run test         # bats + 插件测试
```

- 环境变量（`JOBS`、`BATS_BIN`、`TMPDIR`）、bats 版本与 bun 环境见 [docs/tests.md](../../tests.md)。

## 目录

```text
skills/workflow/rebase-merge/
├── SKILL.md
└── scripts/
    ├── preflight.sh
    └── fast-flow.sh
```

测试在仓库根的 `tests/rebase-merge/`，不随 skill 安装。
