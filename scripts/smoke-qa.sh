#!/usr/bin/env bash
# 烟测 1：纯问答（不依赖工具）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/_smoke_common.sh"

smoke_setup
echo "== smoke-qa =="
out="$(run_cc "只用一个短句回答：1+1等于几？不要工具。")"
echo "$out" | tail -5
echo "$out" | grep -Eq '2|二' || { echo "FAIL: 未见答案 2"; exit 1; }
echo "PASS smoke-qa"
