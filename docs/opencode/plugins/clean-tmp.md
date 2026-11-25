# clean-tmp — 清理 OpenCode 自己的临时目录

**前提：这是给容器环境做的。** 容器里 `/tmp/opencode` 在可写层，只有重建容器才会清空，而重建会打断开发；挂 `tmpfs` 会盖掉镜像里的目录，重启后一切归零；交给外部 cron 又要装调度器、还得跨进容器执行。所以让 OpenCode 自己在每轮执行结束时清扫 `/tmp/opencode`，**不调用任何模型**。

普通桌面环境的 `/tmp` 由系统自己清，这个插件基本没有意义。

`/tmp/opencode` 是 OpenCode 的运行时临时目录（`opencode debug paths tmp`，实际是 `$TMPDIR/opencode`）。OpenCode 不会清它：保留期清理只覆盖数据目录里的 shell / tool 输出（`~/.local/share/opencode`），归档或删除 session 也不动 tmp 里的文件。

## 里面会堆什么

会往里写的至少有：

| 写入方 | 路径 | 说明 |
| --- | --- | --- |
| agent 的 shell / 工具调用 | `$TMPDIR/opencode/*` | 内置环境提示明确要求「优先用这个目录而不是 `/tmp`」，脚本、下载、构建中间产物都会优先落这里 |
| `image_generate` | `images/<sessionID>/image_*` | 不指定 `path` 时，生成的图片直接写到这里 |
| `video_generate` | `videos/<sessionID>/*.mp4` | 同上，不指定 `path` 时的默认落盘位置 |
| 客户端暂存 | `$TMPDIR/opencode/*` | 文件写入接口允许写到 server tmp，客户端可以把待处理文件放进来 |

清扫的代价是每轮执行结束后一次 `readdir` + `lstat`，且最多 24 小时一次。

## /tmp 本身要不要一起清

不建议默认清。`/tmp` 根目录下混着别的进程的东西，而且大部分不是 OpenCode 的：

| 内容 | 归属 | 有清理吗 |
| --- | --- | --- |
| `opencode-pty-<uid>/<hash>.sock` | OpenCode 的持久 PTY daemon | 没有 |
| `opencode-untracked-*`（`.list` / `.index`） | OpenCode 的 git diff 批处理 | 有，批处理结束就删 |
| `.bun-*` | bun 运行时解出来的共享库，每个约 9–13 MB | 没有 |
| `mcp-*`、`code-*`、`bats-*`、`node-compile-cache` 等 | 其他工具 / 测试框架，OpenCode 源码里找不到写入方 | 各自负责 |

清 `/tmp` 的风险不是「删错文件」，而是删到还在跑的东西——socket、正在被映射的 `.so`、别的进程正在写的临时文件；按前缀猜别人的文件更不可取。

真要在单人容器里连 `/tmp` 一起收，至少得：只删自己认识的路径，只删普通文件和目录，跳过 socket/FIFO/软链目标，按 uid + mtime 过滤，并且默认关闭、显式开选项才生效。目前没有实现。

## 行为

- **触发**：`session.execution.succeeded` / `session.execution.failed` / `session.execution.interrupted`，即每轮执行结束时；fire-and-forget，不阻塞事件处理
- **触发范围**：事件是**按会话**的，不是全局空闲；多会话并发时仍可能和别的会话重叠
- **节流**：`ctx.storage` 记录 `lastSweep`，间隔小于 `minIntervalHours` 直接跳过；**没有记录时立即扫一次**
- **删除条件**：`/tmp/opencode` 的顶层条目，`mtime` 超过 `maxAgeDays` **且** 属主是本进程 UID
- **不跟随符号链接**：用 `lstat`，删的是链接本身
- **并发**：同一时刻只跑一轮，重叠触发直接返回
- **订阅生命周期**：`setup` 返回 cleanup，插件卸载时 `abort` 事件订阅
- **失败**：静默；目录不可写（`EACCES`/`EPERM`，例如镜像里是 `root:755`）时在日志里警告一次
- **目录本身不删**：只在其中删条目，避免把正在写的进程弄成 `ENOENT`

## 配置

参数走插件 options，都可以不写：

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [
    {
      "package": "/Path/to/agent-toolkit/opencode/plugins/clean-tmp",
      "options": { "maxAgeDays": 7, "minIntervalHours": 24 }
    }
  ]
}
```

| 字段 | 默认 | 含义 |
| --- | --- | --- |
| `maxAgeDays` | `7` | 多久没动过才删 |
| `minIntervalHours` | `24` | 两次清扫的最小间隔 |

传非数字、`NaN`、`Infinity` 或 ≤0 时**插件加载失败**（`setup` 里抛错），日志里能看到原因——配置写错不该静默退化成默认值。

## 安装

源码在本仓库 `opencode/plugins/clean-tmp/`。两条等价的加载途径，**二选一**：

### 方式一：配置引用源码目录（本机开发推荐）

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["/Path/to/agent-toolkit/opencode/plugins/clean-tmp"]
}
```

- 必须指向**目录**，指向单个文件会被忽略
- 路径被 watcher 监听，改源码即时生效，无需重启服务

### 方式二：放进全局发现目录

`~/.config/opencode/plugins/` 是自动发现目录，复制进去即可，无需注册：

```sh
cp -r opencode/plugins/clean-tmp ~/.config/opencode/plugins/
```

两种方式不要同时用，否则同一插件加载两次。用 `opencode plugin list` 检查，同一 ID 出现两次就是重复了。

## 验证

```sh
# 1. 造一个 8 天前的旧文件和一个新文件
touch -d '8 days ago' /tmp/opencode/old-probe
touch /tmp/opencode/new-probe

# 2. 在任意会话里发一条消息，等这一轮结束（触发 session.execution.succeeded）

# 3. 看结果：旧文件消失，新文件还在
ls /tmp/opencode
```

**注意节流**：24 小时内只扫一次。如果这个 server 刚扫过（`lastSweep` 在 `opencode.db` 的 `kv` 表里），第 2 步不会删除旧文件，看起来像失效。验证时把 `minIntervalHours` 临时调小即可：

```jsonc
{ "options": { "minIntervalHours": 0.001 } }   // 3.6 秒
```

已验证的删除行为：

| 场景 | 结果 |
| --- | --- |
| 8 天前的普通文件 | 删除 |
| 刚创建的文件 | 保留 |
| root 拥有的旧文件 | 保留（uid 不符） |
| 指向 `/tmp/victim-probe` 的旧符号链接 | 只删链接，目标文件完好 |
| `maxAgeDays: -1` | 插件 `state: failed`，错误里有 `options.maxAgeDays must be a positive number` |

删除之后 `lastSweep` 会更新，24 小时内不会再扫。

日志在 `~/.local/share/opencode/log/opencode.log`，出问题先看这里：

```sh
grep clean-tmp ~/.local/share/opencode/log/opencode.log
```

`opencode plugin list` 能确认加载状态；插件加载失败时 `opencode api get /api/plugin` 里会带 `state.failed.error`。

## 明确不做

| 不做 | 原因 |
| --- | --- |
| 清 `~/.cache/opencode`、`~/.local/share/opencode/log` | 缓存删了要重新下载，日志删了没法排查；各自该有各自的策略 |
| 删 `/tmp/opencode` 目录本身 | 运行中删根目录会让正在写的进程 `ENOENT` |
| 启动时清扫、卸载时全删 | 只保留一个触发点：执行结束事件。频率天然是"每轮一次"，且落在真正的空闲间隙 |
| `setInterval` 定时器 | 无生命周期锚点、跨重启丢状态、与 OpenCode 自身的调度没有协同 |
| 让模型参与清理 | 确定性动作不需要推理 |

## 备注

- 依赖服务端插件 API：`ctx.event.subscribe({ types: ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"] })`、`ctx.storage`、`ctx.options`
- `session.idle` 属于 TUI 侧合成事件，服务端事件流里不发；服务端在每轮结束时发的是 `session.execution.*`，所以插件用后者做触发点
- 服务端会持久化 idle 状态（`Session.Message.Idle`，`outcome` 为 `succeeded`/`failed`/`interrupted`），但那是状态记录，不是可订阅的事件
- 若将来给容器加 `tmpfs: /tmp`，本插件仍然有效：目录由运行时用户按需重建，权限天然是属主自己的

## 版本相关

- 删除行为表是手工验证的结果，事件语义（`session.execution.*` 可用、`session.idle` 不发）在服务端实测过；插件用到的 `Plugin.define`、事件订阅、`ctx.storage`、`ctx.options` 语义在 2.4.1 源码核对中未见变化
- 写入方是随版本增长的：`video_generate` 的默认落盘路径较新，旧版本只有图片。这只是「里面会堆什么」的变化，不影响清扫逻辑
