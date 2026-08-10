#!/usr/bin/env bash
# sync-model-catalog.sh — 用最新官方模型列表 + 自定义条目重建 model_catalog_json
#
# 背景：Codex 的 model_catalog_json 是整体替换而非合并，自定义条目必须和
# 官方条目共存，否则切回官方默认时会因找不到默认模型而报错。官方模型列表
# 会随版本/在线下发变化（桌面端缓存于 ~/.codex/models_cache.json），
# 所以合并产物需要定期重建。
#
# 用法:
#   ./sync-model-catalog.sh              立即同步一次
#   ./sync-model-catalog.sh --install    安装 launchd 监听（无定时器，纯事件驱动）：
#                                        models_cache.json 更新或 codex 升级时自动同步
#   ./sync-model-catalog.sh --uninstall  移除监听
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

AGENT_LABEL="com.codex-switch.catalog-sync"

_script_path() {
  local src="${BASH_SOURCE[0]:-$0}" dir target hops=0
  while [[ -L "$src" ]]; do
    hops=$((hops + 1))
    [[ "$hops" -le 20 ]] || return 1
    dir=$(cd -P "$(dirname "$src")" && pwd) || return 1
    target=$(readlink "$src") || return 1
    if [[ "$target" == /* ]]; then src="$target"; else src="$dir/$target"; fi
  done
  dir=$(cd -P "$(dirname "$src")" && pwd) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$src")"
}

install_agent() {
  local script installed plist uid caskroom app_bundle p
  script=$(_script_path) || die "无法解析脚本路径"
  plist="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
  installed="$CS_HOME/sync-model-catalog.sh"
  uid=$(id -u)
  mkdir -p "$HOME/Library/LaunchAgents" "$CS_HOME"

  # launchd 启动的进程没有 ~/Documents 的 TCC 权限，直接指向仓库路径会
  # 报 Operation not permitted；把脚本复制到数据目录下再指向副本。
  if [[ "$script" != "$installed" ]]; then
    cp -p "$script" "$installed"
    chmod +x "$installed"
    info "已复制脚本到 ${installed}（仓库更新后重跑 --install 刷新副本）"
  fi
  script="$installed"

  local watch=()
  if [[ -e "$CACHE" ]]; then
    watch+=("$CACHE")
  else
    warn "监听路径当前不存在（之后出现即生效；也可重新 --install）: ${CACHE}"
    watch+=("$CACHE")
  fi
  caskroom=""
  if command -v brew >/dev/null 2>&1; then caskroom="$(brew --prefix)/Caskroom/codex"; fi
  [[ -n "$caskroom" && -d "$caskroom" ]] && watch+=("$caskroom")
  app_bundle="/Applications/ChatGPT.app"
  [[ -d "$app_bundle" ]] && watch+=("$app_bundle")
  ((${#watch[@]} > 0)) || die "没有可监听的路径"

  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$AGENT_LABEL"
    printf '  <key>ProgramArguments</key>\n  <array>\n    <string>%s</string>\n  </array>\n' "$script"
    printf '  <key>WatchPaths</key>\n  <array>\n'
    for p in "${watch[@]}"; do printf '    <string>%s</string>\n' "$p"; done
    printf '  </array>\n'
    printf '  <key>RunAtLoad</key>\n  <true/>\n'
    printf '  <key>StandardOutPath</key>\n  <string>%s</string>\n' "$CS_HOME/sync.log"
    printf '  <key>StandardErrorPath</key>\n  <string>%s</string>\n' "$CS_HOME/sync.log"
    printf '</dict>\n</plist>\n'
  } > "$plist"

  launchctl bootout "gui/${uid}/${AGENT_LABEL}" 2>/dev/null || true
  if launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null || launchctl load -w "$plist"; then
    ok "已安装监听: ${AGENT_LABEL}"
    info "监听路径:"
    printf '  %s\n' "${watch[@]}"
    info "日志: ${CS_HOME}/sync.log（卸载: ${0} --uninstall）"
  else
    die "launchctl 注册失败: ${plist}"
  fi
}

uninstall_agent() {
  local plist="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist" uid
  uid=$(id -u)
  launchctl bootout "gui/${uid}/${AGENT_LABEL}" 2>/dev/null || true
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    ok "已移除监听: ${AGENT_LABEL}"
  else
    info "监听未安装"
  fi
}

case "${1:-}" in
  --install)   install_agent; exit 0 ;;
  --uninstall) uninstall_agent; exit 0 ;;
  "")          ;;
  *)           die "未知参数: ${1}（用法: sync-model-catalog.sh [--install|--uninstall]）" ;;
esac

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

sync_rc=0
sync_out=$(python3 - "$base" "$EXTRA" "$OUT" "$CS_HOME" <<'PY'
import json, os, sys
from datetime import datetime, timezone

base_path, extra_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
cs_home = sys.argv[4] if len(sys.argv) > 4 else ""

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

# 可见性策略：picker 只展示当前供应商可用的模型。
# - 官方默认：自定义条目隐藏，官方条目保持数据源原始可见性
# - 自定义供应商：只显示该供应商的 model，其余全部隐藏
# visibility=hide 只是不在选择器展示，模型仍可被内部功能解析使用。
custom_set = set(custom_slugs)
current, current_official, current_model = "", True, ""
try:
    store = json.load(open(os.path.join(cs_home, "providers.json")))
    current = store.get("current") or ""
    p = (store.get("providers") or {}).get(current) or {}
    current_official = bool(p.get("official")) or not current
    current_model = p.get("model") or ""
except Exception:
    pass

if current_official:
    for m in result["models"]:
        if m["slug"] in custom_set:
            m["visibility"] = "hide"
else:
    slugs = {m["slug"] for m in result["models"]}
    if current_model and current_model not in slugs:
        print("WARN: 当前模型 %s 不在 catalog 中，跳过可见性调整" % current_model, file=sys.stderr)
    else:
        for m in result["models"]:
            m["visibility"] = "list" if m["slug"] == current_model else "hide"

if os.path.exists(out_path):
    try:
        if json.load(open(out_path)) == result:
            print("无变化: %d 个官方/内置条目 + 自定义: %s" % (len(models), ", ".join(custom_slugs)))
            sys.exit(10)
    except Exception:
        pass
tmp_out = out_path + ".tmp"
with open(tmp_out, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp_out, out_path)
print("共 %d 个官方/内置条目 + 自定义: %s" % (len(models), ", ".join(custom_slugs)))
PY
) || sync_rc=$?

printf '%s\n' "$sync_out"
case "$sync_rc" in
  0)
    ok "已写入 ${OUT}"
    ;;
  10)
    ok "模型列表无变化，跳过写入"
    [[ -n "$tmp_home" ]] && rm -rf "$tmp_home"
    exit 0
    ;;
  *)
    [[ -n "$tmp_home" ]] && rm -rf "$tmp_home"
    die "合并失败（退出码 ${sync_rc}）"
    ;;
esac
[[ -n "$tmp_home" ]] && rm -rf "$tmp_home"

if [[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]]; then
  if "$CODEX_BIN" mcp list >/dev/null 2>&1; then
    ok "codex 配置加载校验通过"
  else
    warn "codex 配置加载失败，请检查 ${OUT}（可运行 codex mcp list 查看原因）"
    exit 1
  fi
fi
printf '  %s重启 Codex 后生效；运行 %s --install 可在模型更新或 codex 升级时自动同步%s\n' "$C_DIM" "$0" "$C_RESET"
