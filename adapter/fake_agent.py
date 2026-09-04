"""FakeAgent —— adapter 的离线假上游，CCA_FAKE_AGENT=1 时替换 cursor_sdk.Agent。

第一性原理：健壮性测试不该依赖真实上游（贵、慢、不确定、有日限额）。
FakeAgent 用与 cursor_sdk.Agent 相同的接口，按 CCA_FAKE_MODE 脚本化行为：

  text       直接流式输出（默认）
  tool       调用指定工具（CCA_FAKE_TOOL，默认 Bash）再走文本——测 CC 会合闭环
  multi_tool 一轮并发调 2 个工具——测并发会合
  slow       先睡 CCA_FAKE_DELAY 秒再输出——测超时/看门狗
  error429   返回 rate limit 错误（CCA_FAKE_RPD=1 时带 RPD 字样）——测 fail-fast
  hang       永不完成——测 TURN_TIMEOUT 与 ESC 取消
  stream     慢速逐 delta 输出——测 SSE 粒度与中断

cursor_sdk 真实形状（从 server.py 用法反推）：
  Agent.create(AgentOptions) / Agent.resume(id, opts) / Agent.list()
  agent.send(outbound, SendOptions(model, on_delta, local)) -> Run
  run.messages() -> 迭代 status 消息；run.wait() -> result(.status/.result)；run.cancel()
  custom_tools: {name: CustomTool(execute=fn)}，模型调工具时 SDK 同步调 execute。
"""
from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable, Dict, Optional


class _Result:
    def __init__(self, status: str, result: str = ""):
        self.status = status
        self.result = result


class _Msg:
    def __init__(self, mtype: str, status: str = "", message: str = ""):
        self.type = mtype
        self.status = status
        self.message = message


class FakeRun:
    def __init__(self, agent: "FakeAgent", outbound: Any, opts: Any):
        self.agent = agent
        self.outbound = outbound
        self.opts = opts
        self.cancelled = False
        self.mode = os.environ.get("CCA_FAKE_MODE", "text")
        # error 模式：worker 先读 messages() 再 wait()，错误消息要在这里就位
        self._err = ""
        if self.mode == "error429":
            rpd = os.environ.get("CCA_FAKE_RPD", "0") == "1"
            self._err = ("rate_limit_error: This request would exceed your account's "
                         "rate limit. Current: 2190, RPD: 1000") if rpd else \
                        "rate limit 429 too many requests"

    def messages(self):
        if self._err:
            return iter([_Msg("status", "ERROR", self._err)])
        return iter([])

    def cancel(self):
        self.cancelled = True

    def _delta(self, text: str) -> None:
        cb = getattr(self.opts, "on_delta", None)
        if cb:
            class _U:
                type = "text-delta"
            u = _U()
            u.text = text
            cb(u)

    def wait(self) -> _Result:
        mode = self.mode

        if mode == "hang":
            # 永不完成，直到 cancel
            while not self.cancelled:
                time.sleep(0.1)
            return _Result("cancelled")

        if mode == "error429":
            return _Result("error")

        if mode == "slow":
            time.sleep(float(os.environ.get("CCA_FAKE_DELAY", "10")))
            self._delta("慢响应完成")
            return _Result("finished", "慢响应完成")

        if mode == "stream":
            for i in range(20):
                if self.cancelled:
                    return _Result("cancelled")
                self._delta(f"段{i} ")
                time.sleep(0.3)
            return _Result("finished", "stream done")

        if mode in ("tool", "multi_tool"):
            names = [os.environ.get("CCA_FAKE_TOOL", "Bash")]
            if mode == "multi_tool":
                names.append("Read")
            results = []
            threads = []
            lock = threading.Lock()

            def call_tool(nm: str) -> None:
                tool = self.agent.custom_tools.get(nm)
                if tool is None:
                    with lock:
                        results.append(f"[{nm}: 未注册]")
                    return
                args = {"command": "echo fake"} if nm == "Bash" else {}
                try:
                    out = tool.execute(args, None)
                except Exception as exc:  # noqa: BLE001
                    out = f"error: {exc}"
                with lock:
                    results.append(f"[{nm} 结果: {str(out)[:80]}]")

            # 真实 SDK 并发执行多个 tool_use
            for nm in names:
                t = threading.Thread(target=call_tool, args=(nm,), daemon=True)
                t.start()
                threads.append(t)
            for t in threads:
                t.join(timeout=700)
            final = "工具闭环: " + " ".join(results)
            self._delta(final)
            return _Result("finished", final)

        # 默认 text
        body = self.outbound if isinstance(self.outbound, str) else getattr(self.outbound, "text", "")
        self._delta(f"fake 回答: 收到 {len(str(body))} 字符")
        return _Result("finished", "fake done")


class FakeAgent:
    """与 cursor_sdk.Agent 接口对齐的离线替身。"""

    def __init__(self, opts: Any = None, agent_id: str = "fake-agent"):
        self.agent_id = agent_id
        local = getattr(opts, "local", None)
        self.custom_tools: Dict[str, Any] = getattr(local, "custom_tools", {}) or {}
        self.model = getattr(getattr(opts, "model", None), "id", None) if opts else None
        self.closed = False

    _registry: Dict[str, "FakeAgent"] = {}

    @classmethod
    def create(cls, opts: Any = None) -> "FakeAgent":
        a = cls(opts, agent_id=f"fake-{len(cls._registry)}")
        cls._registry[a.agent_id] = a
        return a

    @classmethod
    def resume(cls, agent_id: str, opts: Any = None) -> "FakeAgent":
        a = cls(opts, agent_id=agent_id)
        cls._registry[agent_id] = a
        return a

    @classmethod
    def list(cls):
        return []

    def send(self, outbound: Any, opts: Any = None) -> FakeRun:
        return FakeRun(self, outbound, opts)

    def close(self) -> None:
        self.closed = True
