# codex-switch

单文件 bash CLI，在多个 Codex CLI 模型供应商之间快速切换，风格类似 git 子命令。

## 特性

- `git` 风格子命令：`ls` / `use` / `status` / `test` / `add` / `rm`
- 无参数时调用 `fzf` 交互选择（未安装 fzf 自动降级为列表）
- **安全改写 `~/.codex/config.toml`**：只修改顶层 `model`、`model_provider` 和对应 `[model_providers.<name>]` 段，其余段（`[plugins.*]`、`[desktop]` 等）原样保留
- 写入前自动备份 `config.toml.bak`，临时文件 + `mv` 原子写入
- **API key 安全**：不写入 `providers.json` 或 Codex 配置，`use`/`status` 只检查环境变量是否 export；仅在你显式同意时才写入可选 `~/.codex-switch/keys.env`（权限 600）自动 source
- 内置冒烟测试：`curl` 一次 `/responses`（或 `/chat/completions`）端点，显示 HTTP 状态和延迟
- 零依赖：bash 3.2+ + 系统自带 python3 + curl；`fzf` 可选
- 附赠命令：`edit`（$EDITOR 编辑清单）、`doctor`（健康检查）、`install`（自动配置 PATH 和别名）

## 安装

```bash
git clone https://github.com/Xiang-98/codex-switch.git ~/Documents/codex-switch && cd ~/Documents/codex-switch
./codex-switch.sh install   # 链接 ~/bin/codex-switch -> 本仓库脚本，并幂等配置 PATH + alias cs
source ~/.zshrc
```

`install` 创建的是符号链接，之后 `git pull` 更新即生效，无需重新安装。

## 卸载

```bash
codex-switch uninstall           # 切回官方默认 + 删除 ~/bin 链接 + 清理 rc 配置（自动备份 rc）
codex-switch uninstall --purge   # 额外删除数据目录 ~/.codex-switch
```

若当前供应商不是官方默认，卸载会先提示切回（移除 `config.toml` 中的 `model`/`model_provider`），再清理自身；不会删除仓库目录。

## 快速开始

```bash
$ codex-switch add
供应商名称 (如 go): go
base_url (如 https://opencode.ai/zen/go/v1): https://opencode.ai/zen/go/v1
model (如 deepseek-v4-flash): deepseek-v4-flash
env_key（变量名，不是 API key）[OPENCODE_GO_KEY]:
wire_api [responses，可选 chat]:
现在把 key 写入 ~/.codex-switch/keys.env 吗? [y/N] y
OPENCODE_GO_KEY = ********
✓ 已添加 go (deepseek-v4-flash)

$ codex-switch use go
✓ 已切换到 go (deepseek-v4-flash)
  base_url: https://opencode.ai/zen/go/v1
  key: OPENCODE_GO_KEY ✓ 已设置

$ codex-switch test
ℹ POST https://opencode.ai/zen/go/v1/responses
✓ go 连通正常 (HTTP 200, latency 412ms)

$ codex-switch ls
* go      deepseek-v4-flash  https://opencode.ai/zen/go/v1
  openai  官方默认
```

## 命令

| 命令 | 说明 |
| --- | --- |
| `codex-switch` | fzf 交互选择（未装 fzf 时等同 `ls`） |
| `codex-switch ls` | 列出供应商，当前项前缀 `*` |
| `codex-switch use <name>` | 切换供应商；`openai` 恢复官方默认 |
| `codex-switch status` | 当前供应商 + config.toml 实际状态 + key 检查 + 配置不一致告警 |
| `codex-switch test [name]` | 冒烟测试连通性和延迟 |
| `codex-switch add` | 交互式添加供应商，可选写入 key 到 keys.env |
| `codex-switch rm <name> [-y]` | 删除供应商；删的是当前项时会提示切回官方默认 |
| `codex-switch edit` | 用 `$EDITOR` 编辑 providers.json，保存后校验 JSON |
| `codex-switch doctor` | 健康检查（python3 / tomllib / curl / fzf / 配置语法 / key） |
| `codex-switch install` | 符号链接到 `~/bin` + 幂等配置 PATH 和 `alias cs` |
| `codex-switch uninstall [--purge]` | 卸载：删链接、清理 rc 配置；`--purge` 追加删除数据目录 |

## 数据存储

供应商清单在 `~/.codex-switch/providers.json`：

```json
{
  "current": "go",
  "providers": {
    "go": {
      "base_url": "https://opencode.ai/zen/go/v1",
      "model": "deepseek-v4-flash",
      "wire_api": "responses",
      "env_key": "OPENCODE_GO_KEY"
    },
    "openai": { "official": true }
  }
}
```

带 `official: true` 的条目表示官方默认：切换时删掉 `config.toml` 里的 `model` / `model_provider` 行恢复默认。

## 工作原理（use）

1. 读取 `~/.codex/config.toml`
2. 内嵌 python3 做行级手术：替换顶层 `model` / `model_provider`，重写目标 `[model_providers.<name>]` 段，其他所有段逐字保留
3. 有 tomllib（python ≥ 3.11）时写入前后各做一次严格 toml 校验，否则降级为轻量检查
4. 写入前备份为 `config.toml.bak`
5. 临时文件 + `mv` 原子替换，权限收紧为 600

## API Key 原则

- key 不写入 `providers.json` 或 Codex 配置；仅 `add` 时显式同意才会写入 `keys.env`
- `use` / `status` 只检查对应 `env_key` 环境变量是否已 export，未设置则提示
- 可选：`~/.codex-switch/keys.env` 中写 `export XXX_KEY="..."`，权限 600，`use` / `status` / `test` 前自动 source

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CODEX_SWITCH_HOME` | `~/.codex-switch` | 数据目录 |
| `CS_CODEX_CONFIG` | `~/.codex/config.toml` | Codex 配置路径 |
| `NO_COLOR` | — | 设置后禁用彩色输出 |

## 路线图

- [ ] 用量显示（opencode.ai 控制台 API）
- [x] `edit` / `doctor` / `install`

## 许可证

[MIT](LICENSE) © Xiang-98
