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

start_fake() { # mode [rpd] [delay] [extra_env...]
  # 按 PID 文件精确管理（pkill 模式匹配不到——runtime 在环境变量而非命令行）
  [ -f "$RT/fake.pid" ] && kill "$(cat "$RT/fake.pid")" 2>/dev/null && sleep 0.5
  lsof -ti tcp:$PORT | xargs kill 2>/dev/null; sleep 0.3
  mkdir -p "$RT"
  local mode="$1" rpd="${2:-0}" delay="${3:-5}"; shift 3 2>/dev/null || shift $#
  (cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
    CCA_FAKE_AGENT=1 CCA_FAKE_MODE="$mode" CCA_FAKE_RPD="$rpd" CCA_FAKE_DELAY="$delay" \
    CCA_ADAPTER_PORT=$PORT CCA_RUNTIME="$RT" CCA_WORKSPACE="$ROOT" CCA_PREWARM=0 "$@" \
    adapter/.venv/bin/python adapter/server.py >"$RT/server.log" 2>&1 &
    echo $! > "$RT/fake.pid")
  # 健康检查 + 实例指纹：uptime 必须小（防止连到未死透的旧实例）
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
time.sleep(11)  # macOS 半开检测最坏 ~6s；但 ping 时刻受 TCP 栈影响可能拖到 ~12s
PY
# 竞态防护：cancel 日志可能晚于客户端 sleep 结束，循环等它落盘（最多 10s）
for _ in $(seq 20); do
  rg -q 'cancel upstream run|client disconnect' "$RT/server.log" && break
  sleep 0.5
done
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

# ================= 第二批：会合与时序边界 =================

# ---------- 8. 重复 tool_result（CC 重发 bug）：第二次应 stale 秒回 ----------
start_fake tool
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
BASE = sys.argv[1]
def post(body, sid, timeout=30):
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return json.load(urllib.request.urlopen(req, timeout=timeout))
sid = "fake-dup"
tools = [{"name": "Bash", "description": "x", "input_schema": {"type": "object", "properties": {}}}]
r1 = post({"model": "grok-4.6", "max_tokens": 128,
           "messages": [{"role": "user", "content": "跑"}], "tools": tools}, sid)
tu = [b for b in r1["content"] if b.get("type") == "tool_use"][0]
hist = [{"role": "user", "content": "跑"}, {"role": "assistant", "content": r1["content"]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tu["id"], "content": "ok1"}]}]
r2 = post({"model": "grok-4.6", "max_tokens": 128, "messages": hist, "tools": tools}, sid)
r3 = post({"model": "grok-4.6", "max_tokens": 128, "messages": hist, "tools": tools}, sid)
t3 = "".join(b.get("text", "") for b in r3.get("content", []) if b.get("type") == "text")
assert "Acknowledged" in t3, f"重复 tool_result 应 stale: {t3[:80]}"
print("PASS 重复 tool_result → stale 安全处理")
PY
[ $? = 0 ] || bad "重复 tool_result"

# ---------- 9. 工具结果超时（EXEC_TIMEOUT=2s）：应超时收尾而非死等 ----------
start_fake tool 0 5 CCA_EXEC_TIMEOUT=2
python3 - "$BASE" <<'PY'
import json, sys, time, urllib.request
BASE = sys.argv[1]
def post(body, sid, timeout=30):
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return json.load(urllib.request.urlopen(req, timeout=timeout))
sid = "fake-exec-timeout"
tools = [{"name": "Bash", "description": "x", "input_schema": {"type": "object", "properties": {}}}]
t0 = time.time()
r1 = post({"model": "grok-4.6", "max_tokens": 128,
           "messages": [{"role": "user", "content": "跑"}], "tools": tools}, sid)
dt = time.time() - t0
assert dt < 12, f"应在超时后收尾而非死等（{dt:.1f}s）"
print(f"PASS 工具超时收尾（{dt:.1f}s，未死等 600s）")
PY
[ $? = 0 ] || bad "工具结果超时"

# ---------- 10. bg 隔离端到端：主会话 drain 中，haiku 标题请求不排队秒回 ----------
start_fake slow 0 4
python3 - "$BASE" <<'PY'
import json, sys, threading, time, urllib.request
BASE = sys.argv[1]
def post(body, sid, timeout=60):
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return json.load(urllib.request.urlopen(req, timeout=timeout))
sid = "fake-bg"
out = {}
def main_req():
    post({"model": "grok-4.6", "max_tokens": 8,
          "messages": [{"role": "user", "content": "主请求慢任务"}]}, sid)
    out["main"] = time.time()
t0 = time.time()
tm = threading.Thread(target=main_req); tm.start()
time.sleep(0.8)
post({"model": "claude-haiku-4-5", "max_tokens": 8,
      "messages": [{"role": "user", "content": "write a title"}]}, sid)
out["bg_end"] = time.time() - t0
tm.join()
main_end = out["main"] - t0
# 并行：bg 在 0.8s 发出、自身 slow 4s → bg_end≈4.8 < main_end+1；
# 若被 turn_lock 串行：bg_end ≈ main_end+4 ≈ 8
assert out["bg_end"] < main_end + 1.5, \
    f"标题请求疑似排队（bg_end={out['bg_end']:.1f}s main_end={main_end:.1f}s）"
print(f"PASS bg 隔离：bg_end={out['bg_end']:.1f}s 与主请求并行（main_end={main_end:.1f}s）")
PY
[ $? = 0 ] || bad "bg 隔离端到端"

# ---------- 11. 图片桥（fake）：image block → UserMessage 通道 ----------
start_fake text
python3 - "$BASE" <<'PY'
import base64, json, sys, urllib.request
BASE = sys.argv[1]
png = base64.b64encode(bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d4944415478da63fcffff3f030005fe02fea73d815d0000000049454e44ae426082")).decode()
body = {"model": "grok-4.6", "max_tokens": 8, "messages": [{"role": "user", "content": [
    {"type": "text", "text": "看图"},
    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": png}}]}]}
req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
    headers={"content-type": "application/json", "X-Claude-Code-Session-Id": "fake-img"})
r = json.load(urllib.request.urlopen(req, timeout=30))
print("图片桥请求 200" if r else "")
PY
rg -q 'image bridge: 1 image' "$RT/server.log" && ok "图片桥 image bridge 触发" || bad "图片桥未触发"

# ---------- 12. compact 路径（fake）：摘要轮纯文本非空 ----------
start_fake text
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
BASE = sys.argv[1]
# 使用真实 COMPACT_MARKERS 文本，确保走 compaction 路径而非普通 drain
body = {"model": "grok-4.6", "max_tokens": 256, "messages": [
    {"role": "user", "content": "hi"}, {"role": "assistant", "content": "yo"},
    {"role": "user", "content": "Your task is to create a detailed summary of this conversation. "
                                "Respond with text only. Do not call any tools."}]}
req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
    headers={"content-type": "application/json", "X-Claude-Code-Session-Id": "fake-compact"})
r = json.load(urllib.request.urlopen(req, timeout=30))
blocks = r.get("content", [])
assert all(b.get("type") == "text" for b in blocks), f"compact 应纯文本: {blocks}"
assert "".join(b.get("text", "") for b in blocks).strip(), "compact 摘要不得为空"
print("PASS compact 摘要轮（纯文本非空）")
PY
[ $? = 0 ] || bad "compact 摘要轮"
# 真阳性校验：必须真走了 compaction 分支（fake 模式 Agent.prompt 未实现 → fallback 日志）
rg -q 'compaction summary|compaction failed|compaction done' "$RT/server.log" \
  && ok "compact 真走 compaction 分支" || bad "compact 未走 compaction 分支（假阳性）"

# ---------- 13. TTL 过期重建：SESSION_TTL=3s，等 4s 后续聊应重建 agent ----------
start_fake text 0 5 CCA_SESSION_TTL=3
python3 - "$BASE" <<'PY'
import json, sys, time, urllib.request
BASE = sys.argv[1]
def post(tag, sid):
    body = {"model": "grok-4.6", "max_tokens": 8, "messages": [{"role": "user", "content": tag}]}
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return json.load(urllib.request.urlopen(req, timeout=30))
sid = "fake-ttl"
post("第一轮", sid)
time.sleep(4)  # 超过 TTL=3s
r = post("第二轮", sid)  # 应重建 agent 且正常回答
assert r.get("content"), "TTL 重建后应正常返回"
print("PASS TTL 过期后续聊正常")
PY
# 两次 created = 首轮创建 + TTL 过期重建（rg multiline 避免 shell 变量问题）
rg -U -q 'agent created key=fake-ttl[\s\S]*agent created key=fake-ttl' "$RT/server.log" \
  && ok "TTL 过期触发 agent 重建" || bad "TTL 应重建 agent"

# ---------- 14. compact 不占锁：主会话 slow 进行中，compact 并发完成 ----------
start_fake slow 0 4
python3 - "$BASE" <<'PY'
import json, sys, threading, time, urllib.request
BASE = sys.argv[1]
def post(body, sid, timeout=60):
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return json.load(urllib.request.urlopen(req, timeout=timeout))
sid = "fake-cc"
done = {}
t0 = time.time()
def main_req():
    post({"model": "grok-4.6", "max_tokens": 8,
          "messages": [{"role": "user", "content": "慢任务"}]}, sid)
    done["main"] = time.time() - t0
tm = threading.Thread(target=main_req); tm.start()
time.sleep(0.8)
# 主请求占锁中发 compact：真实 marker 文本 → 走独立一次性 agent，不等主请求
t1 = time.time()
post({"model": "grok-4.6", "max_tokens": 128, "messages": [
    {"role": "user", "content": "hi"}, {"role": "assistant", "content": "yo"},
    {"role": "user", "content": "Your task is to create a detailed summary of this conversation. "
                                "Respond with text only. Do not call any tools."}]}, sid)
done["compact"] = time.time() - t0
tm.join()
assert done["compact"] < done["main"] + 1.5, \
    f"compact 应并发不占锁（compact={done['compact']:.1f}s main={done['main']:.1f}s）"
print(f"PASS compact 不占锁：{done['compact']:.1f}s 完成（主请求 {done['main']:.1f}s）")
PY
[ $? = 0 ] || bad "compact 不占锁"

# ---------- 15. SSE 流式 tool 会合闭环（真实 CC 唯一路径） ----------
start_fake tool
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
BASE = sys.argv[1]

def sse_events(resp):
    """按 SSE 规范产出 (event, data)。"""
    ev, data = None, []
    for raw in resp.fp:
        line = raw.decode("utf-8", "replace").rstrip("\n")
        if line.startswith("event:"):
            ev = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].strip())
        elif line == "" and ev:
            yield ev, "\n".join(data)
            ev, data = None, []

def post_sse(body, sid, timeout=30):
    body = dict(body, stream=True)
    req = urllib.request.Request(f"{BASE}/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "X-Claude-Code-Session-Id": sid})
    return urllib.request.urlopen(req, timeout=timeout)

sid = "fake-sse-tool"
tools = [{"name": "Bash", "description": "x",
          "input_schema": {"type": "object", "properties": {"command": {"type": "string"}}}}]

# 第 1 轮（流式）：应看到 content_block_start(tool_use) + input_json_delta 累积出合法 JSON
resp = post_sse({"model": "grok-4.6", "max_tokens": 128,
                 "messages": [{"role": "user", "content": "跑命令"}], "tools": tools}, sid)
tu_id, tu_name, partial, saw_stop = None, None, "", False
for ev, data in sse_events(resp):
    if ev == "content_block_start":
        b = json.loads(data)["content_block"]
        if b.get("type") == "tool_use":
            tu_id, tu_name = b["id"], b["name"]
    elif ev == "content_block_delta":
        d = json.loads(data)["delta"]
        if d.get("type") == "input_json_delta":
            partial += d.get("partial_json", "")
    elif ev == "message_stop":
        saw_stop = True
assert tu_id and tu_name == "Bash", "流式应给出 Bash tool_use block"
args = json.loads(partial)  # partial_json 累积必须能解析成合法 JSON
assert saw_stop, "应有 message_stop"

# 第 2 轮（流式回 tool_result）：应收到最终文本
hist = [{"role": "user", "content": "跑命令"},
        {"role": "assistant", "content": [{"type": "tool_use", "id": tu_id, "name": "Bash", "input": args}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tu_id, "content": "sse-ok-42"}]}]
resp2 = post_sse({"model": "grok-4.6", "max_tokens": 128, "messages": hist, "tools": tools}, sid)
final_text, saw_stop2 = "", False
for ev, data in sse_events(resp2):
    if ev == "content_block_delta":
        d = json.loads(data)["delta"]
        if d.get("type") == "text_delta":
            final_text += d.get("text", "")
    elif ev == "message_stop":
        saw_stop2 = True
assert "sse-ok-42" in final_text, f"第2轮文本应含工具结果: {final_text[:100]}"
assert saw_stop2
print("PASS SSE 流式 tool 会合闭环（tool_use 分片→tool_result→text_delta）")
PY
[ $? = 0 ] || bad "SSE 流式 tool 会合"

[ -f "$RT/fake.pid" ] && kill "$(cat "$RT/fake.pid")" 2>/dev/null
echo
echo "fault-injection: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
