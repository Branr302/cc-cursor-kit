#!/usr/bin/env bash
# 性能基线回归：标准请求组测延迟，超标即 FAIL（防性能退化）
# 耗少量 API（3 个极简请求）。用法: ./scripts/perf-baseline.sh [port]
set -uo pipefail
PORT="${1:-4011}"
BASE="http://127.0.0.1:${PORT}"

curl -sf --max-time 3 "$BASE/health" >/dev/null || { echo "adapter 未运行"; exit 1; }

python3 - "$BASE" <<'PY'
import json, sys, time, urllib.request

BASE = sys.argv[1]
def timed(body, sid):
    req = urllib.request.Request(f"{BASE}/v1/messages",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=90))
    return time.time() - t0, r

results = {}
# 1. 短问答（fast 路由：无 tools 短 prompt）
dt, _ = timed({"model": "grok-4.6", "max_tokens": 8,
               "messages": [{"role": "user", "content": "1+1=? 只回数字"}]}, "perf-fast")
results["短问答整轮"] = dt

# 2. 带工具（smart 路由 + 会合）
dt, r = timed({"model": "grok-4.6", "max_tokens": 64,
               "messages": [{"role": "user", "content": "用 Glob 找 *.md"}],
               "tools": [{"name": "Glob", "description": "find",
                          "input_schema": {"type": "object", "properties": {"pattern": {"type": "string"}}}}]},
              "perf-tool")
results["工具轮整轮"] = dt

# 3. 同 session 第 2 轮（增量路径）
dt, _ = timed({"model": "grok-4.6", "max_tokens": 8,
               "messages": [{"role": "user", "content": "1+1=?"}, {"role": "assistant", "content": "2"},
                            {"role": "user", "content": "2+2=? 只回数字"}]}, "perf-fast")
results["增量轮整轮"] = dt

# 阈值（基于 2026-09-04 基线放宽 ~2x 防误报；针对整轮含生成）
LIMITS = {"短问答整轮": 20.0, "工具轮整轮": 45.0, "增量轮整轮": 20.0}
fails = []
for k, v in results.items():
    lim = LIMITS[k]
    mark = "PASS" if v <= lim else "FAIL"
    if v > lim:
        fails.append(k)
    print(f"{mark} {k}: {v:.1f}s (阈值 {lim}s)")

if fails:
    print(f"\n性能退化: {fails} —— 用 bin/bench 看分布，或查上游状态")
    sys.exit(1)
print("\n性能基线 PASS")
PY
