# OpenCode 插件

源码在 `opencode/plugins/<name>/`，目录名就是插件 id；本目录放说明文档。其他 harness 的插件文档放到 `docs/<harness>/plugins/`。

| 插件 | 用途 | 说明 |
| --- | --- | --- |
| `clean-tmp` | 清扫 OpenCode 自己的临时目录 | [clean-tmp.md](clean-tmp.md) |
| `title-local` | 用首条消息本地生成会话标题，不调用模型 | [title-local.md](title-local.md) |

## 维护约定

- 一个插件一个目录，目录名就是插件 id；说明文档放 `docs/opencode/plugins/<name>.md`。
- 插件只通过 `opencode.jsonc` 的 `plugins` 显式引用，不依赖自动发现。
- 插件之间不互相 import。
- 安装与配置写在每个插件的文档里，本页只做索引。
