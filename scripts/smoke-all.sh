#!/usr/bin/env bash
# 跑全部固定烟测（问答 / 读文件 / Write+Edit / Glob+Grep）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for s in smoke-qa smoke-read smoke-write-edit smoke-glob-grep; do
  echo
  echo "######## $s ########"
  if bash "$ROOT/scripts/$s.sh"; then
    :
  else
    echo "FAILED $s"
    fail=1
  fi
done
echo
# 收掉烟测 :4012，不动日常 :4011
export CCA_ADAPTER_PORT="${CCA_SMOKE_PORT:-4012}"
export CCA_RUNTIME="${CCA_SMOKE_RUNTIME:-$ROOT/runtime/smoke}"
bash "$ROOT/bin/adapter-stop" >/dev/null || true

if [ "$fail" -ne 0 ]; then
  echo "SOME SMOKES FAILED"
  exit 1
fi
echo "ALL SMOKES PASSED"
