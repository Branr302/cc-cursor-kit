#!/usr/bin/env bash
# 一键全量回归：离线套件 + 烟测 +（可选）在线门禁
# 用法: ./scripts/test-all.sh [--online]   (--online 加跑 edge/perf，耗少量 API)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0

run() {
  echo "▶ $1"
  if "$2" >/tmp/cca-testall.out 2>&1; then
    echo "  PASS"
  else
    echo "  FAIL —— tail:"; tail -3 /tmp/cca-testall.out | sed 's/^/    /'
    FAIL=1
  fi
}

run "compact-detect（离线）" ./scripts/test-compact-detect.sh
run "session-fsm（离线）" ./scripts/test-session-fsm.sh
run "smoke-all（:4012 隔离）" ./scripts/smoke-all.sh

if [ "${1:-}" = "--online" ]; then
  run "edge-cases（异常矩阵）" ./scripts/test-edge-cases.sh
  run "perf-baseline（延迟门禁）" ./scripts/perf-baseline.sh
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit "$FAIL"
