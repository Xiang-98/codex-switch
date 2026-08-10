#!/usr/bin/env bash
set -euo pipefail

VERSION="1.3.1"
MIN_CODEX_AUTH_VERSION="0.118.0"
CS_HOME="${CODEX_SWITCH_HOME:-$HOME/.codex-switch}"
CS_STORE="$CS_HOME/providers.json"
CS_KEYS="$CS_HOME/keys.env"
CS_CONFIG="${CS_CODEX_CONFIG:-$HOME/.codex/config.toml}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
info() { printf '%sℹ%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
die()  { err "$*"; exit 1; }

_cs_parse_semver() {
  local raw="$1"
  if [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

_cs_version_at_least() {
  local actual_no_build="${1%%+*}" required_no_build="${2%%+*}"
  local actual_core="${actual_no_build%%-*}" required_core="${required_no_build%%-*}"
  local a_major a_minor a_patch r_major r_minor r_patch

  IFS=. read -r a_major a_minor a_patch <<< "$actual_core"
  IFS=. read -r r_major r_minor r_patch <<< "$required_core"

  if ((a_major != r_major)); then ((a_major > r_major)); return; fi
  if ((a_minor != r_minor)); then ((a_minor > r_minor)); return; fi
  if ((a_patch != r_patch)); then ((a_patch > r_patch)); return; fi

  # 同一核心版本下，稳定版高于预发布版；当前最低要求本身是稳定版。
  [[ "$actual_no_build" != *-* || "$required_no_build" == *-* ]]
}

_cs_codex_runtime_candidates() {
  local cli="" desktop
  if [[ -n "${CODEX_SWITCH_CODEX_BIN:-}" ]]; then
    printf '指定 Codex\t%s\n' "$CODEX_SWITCH_CODEX_BIN"
    return 0
  fi

  cli=$(command -v codex 2>/dev/null || true)
  [[ -n "$cli" ]] && printf 'Codex CLI\t%s\n' "$cli"

  for desktop in \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "$HOME/Applications/ChatGPT.app/Contents/Resources/codex"
  do
    [[ -x "$desktop" && "$desktop" != "$cli" ]] || continue
    printf 'Codex 桌面端\t%s\n' "$desktop"
  done
}

_cs_check_codex_auth_support() {
  local verbose="${1:-0}" label path output version
  local seen=0 supported=0

  while IFS=$'\t' read -r label path; do
    [[ -n "$path" ]] || continue
    seen=$((seen + 1))
    if ! output=$("$path" --version 2>&1); then
      warn "$label 无法读取版本: $path"
      continue
    fi
    if ! version=$(_cs_parse_semver "$output"); then
      warn "$label 返回了无法识别的版本: $output"
      continue
    fi
    if _cs_version_at_least "$version" "$MIN_CODEX_AUTH_VERSION"; then
      supported=$((supported + 1))
      [[ "$verbose" == 1 ]] && ok "$label: ${version}（命令式认证可用）"
    else
      warn "$label: $version 过旧；命令式认证要求 >= $MIN_CODEX_AUTH_VERSION ($path)"
    fi
  done < <(_cs_codex_runtime_candidates)

  if ((seen == 0)); then
    warn "未找到 Codex；命令式认证要求 Codex >= $MIN_CODEX_AUTH_VERSION"
  elif ((supported == 0)); then
    warn "没有检测到支持命令式认证的 Codex 运行时"
  fi
  ((supported > 0))
}

_cs_store() {
  python3 - "$CS_STORE" "$@" <<'PY'
import json, os, sys

path = sys.argv[1]
action = sys.argv[2]
args = sys.argv[3:]

def default():
    return {"current": None, "providers": {"openai": {"official": True}}}

def load():
    if not os.path.exists(path):
        return default()
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except Exception as e:
        sys.stderr.write("✗ providers.json 解析失败: %s\n" % e)
        sys.exit(1)
    if not isinstance(d, dict):
        sys.stderr.write("✗ providers.json 结构非法\n")
        sys.exit(1)
    d.setdefault("current", None)
    d.setdefault("providers", {})
    return d

def save(d):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)

d = load()

if action == "init":
    if not os.path.exists(path):
        save(d)
elif action == "current":
    print(d.get("current") or "")
elif action == "names":
    for n in d["providers"]:
        print(n)
elif action == "exists":
    sys.exit(0 if args[0] in d["providers"] else 1)
elif action == "is_official":
    p = d["providers"].get(args[0])
    sys.exit(0 if p and p.get("official") else 1)
elif action == "get":
    p = d["providers"].get(args[0]) or {}
    v = p.get(args[1], "")
    print("" if v is None else v)
elif action == "list":
    cur = d.get("current")
    for n, p in d["providers"].items():
        mark = "*" if n == cur else ""
        if p.get("official"):
            print("\x1f".join([n, mark, "official", "", ""]))
        else:
            print("\x1f".join([
                n, mark,
                p.get("model", "") or "",
                p.get("base_url", "") or "",
                p.get("env_key", "") or "",
            ]))
elif action == "set_current":
    if args[0] not in d["providers"]:
        sys.stderr.write("✗ 未知供应商: %s\n" % args[0])
        sys.exit(1)
    d["current"] = args[0]
    save(d)
elif action == "upsert":
    d["providers"][args[0]] = json.loads(args[1])
    save(d)
elif action == "delete":
    if args[0] not in d["providers"]:
        sys.exit(1)
    del d["providers"][args[0]]
    if d.get("current") == args[0]:
        d["current"] = None
    save(d)
else:
    sys.stderr.write("unknown store action: %s\n" % action)
    sys.exit(2)
PY
}

_cs_apply_config() {
  python3 - "$CS_CONFIG" "$@" <<'PY'
import json, os, re, sys, tempfile

path = sys.argv[1]
mode = sys.argv[2]
name = sys.argv[3] if len(sys.argv) > 3 else ""
model = sys.argv[4] if len(sys.argv) > 4 else ""
base_url = sys.argv[5] if len(sys.argv) > 5 else ""
env_key = sys.argv[6] if len(sys.argv) > 6 else ""
wire_api = sys.argv[7] if len(sys.argv) > 7 else "responses"
auth_command = sys.argv[8] if len(sys.argv) > 8 else ""
keys_file = sys.argv[9] if len(sys.argv) > 9 else ""

text = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

def validate(t, label):
    try:
        import tomllib
        if t.strip():
            tomllib.loads(t)
        return True
    except ImportError:
        bad = 0
        for ln in t.splitlines():
            s = ln.strip()
            if s.startswith("[") and not (s.endswith("]") and len(s) > 2):
                bad += 1
        if bad:
            sys.stderr.write("⚠ %s 可能存在非法 section 头（无 tomllib，仅做轻量校验）\n" % label)
        return True
    except Exception as e:
        sys.stderr.write("✗ %s toml 校验失败: %s\n" % (label, e))
        return False

if text.strip() and not validate(text, "现有 config.toml"):
    sys.exit(1)

# 行级手术的已知限制：不感知 TOML 多行字符串——""" 块内以 [ 开头或含
# model = 的行会被误判（Codex 配置里概率极低）；写后 validate() 会兜住绝大多数破坏。
section_re = re.compile(r"^\s*\[")
kv_re = re.compile(r'^\s*(model|model_provider)\s*=')
target_re = re.compile(r"^\s*\[model_providers\." + re.escape(name) + r"(?:\.[^\]]+)?\]\s*$")

header_lines = []
sections = []
cur = None
for ln in text.splitlines():
    if section_re.match(ln):
        if cur is not None:
            sections.append(cur)
        cur = [ln, []]
    elif cur is None:
        header_lines.append(ln)
    else:
        cur[1].append(ln)
if cur is not None:
    sections.append(cur)

new_header = [ln for ln in header_lines if not kv_re.match(ln)]

if mode == "provider":
    new_header = ["model = " + json.dumps(model),
                  "model_provider = " + json.dumps(name)] + new_header
    sections = [s for s in sections if not target_re.match(s[0])]
    body = ["name = " + json.dumps(name),
            "base_url = " + json.dumps(base_url),
            "wire_api = " + json.dumps(wire_api)]
    sections.append(["[model_providers." + name + "]", body])
    if env_key:
        if not auth_command or not keys_file:
            sys.stderr.write("✗ 缺少命令式认证配置\n")
            sys.exit(1)
        auth_body = [
            "command = " + json.dumps(auth_command),
            "args = " + json.dumps(["_auth-token", keys_file, env_key]),
            "timeout_ms = 5000",
            "refresh_interval_ms = 30000",
        ]
        sections.append(["[model_providers." + name + ".auth]", auth_body])

while new_header and not new_header[0].strip():
    new_header.pop(0)
while new_header and not new_header[-1].strip():
    new_header.pop()

out = list(new_header)
for hdr, body in sections:
    while body and not body[-1].strip():
        body.pop()
    out.append("")
    out.append(hdr)
    out.extend(body)
result = "\n".join(out).strip("\n") + "\n"

if not validate(result, "生成配置"):
    sys.exit(1)

d = os.path.dirname(path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".config.toml.", dir=d)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(result)
print(tmp)
PY
}

_cs_config_state() {
  python3 - "$CS_CONFIG" <<'PY'
import os, re, sys
path = sys.argv[1]
model = ""
provider = ""
if os.path.exists(path):
    try:
        import tomllib
        with open(path, "rb") as f:
            d = tomllib.load(f)
        model = d.get("model", "") or ""
        provider = d.get("model_provider", "") or ""
    except ImportError:
        in_header = True
        kv = re.compile(r'^\s*(model|model_provider)\s*=\s*["\']?([^"\'#\n]+?)["\']?\s*(?:#.*)?$')
        with open(path, "r", encoding="utf-8") as f:
            for ln in f:
                s = ln.strip()
                if s.startswith("["):
                    in_header = False
                    break
                m = kv.match(ln)
                if m and in_header:
                    if m.group(1) == "model":
                        model = m.group(2)
                    else:
                        provider = m.group(2)
    except Exception as e:
        sys.stderr.write("warn: config.toml 解析失败: %s\n" % e)
print("%s\t%s" % (model, provider))
PY
}

_cs_source_keys() {
  [[ -f "$CS_KEYS" ]] || return 0
  local perm
  perm=$(stat -f '%Lp' "$CS_KEYS" 2>/dev/null || stat -c '%a' "$CS_KEYS" 2>/dev/null || echo "")
  if [[ -n "$perm" && "${perm: -3}" != "600" ]]; then
    warn "keys.env 权限为 ${perm}，建议执行: chmod 600 $CS_KEYS"
  fi
  set -a
  . "$CS_KEYS"
  set +a
}

_cs_save_key() {
  local env_key="$1" secret="$2" tmpk
  [[ "$env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "env_key 非法，拒绝写入 keys.env"
  mkdir -p "$(dirname "$CS_KEYS")"
  touch "$CS_KEYS"
  chmod 600 "$CS_KEYS"
  if grep -q "^export $env_key=" "$CS_KEYS" 2>/dev/null; then
    tmpk=$(mktemp "${TMPDIR:-/tmp}/codex-switch-keys.XXXXXX")
    grep -v "^export $env_key=" "$CS_KEYS" > "$tmpk" || true
    mv "$tmpk" "$CS_KEYS"
    chmod 600 "$CS_KEYS"
  fi
  printf 'export %s=%s\n' "$env_key" "$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$secret")" >> "$CS_KEYS"
}

_cs_cmd_auth_token() {
  local key_file="${1:-}" env_key="${2:-}" value=""
  [[ "$env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    err "凭据变量名非法"
    return 2
  }

  value=${!env_key:-}
  if [[ -z "$value" && -f "$key_file" ]]; then
    set -a
    . "$key_file"
    set +a
    value=${!env_key:-}
  fi
  [[ -n "$value" ]] || {
    err "$env_key 未设置或 $key_file 中不存在该变量"
    return 1
  }
  printf '%s' "$value"
}

_cs_key_report() {
  local env_key="$1"
  if [[ -z "$env_key" ]]; then
    printf '  key: %s(未声明 env_key)%s\n' "$C_DIM" "$C_RESET"
    return 0
  fi
  if [[ -n "${!env_key:-}" ]]; then
    printf '  key: %s %s✓ 已设置%s\n' "$env_key" "$C_GREEN" "$C_RESET"
    return 0
  fi
  printf '  key: %s %s✗ 未设置%s\n' "$env_key" "$C_YELLOW" "$C_RESET"
  printf '       %sexport %s="..." 或写入 %s（权限 600）%s\n' "$C_DIM" "$env_key" "$CS_KEYS" "$C_RESET" >&2
  return 1
}

_cs_cmd_ls() {
  _cs_store init
  local rows name mark model url envk maxn=4 maxm=5
  rows=$(_cs_store list)
  [[ -z "$rows" ]] && { info "还没有供应商，运行 codex-switch add 添加"; return 0; }
  while IFS=$'\x1f' read -r name mark model url envk; do
    ((${#name} > maxn)) && maxn=${#name}
    ((${#model} > maxm)) && maxm=${#model}
  done <<< "$rows"
  while IFS=$'\x1f' read -r name mark model url envk; do
    local disp="$model"
    [[ "$model" == "official" ]] && disp="官方默认"
    if [[ "$mark" == "*" ]]; then
      printf '%s*%s %-*s  %-*s  %s%s%s\n' "$C_GREEN" "$C_RESET" "$maxn" "$name" "$maxm" "$disp" "$C_DIM" "$url" "$C_RESET"
    else
      printf '  %-*s  %-*s  %s%s%s\n' "$maxn" "$name" "$maxm" "$disp" "$C_DIM" "$url" "$C_RESET"
    fi
  done <<< "$rows"
}

_cs_cmd_use() {
  local name="${1:-}"
  [[ -z "$name" ]] && die "用法: codex-switch use <name>"
  _cs_store init
  _cs_store exists "$name" || die "未知供应商: ${name}（用 codex-switch ls 查看，或 codex-switch add 添加）"
  _cs_source_keys

  local tmp model="" base_url="" env_key="" wire_api="" auth_command=""
  if _cs_store is_official "$name"; then
    tmp=$(_cs_apply_config official "$name") || die "写入配置失败（备份未受影响）"
  else
    model=$(_cs_store get "$name" model)
    base_url=$(_cs_store get "$name" base_url)
    env_key=$(_cs_store get "$name" env_key)
    wire_api=$(_cs_store get "$name" wire_api)
    wire_api=${wire_api:-responses}
    [[ -z "$base_url" || -z "$model" ]] && die "供应商 $name 配置不完整（缺 base_url/model），请用 codex-switch edit 修复"
    [[ "$wire_api" == "responses" ]] || die "当前 Codex 仅支持 wire_api=responses；请确认供应商支持 /responses 后重新添加"
    if [[ -n "$env_key" ]]; then
      _cs_check_codex_auth_support || die "请先升级 Codex 到 $MIN_CODEX_AUTH_VERSION 或更高版本，再切换自定义供应商"
      auth_command=$(_cs_script_path) || die "无法解析凭据读取命令路径"
    fi
    tmp=$(_cs_apply_config provider "$name" "$model" "$base_url" "$env_key" "$wire_api" "$auth_command" "$CS_KEYS") || die "写入配置失败（备份未受影响）"
  fi

  if [[ -f "$CS_CONFIG" ]]; then
    cp -p "$CS_CONFIG" "$CS_CONFIG.bak" || warn "备份 config.toml.bak 失败"
  fi
  mkdir -p "$(dirname "$CS_CONFIG")"
  mv "$tmp" "$CS_CONFIG"
  chmod 600 "$CS_CONFIG" 2>/dev/null || true
  _cs_store set_current "$name"

  if _cs_store is_official "$name"; then
    ok "已恢复官方默认 ($name)"
    _cs_key_report "OPENAI_API_KEY" || true
  else
    ok "已切换到 $name ($model)"
    printf '  base_url: %s%s%s\n' "$C_DIM" "$base_url" "$C_RESET"
    _cs_key_report "$env_key" || true
  fi
  info "Codex 桌面端无需重启；新建任务后生效"

  # 配置了 model catalog 时，按新供应商刷新 picker 可见性（只显示可用模型）
  if [[ -f "$CS_HOME/catalog-extra.json" ]]; then
    local self sync sync_rc=0
    self=$(_cs_script_path) && sync="$(dirname "$self")/sync-model-catalog.sh"
    if [[ -n "${sync:-}" && -x "$sync" ]]; then
      "$sync" >/dev/null 2>&1 || sync_rc=$?
      case "$sync_rc" in
        0)
          info "已按当前供应商刷新模型可见性"
          info "picker 列表在进程启动时加载：CLI 重进、桌面端重启 App 后更新显示（功能切换已即时生效）"
          ;;
        10) ;;
        *) warn "模型可见性刷新失败，可手动运行 sync-model-catalog.sh 排查" ;;
      esac
    fi
  fi
}

_cs_cmd_status() {
  _cs_store init
  _cs_source_keys
  local cur cfg cfg_model cfg_provider
  cur=$(_cs_store current)
  cfg=$(_cs_config_state)
  cfg_model=${cfg%%$'\t'*}
  cfg_provider=${cfg##*$'\t'}

  if [[ -z "$cur" ]]; then
    printf '%s当前供应商:%s (未设置，用 codex-switch use <name> 切换)\n' "$C_BOLD" "$C_RESET"
  else
    printf '%s当前供应商:%s %s\n' "$C_BOLD" "$C_RESET" "$cur"
  fi

  if [[ -n "$cur" ]] && _cs_store exists "$cur"; then
    if _cs_store is_official "$cur"; then
      printf '  模式:     官方默认\n'
      _cs_key_report "OPENAI_API_KEY" || true
    else
      printf '  model:    %s\n' "$(_cs_store get "$cur" model)"
      printf '  base_url: %s\n' "$(_cs_store get "$cur" base_url)"
      printf '  wire_api: %s\n' "$(_cs_store get "$cur" wire_api)"
      _cs_key_report "$(_cs_store get "$cur" env_key)" || true
    fi
  fi

  printf '%sconfig.toml:%s %s\n' "$C_BOLD" "$C_RESET" "$CS_CONFIG"
  if [[ -f "$CS_CONFIG" ]]; then
    printf '  model:          %s\n' "${cfg_model:-(默认)}"
    printf '  model_provider: %s\n' "${cfg_provider:-(默认)}"
    [[ -f "$CS_CONFIG.bak" ]] && printf '  备份:           %sconfig.toml.bak 存在%s\n' "$C_DIM" "$C_RESET"
    if [[ -n "$cur" ]] && _cs_store exists "$cur"; then
      local expected=""
      _cs_store is_official "$cur" || expected="$cur"
      [[ "$cfg_provider" != "$expected" ]] && \
        warn "store 记录当前为 ${cur}，但 config.toml 的 model_provider=${cfg_provider:-(默认)}；如非手改，用 codex-switch use $cur 重新对齐"
    elif [[ -z "$cur" && -n "$cfg_provider" ]]; then
      warn "config.toml 的 model_provider=${cfg_provider}，但 codex-switch 未记录当前供应商（可能手改过配置）"
    fi
  else
    printf '  %s(文件不存在，use 时会自动创建)%s\n' "$C_DIM" "$C_RESET"
  fi

  printf '%skeys.env:%s ' "$C_BOLD" "$C_RESET"
  if [[ -f "$CS_KEYS" ]]; then
    local perm
    perm=$(stat -f '%Lp' "$CS_KEYS" 2>/dev/null || stat -c '%a' "$CS_KEYS" 2>/dev/null || echo "?")
    printf '存在 (权限 %s)\n' "$perm"
  else
    printf '%s不存在（可选，用于自动 source key）%s\n' "$C_DIM" "$C_RESET"
  fi
}

_cs_cmd_test() {
  _cs_store init
  _cs_source_keys
  local name="${1:-}"
  [[ -z "$name" ]] && name=$(_cs_store current)
  [[ -z "$name" ]] && die "尚未选择供应商，先 codex-switch use <name>"
  _cs_store exists "$name" || die "未知供应商: $name"

  local model base_url env_key wire_api key url payload
  if _cs_store is_official "$name"; then
    base_url="https://api.openai.com/v1"
    env_key="OPENAI_API_KEY"
    wire_api="responses"
    model=$(_cs_config_state)
    model=${model%%$'\t'*}
    model=${model:-gpt-5}
  else
    model=$(_cs_store get "$name" model)
    base_url=$(_cs_store get "$name" base_url)
    env_key=$(_cs_store get "$name" env_key)
    wire_api=$(_cs_store get "$name" wire_api)
    wire_api=${wire_api:-responses}
  fi
  [[ -z "$base_url" ]] && die "供应商 $name 缺 base_url"

  [[ "$wire_api" == "responses" ]] || die "当前 Codex 仅支持 wire_api=responses"
  url="${base_url%/}/responses"
  payload=$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"input":"ping","max_output_tokens":16}))' "$model")

  local auth=()
  key=${!env_key:-}
  if [[ -n "$key" ]]; then
    auth=(-H "Authorization: Bearer $key")
  else
    warn "$env_key 未设置，本次为无鉴权探测"
  fi

  info "POST $url"
  local resp http code secs ms
  resp=$(mktemp "${TMPDIR:-/tmp}/codex-switch.XXXXXX")
  if ! http=$(curl -sS -o "$resp" -w '%{http_code} %{time_total}' --max-time 20 \
      -X POST "$url" -H 'Content-Type: application/json' ${auth[@]+"${auth[@]}"} -d "$payload"); then
    err "$name 连接失败：网络不可达或超时"
    rm -f "$resp"
    exit 1
  fi
  code=${http%% *}
  secs=${http##* }
  ms=$(awk "BEGIN{printf \"%d\", $secs*1000}")

  case "$code" in
    2*)
      ok "$name 连通正常 (HTTP $code, latency ${ms}ms)" ;;
    401|403)
      warn "$name 网络可达但鉴权失败 (HTTP $code, latency ${ms}ms)，请运行 codex-switch key $name 更新 $env_key" ;;
    404)
      warn "$name 可达但端点 404 (latency ${ms}ms)，请检查 base_url / wire_api" ;;
    000)
      err "$name 连接失败 (curl 无响应)" ;;
    *)
      warn "$name 可达，HTTP $code (latency ${ms}ms)" ;;
  esac
  if [[ "$code" != 2* && -s "$resp" ]]; then
    printf '%s  响应: %.300s%s\n' "$C_DIM" "$(cat "$resp")" "$C_RESET" >&2
  fi
  rm -f "$resp"
  [[ "$code" == 2* ]]
}

_cs_cmd_add() {
  _cs_store init
  local name base_url model env_key wire_api="responses" ans
  while true; do
    read -rp "供应商名称 (如 go): " name
    if [[ -z "$name" ]]; then
      err "名称不能为空，请重新输入"
      continue
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
      err "名称只能包含字母、数字、_、-，请重新输入"
      continue
    fi
    if _cs_store exists "$name"; then
      read -rp "已存在 ${name}，覆盖? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
    fi
    break
  done

  while true; do
    read -rp "base_url (如 https://opencode.ai/zen/go/v1): " base_url
    if [[ -z "$base_url" ]]; then
      err "base_url 不能为空，请重新输入"
      continue
    fi
    if [[ ! "$base_url" =~ ^https?:// ]]; then
      err "base_url 必须以 http:// 或 https:// 开头，请重新输入"
      continue
    fi
    break
  done

  while true; do
    read -rp "model (如 gpt-5.6-luna): " model
    if [[ -z "$model" ]]; then
      err "model 不能为空，请重新输入"
      continue
    fi
    break
  done

  local default_key="OPENCODE_$(tr 'a-z-' 'A-Z_' <<<"$name")_KEY"
  while true; do
    read -rp "env_key（变量名，不是 API key）[$default_key]: " env_key
    env_key=${env_key:-$default_key}
    if [[ ! "$env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      err "env_key 必须是合法 shell 变量名（不是 API key），请重新输入"
      continue
    fi
    break
  done

  local json
  json=$(python3 -c 'import json,sys; print(json.dumps({"base_url":sys.argv[1],"model":sys.argv[2],"wire_api":sys.argv[3],"env_key":sys.argv[4]}))' \
    "$base_url" "$model" "$wire_api" "$env_key")
  _cs_store upsert "$name" "$json"
  ok "已添加 $name ($model)"

  read -rp "现在把 key 写入 $CS_KEYS 吗? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    local secret
    read -rsp "$env_key = " secret
    printf '\n'
    if [[ -n "$secret" ]]; then
      _cs_save_key "$env_key" "$secret"
      ok "已写入 $CS_KEYS (权限 600)"
    else
      warn "Key 为空，未写入"
    fi
  fi

  printf '  下一步: codex-switch use %s\n' "$name"
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    printf '  %sCLI 可 export %s="your-key"；桌面端建议重新 add 并选择写入 keys.env%s\n' "$C_DIM" "$env_key" "$C_RESET"
  fi
}

_cs_cmd_key() {
  local name="${1:-}" env_key secret
  [[ -n "$name" ]] || die "用法: codex-switch key <name>"
  _cs_store init
  _cs_store exists "$name" || die "未知供应商: $name"
  _cs_store is_official "$name" && die "$name 使用 Codex 内置认证，不由 codex-switch 管理 Key"
  env_key=$(_cs_store get "$name" env_key)
  [[ -n "$env_key" ]] || die "供应商 $name 未配置 env_key"

  read -rsp "$env_key = " secret
  printf '\n'
  [[ -n "$secret" ]] || { info "Key 为空，已取消"; return 0; }
  _cs_save_key "$env_key" "$secret"
  ok "已更新 $name 的 Key (${CS_KEYS}，权限 600)"
  info "无需重启 Codex；新建任务后生效"
}

_cs_cmd_rm() {
  local name="${1:-}" flag="${2:-}"
  [[ -z "$name" ]] && die "用法: codex-switch rm <name> [-y]"
  _cs_store init
  _cs_store exists "$name" || die "未知供应商: $name"
  local interactive=1
  [[ "$flag" == "-y" || "$flag" == "--yes" ]] && interactive=0
  if [[ "$interactive" == 1 ]]; then
    local ans
    read -rp "确认删除 $name? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
  fi
  local was_current=""
  was_current=$(_cs_store current)
  _cs_store delete "$name"
  ok "已删除 $name"
  if [[ "$was_current" == "$name" ]]; then
    if [[ "$interactive" == 1 ]] && _cs_store exists openai; then
      local back
      read -rp "删除的是当前供应商，切回官方默认 (openai)? [Y/n] " back
      if [[ ! "$back" =~ ^[Nn]$ ]]; then
        _cs_cmd_use openai
        return 0
      fi
    fi
    warn "config.toml 未改动，仍指向已删除的 ${name}；请用 codex-switch use <name> 切换"
  else
    printf '  %s（config.toml 未改动）%s\n' "$C_DIM" "$C_RESET"
  fi
}

_cs_cmd_edit() {
  _cs_store init
  "${EDITOR:-vi}" "$CS_STORE"
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CS_STORE" 2>/dev/null; then
    ok "providers.json JSON 合法"
  else
    err "providers.json JSON 非法，请修复: $CS_STORE"
    return 1
  fi
}

_cs_cmd_interactive() {
  _cs_store init
  if ! command -v fzf >/dev/null 2>&1; then
    _cs_cmd_ls
    printf '\n%s安装 fzf 后可直接交互选择；用法见 codex-switch help%s\n' "$C_DIM" "$C_RESET"
    return 0
  fi
  local line name
  line=$(_cs_store list | awk 'BEGIN{FS=sprintf("%c",31)} { if ($3=="official") printf "%-12s %s\n", $1, "官方默认"; else printf "%-12s %-22s %s\n", $1, $3, $4 }' \
    | fzf --prompt='codex-switch> ' --header='选择供应商 (enter 切换, esc 取消)' --height=~40% --reverse) || return 0
  [[ -z "$line" ]] && return 0
  name=$(awk '{print $1}' <<<"$line")
  _cs_cmd_use "$name"
}

_cs_rc_file() {
  case "${SHELL:-}" in
    */zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    */bash) printf '%s\n' "$HOME/.bashrc" ;;
    *)      printf '%s\n' "$HOME/.profile" ;;
  esac
}

_cs_script_path() {
  local src="${BASH_SOURCE[0]:-$0}" dir target hops=0
  while [[ -L "$src" ]]; do
    hops=$((hops + 1))
    [[ "$hops" -le 20 ]] || return 1
    dir=$(cd -P "$(dirname "$src")" && pwd) || return 1
    target=$(readlink "$src") || return 1
    if [[ "$target" == /* ]]; then
      src="$target"
    else
      src="$dir/$target"
    fi
  done
  dir=$(cd -P "$(dirname "$src")" && pwd) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$src")"
}

_cs_cmd_update() {
  command -v git >/dev/null 2>&1 || die "更新需要 git"

  local script repo branch upstream before after new_version
  script=$(_cs_script_path) || die "无法解析当前脚本路径"
  repo=$(git -C "$(dirname "$script")" rev-parse --show-toplevel 2>/dev/null) || \
    die "当前安装不在 Git 仓库中，请从 GitHub 重新 clone 后安装"

  if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then
    die "仓库存在未提交的修改，请先提交或用 git stash 临时保存后再更新: $repo"
  fi
  branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null) || \
    die "当前处于 detached HEAD，无法自动更新"
  upstream=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || \
    die "分支 $branch 没有上游分支，无法自动更新"
  before=$(git -C "$repo" rev-parse --short HEAD)

  info "正在从 $upstream 检查更新..."
  if ! git -C "$repo" pull --ff-only; then
    err "无法快进更新；请检查网络、远端配置或本地分支状态"
    return 1
  fi

  after=$(git -C "$repo" rev-parse --short HEAD)
  new_version=$(awk -F'"' '$1 == "VERSION=" { print $2; exit }' "$script")
  if [[ "$before" == "$after" ]]; then
    ok "已是最新版本${new_version:+ (v$new_version)}"
  else
    ok "更新完成: $before -> $after${new_version:+ (v$new_version)}"
  fi
}

_cs_cmd_install() {
  local self bin_dir target rc changed=0
  self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
  bin_dir="$HOME/bin"
  target="$bin_dir/codex-switch"
  rc=$(_cs_rc_file)

  mkdir -p "$bin_dir"
  if [[ "$self" == "$target" ]]; then
    ok "已就位: $target"
  elif [[ -L "$target" && "$(readlink "$target")" == "$self" ]]; then
    ok "已链接: $target -> $self"
  else
    if [[ -L "$target" ]]; then
      mv "$target" "$target.pre-switch.bak"
      info "旧链接已备份为 $target.pre-switch.bak -> $(readlink "$target.pre-switch.bak")"
    elif [[ -e "$target" ]]; then
      cp -p "$target" "$target.pre-switch.bak"
      info "旧版本已备份为 $target.pre-switch.bak"
    fi
    ln -sfn "$self" "$target"
    ok "已链接: $target -> ${self}（仓库更新即生效）"
  fi

  touch "$rc"
  if [[ ":$PATH:" == *":$bin_dir:"* ]]; then
    ok "PATH 已包含 $bin_dir"
  elif grep -q '# codex-switch PATH' "$rc" 2>/dev/null; then
    ok "PATH 配置已存在于 $rc"
  else
    printf '\n# codex-switch PATH\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$rc"
    ok "已向 $rc 追加 PATH: $bin_dir"
    changed=1
  fi

  if grep -q "alias cs='codex-switch'" "$rc" 2>/dev/null; then
    ok "alias cs 已存在于 $rc"
  else
    printf "alias cs='codex-switch'\n" >> "$rc"
    ok "已向 $rc 追加 alias cs='codex-switch'"
    changed=1
  fi

  if [[ "$changed" == 1 ]]; then
    printf '\n  新开终端生效，或现在执行: %ssource %s%s\n' "$C_BOLD" "$rc" "$C_RESET"
  fi
}

_cs_cmd_uninstall() {
  local purge=0
  [[ "${1:-}" == "--purge" ]] && purge=1
  local self bin_dir target rc
  self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
  [[ -L "$self" ]] && self=$(readlink "$self")
  bin_dir="$HOME/bin"
  target="$bin_dir/codex-switch"
  rc=$(_cs_rc_file)

  local cur=""
  cur=$(_cs_store current 2>/dev/null || true)
  if [[ -n "$cur" ]] && ! _cs_store is_official "$cur" 2>/dev/null; then
    local ans tmp
    read -rp "当前供应商是 ${cur}，卸载前切回官方默认? [Y/n] " ans || ans=""
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      if tmp=$(_cs_apply_config official openai); then
        [[ -f "$CS_CONFIG" ]] && cp -p "$CS_CONFIG" "$CS_CONFIG.bak" 2>/dev/null || true
        mkdir -p "$(dirname "$CS_CONFIG")"
        mv "$tmp" "$CS_CONFIG"
        chmod 600 "$CS_CONFIG" 2>/dev/null || true
        _cs_store set_current openai 2>/dev/null || true
        ok "已切回官方默认（config.toml 中的 model/model_provider 已移除）"
      else
        warn "切回失败，config.toml 保持不变，可手动检查 $CS_CONFIG"
      fi
    else
      warn "保留当前配置，$CS_CONFIG 仍指向 $cur"
    fi
  fi

  if [[ -L "$target" ]]; then
    rm -f "$target"
    ok "已删除链接: $target"
  elif [[ -f "$target" ]] && grep -q '_cs_cmd_uninstall' "$target" 2>/dev/null; then
    rm -f "$target"
    ok "已删除: $target"
  elif [[ -e "$target" ]]; then
    warn "$target 存在但不是本工具安装的，跳过删除"
  fi

  if [[ -f "$rc" ]] && grep -q -e '# codex-switch PATH' -e "alias cs='codex-switch'" "$rc" 2>/dev/null; then
    local tmpr
    tmpr=$(mktemp "${TMPDIR:-/tmp}/codex-switch-rc.XXXXXX")
    awk '
      /# codex-switch PATH/ { skip=1; next }
      skip && /^export PATH=/ { skip=0; next }
      $0 == "alias cs='"'"'codex-switch'"'"'" { next }
      { print }
    ' "$rc" > "$tmpr"
    cp -p "$rc" "$rc.codex-switch.bak"
    mv "$tmpr" "$rc"
    ok "已从 $rc 移除 PATH / alias（备份: $rc.codex-switch.bak）"
  fi

  local mon_label mon_plist
  mon_label=$(_cs_monitor_label)
  mon_plist="$HOME/Library/LaunchAgents/${mon_label}.plist"
  if [[ -f "$mon_plist" ]]; then
    launchctl bootout "gui/$(id -u)/${mon_label}" 2>/dev/null || true
    launchctl unload "$mon_plist" 2>/dev/null || true
    rm -f "$mon_plist"
    ok "已移除模型同步监听: ${mon_label}"
  fi

  if [[ -d "$CS_HOME" ]]; then
    if [[ "$purge" == 1 ]]; then
      rm -rf "$CS_HOME"
      ok "已删除数据目录: $CS_HOME"
    else
      info "保留数据目录: ${CS_HOME}（彻底删除用 codex-switch uninstall --purge）"
    fi
  fi

  printf '\n  %s卸载完成。仓库目录未删除:%s %s\n' "$C_DIM" "$C_RESET" "$(dirname "$self")"
  printf '  新开终端生效，或执行: %ssource %s%s\n' "$C_BOLD" "$rc" "$C_RESET"
}

_cs_cmd_doctor() {
  local fail=0
  printf '%s环境%s\n' "$C_BOLD" "$C_RESET"
  if command -v python3 >/dev/null; then
    ok "python3: $(python3 --version 2>&1)"
  else
    err "python3 未安装"; fail=1
  fi
  if python3 -c 'import tomllib' 2>/dev/null; then
    ok "tomllib 可用（严格校验）"
  else
    warn "tomllib 不可用 (python < 3.11)，降级为轻量校验"
  fi
  command -v curl >/dev/null && ok "curl 可用" || { err "curl 未安装"; fail=1; }
  command -v fzf >/dev/null && ok "fzf 可用（无参数交互模式开启）" || warn "fzf 未安装（可选，无参数交互模式不可用）"
  _cs_check_codex_auth_support 1 || fail=1

  printf '%s数据%s\n' "$C_BOLD" "$C_RESET"
  _cs_store init
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CS_STORE" 2>/dev/null; then
    ok "providers.json 合法 ($CS_STORE)"
  else
    err "providers.json 损坏: $CS_STORE"; fail=1
  fi
  if [[ -f "$CS_KEYS" ]]; then
    local perm
    perm=$(stat -f '%Lp' "$CS_KEYS" 2>/dev/null || stat -c '%a' "$CS_KEYS" 2>/dev/null || echo "?")
    if [[ "${perm: -3}" == "600" ]]; then
      ok "keys.env 存在且权限 600"
    else
      warn "keys.env 权限为 ${perm}，建议 chmod 600 $CS_KEYS"
    fi
  else
    info "keys.env 不存在（可选）"
  fi

  printf '%s配置%s\n' "$C_BOLD" "$C_RESET"
  if [[ -f "$CS_CONFIG" ]]; then
    if python3 - "$CS_CONFIG" <<'PY' >/dev/null 2>&1
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as f:
        tomllib.load(f)
except ImportError:
    pass
PY
    then
      ok "config.toml 语法正常"
    else
      err "config.toml 语法错误: ${CS_CONFIG}（可尝试用 config.toml.bak 恢复）"; fail=1
    fi
  else
    warn "config.toml 不存在（use 时会自动创建）"
  fi

  local cur
  cur=$(_cs_store current)
  if [[ -n "$cur" ]]; then
    ok "当前供应商: $cur"
    _cs_source_keys
    local env_key="OPENAI_API_KEY"
    _cs_store is_official "$cur" || env_key=$(_cs_store get "$cur" env_key)
    if [[ -n "$env_key" ]]; then
      [[ -n "${!env_key:-}" ]] && ok "$env_key 已 export" || warn "$env_key 未 export"
    fi
  else
    warn "尚未选择供应商"
  fi
  info "连通性检查请运行: codex-switch test"
  return "$fail"
}

_cs_monitor_label() { printf '%s\n' "com.codex-switch.catalog-sync"; }

_cs_cmd_monitor() {
  local action="${1:-on}" self sync plist label
  label=$(_cs_monitor_label)
  plist="$HOME/Library/LaunchAgents/${label}.plist"

  if [[ "$action" == "status" ]]; then
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
      ok "模型同步监听: 运行中（${plist}）"
    elif [[ -f "$plist" ]]; then
      warn "模型同步监听: plist 存在但未加载，用 codex-switch monitor 重新安装"
    else
      info "模型同步监听: 未安装（codex-switch monitor 安装）"
    fi
    return 0
  fi

  self=$(_cs_script_path) || die "无法解析脚本路径"
  sync="$(dirname "$self")/sync-model-catalog.sh"
  [[ -x "$sync" ]] || die "未找到 ${sync}（sync-model-catalog.sh 应与 codex-switch.sh 同目录）"

  case "$action" in
    on|install|enable)
      if [[ ! -f "$CS_HOME/catalog-extra.json" ]]; then
        warn "未找到 ${CS_HOME}/catalog-extra.json；请先按 README 配置 model catalog 自定义条目，否则同步会失败"
      fi
      "$sync" --install
      ;;
    off|uninstall|disable)
      "$sync" --uninstall
      ;;
    *)
      die "用法: codex-switch monitor [on|off|status]"
      ;;
  esac
}

_cs_usage() {
  cat <<EOF
${C_BOLD}codex-switch${C_RESET} — Codex CLI 模型供应商切换工具 (v$VERSION)

${C_BOLD}用法:${C_RESET}
  codex-switch              fzf 交互选择（未装 fzf 时等同 ls）
  codex-switch ls           列出供应商（* 为当前）
  codex-switch use <name>   切换供应商；openai 为官方默认
  codex-switch status       当前状态 + key 检查
  codex-switch test [name]  冒烟测试连通性 + 延迟
  codex-switch add          交互式添加供应商（可选写入 keys.env）
  codex-switch key <name>   更新供应商的 API Key
  codex-switch rm <name>    删除供应商（-y 跳过确认）
  codex-switch edit         用 \$EDITOR 编辑 providers.json
  codex-switch doctor       配置健康检查
  codex-switch install      链接到 ~/bin 并配置 PATH + alias cs
  codex-switch update       从上游安全更新（upgrade 同义）
  codex-switch monitor [on|off|status]  模型列表自动同步监听（launchd 事件驱动，无定时器）
  codex-switch uninstall    卸载（--purge 同时删除数据目录）
  codex-switch version      显示版本
  codex-switch help         显示本帮助

${C_BOLD}存储:${C_RESET}
  供应商清单  $CS_STORE
  可选 key    $CS_KEYS (权限 600，use/status/test 前自动 source)
  Codex 配置  ${CS_CONFIG}（只改 model / model_provider / [model_providers.*]，其余原样保留，写入前备份 .bak）

${C_BOLD}提示:${C_RESET} alias cs='codex-switch'
${C_BOLD}要求:${C_RESET} 命令式认证需 Codex >= $MIN_CODEX_AUTH_VERSION
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "") _cs_cmd_interactive ;;
    ls|list) _cs_cmd_ls ;;
    use) shift; _cs_cmd_use "$@" ;;
    status|st) _cs_cmd_status ;;
    test) shift; _cs_cmd_test "$@" ;;
    add) _cs_cmd_add ;;
    key|set-key) shift; _cs_cmd_key "$@" ;;
    rm|remove|del) shift; _cs_cmd_rm "$@" ;;
    edit) _cs_cmd_edit ;;
    doctor) _cs_cmd_doctor ;;
    monitor) shift; _cs_cmd_monitor "$@" ;;
    install) _cs_cmd_install ;;
    update|upgrade) _cs_cmd_update ;;
    _auth-token) shift; _cs_cmd_auth_token "$@" ;;
    uninstall) shift; _cs_cmd_uninstall "$@" ;;
    current) _cs_store current ;;
    version|--version|-V) echo "codex-switch $VERSION" ;;
    help|--help|-h) _cs_usage ;;
    *) err "未知命令: $cmd"; _cs_usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
