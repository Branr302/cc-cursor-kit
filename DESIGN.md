# Claude Code → Cursor 中转层方案

## 目标

Claude Code 走 Anthropic Messages；推理与账单走 Cursor 订阅（SDK）。  
产品口径：**用户侧功能对齐标准 CC，仅模型换成 Grok**。

**唯一实现：`adapter/`**（Cursor SDK 长会话 + `customTools`）。  
历史路径 `proxy/`（`agent --mode ask` 文本 JSON 桥）因质量与维护成本不可行，**已删除**。

对标：[docs/research/对照.md](docs/research/对照.md) · 总结：[docs/项目总结.md](docs/项目总结.md) · Agent 约定：[CLAUDE.md](CLAUDE.md)

## 官方边界

- Dashboard User API Key → Cursor SDK local agent  
- **不做**：Keychain、仿客户端、`api2.cursor.sh` Connect/Bidi、复活 proxy

## 数据流

```
Claude Code
  POST http://127.0.0.1:4011/v1/messages
adapter
  Agent.create(disallowed_tools=内置, custom_tools=CC 工具)
  run.stream() → Anthropic SSE
  tool_use → execute 阻塞 → CC 本地执行 → tool_result 会合
Cursor Router（默认 grok-4.6）
```

## 模型

- 默认 `grok-4.6` / haiku→`grok-4.5`（`CCA_SONNET_MODEL` 等可覆写）
- 本账号 Claude 系常区域不可用

## 上下文优化

瘦送给 SDK 的 system / tool_result；不截断 CC 本地 transcript。  
**保留** Skills / Agent 能力目录（超限则分预算压缩，禁止整段砍掉）。  
`/compact`：只认末条 user 的 CC compact 指令，独立无工具摘要。  
**有 pending tool_use 时不跑 compact**（含 compact 指令撞上未会合工具）；否则挂起工具或触发 CC「no assistant message」。  
Glob/Grep：CC 已下发走会合；否则本地补缺。详见 CLAUDE.md。环境变量见 `.env.example`。

## 鉴权与安全

- `CURSOR_API_KEY`（`.env`，gitignore）
- Claude Code：dummy `ANTHROPIC_API_KEY=cc-cursor-kit` + `ANTHROPIC_BASE_URL=http://127.0.0.1:4011`
- 只绑 `127.0.0.1`
