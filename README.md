# agent-toolkit

[![CI](https://github.com/FossenWang/agent-toolkit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/FossenWang/agent-toolkit/actions/workflows/ci.yml)

个人在用的 agent 工具合集：skill 与 OpenCode 插件。只收通用、可复用的部分，不绑定特定机器、内网或模型账号。

## skill

源码在 `skills/`，用子目录分组；说明文档在 [docs/skills](docs/skills/README.md)。

| skill | 用途 |
| --- | --- |
| `agents-draft` | 把本会话已加载的指令文件放进草稿箱，审阅后一次性写回 |
| `npx-skills` | 用 `npx skills` 安装 skill，并解析其依赖 |
| `git-commit` | 按 Conventional Commits 从 diff 生成提交信息 |
| `rebase-merge` | 功能分支 rebase 到主线后快进合入 |
| `grilling` | 反复追问，压测方案与决策；常配合 mattpocock 其他 skill 使用，安装见 [mattpocock.md](docs/skills/mattpocock.md) |

这些 skill 都装到全局。先看有哪些：

```sh
npx skills add FossenWang/agent-toolkit --list
```

安装需要的：

```sh
npx skills add FossenWang/agent-toolkit -s '<name>' -a codex -g
```

从源码安装全部：

```sh
npx skills add ./skills \
  -s agents-draft -s npx-skills -s git-commit -s rebase-merge -s grilling \
  -a codex -g
```

`-g` 必带，装到 `~/.agents/skills`，多个 `-s` 可以一次装完。细节见 [npx-skills-cli.md](docs/skills/npx-skills-cli.md)。

## OpenCode 插件

源码在 `opencode/plugins/<name>/`，目录名就是插件 id；说明文档在 [docs/opencode/plugins](docs/opencode/plugins/README.md)。

| 插件 | 用途 |
| --- | --- |
| `clean-tmp` | 清扫 OpenCode 自己的临时目录，供容器环境使用 |
| `title-local` | 用首条消息本地生成会话标题，不调用模型、不联网，零花费 |
| `warming` | 按会话保温 prompt cache，默认关闭，只对显式开启的会话发 ping |

插件通过 `opencode.jsonc` 的 `plugins` 显式引用，不依赖自动发现。

## License

MIT
