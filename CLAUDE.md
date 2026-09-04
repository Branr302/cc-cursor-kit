# CLAUDE.md — cc-cursor-kit

## 目标

用 **Claude Code 当壳与工具执行器**，账单与模型走 **Cursor 订阅**（默认 `grok-4.6`），不另付 Anthropic。

对用户：**除模型是 Grok 外，功能体验对齐标准 Claude Code**（工具环、会话、`/compact`、工作区、Skills/Agent 目录）。  
架构缺口见文末「已知缺口」。

唯一上游：**`adapter/`**（Cursor SDK 长会话 + customTools 结构化 tool_use）。  
旧 `proxy/`（fork `agent --mode ask` + 文本 JSON）**已移除**，不可行、不再维护。

## 启动

1. [Dashboard → API Keys](https://cursor.com/dashboard/api?section=user-keys) 建 User API Key  
2. `./bin/setup`，再编辑 `.env` 填 `CURSOR_API_KEY`  
3. 在项目目录：

```bash
/path/to/cc-cursor-kit/bin/cc
```

可选：`bin/cca` 直接跑官方 `agent`（不经 Claude Code），与本中转无关。

## 官方红线

- 上游只用官方 Cursor SDK（`CURSOR_API_KEY`）。
- **不做**：读 Keychain、仿客户端、未文档化 Connect / Bidi、`agent` 文本桥回潮。
- 只绑 `127.0.0.1`；`.env` 不进 git。
- 工具由 Claude Code 本地执行；避免 Cursor 与 CC 双边改同一仓库。

## 默认模型

- 主模型 / opus 别名：`grok-4.6`
- haiku 别名：`grok-4.5`
- 本账号 Claude 系常因区域不可用；可用 `--model composer-2.5` 等

账单：User API Key → Cursor **Pro+ Included** 池。

## 上下文用法

- 复盘 / 狂读：`/new`；先 Glob/Grep，再定点 Read  
- 满了：`/compact` 或新开  
- `/compact` 失败（`no assistant message…`）时：当前会话已坏，**`/clear` 或 `/new` 后再用**（adapter 已对摘要轮走无工具纯文本）  
- 摘要检测只看**末条 user 的 compact 指令**，不扫历史（避免压缩后 `<summary>` 误判整段会话）  
- 有 pending 时不跑 compact，先会合 tool_result  
- **Glob/Grep**：CC 已下发 → 经 CC 会合（UI/权限对齐）；未下发 → adapter 本地补缺（有能力、无工具步进）  
- system 瘦身**保留** Skills / Agent 目录；只压长度与丢掉 `<total_tokens>`  
- `CCA_CONTEXT_HINT` 可改/置空；默认不强制中文（语言跟用户自己的 CLAUDE.md）  
- 首轮/重建只带必要历史：默认 `CCA_HISTORY_TURNS=6`，compact 续聊 `CCA_HISTORY_TURNS_COMPACT=10`；后续轮不重复注入 hint  
- 工具集/执行路由变化优先 `Agent.resume` 同一个 Cursor agent 保会话；workspace 变更才 drop/create  
- 启动默认预热 bridge + custom-tools 回调（`CCA_PREWARM=0` 全关；`CCA_PREWARM_AGENT=0` 只热 bridge；`CCA_PREWARM_WAIT=0` 启动不等预热）  
- 工作区：`bin/cc` 把 `runtime/workspace` 写成启动时的 cwd  
- 烟测默认独立 `:4012` + `runtime/smoke`，不改、不杀日常 `:4011`  
- `current_workspace()` 读 **当前 `CCA_RUNTIME`/workspace**（烟测与日常互不串）  
- compact / drain **不占** session 大锁，避免卡住 tool_result 会合  
- **不要**截断 CC 本地对话 transcript  
- adapter 只瘦送给 SDK 的内容（`CCA_SYSTEM_MAX` 等）

## 已知缺口（相对标准 CC）

- 无 Anthropic prompt cache；`unrecognized_model` 提示可能仍在  
- 图片块无法过 Cursor 文本桥（会留 omitted 占位）  
- 默认 `bypassPermissions`（可用 `CCA_PERMISSION_MODE=manual` 恢复确认）  
- 本地补缺的 Glob/Grep 不出现在 CC 工具时间线

## 烟测

```bash
./scripts/test-compact-detect.sh   # 不耗 API
./scripts/smoke-all.sh             # qa / read / write-edit / glob-grep（:4012）
```

## 目录

- `adapter/` — 唯一中转（`server.py` · `requirements.txt`）
- `bin/setup` · `bin/cc` · `bin/adapter-start|stop` · `bin/status` · `bin/cca`
- `profiles/cursor.json` — Claude Code settings 模板（指向 `:4011`）
- `scripts/` — `test-compact-detect.sh` · `smoke-*.sh`（默认 `:4012`）
- `docs/项目总结.md` — 复盘与系统总结 · `docs/research/对照.md`
- `runtime/` — 运行态（不进 git）
