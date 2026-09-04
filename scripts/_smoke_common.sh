#!/usr/bin/env bash
# 烟测公共：起 adapter、选临时目录、跑 bin/cc -p
set -euo pipefail

SMOKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_DIR="${CCA_SMOKE_DIR:-/tmp/cca-smoke-$$}"
export CCA_WORKSPACE="${CCA_WORKSPACE:-$SMOKE_DIR}"

# 默认走独立 :4012 + runtime/smoke，避免 workspace 变更把用户正在用的 :4011 杀掉
smoke_isolate() {
  if [ "${CCA_SMOKE_ISOLATE:-1}" = "0" ]; then
    return
  fi
  export CCA_ADAPTER_PORT="${CCA_SMOKE_PORT:-4012}"
  export CCA_RUNTIME="${CCA_SMOKE_RUNTIME:-$SMOKE_ROOT/runtime/smoke}"
  mkdir -p "$CCA_RUNTIME"
}

smoke_cleanup() {
  # 只改烟测 runtime 的标记，不碰日常 runtime/workspace
  if [ -n "${CCA_RUNTIME:-}" ] && [ "$CCA_RUNTIME" != "$SMOKE_ROOT/runtime" ]; then
    printf '%s\n' "$SMOKE_ROOT" >"$CCA_RUNTIME/workspace" || true
  fi
}
trap smoke_cleanup EXIT

smoke_setup() {
  mkdir -p "$SMOKE_DIR" "$SMOKE_ROOT/runtime"
  if [ -f "$SMOKE_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SMOKE_ROOT/.env"
    set +a
  fi
  if [ -z "${CURSOR_API_KEY:-}" ]; then
    echo "❌ 需要 CURSOR_API_KEY（$SMOKE_ROOT/.env）" >&2
    exit 1
  fi
  smoke_isolate
  # 烟测独占隔离端口；允许同端口在不同临时 workspace 间切换。
  export CCA_ALLOW_WORKSPACE_SWITCH=1
  export CCA_WORKSPACE="$SMOKE_DIR"
  echo "smoke adapter :${CCA_ADAPTER_PORT:-4011} runtime=${CCA_RUNTIME:-$SMOKE_ROOT/runtime} ws=$SMOKE_DIR"
  bash "$SMOKE_ROOT/bin/adapter-start"
}

run_cc() {
  local prompt="$1"
  (
    cd "$SMOKE_DIR"
    "$SMOKE_ROOT/bin/cc" -p "$prompt" --dangerously-skip-permissions
  ) 2>&1
}
