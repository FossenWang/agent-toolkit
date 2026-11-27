# warming — 按会话保温缓存

按会话开启 prompt cache 保温：开启后定时发一次最小请求，让缓存不过期。默认关闭，只对显式开启的顶层会话生效。

官方 warming 是模型级配置，给每个顶层会话各起一个 fiber，没有单会话开关；想要「只保温这几个会话」只能自己调度。所以这个插件替代官方 warming，不叠加使用。

## 边界

- **缓存寿命由 provider 决定。** DeepSeek 官方 API 没有 TTL 参数，`opencode-go` 网关也没有公布；OpenCode 的 `settings.cache.ttl` 只是声明，还会透传给上游，未验证。因此这里做的是「在过期前续期」，不是「把 TTL 改长」。
- **ping 是真实请求。** 走 `ctx.session.generate`，不写历史、不产生用户消息，但仍按缓存读取计费。命中时成本约为输入价的 1/N。
- **只能保温顶层会话。** 子会话（subagent）不单独调度。

## 与官方 warming 的关系

两者会同时 ping，必须二选一。用本插件时把模型的 warming 关掉：

```jsonc
"providers": {
  "opencode-go": {
    "models": {
      "deepseek-v4.1-flash": {
        "settings": { "cache": { "warming": false } }
      }
    }
  }
}
```

配置热加载后，官方已有的 loop 会在下一次 ping 时看到 Off 并停止，不需要重启。之后再开启本插件的会话。

## 安装

`opencode.jsonc` 的 `plugins` 加上插件目录，然后 `opencode reload`：

```jsonc
"plugins": [
  "/path/to/agent-toolkit/opencode/plugins/warming"
]
```

插件只通过 `plugins` 显式引用；本地路径插件不参与自动更新。

## 命令

```text
/warm            状态
/warm on         开启当前会话
/warm off        关闭当前会话
/warm now        立即 ping 一次（未开启时先开启）
/warm status     状态
```

命令回执走 `session.synthetic({ resume: false })`，进 inbox 待投递区，不唤醒模型。需要立刻看到回执时手动刷新一次会话。

## 行为

- **默认关闭**：新会话不保温，必须 `/warm on`。
- **间隔**：默认 25 分钟，基于该模型约 30 分钟的滑动 TTL 经验值；命中后按同一间隔续期。
- **空闲停止**：距最近一次真实请求超过 12 小时就停，避免没人回来还在花钱。
- **miss 停止**：ping 返回 `cache.write > cache.read` 视为未命中，立即停止该会话并记录原因；provider 不报告缓存用量时不会误判。
- **真实请求续期**：`session.execution.*` 刷新窗口，下一次 ping 重新计时。
- **归档/删除停止**：`session.archived` / `session.deleted` 直接停止。
- **持久化**：状态存在插件 storage 的 `warming:state`，插件重载后恢复；不依赖内存定时器。
- **单循环**：一个 30 秒的 tick 扫描到期会话，不为每个会话建 timer。

## 配置

写在插件 options 里（键名固定）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `intervalMinutes` | 25 | 两次 ping 的间隔 |
| `maxIdleHours` | 12 | 距真实请求超过多久停止 |
| `tickSeconds` | 30 | 调度扫描周期 |
| `prompt` | 官方同款 keep-alive 文本 | ping 内容 |

## 已知限制

- **没有可视化面板。** Web UI 不加载 GUI 插件，状态只能看 `/warm` 或插件日志。
- **不区分路由抖动与真过期。** 单次 miss 就停，宁可少花钱，不自动降间隔重试；需要继续时 `/warm on` 重新开。
- **成本只有上界。** 命中时每次约 `cache.read` 计价，但 provider 的计费字段不统一，插件不做预算累计。
- **不做自适应 TTL 测量。** 间隔是固定配置，先用经验值；要自适应得另做一版，用 ping 的 `cache.read` 反推。

## 测试

`tests/warming/` 用 fake ctx 驱动：默认不 ping、到点 ping、命中续期、miss 停止、归档停止、命令开关、状态持久化。跑法见 [docs/tests.md](../../../tests.md)。

```sh
bun test tests/warming
```
