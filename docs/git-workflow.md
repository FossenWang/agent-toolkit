# 分支与发版

本仓库不接受 PR，也没有 PR 流程。

`main` 是稳定线，`develop` 是日常线。功能在 `feature/*` 上开发，rebase 后合入 `develop`；热修按需落到 `main` 或 `develop`；`main` 只接受 `develop` 和 `hotfix/*` 的快进。

合入由 `merge-branch.yml` 完成，只认两条：**已 rebase、可快进**，**测试通过**。测试跑在要推送的那个提交上，绿了才推送，失败什么都不动。

## 分支角色

| 分支 | 角色 | 来源 | 落点 | 可改写 |
| --- | --- | --- | --- | --- |
| `main` | 稳定线，默认分支 | `develop` / `hotfix/*` | — | 永不 |
| `develop` | 日常不稳定版 | `main`（热修同步） | `main`（发版） | 永不 |
| `feature/*` | 功能开发 | `develop` | `develop` | 可以 |
| `hotfix/*` | 线上修复 | `main` 或 `develop` | `main` / `develop` | 可以 |

## 不变量

1. `main` 只接受 `develop` 和 `hotfix/*` 的快进，不接受直接提交。
2. 合入前分支必须 rebase 到目标，具备可快进状态；把 `main` 合回 `develop` 时例外，那是本地普通合并。
3. 发版前 `main` 必须是 `develop` 的祖先，否则说明热修还没合回 `develop`。
4. `main` 和 `develop` 永不改写，任何情况下都不 force push。
5. 合入后分支保留，方便在同一个分支上继续修问题。

## 合并

合入统一走 `merge-branch.yml`，不要本地合并后直推。它保证三件事：合入前检查可快进、测试跑在真正要推送的提交上、`main` 的来源受控。

```sh
gh workflow run merge-branch.yml --ref main \
  -f branch=feature/x -f target=develop
```

| 输入 | 说明 |
| --- | --- |
| `branch` | 要合入的分支 |
| `target` | `develop` 或 `main` |
| `need-merge-commit` | 额外留一个合并提交，用于整段回退，默认不勾 |

合入 `main` 成功后会再触发一次 `ci.yml`，跑在新提交上。`GITHUB_TOKEN` 的 push 不会触发其他 workflow，少了这一步，`main` 的 CI 记录和徽章会停在旧提交。合入 `develop` 不补跑：门禁测试已经在待推送的提交上跑过，再跑一遍只是重复。

- 不勾 `need-merge-commit`：直接把分支推到目标；目标是分支的祖先，所以是快进。
- 勾选：以目标为基点先生成合并提交，再测试、再推送；前提仍是可快进，不放松 rebase 要求。
- 只保护 `main`：来源不是 `develop` 或 `hotfix/*` 一律拒绝；`develop` 不限制来源。
- 任何一步失败都不推送，远端保持原样。

唯一的例外是把 `main` 合回 `develop` 的热修同步：那是本地普通合并，原因见「热修」。

## 常用路径

### 功能

```sh
git switch develop && git switch -c feature/x
# 开发、提交
git fetch origin && git rebase origin/develop
git push -u origin feature/x
gh workflow run merge-branch.yml --ref main -f branch=feature/x -f target=develop
```

### 热修

只在必要时使用，落在哪个分支按现场决定：

| 情况 | 目标 |
| --- | --- |
| `main` 与 `develop` 刚同步过，或 bug 只存在于未发布代码 | `develop` |
| 生产在旧代码上出问题，`develop` 暂时不需要 | `main` |
| 两侧都要 | 先 `main`，再把 `main` 合回 `develop` |

```sh
git switch -c hotfix/y origin/main   # 或 origin/develop
# 修复、提交
git push -u origin hotfix/y
gh workflow run merge-branch.yml --ref main -f branch=hotfix/y -f target=main
```

修复落到 `main` 后，如果 `develop` 也要带上它，就把 `main` 合回 `develop`。这一步不进 Actions：`develop` 通常已有 `main` 没有的提交，无法快进，冲突也只能人工处理。

```sh
git switch develop
git pull --ff-only
git merge main              # 有冲突在这里解决
bun run test
git push
```

`git merge` 本身会产生合并提交，不要加 `--ff-only`。测试在推送前跑过，`develop` 一般不会红。时机自行决定，推迟到发版前也可以；发版时的快进检查会失败并提示先同步。

冲突复杂、想先让 Actions 验证时，把结果放到分支上再走合并流程：

```sh
git switch -c hotfix/merge-main-into-develop origin/develop
git merge main
git push -u origin hotfix/merge-main-into-develop
gh workflow run merge-branch.yml --ref main \
  -f branch=hotfix/merge-main-into-develop -f target=develop
```

### 发版

```sh
gh workflow run merge-branch.yml --ref main -f branch=develop -f target=main
```

快进，`main` 与 `develop` 同树。暂不打版本号、不生成 Release。

## 合并方式一览

| 用途 | 合并提交 | 快进要求 |
| --- | --- | --- |
| 日常功能 → `develop` | 无 | 必须已 rebase |
| 大型功能 → `develop` | 勾选 `need-merge-commit` | 必须已 rebase |
| `hotfix/*` → `main` | 无 | 必须已 rebase |
| `develop` → `main`（发版） | 无 | 必须已 rebase |
| `main` → `develop`（热修同步） | 有 | 本地合并，不走 Actions |

## 历史约定

- 看功能级历史用第一父链：`git log --first-parent --oneline main`
- 整段回退带合并提交的功能：`git revert -m 1 <merge-commit>`
- 已合入的提交不改写：不 squash，不 rebase `develop`，不改写 `main`
- 分支保留后重新合并，已合入的改动会按 patch-id 自动丢弃，只留下新提交

## 尚未落地

- 按版本打 tag 与 Release
- 远端旧分支的定期清理
