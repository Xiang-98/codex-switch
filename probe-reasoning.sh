#!/usr/bin/env bash
# probe-reasoning.sh — 探测供应商对 reasoning.effort（思考深度/档位）的支持情况
#
# 用法:
#   ./probe-reasoning.sh [供应商名] [model 覆盖] [--full]
#
#   --full            探测全部已知档位（none minimal low medium high xhigh max）
#
# 可用环境变量:
#   PROBE_EFFORTS     待探测档位列表（默认 "minimal low medium high"）
#   PROBE_PROMPT      自定义测试问题（默认用一道概率题诱导推理）
#   PROBE_MAX_TOKENS  max_output_tokens（默认 4096）
#   PROBE_TIMEOUT     单次请求超时秒数（默认 180）
set -euo pipefail

CS_HOME="${CODEX_SWITCH_HOME:-$HOME/.codex-switch}"
CS_STORE="$CS_HOME/providers.json"
CS_KEYS="$CS_HOME/keys.env"

PROMPT="${PROBE_PROMPT:-一个袋子里有 3 个红球和 5 个蓝球，不放回地摸出两个球，求两个都是红球的概率。请逐步推理。}"
MAX_TOKENS="${PROBE_MAX_TOKENS:-4096}"
TIMEOUT="${PROBE_TIMEOUT:-180}"
EFFORTS="${PROBE_EFFORTS:-minimal low medium high}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
info() { printf '%sℹ%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
die()  { err "$*"; exit 1; }

name="" model_override="" full=0
for a in "$@"; do
  case "$a" in
    --full)
      full=1
      EFFORTS="${PROBE_EFFORTS:-none minimal low medium high xhigh max}"
      ;;
    *)
      if [[ -z "$name" ]]; then
        name="$a"
      elif [[ -z "$model_override" ]]; then
        model_override="$a"
      else
        die "未知参数: ${a}（用法: probe-reasoning.sh [供应商名] [model] [--full]）"
      fi
      ;;
  esac
done

[[ -f "$CS_STORE" ]] || die "未找到 ${CS_STORE}，先用 codex-switch add 添加供应商"

# 读取供应商配置（字段以 \x1f 分隔，保留空字段）
cfg=$(python3 - "$CS_STORE" "$name" <<'PY'
import json, sys
store, name = sys.argv[1], sys.argv[2]
d = json.load(open(store))
if not name:
    name = d.get("current") or ""
if not name:
    sys.stderr.write("✗ 未指定供应商且没有当前供应商\n")
    sys.exit(1)
p = (d.get("providers") or {}).get(name)
if p is None:
    sys.stderr.write("✗ 未知供应商: %s\n" % name)
    sys.exit(1)
if p.get("official"):
    print("\x1f".join([name, "https://api.openai.com/v1", "", "OPENAI_API_KEY"]))
else:
    print("\x1f".join([
        name,
        p.get("base_url", "") or "",
        p.get("model", "") or "",
        p.get("env_key", "") or "",
    ]))
PY
) || exit 1

IFS=$'\x1f' read -r name base_url model env_key <<<"$cfg"
model="${model_override:-${model:-gpt-5}}"
[[ -n "$base_url" ]] || die "供应商 $name 缺 base_url"
[[ -n "$env_key" ]] || die "供应商 $name 未声明 env_key"

if [[ -f "$CS_KEYS" ]]; then
  set -a
  . "$CS_KEYS"
  set +a
fi
key="${!env_key:-}"
if [[ -z "$key" ]]; then
  hint=""
  [[ "$env_key" == "OPENAI_API_KEY" ]] && hint="；探测自定义供应商请用 ./probe-reasoning.sh <名称>"
  die "${env_key} 未设置（export ${env_key}=\"...\" 或写入 ${CS_KEYS}）${hint}"
fi

url="${base_url%/}/responses"
info "供应商: $name   model: $model"
info "POST $url   efforts: $EFFORTS"

rows=()
for effort in $EFFORTS; do
  payload=$(python3 -c 'import json,sys; print(json.dumps({
      "model": sys.argv[1],
      "input": sys.argv[2],
      "max_output_tokens": int(sys.argv[3]),
      "store": False,
      "reasoning": {"effort": sys.argv[4]},
  }))' "$model" "$PROMPT" "$MAX_TOKENS" "$effort")

  resp=$(mktemp "${TMPDIR:-/tmp}/probe-reasoning.XXXXXX")
  if ! http=$(curl -sS -o "$resp" -w '%{http_code} %{time_total}' --max-time "$TIMEOUT" \
      -X POST "$url" -H 'Content-Type: application/json' -H "Authorization: Bearer $key" \
      -d "$payload"); then
    rows+=("$effort|000|-|-|0|连接失败或超时")
    rm -f "$resp"
    continue
  fi
  code="${http%% *}"; secs="${http##* }"
  ms=$(awk "BEGIN{printf \"%d\", $secs*1000}")

  parsed=$(python3 - "$resp" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("-|-|响应非 JSON")
    sys.exit(0)
u = d.get("usage") or {}
rt = (u.get("output_tokens_details") or {}).get("reasoning_tokens")
rt = "-" if rt is None else str(rt)
has = any(isinstance(i, dict) and i.get("type") == "reasoning"
          for i in (d.get("output") or []))
e = d.get("error")
msg = ""
if isinstance(e, dict):
    msg = e.get("message") or ""
if not msg:
    msg = d.get("message") or ""
print("%s|%s|%s" % (rt, "1" if has else "0", msg.replace("|", "/")[:100]))
PY
)
  rt="${parsed%%|*}"; rest="${parsed#*|}"; has="${rest%%|*}"; emsg="${rest#*|}"
  rows+=("$effort|$code|$rt|$has|$ms|$emsg")
  rm -f "$resp"
done

printf '\n%s%-9s %-6s %-10s %-17s %-9s %s%s\n' \
  "$C_BOLD" "effort" "HTTP" "reasoning" "reasoning_tokens" "latency" "备注" "$C_RESET"
positives=0
rt_values=()
rejected=()
accepted_no_reasoning=0
for row in "${rows[@]}"; do
  IFS='|' read -r e c rt has ms em <<<"$row"
  has_disp="no"
  [[ "$has" == "1" ]] && has_disp="yes"
  note="$em"
  if [[ "$c" == 2* && -z "$note" ]]; then note="${C_DIM}-${C_RESET}"; fi
  printf '%-9s %-6s %-10s %-17s %-9s %s\n' "$e" "$c" "$has_disp" "$rt" "${ms}ms" "$note"
  if [[ "$c" == 2* ]]; then
    if [[ "$rt" =~ ^[0-9]+$ && "$rt" -gt 0 ]]; then
      positives=$((positives + 1))
      rt_values+=("$rt")
    elif [[ "$has" == "1" ]]; then
      positives=$((positives + 1))
    else
      accepted_no_reasoning=$((accepted_no_reasoning + 1))
    fi
  else
    rejected+=("$e (HTTP $c)")
  fi
done

printf '\n'
if ((positives >= 2 && ${#rt_values[@]} >= 2)); then
  distinct=$(printf '%s\n' "${rt_values[@]}" | sort -nu | wc -l | tr -d ' ')
  if ((distinct >= 2)); then
    printf '%s✓%s 结论：支持 reasoning.effort，且档位生效（reasoning_tokens 随档位变化）\n' "$C_GREEN" "$C_RESET"
    if ((full == 0)); then
      info "还可能支持更多档位，试试: ./probe-reasoning.sh ${name} --full"
    fi
  else
    warn "结论：观察到思考过程，但各档 reasoning_tokens 相近——参数可能被接受但未分档；也可用 PROBE_PROMPT 换更复杂的问题再试"
  fi
elif ((positives == 1)); then
  warn "结论：仅个别档位观察到思考输出，详见上表"
elif ((${#rejected[@]} > 0)); then
  warn "结论：部分档位被拒绝：${rejected[*]}；其余档位未观察到思考输出"
elif ((accepted_no_reasoning > 0)); then
  warn "结论：请求均被接受，但无 reasoning 输出——模型可能不是推理模型，或平台忽略了 effort 参数"
else
  err "结论：请求全部失败，请检查网络、key 与 base_url（可先用 codex-switch test 排查连通性）"
fi
