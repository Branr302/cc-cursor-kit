#!/usr/bin/env bash
# 烟测 3：Write → Edit → Bash 回读输出
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/_smoke_common.sh"

smoke_setup
rm -f "$SMOKE_DIR/hello.py"

echo "== smoke-write-edit =="
out="$(run_cc "在 $SMOKE_DIR 依次：1) Write 新建 hello.py 打印 hello-smoke；2) Edit 把 hello-smoke 改成 hi-smoke；3) Bash 运行 python3 hello.py。最后只汇报运行输出那一行。")"
echo "$out" | tail -12
test -f "$SMOKE_DIR/hello.py" || { echo "FAIL: hello.py 未创建"; exit 1; }
grep -q 'hi-smoke' "$SMOKE_DIR/hello.py" || { echo "FAIL: 未改成 hi-smoke"; cat "$SMOKE_DIR/hello.py"; exit 1; }
echo "$out" | grep -Fq 'hi-smoke' || { echo "FAIL: 输出未见 hi-smoke"; exit 1; }
echo "PASS smoke-write-edit"
