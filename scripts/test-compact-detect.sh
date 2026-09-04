#!/usr/bin/env bash
# 本地单测：摘要轮检测不得误伤「压缩后的正常会话」
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CURSOR_API_KEY="${CURSOR_API_KEY:-dummy}"
export ROOT
"$ROOT/adapter/.venv/bin/python" - <<'PY'
import os, importlib.util, tempfile
root = os.environ["ROOT"]
runtime = tempfile.mkdtemp(prefix="cca-test-runtime-")
os.environ["CCA_RUNTIME"] = runtime
with open(os.path.join(runtime, "workspace"), "w", encoding="utf-8") as f:
    f.write(root)
spec = importlib.util.spec_from_file_location("server", f"{root}/adapter/server.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

compact_user = (
    "CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.\n"
    "Your task is to create a detailed summary of this conversation. "
    "This summary will be placed at the start of a continuing session.\n"
    "Your entire response must be plain text: an <analysis> block followed by a <summary> block."
)
assert mod.is_summarization_request({
    "system": "You are Claude Code.",
    "messages": [{"role": "user", "content": compact_user}],
    "tools": [{"name": "Read"}],
}), "real compact must match"

# 压缩后的续聊：历史里已有 <summary>，末条是普通用户话 → 不得命中
post = {
    "system": "You are Claude Code.",
    "messages": [
        {"role": "user", "content": (
            "This session is being continued from a previous conversation...\n"
            "<summary>goals...</summary>\n"
            "Continue the conversation from where it left off."
        )},
        {"role": "assistant", "content": "好的，继续。"},
        {"role": "user", "content": "你能修复完善项目吗？"},
    ],
    "tools": [{"name": "Read"}],
}
assert not mod.is_summarization_request(post), "post-compact normal turn must NOT match"

assert not mod.is_summarization_request({
    "messages": [{"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "x", "content": "ok <summary>fake</summary>"},
    ]}],
}), "tool_result must NOT match"

# pending 存在时：即使末条是真 compact 指令也不跑摘要
assert not mod.should_run_compaction(1, {
    "messages": [{"role": "user", "content": compact_user}],
}), "pending must block compaction"
assert mod.should_run_compaction(0, {
    "messages": [{"role": "user", "content": compact_user}],
}), "zero pending + compact must run"

# Claude 系 id 不得直通；Cursor 模型保持原样
assert mod.resolve_model("claude-sonnet-4-5") == mod.SONNET_MODEL, "sonnet alias"
assert mod.resolve_model("claude-opus-5") == mod.OPUS_MODEL, "opus alias"
assert mod.resolve_model("claude-haiku-4-5") == mod.HAIKU_MODEL, "haiku alias"
assert mod.resolve_model("composer-2.5") == "composer-2.5", "cursor id passthrough"
assert mod.resolve_model("grok-4.6") == "grok-4.6", "grok passthrough"

prompt = mod.build_summarization_prompt({"messages": [{"role": "user", "content": "hi"}]})
assert "<analysis>" in prompt and "<summary>" in prompt, "compact prompt must ask for CC blocks"
wrapped = mod.ensure_compact_blocks("plain summary text about the session work and next steps.")
assert "<summary>" in wrapped and "</summary>" in wrapped, "fallback must wrap summary tags"
already = mod.ensure_compact_blocks("<analysis>a</analysis>\n<summary>s</summary>")
assert already.startswith("<analysis>"), "do not double-wrap"

# 本地工具不得扫出 workspace
outside = mod.run_local_tool("Glob", {"pattern": "*", "path": "/etc"}, root)
assert outside.startswith("error:"), f"glob must jail: {outside}"
outside_g = mod.run_local_tool("Grep", {"pattern": "root", "path": "/etc/passwd"}, root)
assert outside_g.startswith("error:"), f"grep must jail: {outside_g}"
try:
    mod.confine_to_workspace("/etc", root)
    raise SystemExit("confine_to_workspace must reject /etc")
except ValueError:
    pass
inside = mod.confine_to_workspace("adapter/server.py", root)
assert inside.endswith("adapter/server.py"), inside

assert mod._unsafe_glob_pattern("../etc"), "parent glob"
assert mod._unsafe_glob_pattern("/tmp/*"), "abs glob"
assert not mod._unsafe_glob_pattern("**/*.py"), "ok glob"

dotdot = mod.run_local_tool("Glob", {"pattern": "../**"}, root)
assert dotdot.startswith("error:"), f"glob .. must reject: {dotdot}"

hits = mod.run_local_tool("Glob", {"pattern": "test-compact-detect.sh", "path": "scripts"}, root)
assert "test-compact-detect.sh" in hits, hits

grep_lim = mod.run_local_tool(
    "Grep",
    {"pattern": "def ", "path": "adapter/server.py", "output_mode": "content", "head_limit": 3},
    root,
)
assert "truncated" in grep_lim or grep_lim.count("\n") <= 3, grep_lim

bad_g = mod.run_local_tool("Grep", {"pattern": "x", "glob": "../**"}, root)
assert bad_g.startswith("error:"), bad_g

expanded, local_names = mod.inject_missing_local_tools([])
assert set(local_names) == {"Glob", "Grep"}, local_names
assert {t["name"] for t in expanded} == {"Glob", "Grep"}
# CC 已下发时不得再标 local（走会合，对齐标准 CC UI/权限）
_, local2 = mod.inject_missing_local_tools([
    {"name": "Glob", "description": "x", "input_schema": {}},
    {"name": "Grep", "description": "y", "input_schema": {}},
])
assert local2 == [], local2

# Skills / Agent 目录必须保留（能力对齐）；仅丢掉 <total_tokens>
sys_keep = mod.abridge_system(
    "RULES here\n"
    "The following skills are available\n- skill-a: does A\n"
    "Available agent types for the Agent tool\n- explore\n"
    "<total_tokens>99999</total_tokens>"
)
assert "skill-a" in sys_keep and "explore" in sys_keep, sys_keep
assert "total_tokens" not in sys_keep, sys_keep
assert sys_keep.startswith("RULES"), sys_keep
# 超限时仍应尽量保住目录关键词
fat = "CORE " + ("z" * 8000) + "\nThe following skills are available\n- skill-b\n"
fat_out = mod.abridge_system(fat, limit=2000)
assert "skill" in fat_out.lower() or "skills are available" in fat_out.lower(), fat_out

flat = mod.flatten_content([
    {"type": "text", "text": "see"},
    {"type": "image", "source": {"media_type": "image/png"}},
    {"type": "thinking", "thinking": "plan"},
])
assert "image" in flat and "omitted" in flat and "thinking" in flat, flat

# ensure_agent：同工具复用；工具路由/集合变化优先 resume，避免 drop→create 丢 SDK 记忆
class FakeAgent:
    created = 0
    resumed = 0
    closed = 0

    def __init__(self, agent_id):
        self.agent_id = agent_id

    @classmethod
    def create(cls, opts):
        cls.created += 1
        return cls(f"fake-{cls.created}")

    @classmethod
    def resume(cls, agent_id, opts):
        cls.resumed += 1
        return cls(agent_id)

    def close(self):
        type(self).closed += 1

real_agent = mod.Agent
mod.Agent = FakeAgent
try:
    s = mod.Session("t:main")
    read_tool = [{
        "name": "Read",
        "description": "read",
        "input_schema": {"type": "object", "properties": {}},
    }]
    s.ensure_agent("grok-4.6", read_tool)
    assert FakeAgent.created == 1 and FakeAgent.resumed == 0
    s.turns = 4
    s.ensure_agent("grok-4.6", read_tool)
    assert FakeAgent.created == 1 and FakeAgent.resumed == 0, "same tools must reuse"

    with_glob_grep = read_tool + [
        {"name": "Glob", "description": "g", "input_schema": {"type": "object", "properties": {}}},
        {"name": "Grep", "description": "g", "input_schema": {"type": "object", "properties": {}}},
    ]
    s.ensure_agent("grok-4.6", with_glob_grep)
    assert FakeAgent.created == 1 and FakeAgent.resumed == 1, "CC Glob/Grep 到达应 resume 重绑，不是重建"
    assert s.turns == 4 and not s.local_tools, "resume 不得重置会话轮次"

    s.ensure_agent("grok-4.6", with_glob_grep + [{
        "name": "Write",
        "description": "w",
        "input_schema": {"type": "object", "properties": {}},
    }])
    assert FakeAgent.created == 1 and FakeAgent.resumed == 2, "工具集变化应 resume 保会话"
    assert s.turns == 4
finally:
    mod.Agent = real_agent

print("PASS compact-detect")
PY
