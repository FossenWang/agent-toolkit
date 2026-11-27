# OpenCode 插件

源码在 `opencode/plugins/<name>/`，目录名就是插件 id；本目录放说明文档。其他 harness 的插件文档放到 `docs/<harness>/plugins/`。

| 插件 | 用途 | 说明 |
| --- | --- | --- |
| `clean-tmp` | 清扫 OpenCode 自己的临时目录 | [clean-tmp.md](clean-tmp.md) |
| `title-local` | 用首条消息本地生成会话标题，不调用模型 | [title-local.md](title-local.md) |
| `warming` | 按会话保温 prompt cache，默认关闭 | [warming.md](warming.md) |

## 维护约定

- 一个插件一个目录，目录名就是插件 id；说明文档放 `docs/opencode/plugins/<name>.md`。
- 插件只通过 `opencode.jsonc` 的 `plugins` 显式引用，不依赖自动发现。
- 插件之间不互相 import。
- 安装与配置写在每个插件的文档里，本页只做索引。

## 测试

OpenCode 没有官方的插件测试方案：没有 testing 文档，没有 `@opencode/plugin/testing`，也没有 `opencode plugin test`。社区通行做法是把插件的默认导出当普通对象，写一个 fake ctx 再调 `setup`，断言副作用。

- 测试放仓库根的 `tests/<plugin>/`，不放插件目录；插件目录保持单文件，测试随仓库分发，不随插件拆走。
- 依赖装在仓库根（`package.json`），不在插件目录建房 `package.json`；跑法见 [docs/tests.md](../../tests.md)：
  - `bun run test:plugins` 或 `bun test tests/`（全部）
  - `bun run test`（bats + 插件测试）
- **不改插件源码**：测试直接 import `opencode/plugins/<name>/index.ts` 的默认导出。
- ctx 类型从插件反推，不要手抄：`type Ctx = Parameters<typeof plugin.setup>[0]`。插件升级 API 时测试会编译报错，而不是悄悄失真。
- fake ctx 只实现用到的字段：
  - `title-local`：`session.hook` 记录回调后手动触发，`session.get` / `session.context` 返回构造数据；
  - `clean-tmp`：`event.subscribe` 用异步生成器，`storage` 用内存 Map，文件操作用 `mkdtemp` 的真目录。
- 单文件插件测不到内部函数，这是有意的取舍：`titleOf` 这类逻辑通过 hook 回调间接验证，不为测试加导出。
- 框架用 `bun:test`：插件运行时是 bun；社区里 `bun:test` 与 `vitest` 各占一半。
- 发布前测**装好的包**，不只测工作区里的副本（官方唯一的明确要求）：临时 `opencode.jsonc` 指向插件目录，用 `opencode plugin list` 和 `/api/plugin` 确认 `active`，再跑一次真实会话。
- 真机验证步骤（发消息看标题、造旧文件看是否删除）写在各自的插件文档里，与自动化测试分开。
