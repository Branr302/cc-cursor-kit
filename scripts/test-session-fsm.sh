#!/usr/bin/env bash
# 离线单测：假上游驱动 Session 会合 / drain / reemit / stale / SSE 形状（不耗 Cursor API）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CURSOR_API_KEY="${CURSOR_API_KEY:-dummy}"
export ROOT
"$ROOT/adapter/.venv/bin/python" - <<'PY'
import io
import json
import os
import importlib.util
import tempfile
import threading
import time
from types import SimpleNamespace

root = os.environ["ROOT"]
runtime = tempfile.mkdtemp(prefix="cca-fsm-runtime-")
os.environ["CCA_RUNTIME"] = runtime
with open(os.path.join(runtime, "workspace"), "w", encoding="utf-8") as f:
    f.write(root)

spec = importlib.util.spec_from_file_location("server", f"{root}/adapter/server.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeRun:
    def __init__(self, messages=None, result="OK.", status="finished"):
        self._messages = list(messages or [])
        self._result = SimpleNamespace(result=result, status=status, usage=None)

    def messages(self):
        return list(self._messages)

    def wait(self):
        return self._result


class FakeAgent:
    created = 0
    resumed = 0

    def __init__(self, agent_id, script):
        self.agent_id = agent_id
        self._script = script  # callable(prompt, opts) -> FakeRun | None
        self.model = None

    @classmethod
    def create(cls, opts):
        cls.created += 1
        return cls(f"fake-{cls.created}", getattr(cls, "_script", None))

    @classmethod
    def resume(cls, agent_id, opts):
        cls.resumed += 1
        return cls(agent_id, getattr(cls, "_script", None))

    def send(self, prompt, opts=None):
        if self._script is None:
            return FakeRun(result="OK.")
        return self._script(self, prompt, opts)

    def close(self):
        pass


def make_handler_stub():
    h = object.__new__(mod.Handler)
    h.wfile = io.BytesIO()
    h.close_connection = False
    h.requestline = "POST /v1/messages HTTP/1.1"
    h.client_address = ("127.0.0.1", 9)
    h.command = "POST"
    h.request_version = "HTTP/1.1"
    # 跳过真实 HTTP 头，只测 SSE 事件体
    h._begin_sse = lambda: None
    return h


# ---- _collect: text only ----
sess = mod.Session("fsm:text")
sess.turn_id = 1
sess.events.put({"type": "text", "text": "hello ", "turn": 1})
sess.events.put({"type": "text", "text": "world", "turn": 1})
sess.events.put({"type": "turn_end", "usage": None, "turn": 1})
seen = []
msg = mod.Handler._collect(object(), sess, lambda t: seen.append(t), lambda p: None)
assert msg["stop_reason"] == "end_turn", msg
assert msg["content"] == [{"type": "text", "text": "hello world"}], msg
assert "".join(seen) == "hello world"

# ---- _collect: tool_use then stop ----
sess = mod.Session("fsm:tool")
sess.turn_id = 2
pending = mod.Pending("toolu_abc", "Read", {"file_path": "README.md"})
with sess.pending_lock:
    sess.pending[pending.our_id] = pending
sess.events.put({"type": "text", "text": "reading", "turn": 2})
sess.events.put({"type": "tool_call", "pending": pending, "turn": 2})
# 有 tool_call 后 _collect 会短暂再等；直接 turn_end 也可结束
sess.events.put({"type": "turn_end", "usage": None, "turn": 2})
calls = []
msg = mod.Handler._collect(object(), sess, lambda t: None, lambda p: calls.append(p))
assert msg["stop_reason"] == "tool_use", msg
assert len(calls) == 1 and calls[0].name == "Read"
assert any(b.get("type") == "tool_use" and b.get("id") == "toolu_abc" for b in msg["content"]), msg
assert any(b.get("type") == "text" and b.get("text") == "reading" for b in msg["content"]), msg

# ---- feed_tool_results 放行 execute 会合 ----
sess = mod.Session("fsm:feed")
sess.turn_id = 3
sess.workspace = root
execute = sess._make_execute("Read", local=False)
holder = {"out": None, "err": None}

def runner():
    try:
        holder["out"] = execute({"file_path": "README.md"}, None)
    except Exception as exc:  # noqa: BLE001
        holder["err"] = exc

th = threading.Thread(target=runner, daemon=True)
th.start()
# 等 tool_call 事件
ev = sess.events.get(timeout=2)
assert ev["type"] == "tool_call"
p = ev["pending"]
assert p.name == "Read"
assert sess.pending_count() == 1
fed = sess.feed_tool_results({
    "messages": [{
        "role": "user",
        "content": [{
            "type": "tool_result",
            "tool_use_id": p.our_id,
            "content": "file body here",
        }],
    }],
})
assert fed == 1, fed
th.join(timeout=2)
assert holder["err"] is None, holder
assert holder["out"] == "file body here"
assert sess.pending_count() == 0

# ---- stale：有 tool_result 但无匹配 pending ----
sess = mod.Session("fsm:stale")
assert sess.body_has_tool_results({
    "messages": [{"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "missing", "content": "x"},
    ]}],
})
assert sess.feed_tool_results({
    "messages": [{"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "missing", "content": "x"},
    ]}],
}) == 0

# ---- reemit 形状 ----
sess = mod.Session("fsm:reemit")
p1 = mod.Pending("toolu_1", "Bash", {"command": "echo hi"})
p2 = mod.Pending("toolu_2", "Glob", {"pattern": "*.py"})
with sess.pending_lock:
    sess.pending[p1.our_id] = p1
    sess.pending[p2.our_id] = p2
re = sess.pending_as_message("grok-4.6")
assert re["stop_reason"] == "tool_use"
assert [b["name"] for b in re["content"]] == ["Bash", "Glob"]

# ---- SSE text emission 顺序 ----
h = make_handler_stub()
mod.Handler._emit_text_sse(h, mod.text_only_message("grok-4.6", "摘要正文"))
raw = h.wfile.getvalue().decode("utf-8")
assert "event: message_start" in raw
assert "event: content_block_start" in raw
assert "event: content_block_delta" in raw
assert "摘要正文" in raw
assert "event: content_block_stop" in raw
assert "event: message_delta" in raw
assert "event: message_stop" in raw
assert '"stop_reason": "end_turn"' in raw or '"stop_reason":"end_turn"' in raw

# ---- SSE tool_use reemit 顺序（partial_json）----
h = make_handler_stub()
# 手工走 reemit 分支的写出逻辑：复用 Handler._handle_messages 太重，直接断言 sse_line 形状
line = mod.sse_line("content_block_delta", {
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "input_json_delta", "partial_json": json.dumps({"pattern": "*.py"}, ensure_ascii=False)},
}).decode("utf-8")
assert "event: content_block_delta" in line
assert "input_json_delta" in line
assert "partial_json" in line
assert "*.py" in line

# ---- start_turn 假上游：先 on_delta 文本，再 wait ----
def script_text(agent, prompt, opts):
    on_delta = getattr(opts, "on_delta", None) if opts is not None else None
    if on_delta:
        on_delta(SimpleNamespace(type="text-delta", text="pong"))
    return FakeRun(result="pong", status="finished")

FakeAgent._script = script_text
real_agent = mod.Agent
mod.Agent = FakeAgent
try:
    sess = mod.Session("fsm:start")
    sess.ensure_agent("grok-4.6", [{
        "name": "Read",
        "description": "r",
        "input_schema": {"type": "object", "properties": {}},
    }])
    sess.start_turn({"messages": [{"role": "user", "content": "hi"}]}, "grok-4.6")
    # drain
    msg = mod.Handler._collect(object(), sess, lambda t: None, lambda p: None)
    assert msg["stop_reason"] == "end_turn"
    assert any(b.get("text") == "pong" for b in msg["content"] if b.get("type") == "text"), msg
finally:
    mod.Agent = real_agent
    FakeAgent._script = None

# ---- should_run_compaction 与 pending 互斥（已有，再钉一次）----
assert not mod.should_run_compaction(1, {
    "messages": [{"role": "user", "content": (
        "CRITICAL: Respond with TEXT ONLY. Do NOT call any tools. "
        "Your task is to create a detailed summary of this conversation."
    )}],
})

# ---- extract_images：CC image block → SDK 线格式 ----
imgs = mod.extract_images([
    {"type": "text", "text": "看图"},
    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "QUJD"}},
    {"type": "image", "source": {"type": "url", "url": "https://x/y.png"}},  # 无 data，跳过
    {"type": "tool_result", "tool_use_id": "t1", "content": "x"},
])
assert imgs == [{"data": "QUJD", "mimeType": "image/png"}], imgs
assert mod.extract_images("纯文本") == []
assert mod.extract_images(None) == []

# ---- has_tool_result_turn：只看末条 user（--continue 回归）----
# 历史含旧 tool_result，但当前轮是纯文本提问 → False（修复前误判 True → stale）
assert not mod.Session("fsm:tr").has_tool_result_turn({
    "messages": [
        {"role": "user", "content": "读文件"},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "old"}]},
        {"role": "assistant", "content": "读完了"},
        {"role": "user", "content": "接下来呢"},
    ]
})
# 当前轮是 tool_result → True
assert mod.Session("fsm:tr2").has_tool_result_turn({
    "messages": [
        {"role": "user", "content": "读文件"},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "t2", "name": "Read", "input": {}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t2", "content": "data"}]},
    ]
})

# ---- cancel_current：有 run 时取消，无 run 时安全 ----
sess_cancel = mod.Session("fsm:cancel")
sess_cancel.cancel_current("no run")  # 不抛异常
class FakeCancelRun:
    cancelled = False
    def cancel(self):
        self.cancelled = True
fake_run = FakeCancelRun()
sess_cancel.current_run = fake_run
sess_cancel.cancel_current("client disconnect")
assert fake_run.cancelled
sess_cancel.current_run = None

print("PASS session-fsm")
PY
