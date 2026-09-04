#!/usr/bin/env bash
# 故障注入矩阵：CCA_FAKE_AGENT 假上游，零 API 消耗，秒级确定性
# 覆盖：基本问答 / 工具会合闭环 / 多工具并发 / 慢响应 / 429 重试策略 / hang+取消 / 并发串行
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=4060
RT="$ROOT/runtime/fake-test"
BASE="http://127.0.0.1:$PORT"
PASS=0; FAIL=0

ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }

start_fake() { # mode
  # 按 PID 文件精确管理（pkill 模式匹配不到——runtime 在环境变量而非命令行）
  [ -f "$RT/fake.pid" ] && kill "$(cat "$RT/fake.pid")" 2>/dev/null && sleep 0.5
  lsof -ti tcp:$PORT | xargs kill 2>/dev/null; sleep 0.3
  mkdir -p "$RT"
  (cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
    CCA_FAKE_AGENT=1 CCA_FAKE_MODE="$1" CCA_FAKE_RPD="${2:-0}" CCA_FAKE_DELAY="${3:-5}" \
    CCA_ADAPTER_PORT=$PORT CCA_RUNTIME="$RT" CCA_WORKSPACE="$ROOT" CCA_PREWARM=0 \
    adapter/.venv/bin/python adapter/server.py >"$RT/server.log" 2>&1 &
    echo $! > "$RT/fake.pid")
  # 健康检查 + 实例指纹：确认是新进程（uptime 应很小）
  for _ in $(seq 40); do
    up=$(curl -sf --max-time 1 "$BASE/health" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("uptime_s",999))' 2>/dev/null || echo 999)
    [ "${up:-999}" -lt 15 ] 2>/dev/null && return 0
    sleep 0.25
  done
  echo "fake adapter 启动失败"; tail -5 "$RT/server.log"; exit 1
}

# ---------- 1. text 模式：基本问答 ----------
start_fake text
code=$(curl -s -o /tmp/fake1.out -w '%{http_code}' --max-time 10 "$BASE/v1/messages" \
  -H 'content-type: application/json' -H 'X-Claude-Code-Session-Id: fake-t1' \
  -d '{"model":"grok-4.6","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}')
[ "$code" = "200" ] && rg -q 'fake 回答' /tmp/fake1.out && ok "text 基本问答" || bad "text 基本问答 ($code)"

# ---------- 2. tool 模式：完整会合闭环（模拟 CC 行为） ----------
start_fake tool
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
BASE = sys.argv[1]
def post(body, sid):
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return json.load(urllib.request.urlopen(req, timeout=30))
sid = "fake-tool"
r1 = post({"model": "grok-4.6", "max_tokens": 128,
           "messages": [{"role": "user", "content": "跑个命令"}],
           "tools": [{"name": "Bash", "description": "x",
                      "input_schema": {"type": "object", "properties": {"command": {"type": "string"}}}}]}, sid)
tu = [b for b in r1.get("content", []) if b.get("type") == "tool_use"]
assert len(tu) == 1 and tu[0]["name"] == "Bash", f"第1轮应返回 Bash tool_use: {r1}"
# 模拟 CC 执行并回结果
r2 = post({"model": "grok-4.6", "max_tokens": 128,
           "messages": [{"role": "user", "content": "跑个命令"},
                        {"role": "assistant", "content": r1["content"]},
                        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tu[0]["id"],
                                                      "content": "fake-output-ok"}]}]}, sid)
text = "".join(b.get("text", "") for b in r2.get("content", []) if b.get("type") == "text")
assert "fake-output-ok" in text, f"第2轮应含工具结果: {text[:100]}"
print("PASS tool 会合闭环（tool_use→tool_result→文本）")
PY
[ $? = 0 ] || bad "tool 会合闭环"

# ---------- 3. multi_tool：一轮并发 2 工具 ----------
start_fake multi_tool
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
BASE = sys.argv[1]
def post(body, sid):
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return json.load(urllib.request.urlopen(req, timeout=30))
sid = "fake-mt"
tools = [{"name": n, "description": "x", "input_schema": {"type": "object", "properties": {}}}
         for n in ("Bash", "Read")]
r1 = post({"model": "grok-4.6", "max_tokens": 128,
           "messages": [{"role": "user", "content": "并发调两个"}], "tools": tools}, sid)
tus = [b for b in r1.get("content", []) if b.get("type") == "tool_use"]
assert len(tus) == 2, f"应并发 2 个 tool_use: {r1}"
tr = [{"type": "tool_result", "tool_use_id": t["id"], "content": f"res-{t['name']}"} for t in tus]
r2 = post({"model": "grok-4.6", "max_tokens": 128,
           "messages": [{"role": "user", "content": "并发调两个"},
                        {"role": "assistant", "content": r1["content"]},
                        {"role": "user", "content": tr}]}, sid)
text = "".join(b.get("text", "") for b in r2.get("content", []) if b.get("type") == "text")
assert "res-Bash" in text and "res-Read" in text, f"两结果都该会合: {text[:150]}"
print("PASS multi_tool 并发会合")
PY
[ $? = 0 ] || bad "multi_tool 并发会合"

# ---------- 4. error429 瞬时：应重试一次（日志断言） ----------
start_fake error429 0
curl -s --max-time 15 "$BASE/v1/messages" -H 'content-type: application/json' \
  -H 'X-Claude-Code-Session-Id: fake-429a' \
  -d '{"model":"grok-4.6","max_tokens":8,"messages":[{"role":"user","content":"x"}]}' >/dev/null
rg -q 'transient upstream error, retry once' "$RT/server.log" && ok "429 瞬时 → 重试一次" || bad "429 瞬时应重试"

# ---------- 5. error429 RPD 日限额：不得重试 ----------
start_fake error429 1
curl -s --max-time 15 "$BASE/v1/messages" -H 'content-type: application/json' \
  -H 'X-Claude-Code-Session-Id: fake-429b' \
  -d '{"model":"grok-4.6","max_tokens":8,"messages":[{"role":"user","content":"x"}]}' >/dev/null
if rg -q 'daily rate cap hit' "$RT/server.log" && ! rg -q 'transient upstream error, retry' "$RT/server.log"; then
  ok "429 RPD 日限额 → fail-fast 不重试"
else
  bad "429 RPD 不应重试"
fi

# ---------- 6. hang + 客户端断开（stream）：应 cancel ----------
# 注意：必须 stream 模式——非流式在回合完成前零字节，TCP 半开无法感知断开；
# 流式的 on_idle ping（5s）才是断开探测通道，与真实 CC 行为一致。
start_fake hang
python3 - "$BASE" <<'PY'
import http.client, json, sys, time
BASE = sys.argv[1].replace("http://", "")
conn = http.client.HTTPConnection(BASE, timeout=10)
conn.request("POST", "/v1/messages",
    json.dumps({"model": "grok-4.6", "max_tokens": 8, "stream": True,
                "messages": [{"role": "user", "content": "挂起我"}]}),
    {"content-type": "application/json", "X-Claude-Code-Session-Id": "fake-hang"})
resp = conn.getresponse()
resp.fp.readline()  # 读到一个 SSE 事件行即确认流已建立（不用 read(64)，会阻塞等满）
conn.close()    # 模拟 ESC：客户端断开
time.sleep(8)   # ping 周期 2s；macOS 半开第 3 次 write 才抛 → 最坏 ~6s，留余量
PY
rg -q 'cancel upstream run|client disconnect' "$RT/server.log" && ok "hang + 断开 → 取消上游" || bad "hang 断开后应 cancel"

# ---------- 7. 并发 user 请求同 session：串行 ----------
start_fake slow 0 3
python3 - "$BASE" <<'PY'
import json, sys, threading, time, urllib.request
BASE = sys.argv[1]
def ask(sid, tag, res):
    body = {"model": "grok-4.6", "max_tokens": 8, "messages": [{"role": "user", "content": tag}]}
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    t0 = time.time()
    try:
        urllib.request.urlopen(req, timeout=60)
        res[tag] = time.time() - t0
    except Exception as e:
        res[tag] = -1
res = {}
ts = [threading.Thread(target=ask, args=("fake-conc", f"q{k}", res)) for k in "12"]
t0 = time.time(); [t.start() for t in ts]; [t.join() for t in ts]
total = time.time() - t0
# slow 模式每轮 3s：串行应 ~6s（total≥5.5），并行则 ~3s
assert total >= 5.5 and all(v > 0 for v in res.values()), f"应串行（total={total:.1f}s）: {res}"
print(f"PASS 并发串行 total={total:.1f}s（两轮各 ~3s）")
PY
[ $? = 0 ] || bad "并发 user 请求应串行"

[ -f "$RT/fake.pid" ] && kill "$(cat "$RT/fake.pid")" 2>/dev/null
echo
echo "fault-injection: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
