#!/usr/bin/env bash
# 烟测 2：读文件并引用内容
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/_smoke_common.sh"

smoke_setup
MARKER="smoke-read-$(date +%s)"
printf '# fixture\n\nMARKER=%s\n' "$MARKER" >"$SMOKE_DIR/NOTE.md"

echo "== smoke-read =="
out="$(run_cc "用 Read 读取 $SMOKE_DIR/NOTE.md，然后只输出文件里的 MARKER 那一行。")"
echo "$out" | tail -8
echo "$out" | grep -F "MARKER=$MARKER" || { echo "FAIL: 未读到 MARKER"; exit 1; }
echo "PASS smoke-read"
