#!/usr/bin/env bash
# 异常矩阵：adapter 对畸形/极端输入的鲁棒性
# 默认打 ${CCA_ADAPTER_PORT:-4011}（真实上游，少量调用）；
# `--fake` 自起 FakeAgent 实例（:4062），全部用例零 API 消耗、确定性秒回。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAKE_PID=""
if [ "${1:-}" = "--fake" ]; then
  PORT=4062
  RT="$ROOT/runtime/edge-fake"
  mkdir -p "$RT"
  lsof -ti tcp:$PORT | xargs kill 2>/dev/null; sleep 0.3
  (cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
    CCA_FAKE_AGENT=1 CCA_FAKE_MODE=text \
    CCA_ADAPTER_PORT=$PORT CCA_RUNTIME="$RT" CCA_WORKSPACE="$ROOT" CCA_PREWARM=0 \
    adapter/.venv/bin/python adapter/server.py >"$RT/server.log" 2>&1 &
    echo $! > "$RT/fake.pid")
  FAKE_PID="$(cat "$RT/fake.pid")"
  for _ in $(seq 40); do curl -sf --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.25; done
else
  PORT="${CCA_ADAPTER_PORT:-4011}"
fi
BASE="http://127.0.0.1:${PORT}"
export CCA_EDGE_PORT="$PORT"   # 透传给内嵌 python（原来硬编码 4011 会打日常实例）
PASS=0; FAIL=0

check() { # name condition
  if [ "$2" = "0" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi
}

# 1. 畸形 JSON body
code=$(curl -s -o /tmp/edge1.out -w '%{http_code}' --max-time 10 "$BASE/v1/messages" \
  -H 'content-type: application/json' -d '{invalid json')
[ "$code" != "000" ]; check "malformed-json 不挂起(http=$code)" $?
rg -q 'error' /tmp/edge1.out 2>/dev/null; check "malformed-json 返回 error 结构" $?

# 2. 空 messages 数组
code=$(curl -s -o /tmp/edge2.out -w '%{http_code}' --max-time 30 "$BASE/v1/messages" \
  -H 'content-type: application/json' -H 'X-Claude-Code-Session-Id: edge-empty' \
  -d '{"model":"grok-4.6","max_tokens":16,"messages":[]}')
[ "$code" = "400" ]; check "empty-messages 快速拒绝(http=$code)" $?

# 3. 缺 model 字段
code=$(curl -s -o /tmp/edge3.out -w '%{http_code}' --max-time 30 "$BASE/v1/messages" \
  -H 'content-type: application/json' -H 'X-Claude-Code-Session-Id: edge-nomodel' \
  -d '{"max_tokens":16,"messages":[{"role":"user","content":"hi"}]}')
[ "$code" != "000" ]; check "missing-model 不挂起(http=$code)" $?

# 4. 未知路径
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/v1/unknown" \
  -H 'content-type: application/json' -d '{}')
[ "$code" = "404" ]; check "unknown-path 返回 404" $?

# 5. 超大单条消息（200KB）
python3 -c "
import json
big = 'x' * 200000
body = {'model':'grok-4.6','max_tokens':16,'messages':[{'role':'user','content':big}]}
json.dump(body, open('/tmp/edge-big.json','w'))
"
code=$(curl -s -o /tmp/edge5.out -w '%{http_code}' --max-time 60 "$BASE/v1/messages" \
  -H 'content-type: application/json' -H 'X-Claude-Code-Session-Id: edge-big' \
  --data-binary @/tmp/edge-big.json)
[ "$code" != "000" ]; check "200KB-message 不挂起(http=$code)" $?

# 6. content 为非法类型（数字）
code=$(curl -s -o /tmp/edge6.out -w '%{http_code}' --max-time 30 "$BASE/v1/messages" \
  -H 'content-type: application/json' -H 'X-Claude-Code-Session-Id: edge-num' \
  -d '{"model":"grok-4.6","max_tokens":16,"messages":[{"role":"user","content":42}]}')
[ "$code" != "000" ]; check "numeric-content 不挂起(http=$code)" $?

# 7. 并发写同一文件（两个 session 同时 Edit）
mkdir -p /tmp/cca-edge && echo "line1" > /tmp/cca-edge/shared.txt
python3 - <<'PY'
import json, os, urllib.request, threading
PORT = int(os.environ.get("CCA_EDGE_PORT", "4011"))
def edit(sid, old, new, results, i):
    body = {"model":"grok-4.6","max_tokens":256,"messages":[{"role":"user","content":f"用 Edit 把 /tmp/cca-edge/shared.txt 里的 '{old}' 改成 '{new}'"}],
            "tools":[{"name":"Edit","description":"edit","input_schema":{"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}}}}]}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/messages",
        data=json.dumps(body).encode(),
        headers={"content-type":"application/json","X-Claude-Code-Session-Id":sid})
    try:
        r = json.load(urllib.request.urlopen(req, timeout=90))
        results[i] = "ok"
    except Exception as e:
        results[i] = f"exc:{e}"
results = {}
ts = [threading.Thread(target=edit, args=(f"edge-conc-{k}","line1",f"line-{k}",results,k)) for k in "AB"]
[t.start() for t in ts]; [t.join() for t in ts]
print("concurrent-edit:", results)
PY
check "concurrent-edit 两 session 都返回（不挂死）" $?

# 8. 并发 user 请求同 session（TUI 标题生成场景）：必须串行，不得互踩
python3 - <<'PY'
import json, os, urllib.request, threading, time
PORT = int(os.environ.get("CCA_EDGE_PORT", "4011"))
def ask(sid, text, results, i):
    body = {"model":"grok-4.6","max_tokens":8,"messages":[{"role":"user","content":text}]}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/messages",
        data=json.dumps(body).encode(),
        headers={"content-type":"application/json","X-Claude-Code-Session-Id":sid})
    try:
        t0=time.time()
        r = json.load(urllib.request.urlopen(req, timeout=120))
        txt = ''.join(b.get('text','') for b in r.get('content',[]) if b.get('type')=='text')
        results[i] = f"ok:{time.time()-t0:.1f}s:{txt[:10]}"
    except Exception as e:
        results[i] = f"exc:{e}"
results = {}
ts = [threading.Thread(target=ask, args=("conc-user", f"说{k}", results, k)) for k in "12"]
t0=time.time(); [t.start() for t in ts]; [t.join() for t in ts]
print(f"concurrent-user: {results} total={time.time()-t0:.1f}s")
PY
check "concurrent-user 同 session 串行不互踩" $?

# 9. adapter 进程仍健康
curl -sf --max-time 3 "$BASE/health" >/dev/null; check "adapter 存活" $?

[ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
echo
echo "edge-matrix: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
