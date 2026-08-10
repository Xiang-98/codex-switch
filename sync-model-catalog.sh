#!/usr/bin/env bash
# sync-model-catalog.sh — 用最新官方模型列表 + 自定义条目重建 model_catalog_json
#
# 背景：Codex 的 model_catalog_json 是整体替换而非合并，自定义条目必须和
# 官方条目共存，否则切回官方默认时会因找不到默认模型而报错。官方模型列表
# 会随版本/在线下发变化（桌面端缓存于 ~/.codex/models_cache.json），
# 所以合并产物需要定期重建。
#
# 用法:
#   ./sync-model-catalog.sh
#
# 数据源优先级：
#   1. ~/.codex/models_cache.json（桌面端在线拉取的最新 catalog，首选）
#   2. codex debug models 导出的二进制内置快照（缓存不存在时兜底）
# 自定义条目来自 ~/.codex-switch/catalog-extra.json（按 slug 覆盖同名官方条目）。
#
# 可用环境变量:
#   CS_CATALOG_EXTRA   自定义条目文件（默认 ~/.codex-switch/catalog-extra.json）
#   CS_CATALOG_OUT     输出路径（默认 ~/.codex/models.json）
#   CS_MODELS_CACHE    在线缓存路径（默认 ~/.codex/models_cache.json）
#   CODEX_SWITCH_CODEX_BIN  codex 二进制路径（默认自动检测）
set -euo pipefail

CS_HOME="${CODEX_SWITCH_HOME:-$HOME/.codex-switch}"
EXTRA="${CS_CATALOG_EXTRA:-$CS_HOME/catalog-extra.json}"
OUT="${CS_CATALOG_OUT:-$HOME/.codex/models.json}"
CACHE="${CS_MODELS_CACHE:-$HOME/.codex/models_cache.json}"
CODEX_BIN="${CODEX_SWITCH_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
info() { printf '%sℹ%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
die()  { err "$*"; exit 1; }

[[ -f "$EXTRA" ]] || die "未找到自定义条目文件 ${EXTRA}（格式: {\"models\": [...]}）"

base="" tmp_home=""
if [[ -f "$CACHE" ]]; then
  base="$CACHE"
  info "数据源: 在线缓存 ${CACHE}"
else
  [[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]] || die "缓存 ${CACHE} 不存在，且未找到 codex 二进制用于导出内置 catalog"
  tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/sync-model-catalog.XXXXXX")
  base="$tmp_home/builtin.json"
  info "数据源: codex 二进制内置快照（缓存不存在）"
  CODEX_HOME="$tmp_home" "$CODEX_BIN" debug models > "$base" || die "codex debug models 执行失败"
fi

python3 - "$base" "$EXTRA" "$OUT" <<'PY'
import json, os, sys
from datetime import datetime, timezone

base_path, extra_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

base = json.load(open(base_path))
extra = json.load(open(extra_path))

fetched = base.get("fetched_at")
if fetched:
    try:
        dt = datetime.fromisoformat(fetched.replace("Z", "+00:00"))
        age_h = (datetime.now(timezone.utc) - dt).total_seconds() / 3600
        age = "%.1f 天" % (age_h / 24) if age_h >= 48 else "%.1f 小时" % age_h
        print("缓存抓取时间: %s（%s前）" % (fetched, age))
        if age_h > 7 * 24:
            print("WARN: 缓存超过 7 天，建议先打开一次 Codex 桌面端刷新", file=sys.stderr)
    except Exception:
        pass

models = [m for m in base.get("models", []) if isinstance(m, dict) and m.get("slug")]
if not models:
    sys.stderr.write("✗ 数据源里没有模型条目\n")
    sys.exit(1)

merged = {m["slug"]: m for m in models}
custom_slugs = []
for m in extra.get("models", []):
    if not isinstance(m, dict) or not m.get("slug"):
        sys.stderr.write("✗ 自定义条目缺 slug\n")
        sys.exit(1)
    merged[m["slug"]] = m
    custom_slugs.append(m["slug"])

result = {"models": list(merged.values())}
tmp_out = out_path + ".tmp"
with open(tmp_out, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp_out, out_path)
print("共 %d 个官方/内置条目 + 自定义: %s" % (len(models), ", ".join(custom_slugs)))
PY

ok "已写入 ${OUT}"
[[ -n "$tmp_home" ]] && rm -rf "$tmp_home"

if [[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]]; then
  if "$CODEX_BIN" mcp list >/dev/null 2>&1; then
    ok "codex 配置加载校验通过"
  else
    warn "codex 配置加载失败，请检查 ${OUT}（可运行 codex mcp list 查看原因）"
    exit 1
  fi
fi
printf '  %s重启 Codex 后生效；定期重跑本脚本即可跟进官方模型变化%s\n' "$C_DIM" "$C_RESET"
