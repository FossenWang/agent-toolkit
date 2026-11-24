# git-commit

按 Conventional Commits 写提交信息。分叉自
[github/awesome-copilot › skills/git-commit](https://github.com/github/awesome-copilot/tree/a8940549dcf7258a2cdaa0b7fc9a9ac7fceec466/skills/git-commit)。

## 分叉说明

- 分叉点：`a8940549dcf7258a2cdaa0b7fc9a9ac7fceec466`（2026-11-05）
- 初始分叉：`98b45a78`
- 后续有意引入上游 `2eff5682`、`f65c41ef`、`a8940549` 的进行中操作守卫
- 不跟随上游更新，升级时按上述 commit 手动对照

## 改动

- frontmatter：description 精简为触发场景与排除项，去掉 `compatibility` 与 `allowed-tools`，保留 `license: MIT`。
- 工作流合并重复的「写消息」步骤，去掉 PowerShell 说明和重复的 intro。
- 引入进行中操作守卫：merge / cherry-pick / revert / rebase / am 或存在 unmerged 文件时，不 unstage、不拆分提交；合并类操作沿用 Git 预置消息（`git commit --no-edit`）。
- 冲突处理改成显式暂存已解决文件，不依赖 Git 2.56；暂存前用 `git diff --check` 检查残留冲突标记，binary / delete / rename 等结构冲突交给用户。
- 不采用上游的 `git add --resolved` + Git 2.56 分支、porcelain v2 判定矩阵，也不解析本地化的 `git status` 文案。
- 正文只写判断与约束；模型已掌握的通用 Git 命令不列，固定策略或安全边界的命令/参数保留。
- Footer 只保留 `Token: value` 一种写法。
- Safety Rules 由五条压成三条。

## License

MIT License, Copyright GitHub, Inc. Upstream: [awesome-copilot/LICENSE](https://github.com/github/awesome-copilot/blob/a8940549dcf7258a2cdaa0b7fc9a9ac7fceec466/LICENSE).
