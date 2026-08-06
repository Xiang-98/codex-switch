<div align="center">

# codex-switch

单文件 bash CLI，在多个 Codex CLI 模型供应商之间快速切换，风格类似 git 子命令。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-green)
![Codex 0.118+](https://img.shields.io/badge/Codex-0.118%2B-blue)
![platform macOS](https://img.shields.io/badge/platform-macOS-lightgrey)

[特性](#特性) · [安装](#安装) · [快速开始](#快速开始) · [供应商清单](#支持-responses-api-的供应商) · [命令](#命令) · [环境变量](#环境变量)

</div>

## 特性

- `git` 风格子命令：`ls` / `use` / `status` / `test` / `add` / `rm`
- 无参数时调用 `fzf` 交互选择（未安装 fzf 自动降级为列表）
- **安全改写 `~/.codex/config.toml`**：只修改顶层 `model`、`model_provider` 和对应 `[model_providers.<name>]` 段，其余段（`[plugins.*]`、`[desktop]` 等）原样保留
- 写入前自动备份 `config.toml.bak`，临时文件 + `mv` 原子写入
- **API key 安全**：不写入 `providers.json` 或 Codex 配置；仅在你显式同意时写入 `~/.codex-switch/keys.env`（权限 600），Codex 通过本地凭据命令按需读取
- **桌面端免重启切换**：`use` 后新建 Codex 任务即可生效，无需退出应用
- 内置冒烟测试：`curl` 一次 `/responses` 端点，显示 HTTP 状态和延迟
- 轻量依赖：Codex 0.118.0+、bash 3.2+、python3、curl；`fzf` 可选
- 附赠命令：`edit`（`$EDITOR` 编辑清单）、`doctor`（健康检查）、`install`（自动配置 PATH 和别名）、`update` / `upgrade`（安全更新）

## 运行要求

命令式认证要求 **Codex 0.118.0 或更高版本**。这是首个正式支持自定义模型供应商动态获取及刷新 bearer token 的稳定版本，见 [Codex 0.118.0 release notes](https://github.com/openai/codex/releases/tag/rust-v0.118.0) 和对应的 [实现 PR #16288](https://github.com/openai/codex/pull/16288)。

CLI 和桌面端各自使用自己的 Codex 运行时；你实际使用的那个运行时必须满足最低版本。可运行以下命令检查，`doctor` 会同时检查 PATH 中的 CLI 和 macOS 桌面端内置运行时：

```bash
codex --version
codex-switch doctor
```

切换带 `env_key` 的自定义供应商时也会自动校验：没有检测到 0.118.0+ Codex 运行时就停止写配置。非标准安装路径可用 `CODEX_SWITCH_CODEX_BIN=/path/to/codex` 指定待检查的二进制。

## 安装

```bash
git clone https://github.com/Xiang-98/codex-switch.git ~/Documents/codex-switch && cd ~/Documents/codex-switch
./codex-switch.sh install   # 链接 ~/bin/codex-switch -> 本仓库脚本，并幂等配置 PATH + alias cs
source ~/.zshrc
```

`install` 创建的是符号链接，之后运行以下任一命令即可更新，无需重新安装：

```bash
codex-switch update
codex-switch upgrade  # update 的同义命令
```

更新仅允许 Git 快进合并；仓库存在未提交修改或分支发生分叉时会停止，不会覆盖本地改动。

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
model (如 gpt-5.6-luna): gpt-5.6-luna
env_key（变量名，不是 API key）[OPENCODE_GO_KEY]:
现在把 key 写入 ~/.codex-switch/keys.env 吗? [y/N] y
OPENCODE_GO_KEY = ********
✓ 已添加 go (gpt-5.6-luna)

$ codex-switch use go
✓ 已切换到 go (gpt-5.6-luna)
  base_url: https://opencode.ai/zen/go/v1
  key: OPENCODE_GO_KEY ✓ 已设置

$ codex-switch test
ℹ POST https://opencode.ai/zen/go/v1/responses
✓ go 连通正常 (HTTP 200, latency 412ms)

$ codex-switch ls
* go      gpt-5.6-luna  https://opencode.ai/zen/go/v1
  openai  官方默认
```

## 支持 Responses API 的供应商

当前 Codex 仅支持 `wire_api = "responses"`（见[数据存储](#数据存储)），供应商必须提供 OpenAI Responses 格式的 `/responses` 端点。

### 原生支持（可直接接入）

以下供应商已确认原生支持 Responses API，可直接 `codex-switch add` 接入（model 名称以各平台控制台为准）：

| 供应商 | base_url | 说明 |
| --- | --- | --- |
| OpenAI 官方 | 内置 `openai`，无需添加 | Codex 默认供应商 |
| [Azure OpenAI](https://learn.microsoft.com/azure/ai-foundry/openai/overview) | `https://{resource}.openai.azure.com/openai/v1` | 需替换 `{resource}` 为你的资源名 |
| [阿里云百炼](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-responses) | `https://dashscope.aliyuncs.com/compatible-mode/v1` | Qwen 系列；推荐迁移到带业务空间 ID 的新域名 |
| [火山方舟（豆包）](https://www.volcengine.com/docs/82379/1585128) | `https://ark.cn-beijing.volces.com/api/v3` | Doubao 系列，个别老模型不支持 |
| [百度千帆](https://cloud.baidu.com/doc/qianfan/s/Smovaaszj) | `https://qianfan.baidubce.com/v2` | ERNIE 系列，也托管 DeepSeek 等第三方模型 |
| [MiniMax](https://platform.minimaxi.com/docs/token-plan/codex) | `https://api.minimaxi.com/v1` | MiniMax-M 系列；官方提供 Codex 接入文档 |
| [xAI](https://docs.x.ai/) | `https://api.x.ai/v1` | Grok 系列，含 Live Search 等内置工具 |
| [OpenRouter](https://openrouter.ai/docs/api/reference/responses/overview) | `https://openrouter.ai/api/v1` | 300+ 模型聚合；Responses 为 Beta 且无状态（拒绝 `store: true` / `previous_response_id`） |
| [七牛云](https://news.qiniu.com/archives/1784274369892) | `https://api.qnaigc.com/bypass/openai/v1` | Codex 专用 Responses 端点，聚合多家模型 |
| [opencode zen](https://opencode.ai/) | `https://opencode.ai/zen/go/v1` | 见上方快速开始示例 |

### 仅 Chat Completions（需中转或网关）

DeepSeek 官方、Kimi（月之暗面）、智谱 GLM、腾讯混元、硅基流动、阶跃星辰，以及 Groq / Together / Fireworks / Gemini OpenAI 兼容端点等平台**只有** `/chat/completions` 接口，不提供 `/responses` 端点，直连会 404。想用这些模型可以：

- 经上表中的**平台方**中转——例如百度千帆、七牛云上托管了 DeepSeek / Kimi 等模型，走平台的 Responses 端点即可（deepseek-v4-flash 这类模型通常就是这么接入的）；
- 自建协议转换网关，把 `/responses` 转成 `/chat/completions`，如 [LiteLLM](https://github.com/BerriAI/litellm)、[new-api](https://github.com/QuantumNous/new-api)、[codex-openai-proxy](https://github.com/scorpioash/codex-openai-proxy)、[GodeX](https://www.oschina.net/news/450110)。

> 提示：接入后一律用 `codex-switch test` 验证——HTTP 200 即可用；404 通常意味着该端点不支持 Responses API。

## 思考量级与自定义供应商

在 Codex 里切换思考量级（`/model` 选 low / medium / high…）**不会切换供应商**：它只是改变请求体里的 `reasoning.effort` 参数，请求仍发往当前 `model_provider` 的 base_url，codex-switch 写入的配置不受影响。

自定义模型要在 `/model` 菜单里正确显示可用档位，需用 `model_catalog_json` 声明模型能力（参考 [MiniMax](https://platform.minimaxi.com/docs/token-plan/codex)、[小米 MiMo](https://mimo.mi.com/docs/zh-CN/tokenplan/integration/codex-configuration) 的官方 Codex 文档）：

```toml
# ~/.codex/config.toml
model_catalog_json = "~/.codex/model-catalogs/custom-catalog.json"
```

```json
{
  "models": [
    {
      "slug": "MiniMax-M3",
      "display_name": "MiniMax-M3",
      "default_reasoning_level": "high",
      "supported_reasoning_levels": [
        { "effort": "none", "description": "关闭思考" },
        { "effort": "low", "description": "轻量思考" },
        { "effort": "high", "description": "深度思考" }
      ]
    }
  ]
}
```

未配置 catalog 时，退回 `config.toml` 顶层的 `model_reasoning_effort` 全局设置。

`reasoning.effort` 发出去后是否生效由供应商决定：

- 已确认支持：阿里云百炼（`none` → `max` 共 7 档）、MiniMax-M3（映射为 thinking 开关）、OpenRouter（Beta 支持 reasoning 参数）
- 不认识该参数的平台多数会静默忽略，少数会报错；报错时把档位调低或设为 `none`

验证是否真生效：用不同档位各发一次请求，对比响应里的 `reasoning` 输出项和 `usage.output_tokens_details.reasoning_tokens`：

```bash
curl -X POST "<base_url>/responses" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"<model>","input":"9.11 和 9.9 哪个大？","reasoning":{"effort":"high"}}'
```

`reasoning_tokens` 随档位明显变化即为生效。注意 `codex-switch test` 只探测连通性，不校验 reasoning。

## 命令

| 命令 | 说明 |
| --- | --- |
| `codex-switch` | fzf 交互选择（未装 fzf 时等同 `ls`） |
| `codex-switch ls` | 列出供应商，当前项前缀 `*` |
| `codex-switch use <name>` | 切换供应商；`openai` 恢复官方默认 |
| `codex-switch status` | 当前供应商 + config.toml 实际状态 + key 检查 + 配置不一致告警 |
| `codex-switch test [name]` | 冒烟测试连通性和延迟 |
| `codex-switch add` | 交互式添加供应商，可选写入 key 到 keys.env |
| `codex-switch key <name>` | 安全更新供应商的 API Key，无需重新填写供应商配置 |
| `codex-switch rm <name> [-y]` | 删除供应商；删的是当前项时会提示切回官方默认 |
| `codex-switch edit` | 用 `$EDITOR` 编辑 providers.json，保存后校验 JSON |
| `codex-switch doctor` | 健康检查（python3 / tomllib / curl / fzf / 配置语法 / key） |
| `codex-switch install` | 符号链接到 `~/bin` + 幂等配置 PATH 和 `alias cs` |
| `codex-switch update` / `upgrade` | 从当前分支的上游执行仅快进更新，保留本地改动 |
| `codex-switch uninstall [--purge]` | 卸载：删链接、清理 rc 配置；`--purge` 追加删除数据目录 |

## 数据存储

供应商清单在 `~/.codex-switch/providers.json`：

```json
{
  "current": "go",
  "providers": {
    "go": {
      "base_url": "https://opencode.ai/zen/go/v1",
      "model": "gpt-5.6-luna",
      "wire_api": "responses",
      "env_key": "OPENCODE_GO_KEY"
    },
    "openai": { "official": true }
  }
}
```

带 `official: true` 的条目表示官方默认：切换时删掉 `config.toml` 里的 `model` / `model_provider` 行恢复默认。

当前 Codex 仅支持 `wire_api = "responses"`，因此供应商必须提供兼容的 `/responses` 接口。

## 工作原理（use）

1. 读取 `~/.codex/config.toml`
2. 内嵌 python3 做行级手术：替换顶层 `model` / `model_provider`，重写目标 `[model_providers.<name>]` 及其 `.auth` 段，其他所有段逐字保留
3. 有 tomllib（python ≥ 3.11）时写入前后各做一次严格 toml 校验，否则降级为轻量检查
4. 写入前备份为 `config.toml.bak`
5. 临时文件 + `mv` 原子替换，权限收紧为 600

## API Key 原则

- key 不写入 `providers.json` 或 Codex 配置；仅 `add` 时显式同意才会写入 `keys.env`
- `~/.codex-switch/keys.env` 中以 `export XXX_KEY="..."` 保存，权限固定为 600
- `config.toml` 只记录本脚本的凭据读取命令和变量名，不包含 Key
- Codex 请求模型时按需执行凭据命令，因此桌面端无需继承 shell 环境，也无需重启；切换后新建任务即可

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CODEX_SWITCH_HOME` | `~/.codex-switch` | 数据目录 |
| `CS_CODEX_CONFIG` | `~/.codex/config.toml` | Codex 配置路径 |
| `CODEX_SWITCH_CODEX_BIN` | 自动检测 | 指定用于最低版本校验的 Codex 二进制 |
| `NO_COLOR` | — | 设置后禁用彩色输出 |

## 路线图

- [ ] 用量显示（opencode.ai 控制台 API）
- [x] `edit` / `doctor` / `install`

## 许可证

[MIT](LICENSE) © Xiang-98
