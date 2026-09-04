#!/usr/bin/env bash
# 烟测：Glob（及必要时 Grep）——CC 2.1+ 可能由 adapter 本地补缺
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/_smoke_common.sh"

smoke_setup
mkdir -p "$SMOKE_DIR/scripts"
printf '#!/bin/sh\necho ok\n' >"$SMOKE_DIR/scripts/alpha.sh"
printf '#!/bin/sh\necho ok\n' >"$SMOKE_DIR/scripts/beta.sh"
printf 'needle-cca-smoke\n' >"$SMOKE_DIR/scripts/findme.txt"

echo "== smoke-glob-grep =="
out="$(run_cc "只用 Glob（禁止 Bash/Read/Grep），pattern 用 scripts/*，根据工具结果列出文件名。")"
echo "$out" | tail -12
echo "$out" | grep -Eq 'alpha\.sh' || { echo "FAIL: Glob 未见 alpha.sh"; exit 1; }
echo "$out" | grep -Eq 'beta\.sh' || { echo "FAIL: Glob 未见 beta.sh"; exit 1; }

out2="$(run_cc "只用 Grep（禁止 Bash），pattern 用 needle-cca-smoke，path 用 scripts，output_mode 用 files_with_matches。只输出匹配路径。")"
echo "$out2" | tail -12
echo "$out2" | grep -Eq 'findme\.txt|needle-cca-smoke' || { echo "FAIL: Grep 未见 findme/needle"; exit 1; }

echo "PASS smoke-glob-grep"
