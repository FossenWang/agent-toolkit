# title-local — 用首条消息生成会话标题

**前提**：OpenCode 默认在会话首次提交输入时，交给 `title` agent 调一次模型生成标题。当这个辅助请求落在 zen 免费池时会被 gate 拒绝（`403 FreeTierError`），而标题链路会静默吞掉错误且不重试，结果是免费模型会话永远没有标题。

插件在标题请求发出前直接用会话首条消息给出标题，跳过模型调用：零 token、零网络，与主模型、代理、网络环境无关。

## 行为

- **接管点**：`session.hook("title")`。设置 `event.result` 即跳过这次模型请求
- **标题来源**：会话首条 user 消息的第一个非空行；去掉行首 Markdown 标记（`#`、`>`、`*`、`-`），压缩连续空白，超过 40 字符截断并追加 `…`
- **已有标题时不接管**：`session.title !== undefined` 直接返回，留给原本的链路
- **拿不到文本时不接管**：首条消息是纯附件、或读不到会话，都安静地让原链路处理
- **不解析提示词**：只用 `session.hook("title")`、`session.get`、`session.context` 三个公开接口，不认识 OpenCode 的模板字符串
- **不调用模型**，也不干预手动改名（`/rename <文字>` 走的是改名路径）

## 子代理会话不会被接管

子代理的会话在创建时就带上了标题：子代理工具把自己收到的 `description` 直接写成该会话的 `title`（`@opencode/core` 的 `tool/plugin/subagent.ts` 里 `sessions.create({ parentID, title: input.description, ... })`）。

于是：

- OpenCode 不会为它发起标题请求——标题生成只在「根会话 + 还没有标题」时发生；
- 插件即使被调用，也会因为 `session.title !== undefined` 直接让行。

子代理卡片上显示的就是那个 `description`，和本插件无关。这也意味着给子代理起名要准确，它不会像普通会话那样按首行或模型结果改写。

## 安装

源码在本仓库 `opencode/plugins/title-local/`。两种加载方式**二选一**：

### 方式一：配置引用源码目录（本机开发推荐）

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["/Path/to/agent-toolkit/opencode/plugins/title-local"]
}
```

- 必须指向**目录**，指向单个文件会被忽略
- 路径被 watcher 监听，改源码即时生效，无需重启服务

### 方式二：放进全局发现目录

`~/.config/opencode/plugins/` 是自动发现目录，复制进去即可，无需注册：

```sh
cp -r opencode/plugins/title-local ~/.config/opencode/plugins/
```

两种方式不要同时用，否则同一插件加载两次。用 `opencode plugin list` 检查，同一 ID 出现两次就是重复了。

## 验证

1. 新开一个会话，发送任意消息
2. 标题应当就是这条消息的首行（去掉了 Markdown 前缀），而不是模型生成的短语
3. `opencode api get /api/session` 可以直接查到 title

没生效时看日志：

```sh
grep title-local ~/.local/share/opencode/log/opencode.log
```

## 明确不做

| 不做 | 原因 |
| --- | --- |
| 解析提示词模板判断「初始生成 / 重新生成」 | 模板是 OpenCode 的内部实现，改一个字就失效，还会把包装文字当标题 |
| 重新生成标题 | 当前版本的重新命名只是改名，不会重新发起标题请求 |
| 用模型润色首行 | 目标就是零 token |
| 覆盖手动标题 | 已有标题时直接让行 |

## 版本相关

- 只在会话**还没有标题**时接管。数据层里「没有标题」是 `undefined`；空字符串会被当成已有标题，所以这里用 `!== undefined` 而不是 `!session.title`
- 「标题请求只在首条输入后、首轮请求前发出」是 OpenCode 的调度行为，插件不依赖这个时序，只是它决定了插件的实际触发时机
- OpenCode 若改回「改标题也重新生成」，本插件会因为「已有标题」而自动让行，不需要跟着改
- 子代理会话带标题这件事来自 OpenCode 的创建路径，不是插件行为；核对版本时一并看过

核对版本：OpenCode 2.4.1。
