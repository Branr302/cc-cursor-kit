#!/usr/bin/env python3
"""Anthropic Messages 适配器：Cursor SDK 长会话 + customTools 结构化桥。

把 Claude Code 的工具注册成 SDK custom tools（带完整 input_schema），模型原生
tool_use；execute 回调会合回 Claude Code，由 CC 本地执行后再喂回模型。
"""
from __future__ import annotations

import json
import os
import queue
import re
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse

from cursor_sdk import (
    Agent,
    AgentOptions,
    CustomTool,
    LocalAgentOptions,
    ModelSelection,
    SendOptions,
    UserMessage,
)

HOST = os.environ.get("CCA_HOST", "127.0.0.1")
PORT = int(os.environ.get("CCA_ADAPTER_PORT", "4011"))
_BOOT_TS = time.time()
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TURN_TIMEOUT = int(os.environ.get("CCA_TURN_TIMEOUT", "600"))
EXEC_TIMEOUT = int(os.environ.get("CCA_EXEC_TIMEOUT", "600"))

# 注意：Claude 系在此账号被区域限制（provider not supported in your region），别设为默认。
SONNET_MODEL = os.environ.get("CCA_SONNET_MODEL", "grok-4.6")
OPUS_MODEL = os.environ.get("CCA_OPUS_MODEL", "grok-4.6")
HAIKU_MODEL = os.environ.get("CCA_HAIKU_MODEL", "grok-4.5")

# 禁内置读写/执行类工具，但保留 mcp 与 getMcpTools/listMcpResources 等发现工具——
# 禁掉它们模型就看不到 custom tools（custom tools 走 MCP 通道）。
BUILTIN_TOOLS = (
    "read edit glob grep ls semSearch shell task webSearch webFetch delete "
    "piBash piEdit piFind piGrep piLs piRead piWrite "
    "applyAgentDiff computerUse recordScreen replaceEnv setupVmEnvironment "
    "writeShellStdin createAgent stopAgent sendToAgent "
    "startGrindExecution startGrindPlanning adopt"
).split()

# Cursor 可直通的模型 id。Claude 系不列入：精确命中会跳过 grok 别名，本账号常区域不可用。
KNOWN_MODELS = {
    "default", "composer-2.5", "composer-2", "grok-4.6", "grok-4.5",
    "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
    "gpt-5.4-nano", "gpt-5.3-codex", "gpt-5.2", "gpt-5.1", "gpt-5-mini",
    "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash",
    "gemini-3-flash", "gemini-3.1-pro", "gemini-2.5-flash",
    "kimi-k3", "kimi-k2.7-code", "glm-5.2",
}


def log(msg: str) -> None:
    print(f"[cc-adapter] {msg}", flush=True)


def _ms(t0: float) -> int:
    return int((time.perf_counter() - t0) * 1000)


def runtime_dir() -> str:
    return os.environ.get("CCA_RUNTIME") or os.path.join(ROOT, "runtime")


# 进程启动时冻结的工作区。marker 可被外部误写；健康探针与 ensure_agent 必须跟进程绑定值，
# 不能跟着被污染的 runtime/workspace 漂移。
_BOOT_WORKSPACE: Optional[str] = None


def _resolve_workspace() -> str:
    marker = os.path.join(runtime_dir(), "workspace")
    try:
        with open(marker, encoding="utf-8") as f:
            path = f.read().strip()
        if path and os.path.isdir(path):
            return path
    except OSError:
        pass
    env = os.environ.get("CCA_WORKSPACE")
    if env and os.path.isdir(env):
        return env
    return ROOT


def current_workspace() -> str:
    global _BOOT_WORKSPACE
    if _BOOT_WORKSPACE and os.path.isdir(_BOOT_WORKSPACE):
        return _BOOT_WORKSPACE
    return _resolve_workspace()


def bind_boot_workspace(path: str | None = None) -> str:
    """adapter 进程入口调用一次：之后 current_workspace()/health 不再跟随 marker 漂移。"""
    global _BOOT_WORKSPACE
    resolved = path if path and os.path.isdir(path) else _resolve_workspace()
    _BOOT_WORKSPACE = resolved
    return resolved


def resolve_model(name: str | None, task_hint: str = "") -> str:
    """按任务类型路由模型：简单任务用 fast，复杂推理用 smart。

    task_hint: "fast" | "smart" | ""（默认按 SONNET_MODEL）
    """
    raw = (name or "").strip() or SONNET_MODEL
    low = raw.lower()
    if raw in KNOWN_MODELS:
        return raw
    if "opus" in low:
        return OPUS_MODEL
    if "haiku" in low or "small" in low:
        return HAIKU_MODEL
    # 任务路由：fast 用 composer-2.5，smart 用 grok-4.6
    if task_hint == "fast":
        return os.environ.get("CCA_MODEL_FAST", "composer-2.5")
    if task_hint == "smart":
        return os.environ.get("CCA_MODEL_SMART", "grok-4.6")
    return SONNET_MODEL


SYSTEM_MAX = int(os.environ.get("CCA_SYSTEM_MAX", "12000"))
TOOL_DESC_MAX = int(os.environ.get("CCA_TOOL_DESC_MAX", "800"))
TOOL_RESULT_MAX = int(os.environ.get("CCA_TOOL_RESULT_MAX", "24000"))
PROMPT_MSG_MAX = int(os.environ.get("CCA_PROMPT_MSG_MAX", "12000"))
# 首轮/重建时带给 Cursor 的历史轮次：默认收紧，压缩续聊轮多带一点。
HISTORY_TURNS = int(os.environ.get("CCA_HISTORY_TURNS", "6"))
HISTORY_TURNS_COMPACT = int(os.environ.get("CCA_HISTORY_TURNS_COMPACT", "10"))
GLOB_MAX = 500

# 空字符串可关掉。默认只提醒省上下文，不改语言/工具偏好（语言跟用户 CLAUDE.md）。
_DEFAULT_CONTEXT_HINT = (
    "Context is scarce. Prefer Grep/Glob with tight patterns before Read; "
    "when Reading, pass limit/offset and only paths you must see. "
    "If you intend to call multiple tools and there are no dependencies "
    "between the calls, make all of the independent calls in the same turn."
)
CONTEXT_HINT = os.environ.get("CCA_CONTEXT_HINT", _DEFAULT_CONTEXT_HINT)

# CC 若已下发 Glob/Grep → 走会合（UI+权限对齐标准 CC）。
# 未下发时才本地补缺（能力对齐；无 CC 工具步进，属已知取舍）。
LOCAL_TOOL_SPECS: Dict[str, dict] = {
    "Glob": {
        "description": (
            "Find files by glob pattern. Returns matching paths (one per line). "
            "Use instead of shell find/ls for file discovery."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Glob pattern, e.g. **/*.py or scripts/*"},
                "path": {"type": "string", "description": "Directory to search; omit for workspace cwd"},
            },
            "required": ["pattern"],
        },
    },
    "Grep": {
        "description": (
            "Search file contents with regex (ripgrep). "
            "Prefer this over shell rg/grep for code search."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Regex pattern"},
                "path": {"type": "string", "description": "File or directory; omit for workspace cwd"},
                "glob": {"type": "string", "description": "Optional file filter glob, e.g. *.py"},
                "output_mode": {
                    "type": "string",
                    "enum": ["content", "files_with_matches", "count"],
                    "description": "Default files_with_matches",
                },
                "case_insensitive": {"type": "boolean"},
                "head_limit": {"type": "integer"},
            },
            "required": ["pattern"],
        },
    },
}

# 只认 Claude Code compact 服务真正下发的指令（见 compact/prompt.ts）。
# 绝不能扫整段历史：压缩后对话里自带 <summary> / continued from…，会把后续正常轮全部误判。
COMPACT_MARKERS = (
    "critical: respond with text only. do not call any tools",
    "respond with text only. do not call any tools",
    "your entire response must be plain text: an <analysis> block followed by a <summary> block",
    "your task is to create a detailed summary of this conversation",
    "your task is to create a detailed summary of the recent portion of the conversation",
    "this summary will be placed at the start of a continuing session",
    "summarize thoroughly so that someone reading only your summary",
)


def _last_user_text(body: dict) -> str:
    """末条「非纯 tool_result」的 user 文本；tool_result 轮不算摘要请求。"""
    for msg in reversed(body.get("messages") or []):
        if not isinstance(msg, dict) or msg.get("role") != "user":
            continue
        content = msg.get("content")
        if isinstance(content, list):
            if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                # 纯 tool_result 轮：交给会合，不当 compact
                if all(
                    not isinstance(b, dict) or b.get("type") in ("tool_result",)
                    for b in content
                ):
                    return ""
                texts = [
                    flatten_content(b.get("text") if b.get("type") == "text" else "")
                    for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                ]
                return "\n".join(texts)
            return flatten_content(content)
        return flatten_content(content)
    return ""


def is_summarization_request(body: dict) -> bool:
    """仅当末条 user 指令是 CC compact 摘要提示时为真。"""
    text = _last_user_text(body).lower()
    if not text.strip():
        return False
    return any(k in text for k in COMPACT_MARKERS)


def should_run_compaction(pending_count: int, body: dict) -> bool:
    """有未会合工具时绝不 compact，否则 pending 悬挂、CC 报 no assistant message。"""
    if pending_count:
        return False
    return is_summarization_request(body)


def build_summarization_prompt(body: dict) -> str:
    system = abridge_system(flatten_content(body.get("system")), min(4000, SYSTEM_MAX))
    real = [
        m for m in (body.get("messages") or [])
        if isinstance(m, dict) and m.get("role") in ("user", "assistant")
    ]
    # 摘要轮对话往往极长：只保留头尾，避免 SDK 也爆窗
    chunks: List[str] = [
        "You are summarizing a coding-agent conversation for context compaction.",
        "Output ONLY plain text: an <analysis> block followed by a <summary> block.",
        "Do not call tools. Do not output JSON.",
        "The <summary> must include: goals, decisions, files touched, current state, next steps.",
        "Write at least 12 sentences in the <summary>. Language: match the user (usually Chinese).",
        "",
    ]
    if system:
        chunks.extend(["SYSTEM (abridged):", system, ""])
    if len(real) <= 8:
        keep = real
    else:
        keep = real[:3] + real[-5:]
        chunks.append("(middle turns omitted for length)")
    chunks.append("TRANSCRIPT:")
    per = max(1500, PROMPT_MSG_MAX // max(1, len(keep)))
    for m in keep:
        chunks.append(
            f"{m.get('role')}: {abridge_text(flatten_content(m.get('content')), per, 'turn')}"
        )
    chunks.append("")
    chunks.append("Now write the <analysis> block then the <summary> block:")
    return "\n".join(chunks)


def ensure_compact_blocks(text: str) -> str:
    """CC compact 解析 <summary>；没有标签时由 adapter 包一层。"""
    body = (text or "").strip() or "(empty summary)"
    low = body.lower()
    if "<summary>" in low and "</summary>" in low:
        return body
    return (
        "<analysis>\nAdapter wrapped this summary so Claude Code can parse it.\n</analysis>\n"
        f"<summary>\n{body}\n</summary>"
    )


def run_compaction_summary(body: dict, model: str) -> str:
    """独立一次性 Agent（无 tools），专供 /compact。"""
    from cursor_sdk import AgentOptions, LocalAgentOptions

    prompt = build_summarization_prompt(body)
    t0 = time.perf_counter()
    log(f"compaction summary model={model} prompt_chars={len(prompt)}")
    fallback = ensure_compact_blocks(
        "Conversation summary (fallback): The session covered project work with Claude Code "
        "via the Cursor SDK adapter. Key files and commands were inspected or edited; "
        "continue from the latest user goal. Prefer Grep/Glob before full-file Read."
    )
    try:
        result = Agent.prompt(
            prompt,
            AgentOptions(
                model=ModelSelection(id=model),
                tools=[],
                local=LocalAgentOptions(cwd=current_workspace()),
            ),
        )
        text = (getattr(result, "result", None) or "").strip()
        status = str(getattr(result, "status", "") or "")
        log(f"compaction done_ms={_ms(t0)} status={status} chars={len(text)}")
        if status.lower() == "error" or len(text) < 40:
            log(f"compaction weak result status={status} chars={len(text)}")
            return ensure_compact_blocks(text) if len(text) >= 40 else fallback
        return ensure_compact_blocks(text)
    except Exception as exc:  # noqa: BLE001
        log(f"compaction failed ms={_ms(t0)}: {exc}")
        return fallback


def text_only_message(model: str, text: str) -> dict:
    body = (text or "").strip() or "OK."
    return {
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [{"type": "text", "text": body}],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": estimate_tokens(body), "output_tokens": estimate_tokens(body)},
    }


def estimate_tokens(text: str) -> int:
    """校准后的 token 估算，驱动 CC 的 compact 时机。

    调研结论：CC 的 auto-compact 阈值约 83.5% 窗口（200K → 167K），
    token 计数来自 adapter 的 count_tokens 或响应 usage。
    报高了 CC 提前压缩浪费上下文，报低了 CC 到死才压。
    校准目标：与 Cursor 实际计费 token 误差 <20%。
    """
    if not text:
        return 1
    # 汉字/全角 ~1.0 token（GPT-4  tokenizer 实测），ASCII ~0.25；结构开销 5%
    cjk = sum(1 for ch in text if ord(ch) > 0x2E80)
    other = len(text) - cjk
    return max(1, int(cjk * 1.0 + other * 0.25 + len(text) * 0.05))


def abridge_system(system: str, limit: int = SYSTEM_MAX) -> str:
    """瘦身 system，但保留 Skills / Agent 能力目录（对齐标准 CC）。

    旧逻辑在目录标记处整段截断，会导致 Skill/Agent 工具在却不可用。
    新逻辑：丢掉无用的 <total_tokens> 尾；超限时按「核心指令 + 目录」分预算压缩。
    """
    text = (system or "").strip()
    if not text:
        return ""
    tok = text.find("<total_tokens>")
    if tok != -1:
        text = text[:tok].strip()

    markers = (
        "The following skills are available",
        "Available agent types for the Agent tool",
    )
    cuts: List[tuple[int, str]] = []
    for marker in markers:
        idx = text.find(marker)
        if idx != -1:
            cuts.append((idx, marker))
    cuts.sort()

    if not cuts:
        return abridge_text(text, limit, "system") if len(text) > limit else text

    core = text[: cuts[0][0]].strip()
    sections: List[str] = []
    for i, (idx, _marker) in enumerate(cuts):
        end = cuts[i + 1][0] if i + 1 < len(cuts) else len(text)
        chunk = text[idx:end].strip()
        if chunk:
            sections.append(chunk)

    if len(text) <= limit:
        parts = [core] if core else []
        parts.extend(sections)
        return "\n\n".join(parts)

    # 核心至少 55%；剩余均分给能力目录（目录再短也要留名字清单）
    n_sec = max(1, len(sections))
    core_budget = max(limit * 55 // 100, limit - 1500 * n_sec)
    core_budget = min(core_budget, limit - 200 * n_sec)
    rest = max(400, limit - core_budget)
    per = max(200, rest // n_sec)

    parts = []
    if core:
        parts.append(abridge_text(core, core_budget, "system-core"))
    for sec in sections:
        parts.append(abridge_text(sec, per, "system-catalog"))
    out = "\n\n".join(parts)
    if len(out) > limit:
        out = abridge_text(out, limit, "system")
    return out


def abridge_text(text: str, limit: int, label: str = "content") -> str:
    raw = text or ""
    if len(raw) <= limit:
        return raw
    head = limit * 2 // 3
    tail = limit - head - 80
    if tail < 0:
        return raw[:limit] + f"\n…[{label} truncated {len(raw)} chars]"
    return (
        raw[:head]
        + f"\n\n…[{label} truncated middle, original {len(raw)} chars]…\n\n"
        + raw[-tail:]
    )


def flatten_content(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    parts: List[str] = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                btype = block.get("type")
                if btype == "text":
                    parts.append(str(block.get("text") or ""))
                elif btype == "tool_result":
                    inner = flatten_content(block.get("content"))
                    parts.append(f"[tool_result {block.get('tool_use_id', '')}]\n{inner}")
                elif btype == "tool_use":
                    payload = json.dumps(block.get("input", {}), ensure_ascii=False)
                    parts.append(f"[tool_use {block.get('name', '')}]\n{payload}")
                elif btype == "image":
                    src = block.get("source") if isinstance(block.get("source"), dict) else {}
                    media = src.get("media_type") or block.get("media_type") or "image"
                    parts.append(
                        f"[image {media} omitted: upstream text-only bridge; "
                        f"describe path or OCR via Read/Bash if needed]"
                    )
                elif btype in ("thinking", "redacted_thinking"):
                    thinking = str(block.get("thinking") or block.get("data") or "")
                    if thinking:
                        parts.append(f"[thinking]\n{abridge_text(thinking, 1500, 'thinking')}")
                elif btype:
                    # 未知块至少留类型，避免静默丢能力信号
                    parts.append(f"[{btype} omitted]")
    return "\n".join(p for p in parts if p)


def extract_images(content: Any) -> List[dict]:
    """从 CC 消息 content 提取 base64 图片，转成 SDK UserMessage.images 线格式。

    CC/Anthropic: {"type":"image","source":{"type":"base64","media_type":"image/png","data":"..."}}
    SDK 线格式:  {"data": {"data": <b64>, "mimeType": <media>}}（_image_to_proto_wire 兼容 dict 入参）
    """
    out: List[dict] = []
    if not isinstance(content, list):
        return out
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "image":
            continue
        src = block.get("source") if isinstance(block.get("source"), dict) else {}
        data = src.get("data") or block.get("data") or ""
        media = src.get("media_type") or block.get("media_type") or "image/png"
        if data:
            out.append({"data": data, "mimeType": media})
    return out


def expand_tools(tools: List[dict]) -> List[dict]:
    """补全常见 aliases：Read 的 path、Glob 的 glob、Edit 的 path 等。"""
    expanded: List[dict] = []
    for t in tools:
        if not isinstance(t, dict):
            continue
        name = t.get("name", "")
        schema = dict(t.get("input_schema") or t.get("inputSchema") or {})
        props = dict(schema.get("properties", {}))
        if name == "Read" and "path" not in props and "file_path" in props:
            props["path"] = {"type": "string", "description": "Alias for file_path"}
        if name == "Edit" and "path" not in props and "file_path" in props:
            props["path"] = {"type": "string", "description": "Alias for file_path"}
        if name == "Glob" and "glob" not in props and "pattern" in props:
            props["glob"] = {"type": "string", "description": "Alias for pattern"}
        if name == "Grep" and "regex" not in props and "pattern" in props:
            props["regex"] = {"type": "string", "description": "Alias for pattern"}
        if props:
            schema["properties"] = props
        expanded.append({
            "name": name,
            "description": str(t.get("description") or "")[:TOOL_DESC_MAX],
            "input_schema": schema,
        })
    return expanded


def inject_missing_local_tools(expanded: List[dict]) -> tuple[List[dict], List[str]]:
    """若 CC 未下发 Glob/Grep，则注入 adapter 本地实现。"""
    have = {str(t.get("name")) for t in expanded if t.get("name")}
    local_names: List[str] = []
    out = list(expanded)
    for name, spec in LOCAL_TOOL_SPECS.items():
        if name in have:
            continue
        out.append({
            "name": name,
            "description": spec["description"][:TOOL_DESC_MAX],
            "input_schema": spec["input_schema"],
        })
        local_names.append(name)
    return out, local_names


def confine_to_workspace(path: str, cwd: str) -> str:
    """解析为 workspace 内绝对路径；越界或非法则 ValueError。"""
    from pathlib import Path

    base = Path(cwd).expanduser().resolve()
    raw = Path(str(path or cwd)).expanduser()
    if not raw.is_absolute():
        raw = base / raw
    resolved = raw.resolve()
    try:
        resolved.relative_to(base)
    except ValueError as exc:
        raise ValueError(f"path outside workspace: {resolved}") from exc
    return str(resolved)


def _unsafe_glob_pattern(pattern: str) -> bool:
    if pattern.startswith(("/", "~", "\\")):
        return True
    return any(part == ".." for part in pattern.replace("\\", "/").split("/"))


def _glob_capped(root, pattern: str, cap: int, cwd: str) -> tuple[List[str], bool]:
    matches: List[str] = []
    truncated = False
    for p in root.glob(pattern):
        try:
            s = confine_to_workspace(str(p), cwd)
        except ValueError:
            continue
        if len(matches) >= cap:
            truncated = True
            break
        matches.append(s)
    return matches, truncated


def run_local_tool(name: str, args: dict, cwd: str) -> str:
    """在 adapter 进程内执行 Glob/Grep（只读，限制在 workspace），结果直接回给 Cursor agent。"""
    import subprocess
    from pathlib import Path

    inp = dict(args or {})
    if name == "Glob":
        pattern = str(inp.get("pattern") or inp.get("glob") or "").strip()
        if not pattern:
            return "error: pattern required"
        if _unsafe_glob_pattern(pattern):
            return "error: glob pattern must be relative (no .. or absolute path)"
        try:
            root_s = confine_to_workspace(str(inp.get("path") or cwd), cwd)
        except ValueError as exc:
            return f"error: {exc}"
        root = Path(root_s)
        if not root.exists():
            return f"error: path not found: {root}"
        if not root.is_dir():
            return f"error: path is not a directory: {root}"
        try:
            matches, truncated = _glob_capped(root, pattern, GLOB_MAX, cwd)
        except ValueError as exc:
            return f"error: invalid glob: {exc}"
        if not matches and "**" not in pattern:
            try:
                matches, truncated = _glob_capped(root, f"**/{pattern}", GLOB_MAX, cwd)
            except ValueError:
                pass
        if truncated:
            matches = matches + [f"…[truncated at {GLOB_MAX}]"]
        return "\n".join(matches) if matches else "(no matches)"

    if name == "Grep":
        pattern = str(inp.get("pattern") or inp.get("regex") or "").strip()
        if not pattern:
            return "error: pattern required"
        try:
            path = confine_to_workspace(str(inp.get("path") or cwd), cwd)
        except ValueError as exc:
            return f"error: {exc}"
        if not Path(path).exists():
            return f"error: path not found: {path}"
        mode = str(inp.get("output_mode") or "files_with_matches")
        cmd = ["rg", "--color", "never"]
        if inp.get("case_insensitive"):
            cmd.append("-i")
        if mode == "files_with_matches":
            cmd.append("-l")
        elif mode == "count":
            cmd.append("-c")
        else:
            cmd.extend(["-n", "--heading"])
        g = inp.get("glob")
        if g:
            g = str(g)
            if _unsafe_glob_pattern(g):
                return "error: grep glob must be relative (no .. or absolute path)"
            cmd.extend(["--glob", g])
        cmd.extend(["--", pattern, path])
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, cwd=cwd)
        except FileNotFoundError:
            return "error: ripgrep (rg) not installed"
        except subprocess.TimeoutExpired:
            return "error: rg timed out"
        out = (proc.stdout or "").strip()
        err = (proc.stderr or "").strip()
        if proc.returncode not in (0, 1):
            return f"error: rg exit {proc.returncode}: {err or out}"[:TOOL_RESULT_MAX]
        if not out:
            return "(no matches)"
        try:
            limit_n = int(inp["head_limit"]) if inp.get("head_limit") is not None else 0
        except (TypeError, ValueError):
            limit_n = 0
        if limit_n > 0:
            lines = out.splitlines()
            if len(lines) > limit_n:
                extra = len(lines) - limit_n
                out = "\n".join(lines[:limit_n]) + f"\n…[{extra} more truncated]"
        return abridge_text(out, TOOL_RESULT_MAX, "grep")

    return f"error: unsupported local tool {name}"


def sse_line(event: str, data: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode("utf-8")


class Pending:
    """一个待会合的工具调用：execute 阻塞在此，等 CC 的 tool_result。"""

    def __init__(self, our_id: str, name: str, args: dict) -> None:
        self.our_id = our_id
        self.name = name
        self.args = args
        self.event = threading.Event()
        self.result: Any = ""  # str 或 {"content": [...]} 富内容（图片 tool_result）


class Session:
    def __init__(self, key: str) -> None:
        self.key = key
        self.lock = threading.Lock()
        # ensure_agent 可能做 Create/Resume RPC；用独立锁，避免和消息状态锁纠缠。
        self.agent_lock = threading.RLock()
        self.agent: Optional[Agent] = None
        self.model: Optional[str] = None
        self.workspace: Optional[str] = None
        self.tool_names: List[str] = []
        self.cc_tool_names: List[str] = []
        self.local_tools: set[str] = set()
        self.events: "queue.Queue[dict]" = queue.Queue()
        self.pending: Dict[str, Pending] = {}
        self.pending_lock = threading.Lock()
        self.current_run: Any = None  # 进行中的上游 run；客户端断开时 cancel 防白烧额度
        self.turn_id = 0
        self.turns = 0
        self.last_used = time.time()

    def _flush_events(self) -> None:
        while True:
            try:
                self.events.get_nowait()
            except queue.Empty:
                break

    def _put_event(self, ev: dict, turn: int) -> None:
        if turn != self.turn_id:
            return
        ev["turn"] = turn
        self.events.put(ev)

    def pending_count(self) -> int:
        with self.pending_lock:
            return len(self.pending)

    def _drop_agent(self, reason: str) -> None:
        old = self.agent
        with self.pending_lock:
            had_pending = bool(self.pending)
            pending_copy = list(self.pending.values())
            self.pending.clear()
        if old is None and not had_pending:
            return
        log(f"drop agent key={self.key[:20]} reason={reason} pending={len(pending_copy)}")
        self.turn_id += 1
        for p in pending_copy:
            if not p.event.is_set():
                p.result = f"error: session reset ({reason})"
                p.event.set()
        self.agent = None
        self.model = None
        self.workspace = None
        self.tool_names = []
        self.cc_tool_names = []
        self.local_tools = set()
        self.turns = 0
        self._flush_events()
        if old is not None:
            try:
                old.close()
            except Exception:  # noqa: BLE001
                pass

    def _build_agent_options(
        self,
        model: str,
        expanded: List[dict],
        local_set: set[str],
        ws: str,
    ) -> tuple[AgentOptions, Dict[str, CustomTool]]:
        custom: Dict[str, CustomTool] = {}
        for t in expanded:
            name = t.get("name")
            if not name:
                continue
            n = str(name)
            custom[n] = CustomTool(
                description=str(t.get("description") or "")[:TOOL_DESC_MAX],
                input_schema=t.get("input_schema") or {"type": "object", "properties": {}},
                execute=self._make_execute(n, local=n in local_set),
            )
        opts = AgentOptions(
            model=ModelSelection(id=model),
            disallowed_tools=list(BUILTIN_TOOLS),
            local=LocalAgentOptions(cwd=ws, custom_tools=custom),
        )
        return opts, custom

    def _write_last_tools(self, names: List[str], local_set: set[str]) -> None:
        if not names:
            return
        log(f"custom tool names: {', '.join(names)}")
        try:
            with open(os.path.join(runtime_dir(), "last-tools.txt"), "w", encoding="utf-8") as f:
                f.write("\n".join(names) + "\n")
                if local_set:
                    f.write(f"# local: {', '.join(sorted(local_set))}\n")
        except OSError:
            pass

    def ensure_agent(self, model: str, tools: List[dict]) -> None:
        ws = current_workspace()
        expanded = expand_tools(tools)
        cc_names = sorted(
            str(t.get("name")) for t in expanded if isinstance(t, dict) and t.get("name")
        )
        expanded, local_names = inject_missing_local_tools(expanded)
        names = sorted(
            str(t.get("name")) for t in expanded if isinstance(t, dict) and t.get("name")
        )
        local_set = set(local_names)

        with self.agent_lock:
            if self.agent is not None and self.workspace == ws:
                if names == self.tool_names and local_set == self.local_tools:
                    return
                # 工具集/执行路由变化：优先 resume 同一个 Cursor agent。
                # 好处：保住 SDK 侧会话记忆，避免 drop→create 后重新灌历史。
                try:
                    opts, custom = self._build_agent_options(model, expanded, local_set, ws)
                    t_resume = time.perf_counter()
                    self.agent = Agent.resume(self.agent.agent_id, opts)
                    self.model = model
                    self.workspace = ws
                    self.tool_names = names
                    self.cc_tool_names = cc_names
                    self.local_tools = local_set
                    log(
                        f"agent resumed key={self.key[:20]} model={model} cwd={ws} "
                        f"custom_tools={len(custom)} local={sorted(local_set) or '-'} "
                        f"resume_ms={_ms(t_resume)}"
                    )
                    self._write_last_tools(names, local_set)
                    return
                except Exception as exc:  # noqa: BLE001
                    log(f"agent resume failed key={self.key[:20]}: {exc}; recreate")
                    self._drop_agent(f"resume failed: {exc}")
            elif self.agent is not None:
                self._drop_agent(f"workspace {self.workspace} → {ws}")

            opts, custom = self._build_agent_options(model, expanded, local_set, ws)
            t_create = time.perf_counter()
            self.agent = Agent.create(opts)
            self.model = model
            self.workspace = ws
            self.tool_names = names
            self.cc_tool_names = cc_names
            self.local_tools = local_set
            self.turns = 0
            log(
                f"agent created key={self.key[:20]} model={model} cwd={ws} "
                f"custom_tools={len(custom)} local={sorted(local_set) or '-'} "
                f"create_ms={_ms(t_create)}"
            )
            self._write_last_tools(names, local_set)

    def _make_execute(self, name: str, local: bool = False):
        def execute(args: dict, ctx: Any) -> str:
            inp = dict(args or {})
            if name in ("Read", "Edit") and "file_path" not in inp and "path" in inp:
                inp["file_path"] = inp.pop("path")
            if name == "Write" and "content" not in inp and "contents" in inp:
                inp["content"] = inp.pop("contents")
            if name == "Glob" and "pattern" not in inp and "glob" in inp:
                inp["pattern"] = inp.pop("glob")
            if name == "Grep" and "pattern" not in inp and "regex" in inp:
                inp["pattern"] = inp.pop("regex")

            if local or name in self.local_tools:
                t0 = time.perf_counter()
                out = run_local_tool(name, inp, self.workspace or current_workspace())
                log(f"local_tool {name} ms={_ms(t0)}")
                return out

            gen = self.turn_id
            our_id = f"toolu_{uuid.uuid4().hex[:20]}"
            p = Pending(our_id, name, inp)
            with self.pending_lock:
                if gen != self.turn_id:
                    return "error: session reset (stale turn)"
                self.pending[our_id] = p
            self._put_event({"type": "tool_call", "pending": p}, gen)
            log(f"tool_call {name} id={our_id[:12]}")
            t_wait = time.perf_counter()
            if not p.event.wait(timeout=EXEC_TIMEOUT):
                with self.pending_lock:
                    self.pending.pop(our_id, None)
                log(f"tool_wait {name} id={our_id[:12]} ms={_ms(t_wait)} timeout=1")
                return "error: client did not return a tool result in time"
            with self.pending_lock:
                self.pending.pop(our_id, None)
            log(f"tool_wait {name} id={our_id[:12]} ms={_ms(t_wait)}")
            return p.result

        return execute

    @staticmethod
    def _real_messages(body: dict) -> List[dict]:
        # CC 会在 messages 尾部塞 role=system 的提醒/token 计数，真正的对话要过滤出来。
        return [m for m in (body.get("messages") or [])
                if isinstance(m, dict) and m.get("role") in ("user", "assistant")]

    def feed_tool_results(self, body: dict) -> int:
        fed = 0
        for msg in self._real_messages(body):
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                tid = str(block.get("tool_use_id") or "")
                with self.pending_lock:
                    p = self.pending.get(tid)
                if p is None:
                    continue
                tr_content = block.get("content")
                # tool_result 含图片时走富内容通道：MCP content 数组原样透传
                # （SDK _normalize_custom_tool_result 对带 content list 的 Mapping 不包装）
                tr_images = extract_images(tr_content)
                if tr_images and isinstance(tr_content, list):
                    text_part = abridge_text(
                        flatten_content([b for b in tr_content
                                         if isinstance(b, dict) and b.get("type") != "image"]),
                        TOOL_RESULT_MAX, "tool_result",
                    )
                    blocks: List[dict] = [{"type": "text", "text": text_part or "(image attached)"}]
                    blocks.extend(b for b in tr_content
                                  if isinstance(b, dict) and b.get("type") == "image")
                    p.result = {"content": blocks}  # type: ignore[assignment]
                    log(f"tool_result image passthrough: {len(tr_images)} image(s) id={tid[:12]}")
                else:
                    p.result = abridge_text(
                        flatten_content(tr_content) or "(empty result)",
                        TOOL_RESULT_MAX,
                        "tool_result",
                    )
                if block.get("is_error"):
                    p.result = ("error: " + p.result) if isinstance(p.result, str) else p.result
                p.event.set()
                fed += 1
        return fed

    def body_has_tool_results(self, body: dict) -> bool:
        """任意 user 消息里出现 tool_result（CC 常在末尾再塞 system，不能只看最后一条）。"""
        for msg in self._real_messages(body):
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content
            ):
                return True
        return False

    def has_tool_result_turn(self, body: dict) -> bool:
        """当前轮（最后一条 user 消息）是否含 tool_result。

        不能扫全历史：--continue/--resume 恢复的会话历史里含旧 tool_result，
        扫描历史会把新的纯文本提问误判为结果轮 → fed=0 → 误回 "Acknowledged."。
        _real_messages 已过滤 CC 尾部塞的 system 提醒，末条即当前轮。
        """
        for msg in reversed(self._real_messages(body)):
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            return isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content
            )
        return False

    def pending_as_message(self, model: str) -> dict:
        with self.pending_lock:
            items = list(self.pending.values())
        content = [
            {"type": "tool_use", "id": p.our_id, "name": p.name, "input": p.args}
            for p in items
        ]
        return {
            "id": f"msg_{uuid.uuid4().hex[:24]}",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content or [{"type": "text", "text": "OK."}],
            "stop_reason": "tool_use" if content else "end_turn",
            "stop_sequence": None,
            "usage": {"input_tokens": 0, "output_tokens": 1},
        }

    def start_turn(self, body: dict, model: str, force: bool = False) -> None:
        self.turn_id += 1
        my_id = self.turn_id
        self._flush_events()
        hint = (CONTEXT_HINT or "").strip()
        real = self._real_messages(body)

        # 分叉检测：CC 历史被 compact/clear/rewind 后，与 Cursor Agent 的 checkpoint 分叉。
        # 信号：CC 发来的 messages 数量比上次少（rewind/clear），或首条 user 含 <summary>（compact 后续聊）。
        # 注意：tool_result 轮不算分叉（CC 会在末尾追加 tool_result，数量可能波动）。
        if self.turns > 0 and real:
            prev_count = getattr(self, "_last_msg_count", 0)
            curr_count = len(real)
            first_user = ""
            for m in real:
                if m.get("role") == "user":
                    first_user = flatten_content(m.get("content")).lower()
                    break
            # 数量减少超过 2 才认为 rewind（避免 tool_result 轮误伤）
            if curr_count < prev_count - 2:
                log(f"history divergence: msg count {prev_count}→{curr_count}, drop agent")
                self._drop_agent("history rewound")
                # 重建 agent 后再继续（turns 重置为 0，走首轮全量）
                self.ensure_agent(model, [])
            elif "<summary>" in first_user and "continued from" in first_user:
                log("history divergence: compact summary detected, drop agent")
                self._drop_agent("compact summary restart")
                self.ensure_agent(model, [])
        self._last_msg_count = len(real)

        if self.turns == 0:
            system = abridge_system(flatten_content(body.get("system")), SYSTEM_MAX)
            lines: List[str] = []
            if hint:
                lines.extend([hint, ""])
            if system:
                lines.extend(["SYSTEM:", system, ""])
            # 首轮 / Agent 重建：只带必要轮次。Agent 复用后不再重复灌历史。
            blob = "\n".join(flatten_content(m.get("content")) for m in real[:3]).lower()
            keep_n = HISTORY_TURNS_COMPACT if "<summary>" in blob else HISTORY_TURNS
            keep = real[-keep_n:] if len(real) > keep_n else real
            lines.append("CONVERSATION:")
            for msg in keep:
                chunk = abridge_text(
                    flatten_content(msg.get("content")),
                    PROMPT_MSG_MAX // max(1, len(keep)),
                    msg.get("role") or "msg",
                )
                lines.append(f"{msg.get('role') or 'user'}: {chunk}")
            prompt = "\n".join(lines).strip()
        else:
            # 增量发送：Cursor Agent 持 checkpoint，只发当前轮内容
            last = real[-1] if real else {}
            prompt = abridge_text(
                flatten_content(last.get("content")),
                TOOL_RESULT_MAX + 4000,
                "latest",
            )
            if not prompt.strip():
                prompt = "Continue."
            # CONTEXT_HINT 只在首轮注入；Agent 复用后每轮重复只会增加上游读 prompt 时间。

        # 图片桥：当前轮（末条 user）的 image block 提取为 SDK images，随 prompt 一起 send。
        # 有图时去掉文本里的 [image omitted] 占位，避免「既收到图又说没图」的矛盾。
        turn_images: List[dict] = []
        if real:
            last_user = next((m for m in reversed(real) if m.get("role") == "user"), None)
            if last_user is not None:
                turn_images = extract_images(last_user.get("content"))
                if turn_images:
                    prompt = re.sub(
                        r"\[image [^\]]* omitted: upstream text-only bridge[^\]]*\]\n?",
                        "",
                        prompt,
                    ).strip() or "请看图。"
                if turn_images:
                    log(f"image bridge: {len(turn_images)} image(s) attached model={model}")

        saw_text = {"v": False}
        t_send = time.perf_counter()
        first_out = {"ms": None}

        def on_delta(u: Any) -> None:
            if getattr(u, "type", None) == "text-delta":
                text = getattr(u, "text", "")
                if text:
                    if first_out["ms"] is None:
                        first_out["ms"] = _ms(t_send)
                        log(f"upstream first_text_ms={first_out['ms']} model={model}")
                    saw_text["v"] = True
                    self._put_event({"type": "text", "text": str(text)}, my_id)

        def worker() -> None:
            try:
                from cursor_sdk import LocalSendOptions

                send_model = ModelSelection(id=model) if model != self.model else None
                if send_model is not None:
                    self.model = model
                opts = SendOptions(
                    model=send_model,
                    on_delta=on_delta,
                    local=LocalSendOptions(force=True) if force else None,
                )
                # 有图片时升级为 UserMessage（SDK 原生多模态通道）
                outbound: Any = (
                    UserMessage(text=prompt, images=turn_images) if turn_images else prompt
                )
                try:
                    run = self.agent.send(outbound, opts)  # type: ignore[union-attr]
                except Exception as exc:  # noqa: BLE001
                    if "active run" not in str(exc):
                        raise
                    log("send hit active run, force retry")
                    opts = SendOptions(model=send_model, on_delta=on_delta,
                                       local=LocalSendOptions(force=True))
                    run = self.agent.send(outbound, opts)  # type: ignore[union-attr]
                self.current_run = run
                err_msg = ""
                for m in run.messages():
                    if getattr(m, "type", None) == "status":
                        st = str(getattr(m, "status", "") or "")
                        if st.upper() == "ERROR":
                            err_msg = str(getattr(m, "message", "") or "") or err_msg
                result = run.wait()
                log(
                    f"upstream done_ms={_ms(t_send)} first_text_ms={first_out['ms']} "
                    f"status={getattr(result, 'status', '')} model={model}"
                )
                if str(getattr(result, "status", "")).lower() == "error":
                    # 瞬时错误（限流/超时/5xx）自动重试一次；已产出过文本则不再重试（防重复输出）
                    transient = any(k in err_msg.lower() for k in (
                        "rate limit", "429", "timeout", "timed out", "503", "502", "overloaded"))
                    if transient and not saw_text["v"] and not getattr(self, "_retried", False):
                        self._retried = True
                        log(f"transient upstream error, retry once: {err_msg[:120]}")
                        time.sleep(2)
                        run2 = self.agent.send(outbound, opts)  # type: ignore[union-attr]
                        self.current_run = run2
                        for m in run2.messages():
                            if getattr(m, "type", None) == "status":
                                st2 = str(getattr(m, "status", "") or "")
                                if st2.upper() == "ERROR":
                                    err_msg = str(getattr(m, "message", "") or "") or err_msg
                        result = run2.wait()
                        log(f"retry done_ms={_ms(t_send)} status={getattr(result, 'status', '')}")
                    self._retried = False
                    if str(getattr(result, "status", "")).lower() == "error":
                        self._put_event({"type": "error", "message": err_msg or "upstream run error"}, my_id)
                        return
                final = (getattr(result, "result", None) or "").strip()
                if final and not saw_text["v"]:
                    self._put_event({"type": "text", "text": final}, my_id)
                usage = getattr(result, "usage", None)
                self._put_event({"type": "turn_end", "usage": usage}, my_id)
            except Exception as exc:  # noqa: BLE001
                log(traceback.format_exc())
                self._put_event({"type": "error", "message": str(exc)[:1500]}, my_id)
            finally:
                self.current_run = None

        threading.Thread(target=worker, daemon=True).start()

    def cancel_current(self, reason: str) -> None:
        """客户端断开（ESC/超时）时取消上游 run，避免白烧额度。"""
        run = self.current_run
        if run is None:
            return
        try:
            run.cancel()
            log(f"cancel upstream run reason={reason}")
        except Exception:  # noqa: BLE001
            pass

    def close(self) -> None:
        self._drop_agent("close")


SESSIONS: Dict[str, Session] = {}
SESSIONS_LOCK = threading.Lock()
SESSION_TTL = int(os.environ.get("CCA_SESSION_TTL", "1800"))


def get_session(key: str) -> Session:
    now = time.time()
    with SESSIONS_LOCK:
        stale = [k for k, s in SESSIONS.items() if now - s.last_used > SESSION_TTL]
        for k in stale:
            SESSIONS.pop(k).close()
        if key not in SESSIONS:
            SESSIONS[key] = Session(key)
        s = SESSIONS[key]
        s.last_used = now
        return s


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        log(f"{self.client_address[0]} {fmt % args}")

    def _json(self, code: int, obj: dict) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _begin_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

    def _sse(self, event: str, data: dict) -> None:
        self.wfile.write(sse_line(event, data))
        self.wfile.flush()

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            with SESSIONS_LOCK:
                n_sess = len(SESSIONS)
            prewarm = ""
            try:
                with open(os.path.join(runtime_dir(), "prewarm.status"), encoding="utf-8") as f:
                    prewarm = f.read().strip()
            except OSError:
                pass
            self._json(200, {
                "ok": True,
                "upstream": "cursor-sdk",
                "default_model": SONNET_MODEL,
                "workspace": current_workspace(),
                "sessions": n_sess,
                "uptime_s": int(time.time() - _BOOT_TS),
                "prewarm": prewarm,
            })
            return
        if path in ("/v1/models", "/models"):
            data = [{"id": m, "object": "model", "created": 0, "owned_by": "cursor"}
                    for m in (SONNET_MODEL, OPUS_MODEL, HAIKU_MODEL)]
            self._json(200, {"object": "list", "data": data})
            return
        self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": path}})

    def do_HEAD(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
            if not isinstance(body, dict):
                raise ValueError("body must be object")
        except (json.JSONDecodeError, ValueError) as exc:
            self._json(400, {"type": "error", "error": {"type": "invalid_request_error", "message": str(exc)}})
            return
        if path in ("/v1/messages/count_tokens", "/messages/count_tokens"):
            # 按 system + messages 估算（含工具名），略保守，促发 CC 更早 compact
            blob_parts = [flatten_content(body.get("system"))]
            for m in body.get("messages") or []:
                if isinstance(m, dict):
                    blob_parts.append(flatten_content(m.get("content")))
            tools = body.get("tools") or []
            if isinstance(tools, list):
                blob_parts.append(json.dumps(
                    [{"name": t.get("name"), "description": str(t.get("description") or "")[:120]}
                     for t in tools if isinstance(t, dict)],
                    ensure_ascii=False,
                ))
            self._json(200, {"input_tokens": estimate_tokens("\n".join(blob_parts))})
            return
        if path not in ("/v1/messages", "/messages"):
            self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": path}})
            return
        if os.environ.get("CCA_DUMP_REQUESTS"):
            try:
                msgs = body.get("messages") or []
                last = msgs[-1] if msgs else {}
                content = last.get("content")
                summary = {
                    "ts": time.time(),
                    "n_msgs": len(msgs),
                    "last_role": last.get("role"),
                    "last_content": content if not isinstance(content, list) else [
                        {k: ("<image omitted>" if k in ("source", "data") else str(v)[:300])
                         for k, v in b.items()}
                        for b in content if isinstance(b, dict)
                    ],
                }
                with open(os.path.join(runtime_dir(), "adapter-requests.jsonl"), "a", encoding="utf-8") as f:
                    f.write(json.dumps(summary, ensure_ascii=False) + "\n")
            except (OSError, TypeError):
                pass
        self._handle_messages(body)

    def _session_key(self) -> str:
        sid = self.headers.get("X-Claude-Code-Session-Id") or self.headers.get("x-claude-code-session-id") or ""
        aid = self.headers.get("X-Claude-Code-Agent-Id") or self.headers.get("x-claude-code-agent-id") or "main"
        sid = sid.strip() or "anon"
        return f"{sid}:{aid}"

    def _handle_messages(self, body: dict) -> None:
        # 任务类型推断：有 tools 或长 prompt → smart；短问答 → fast
        tools = [t for t in (body.get("tools") or []) if isinstance(t, dict)]
        messages = body.get("messages") or []
        last_content = ""
        for m in reversed(messages):
            if isinstance(m, dict) and m.get("role") == "user":
                last_content = flatten_content(m.get("content"))
                break
        task_hint = "smart" if tools or len(last_content) > 500 else "fast"
        model = resolve_model(str(body.get("model") or "") or None, task_hint)
        stream = bool(body.get("stream"))
        sess = get_session(self._session_key())

        # 短临界区：只做状态机决策；compact / drain 出锁，避免阻塞 tool_result 会合。
        action = "error"
        reemit_msg: Optional[dict] = None
        err_msg = ""
        with sess.lock:
            if should_run_compaction(sess.pending_count(), body):
                action = "compact"
            else:
                try:
                    sess.ensure_agent(model, tools)
                except Exception as exc:  # noqa: BLE001
                    log(traceback.format_exc())
                    action = "error"
                    err_msg = str(exc)[:1500]
                else:
                    is_result = sess.has_tool_result_turn(body)
                    log(
                        f"req key={sess.key[:20]} kind={'tool_result' if is_result else 'user'} "
                        f"turns={sess.turns} pending={sess.pending_count()} ws={sess.workspace}"
                    )
                    if is_result:
                        fed = sess.feed_tool_results(body)
                        log(f"tool_result turn fed={fed} key={sess.key[:20]}")
                        if fed == 0:
                            action = "stale"
                        else:
                            sess.turns += 1
                            action = "drain"
                    elif sess.pending_count():
                        log(f"re-emit {sess.pending_count()} pending tool_use (no abandon)")
                        reemit_msg = sess.pending_as_message(model)
                        action = "reemit"
                    else:
                        sess.start_turn(body, model)
                        sess.turns += 1
                        # 15M 假窗口下 auto-compact 永不触发：轮数超阈值日志提醒手动 /compact
                        warn_n = int(os.environ.get("CCA_COMPACT_WARN_TURNS", "40"))
                        if sess.turns == warn_n:
                            log(f"session {sess.key[:20]} reached {warn_n} turns — 建议手动 /compact（auto-compact 不触发）")
                        action = "drain"

        if action == "error":
            self._json(502, {"type": "error", "error": {"type": "api_error", "message": err_msg or "error"}})
            return

        if action == "compact":
            log(f"req key={sess.key[:20]} kind=compaction")
            try:
                summary = run_compaction_summary(body, model)
            except Exception as exc:  # noqa: BLE001
                log(traceback.format_exc())
                summary = ensure_compact_blocks(
                    f"Conversation summary unavailable ({exc}). Continue from the latest user request."
                )
            msg = text_only_message(model, summary)
            if stream:
                self._emit_text_sse(msg)
            else:
                self._json(200, msg)
            return

        if action == "stale":
            log("stale tool_result ignored (no matching pending)")
            msg = text_only_message(model, "Acknowledged.")
            if stream:
                self._emit_text_sse(msg)
            else:
                self._json(200, msg)
            return

        if action == "reemit":
            msg = reemit_msg or text_only_message(model, "OK.")
            if stream:
                self._begin_sse()
                self._sse("message_start", {"type": "message_start", "message": {**msg, "content": []}})
                from_index = 0
                for i, block in enumerate(msg["content"]):
                    if block.get("type") != "tool_use":
                        continue
                    self._sse("content_block_start", {
                        "type": "content_block_start", "index": from_index + i,
                        "content_block": {"type": "tool_use", "id": block["id"],
                                         "name": block["name"], "input": {}},
                    })
                    self._sse("content_block_delta", {
                        "type": "content_block_delta", "index": from_index + i,
                        "delta": {"type": "input_json_delta",
                                  "partial_json": json.dumps(block.get("input") or {}, ensure_ascii=False)},
                    })
                    self._sse("content_block_stop", {"type": "content_block_stop", "index": from_index + i})
                self._sse("message_delta", {"type": "message_delta",
                                           "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                                           "usage": msg["usage"]})
                self._sse("message_stop", {"type": "message_stop"})
                self.close_connection = True
            else:
                self._json(200, msg)
            return

        # action == drain
        try:
            if stream:
                self._drain_sse(sess, model)
            else:
                self._drain_json(sess, model)
        except Exception as exc:  # noqa: BLE001
            log(traceback.format_exc())
            # 客户端断开（ESC/超时）：取消上游 run，不再白烧额度
            if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
                sess.cancel_current("client disconnect")
            with sess.lock:
                if not sess.pending_count():
                    sess.turn_id += 1
                    sess._flush_events()
            try:
                self._json(502, {"type": "error", "error": {"type": "api_error", "message": str(exc)[:1500]}})
            except Exception:  # noqa: BLE001
                pass

    def _emit_text_sse(self, msg: dict) -> None:
        text = ""
        for b in msg.get("content") or []:
            if isinstance(b, dict) and b.get("type") == "text":
                text += b.get("text") or ""
        if not text.strip():
            text = "OK."
            msg = {**msg, "content": [{"type": "text", "text": text}]}
        self._begin_sse()
        stub = {**msg, "content": []}
        self._sse("message_start", {"type": "message_start", "message": stub})
        self._sse("content_block_start", {
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""},
        })
        self._sse("content_block_delta", {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": text},
        })
        self._sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        self._sse("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": msg.get("usage") or {"input_tokens": 0, "output_tokens": estimate_tokens(text)},
        })
        self._sse("message_stop", {"type": "message_stop"})
        self.close_connection = True
        log(f"ok stream model={msg.get('model')} stop=end_turn compaction_or_text chars={len(text)}")

    # ---- 把 worker 的事件流收敛成一条 Anthropic 消息 ----

    def _collect(self, sess: Session, on_text, on_call, on_idle=None) -> dict:
        """返回最终 message dict；on_text/on_call 流式转发，on_idle 用于保活 ping。"""
        text_parts: List[str] = []
        calls: List[Pending] = []
        usage: Any = None
        t0 = time.perf_counter()
        first_ms: Optional[int] = None
        first_kind = ""
        deadline = time.time() + TURN_TIMEOUT
        while True:
            idle = 1.5 if calls else 5.0
            try:
                ev = sess.events.get(timeout=idle)
            except queue.Empty:
                if calls:
                    # 并行工具再等一小会，避免只吐出首个 tool_use
                    try:
                        ev = sess.events.get(timeout=0.8)
                    except queue.Empty:
                        break
                elif time.time() > deadline:
                    raise TimeoutError(f"turn timeout {TURN_TIMEOUT}s")
                else:
                    if on_idle:
                        on_idle()
                    continue
            etype = ev.get("type")
            if ev.get("turn") not in (None, sess.turn_id):
                continue
            if etype == "text":
                if first_ms is None:
                    first_ms = _ms(t0)
                    first_kind = "text"
                text_parts.append(ev["text"])
                on_text(ev["text"])
            elif etype == "tool_call":
                if first_ms is None:
                    first_ms = _ms(t0)
                    first_kind = "tool"
                p: Pending = ev["pending"]
                calls.append(p)
                on_call(p)
            elif etype == "turn_end":
                usage = ev.get("usage")
                break
            elif etype == "error":
                raise RuntimeError(ev.get("message") or "agent error")
        text = "".join(text_parts).strip()
        # 纯文本轮绝不能空 content，否则 /compact 报 no assistant message
        if not text and not calls:
            text = "OK."
        content: List[dict] = []
        if text:
            content.append({"type": "text", "text": text})
        for p in calls:
            content.append({"type": "tool_use", "id": p.our_id, "name": p.name, "input": p.args})
        log(
            f"timing drain total_ms={_ms(t0)} first_ms={first_ms} first={first_kind or '-'} "
            f"tools={len(calls)} stop={'tool_use' if calls else 'end_turn'}"
        )
        return {
            "id": f"msg_{uuid.uuid4().hex[:24]}",
            "type": "message",
            "role": "assistant",
            "model": "cursor-sdk",
            "content": content or [{"type": "text", "text": "OK."}],
            "stop_reason": "tool_use" if calls else "end_turn",
            "stop_sequence": None,
            "usage": {
                "input_tokens": getattr(usage, "input_tokens", None) or 0,
                "output_tokens": getattr(usage, "output_tokens", None) or estimate_tokens(text),
            },
        }

    def _drain_json(self, sess: Session, model: str) -> None:
        msg = self._collect(sess, lambda t: None, lambda p: None)
        msg["model"] = model
        log(f"ok model={model} tools={sum(1 for b in msg['content'] if b['type'] == 'tool_use')} turns={sess.turns}")
        self._json(200, msg)

    def _drain_sse(self, sess: Session, model: str) -> None:
        msg_id = f"msg_{uuid.uuid4().hex[:24]}"
        state = {"started": False, "text_open": False, "index": 0}

        def ensure_start() -> None:
            if not state["started"]:
                self._begin_sse()
                stub = {"id": msg_id, "type": "message", "role": "assistant", "model": model,
                        "content": [], "stop_reason": None, "stop_sequence": None,
                        "usage": {"input_tokens": 0, "output_tokens": 0}}
                self._sse("message_start", {"type": "message_start", "message": stub})
                state["started"] = True

        def open_text() -> None:
            if not state["text_open"]:
                self._sse("content_block_start", {"type": "content_block_start", "index": state["index"],
                                                  "content_block": {"type": "text", "text": ""}})
                state["text_open"] = True

        def close_text() -> None:
            if state["text_open"]:
                self._sse("content_block_stop", {"type": "content_block_stop", "index": state["index"]})
                state["index"] += 1
                state["text_open"] = False

        def on_text(t: str) -> None:
            ensure_start()
            open_text()
            self._sse("content_block_delta", {"type": "content_block_delta", "index": state["index"],
                                              "delta": {"type": "text_delta", "text": t}})

        def on_call(p: Pending) -> None:
            ensure_start()
            close_text()
            i = state["index"]
            self._sse("content_block_start", {"type": "content_block_start", "index": i,
                                              "content_block": {"type": "tool_use", "id": p.our_id,
                                                                "name": p.name, "input": {}}})
            self._sse("content_block_delta", {"type": "content_block_delta", "index": i,
                                              "delta": {"type": "input_json_delta",
                                                        "partial_json": json.dumps(p.args, ensure_ascii=False)}})
            self._sse("content_block_stop", {"type": "content_block_stop", "index": i})
            state["index"] += 1

        # 立刻发响应头 + message_start，之后每 5s 一个 ping——
        # 否则模型思考期零字节，CC 会判定超时并换会话重试。
        ensure_start()

        def on_idle() -> None:
            try:
                self._sse("ping", {"type": "ping"})
            except (BrokenPipeError, ConnectionResetError):
                raise  # 客户端断开要传播出去触发 cancel_current，不能吞
            except Exception:  # noqa: BLE001
                pass

        msg = self._collect(sess, on_text, on_call, on_idle)
        msg["id"] = msg_id
        msg["model"] = model
        ensure_start()
        close_text()
        self._sse("message_delta", {"type": "message_delta",
                                    "delta": {"stop_reason": msg["stop_reason"], "stop_sequence": None},
                                    "usage": msg["usage"]})
        self._sse("message_stop", {"type": "message_stop"})
        self.close_connection = True
        log(f"ok stream model={model} stop={msg['stop_reason']} turns={sess.turns}")


def _prewarm_mark(status: str) -> None:
    try:
        with open(os.path.join(runtime_dir(), "prewarm.status"), "w", encoding="utf-8") as f:
            f.write(status.strip() + "\n")
    except OSError:
        pass


def prewarm_upstream() -> None:
    """预热 Cursor SDK bridge + custom-tools 回调，把首个 Agent.create 冷启动挪到启动期。"""
    if os.environ.get("CCA_PREWARM", "1").strip().lower() in ("0", "false", "no"):
        _prewarm_mark("disabled")
        return
    t0 = time.perf_counter()
    try:
        Agent.list()
        log(f"prewarm bridge ok ms={_ms(t0)}")
    except Exception as exc:  # noqa: BLE001
        log(f"prewarm bridge failed ms={_ms(t0)}: {exc}")
        _prewarm_mark(f"bridge_failed ms={_ms(t0)} err={exc}")
        return

    if os.environ.get("CCA_PREWARM_AGENT", "1").strip().lower() in ("0", "false", "no"):
        _prewarm_mark(f"bridge_ok ms={_ms(t0)}")
        return

    def _noop_execute(args: dict, ctx: Any) -> str:
        return "ok"

    t1 = time.perf_counter()
    agent: Optional[Agent] = None
    try:
        # 真实走一遍 CreateAgent + custom tool 注册/注销；不 send，不消耗模型。
        warm_tool = CustomTool(
            description="cc-adapter prewarm noop",
            input_schema={"type": "object", "properties": {}},
            execute=_noop_execute,
        )
        agent = Agent.create(
            AgentOptions(
                model=ModelSelection(id=SONNET_MODEL),
                disallowed_tools=list(BUILTIN_TOOLS),
                local=LocalAgentOptions(
                    cwd=current_workspace(),
                    custom_tools={"cca_prewarm": warm_tool},
                ),
            )
        )
        log(f"prewarm agent ok ms={_ms(t1)}")
        # 真实 send 一次极小 prompt：首个 send 有 ~5s 惰性初始化（上游会话建立），
        # 不预热则落在首个真实请求上。max_tokens=1，成本可忽略。
        # CCA_PREWARM_SEND=0 可关（省这一次调用）。
        if os.environ.get("CCA_PREWARM_SEND", "1").strip().lower() not in ("0", "false", "no"):
            t2 = time.perf_counter()
            try:
                run = agent.send("hi", SendOptions(model=ModelSelection(id=HAIKU_MODEL)))
                for _m in run.messages():
                    pass
                log(f"prewarm send ok ms={_ms(t2)}")
                _prewarm_mark(f"ok bridge_ms={_ms(t0)} agent_ms={_ms(t1)} send_ms={_ms(t2)}")
            except Exception as exc:  # noqa: BLE001
                log(f"prewarm send failed ms={_ms(t2)}: {exc}")
                _prewarm_mark(f"send_failed ms={_ms(t2)} err={exc}")
        else:
            _prewarm_mark(f"ok bridge_ms={_ms(t0)} agent_ms={_ms(t1)}")
    except Exception as exc:  # noqa: BLE001
        log(f"prewarm agent failed ms={_ms(t1)}: {exc}")
        _prewarm_mark(f"agent_failed ms={_ms(t1)} err={exc}")
    finally:
        if agent is not None:
            try:
                agent.close()
            except Exception:  # noqa: BLE001
                pass


def main() -> None:
    if not os.environ.get("CURSOR_API_KEY"):
        raise SystemExit("缺少 CURSOR_API_KEY（source .env 或 export）")
    if HOST not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit(f"拒绝绑定 {HOST}：只允许本机回环")
    ws = bind_boot_workspace()
    log(f"listen http://{HOST}:{PORT} workspace={ws} default={SONNET_MODEL}")
    threading.Thread(target=prewarm_upstream, daemon=True).start()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
