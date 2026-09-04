# cc-cursor-kit

Claude Code 当壳 → **`adapter/`（Cursor SDK）** → Cursor 订阅（默认 Grok）。

旧 `proxy/`（fork `agent` + 文本 JSON）已移除。

- 方案：[DESIGN.md](DESIGN.md) · Agent 约定：[CLAUDE.md](CLAUDE.md)  
- 复盘总结：[docs/项目总结.md](docs/项目总结.md) · 对照笔记：[docs/research/对照.md](docs/research/对照.md)

## 安装

需要 [uv](https://docs.astral.sh/uv/) 与 [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)。

1. [Dashboard → API Keys](https://cursor.com/dashboard/api?section=user-keys) 建 User API Key  
2. `./bin/setup`（建 venv、装 `cursor-sdk`；若无 `.env` 则从 `.env.example` 复制）  
3. 编辑 `.env`，填入 `CURSOR_API_KEY`  
4. 在目标项目目录：

```bash
/path/to/cc-cursor-kit/bin/cc
# 默认跳过逐条授权（bypassPermissions）
# 恢复确认：CCA_PERMISSION_MODE=manual /path/to/cc-cursor-kit/bin/cc
```

```bash
./bin/status
./bin/adapter-stop   # 停中转；改 adapter 后需重启
```

第一次跑 `bin/cc` 时若还没 venv，`adapter-start` 会自动调 `bin/setup`。

## 默认模型

`grok-4.6`（haiku → `grok-4.5`）。账单走 Cursor Pro+ Included。  
可选环境变量见 `.env.example`。

## 目录

```
adapter/     # 唯一中转（server.py）
bin/         # setup · cc · adapter-start|stop · status · cca
profiles/    # Claude Code settings 模板
scripts/     # 单测与烟测（默认独立 :4012）
docs/        # 项目总结与研究对照
runtime/     # 运行态（gitignore）
```

## 烟测

```bash
./scripts/test-compact-detect.sh   # 不耗 API
./scripts/smoke-all.sh             # 问答 / 读 / 写改（不杀日常 :4011）
```
