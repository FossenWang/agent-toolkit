# npx-skills

类型：自建。

用 `npx skills` 查找、评估、安装 agent skill，覆盖发现、推荐质量判断、非交互安装、大仓库安装和安装后确认。由用户手动调用（`disable-model-invocation: true`）：CLI 不解析 skill 之间的依赖，这个 skill 负责在安装前把依赖理清。

## 目录内容

- `SKILL.md`：主流程（`find` / `add` / `list`）
- `large-repos.md`：大仓库或 clone 卡住时改走稀疏克隆
- `scripts/add-sparse.sh`：稀疏克隆脚本，Linux/macOS，git 2.25+

## 维护

- 推荐规则（安装量、来源可信度）随使用反馈调整。
- `scripts/add-sparse.sh` 依赖 CLI 当前的 clone 形态；CLI 升级后要重新验证，见 [npx-skills-cli.md](../npx-skills-cli.md)。
- `--mirror` 是环境相关的传输前缀，不写死默认值。
