# 测试

仓库级测试入口。测试按套件放子目录，不随 skill 或插件一起分发。

## 目录

| 路径 | 用途 |
| --- | --- |
| `run.sh` | bats 入口：处理环境变量与并行度 |
| `rebase-merge/` | `skills/workflow/rebase-merge` 的 bats 套件 |
| `title-local/` | `opencode/plugins/title-local` 的 bun 测试 |
| `clean-tmp/` | `opencode/plugins/clean-tmp` 的 bun 测试 |
| `smoke/` | 用真实 OpenCode 验证插件能被加载 |

## 环境准备（bun）

bats 和插件测试都走仓库根的 `package.json`，所以先装 bun：

- 官方脚本装到 `~/.bun`（`BUN_INSTALL`）：二进制约 100 MB，另带包缓存
- **不往 PATH 里加 `~/.bun/bin`**。把 `bun`、`bunx` 软链到已经在 PATH 上的 `~/.local/bin`：

  ```sh
  ln -s ~/.bun/bin/bun  ~/.local/bin/bun
  ln -s ~/.bun/bin/bunx ~/.local/bin/bunx
  ```

  `bun upgrade` 替换的是 `~/.bun/bin/bun` 本体，软链不受影响

- 依赖：`bun install`，生成 `bun.lock`（入库）；`node_modules/` 已忽略
- 维护：`bun upgrade` 升级；`bun pm cache rm` 清缓存

## 依赖

- bats 1.13.0 是仓库根的 devDependency，`bun install` 之后由 `node_modules/.bin/bats` 提供
- 插件测试依赖 `@opencode/plugin`，同样在仓库根

## 运行

```sh
bun run test              # bats 套件 + 插件测试
bun run test:bats         # 只跑 bats
bun run test:plugins      # 只跑插件测试
bun run test:smoke        # 用真实 OpenCode 验证插件加载
```

单独跑 bats 时可以直接给参数：

```sh
bash tests/run.sh --filter 'diverged'
```

## 加载冒烟

`tests/smoke/` 不跑 fake ctx，而是用隔离的 `HOME`/XDG 目录和私有端口起一个 OpenCode 服务，确认两个插件真的被加载。它需要 `opencode` 可执行文件，缺失时整条测试跳过，所以不在 `test` 的默认链里。

```sh
bun run test:smoke
```

断言三件事：`opencode plugin list` 里两个插件 ID 各出现一次、SOURCE 指向本仓库的源码目录、没有以 `-` 开头的失败行。测试结束会停掉自己起的服务，不碰用户配置。

bats 的查找顺序：`BATS_BIN` → `node_modules/.bin/bats` → `npx bats@1.13.0`。前两个都没有时才走 npx，所以装好依赖就能离线跑。

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `JOBS` | `3` | bats 并行度；找不到 GNU parallel 或 rush 时自动降为 1 |
| `BATS_BIN` | 空 | 指定已安装的 bats，优先于本地依赖 |
| `TMPDIR` | `mktemp -d` | bats 夹具的临时目录；显式设置则按给定路径使用并要求可写 |

没设置 `TMPDIR` 时，每次运行会在系统临时目录下建一个独占目录，成功时删除；失败时保留并打印路径，方便看现场。显式设置 `TMPDIR` 就按给定路径使用，不可写直接报错退出（退出码 2），不做静默回退。

## 新增套件

1. 放 `tests/<suite>/`：bats 用例写成 `*.bats`，公共函数放 `helpers.bash`
2. bats 套件在 `run.sh` 的 `suites` 数组里登记；bun 测试放 `tests/<suite>/`，并把目录加进 `package.json` 的 `test:plugins`
3. 插件测试通过 `bun:test` 编写，直接 import 插件默认导出并捕获 `setup` 注册的回调，不修改插件源码

测试留在仓库根，skill 目录只放运行资产，安装时不会带走测试。
