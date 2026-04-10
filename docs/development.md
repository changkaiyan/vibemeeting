# Development Guide

这份文档是仓库当前唯一的本地开发主入口，覆盖：

- `uv` 管理的 Python 环境初始化
- Django 主应用本地启动
- 数据库迁移
- Flutter Web 会议页开发与静态产物同步
- STT worker 本地联调
- LiveKit 本地启动

本页只保留“真正会执行的步骤”。更细的专题文档继续保留，但不再重复整套启动流程。

## 1. 先理解当前开发形态

本仓库本地开发有 4 层：

- Django 主应用
  - 用户、会议、页面、API、数据库
- Flutter Web 会议页
  - 当前实际给用户访问的会议室 UI
- STT worker
  - 实时字幕 WebSocket 服务
- LiveKit
  - 实时音视频房间与入会 token

因此本地开发也分成 4 个强度：

- 最小开发
  - 只起 Django，验证页面、接口、模型、后台
- 前端联调
  - Django + Flutter Web build，同步真实会议页 UI
- 字幕联调
  - Django + Flutter Web + STT worker
- 完整会议联调
  - Django + Flutter Web + STT worker + LiveKit

关键事实：

- 当前实际会议页不是 `app/templates/meeting_room.html`
- 当前实际会议页是 Flutter Web 构建产物
- Django 优先读取 `artifacts/flutter_app_web/`
- 只修改 `flutter_app/lib/` 不会直接生效
- 修改 Flutter 源码后，必须重新 build，并把 `build/web` 同步到 `artifacts/flutter_app_web`

## 2. 先决条件

在仓库根目录执行命令。

### 2.1 必备工具

- `uv`
- Python `3.10.x`

检查方式：

```bash
uv --version
uv python list
```

### 2.2 做真实会议页开发时额外需要

- Flutter SDK
- Chrome

检查方式：

```bash
flutter --version
which google-chrome || which "Google Chrome" || true
```

### 2.3 做完整会议联调时额外需要

- `livekit-server`

检查方式：

```bash
livekit-server --version
```

## 3. 初始化 Python 环境

仓库当前没有 `pyproject.toml` 或 `uv.lock`，因此开发环境直接基于 `requirements.txt` 构建。

```bash
uv venv --python 3.10 .venv
uv pip install -r requirements.txt --python .venv
cp .env.example .env
```

说明：

- `.env` 默认使用 SQLite，本地最小启动不依赖额外数据库
- 如果 `.venv` 已存在，`uv venv` 会复用该目录
- 若要彻底重建环境，删掉 `.venv` 后重新执行即可

如果你要联调 STT worker，再额外装一份 worker 依赖：

```bash
uv pip install -r services/stt_worker/requirements.txt --python .venv
```

如果你的网络环境需要代理，请按你自己的环境设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 后再执行安装命令。文档不预设任何机器相关的代理地址或端口。

## 4. 初始化数据库

```bash
uv run --python .venv/bin/python manage.py migrate
uv run --python .venv/bin/python manage.py check
```

如果你需要后台账号：

```bash
uv run --python .venv/bin/python manage.py createsuperuser
```

说明：

- 当前仓库需要 `conference/migrations/0020_merge_20260410_1422.py` 来收敛 `conference` 的并行叶子迁移
- 如果你在旧提交上执行 `migrate`，可能会遇到 `Conflicting migrations detected`

## 5. 关键环境变量

以 `.env.example` 为模板创建 `.env`。

### 5.1 Django 最小开发

这些变量足够支撑最小本地启动：

- `SECRET_KEY`
- `DEBUG`
- `ALLOWED_HOSTS`
- `DATABASE_URL`
- `TIME_ZONE`

### 5.2 LiveKit

这些变量用于真实会议音视频能力：

- `LIVEKIT_URL`
- `LIVEKIT_PUBLIC_URL`
- `LIVEKIT_API_KEY`
- `LIVEKIT_API_SECRET`
- `LIVEKIT_MEET_URL`
- `LIVEKIT_EGRESS_OUTPUT_ROOT`

常见本地开发值：

- `LIVEKIT_URL=ws://localhost:7880`
- `LIVEKIT_API_KEY=devkey`
- `LIVEKIT_API_SECRET=secret`
- `LIVEKIT_PUBLIC_URL=` 留空

说明：

- `LIVEKIT_PUBLIC_URL` 为空时，应用会把 `localhost` 自动改写成当前请求 host
- 如果要让别的机器访问，应该显式设置成可访问的 `ws://` 或 `wss://`

### 5.3 STT / Agent

这些变量用于实时字幕和 agent bridge：

- `MEETING_REALTIME_STT_WORKER_URL`
- `MEETING_STT_PROVIDER`
- `MEETING_AGENT_BRIDGE_MODE`
- `MEETING_AGENT_BRIDGE_URL`
- `MEETING_AGENT_BRIDGE_TIMEOUT_SECONDS`
- `STT_WORKER_HOST`
- `STT_WORKER_PORT`
- `STT_WORKER_PROVIDER`
- `STT_WORKER_MODEL_SIZE`
- `STT_WORKER_COMPUTE_TYPE`
- `STT_WORKER_LANGUAGE`
- `STT_WORKER_LOCAL_FILES_ONLY`
- `MEETING_AGENT_BRIDGE_HOST`
- `MEETING_AGENT_BRIDGE_PORT`
- `MEETING_AGENT_BRIDGE_WORKSPACE_ROOT`
- `MEETING_AGENT_BRIDGE_CODEX_BIN`
- `MEETING_AGENT_BRIDGE_CODEX_MODEL`
- `MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX`

推荐本地联调值：

```dotenv
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe
MEETING_AGENT_BRIDGE_MODE=http
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787
STT_WORKER_PROVIDER=faster_whisper
STT_WORKER_MODEL_SIZE=tiny
STT_WORKER_COMPUTE_TYPE=int8
STT_WORKER_LANGUAGE=zh
STT_WORKER_LOCAL_FILES_ONLY=0
```

说明：

- `MEETING_REALTIME_STT_WORKER_URL` 控制会议页“实时字幕”按钮背后的实时 WebSocket 链路
- `MEETING_AGENT_BRIDGE_URL` 指向本地 bridge service
- 当前仓内 bridge service 默认通过 `codex exec` 执行真实 agent action
- `claude` 当前默认没有独立 runner；如果你想让它也临时复用 `codex`，显式设置 `MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX=1`

## 6. 启动 Django

```bash
uv run --python .venv/bin/python manage.py runserver 127.0.0.1:8000 --noreload
```

验证方式：

```bash
curl -fsS http://127.0.0.1:8000/healthz
curl -I -s http://127.0.0.1:8000/
```

预期结果：

- `/healthz` 返回 `{"status": "ok"}`
- 首页返回 `HTTP/1.1 200 OK`

到这里，最小本地开发环境已经完成。

## 7. Flutter Web 会议页开发

如果你不修改真实会议页 UI，可以跳过这一节。

如果你要改当前实际会议室页面，这一节是必须的。

### 7.1 安装 Flutter SDK

你可以用自己熟悉的方式安装 Flutter；例如：

```bash
HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask flutter
```

如果你的网络环境需要代理，请在当前 shell 中自行设置代理环境变量后再执行。

验证方式：

```bash
flutter --version
```

### 7.2 拉取 Flutter 依赖

```bash
cd flutter_app
flutter pub get
```

### 7.3 本地直接跑 Flutter 页面

如果你只是单独调 UI：

```bash
cd flutter_app
flutter run -d chrome
```

说明：

- 这里走的是 Flutter 自己的开发服务器
- 当前默认 API 地址写在 `flutter_app/lib/main.dart`
- 如果你联调本地 Django，确保 Django 已在 `127.0.0.1:8000` 上启动

### 7.4 让 Django 使用新的 Flutter 页面

这一步最关键。

只改源码不会生效，必须 build 并同步静态产物：

```bash
cd flutter_app
flutter pub get
flutter build web
mkdir -p ../artifacts/flutter_app_web
rsync -av --delete build/web/ ../artifacts/flutter_app_web/
```

说明：

- Django 会优先读取 `artifacts/flutter_app_web/`
- 这也是当前推荐的集成目录
- 不要手改 `artifacts/flutter_app_web` 下的文件

### 7.5 如何确认改动真的生效

构建同步后，重开页面并强刷浏览器缓存。

当前实际会议页入口通常是：

- `/my/meetings/<meeting_ref>`

如果页面看起来还是旧的，优先检查这几件事：

- `flutter build web` 是否成功
- `rsync` 是否把产物同步到了 `artifacts/flutter_app_web`
- 浏览器是否还缓存着旧的 `main.dart.js`

## 8. 启动 STT worker

如果你只做普通页面和 API 开发，可以跳过。

如果你要联调“实时字幕”或工作区 transcript，这一节需要启用。

### 8.1 mock 模式

这是本地最推荐的联调方式，不依赖模型下载：

```bash
uv run --python .venv/bin/python -m services.stt_worker.stt_worker.server
```

默认监听：

- `ws://127.0.0.1:8765/ws/realtime-transcribe`

### 8.2 Django 连接本地 worker

在 `.env` 中设置：

```dotenv
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe
```

改完后重启 Django。

### 8.3 最小握手验证

```bash
uv run python -c 'import asyncio, json, websockets
async def main():
    async with websockets.connect("ws://127.0.0.1:8765/ws/realtime-transcribe") as ws:
        await ws.send(json.dumps({"type":"start","speaker_name":"Owner","speaker_identity":"owner-1"}))
        print(await ws.recv())
        await ws.send(json.dumps({"type":"stop"}))
        print(await ws.recv())
asyncio.run(main())'
```

预期至少看到：

- `session_started`
- `final_transcript`

### 8.4 faster-whisper 模式

如果你要验证真实模型路径：

```bash
STT_WORKER_PROVIDER=faster_whisper \
STT_WORKER_MODEL_SIZE=tiny \
STT_WORKER_COMPUTE_TYPE=int8 \
STT_WORKER_LANGUAGE=zh \
STT_WORKER_LOCAL_FILES_ONLY=0 \
uv run --python .venv/bin/python -m services.stt_worker.stt_worker.server
```

首次模型下载如果需要代理，请按你自己的环境设置代理变量后再执行。

说明：

- 当前浏览器通过 `MediaRecorder` 上传 `audio/webm`
- worker 现在会按 `mime_type` 选择临时文件扩展名，不再强制写成 `.mp3`
- 首次下载模型完成后，如果你想切回离线模式，可把 `STT_WORKER_LOCAL_FILES_ONLY=1`

### 8.5 会议页里的实际表现

当前这条链路已经不是 mock-only：

- `开始` 后会建立浏览器 -> Django -> STT worker 的 WebSocket 通路
- `停止` 后会触发一次 final transcript 入库
- transcript 会进入 `Live Transcript`
- transcript 会自动进入 `Current Context`

当前仍然有一个现实限制：

- `faster-whisper` 现在主要输出 final transcript
- partial 区域更多是“已缓冲音频”的状态提示，不是稳定的逐字字幕

## 9. 启动本地 Agent Bridge

如果你要让会议工作区里的 `Alice / Codex` 走真实 agent，而不是 Django 内置 mock，这一节需要启用。

### 9.1 启动 bridge service

```bash
MEETING_AGENT_BRIDGE_HOST=127.0.0.1 \
MEETING_AGENT_BRIDGE_PORT=8787 \
MEETING_AGENT_BRIDGE_WORKSPACE_ROOT="$(pwd)" \
MEETING_AGENT_BRIDGE_CODEX_BIN=codex \
uv run --python .venv/bin/python -m services.meeting_agent_bridge.server
```

默认行为：

- `codex` 会走真实 `codex exec`
- `claude` 默认返回未配置
- 如果你确定要让 `claude` 也临时复用 `codex`，显式加：

```bash
MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX=1
```

### 9.2 Django 连接本地 bridge

在 `.env` 中设置：

```dotenv
MEETING_AGENT_BRIDGE_MODE=http
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787
```

改完后重启 Django。

### 9.3 最小健康检查

```bash
curl -fsS 'http://127.0.0.1:8787/health?agent_type=codex'
curl -s 'http://127.0.0.1:8787/health?agent_type=claude'
```

预期结果：

- `codex` 返回 `ok: true`
- `claude` 默认返回 `ok: false`

### 9.4 最小动作验证

```bash
curl -s http://127.0.0.1:8787/meeting-agent/actions \
  -H 'Content-Type: application/json' \
  -d '{
    "meeting_id": 8,
    "agent_type": "codex",
    "task_type": "summarize",
    "instruction": "",
    "context": {"topic_label": "Demo", "summary_text": "用户在验证会议工作区。", "decisions": [], "todos": [], "open_questions": [], "source_chunk_ids": [1]},
    "chunks": [{"id": 1, "speaker_name": "Owner", "speaker_identity": "owner-1", "text": "请总结一下当前验证状态。", "start_ms": 0, "end_ms": 0}]
  }'
```

预期返回字段：

- `short_reply`
- `artifact_type`
- `artifact_title`
- `artifact_content`

## 10. 启动 LiveKit

如果你要验证真实会议房间、join token、浏览器音视频链路，需要把 LiveKit 一起起起来。

```bash
livekit-server --dev --bind 127.0.0.1 --port 7880 --keys "devkey: secret"
```

这条命令和默认 `.env` 是对齐的：

- `LIVEKIT_URL=ws://localhost:7880`
- `LIVEKIT_API_KEY=devkey`
- `LIVEKIT_API_SECRET=secret`

验证方式：

```bash
lsof -nP -iTCP:7880 -sTCP:LISTEN
lsof -nP -iTCP:7881 -sTCP:LISTEN
curl -I -s http://127.0.0.1:7880
```

预期结果：

- `7880` 在监听
- `7881` 在监听
- `http://127.0.0.1:7880` 返回 `HTTP/1.1 200 OK`

说明：

- 这条命令适合本地开发，不是生产部署方式
- 当前命令没有拉起 egress，也没有 Redis 多节点能力
- 如果你要做 HTTPS / `wss://` 联调，继续参考 `LIVEKIT_SSL_STARTUP.md`

## 11. 一套完整本地联调顺序

推荐按这个顺序启动：

1. 初始化 `.venv`，安装 Python 依赖
2. `cp .env.example .env`
3. 在 `.env` 中补齐 `MEETING_REALTIME_STT_WORKER_URL`、`MEETING_AGENT_BRIDGE_MODE`、`MEETING_AGENT_BRIDGE_URL`
4. `uv run --python .venv/bin/python manage.py migrate`
5. 启动 `livekit-server`
6. 启动 STT worker
7. 启动 meeting agent bridge
8. 启动 Django
9. 如果你改了 Flutter 源码，执行 `flutter pub get`、`flutter build web`、`rsync`
10. 打开会议页验证

## 12. 常见问题

### 12.1 `migrate` 提示 conflicting migrations

检查当前代码是否包含：

- `conference/migrations/0020_merge_20260410_1422.py`

### 12.2 Django 能启动，但会议页还是旧 UI

通常不是 Django 没重启，而是 Flutter 产物没更新：

- 你改的是 `flutter_app/lib/`
- 但 Django 实际读的是 `artifacts/flutter_app_web/`
- 需要重新执行 `flutter build web` 和 `rsync`

### 12.3 进入会议后看不到“实时字幕”或工作区

先区分两类问题：

- UI 没暴露出来
  - 先确认你看到的是新的 Flutter build
- UI 有了但点了没反应
  - 检查 `MEETING_REALTIME_STT_WORKER_URL`
  - 检查 STT worker 是否真的在 `127.0.0.1:8765` 监听
  - 检查页面右侧是否把“会议聊天”或“会议工作区”放大到了单独视图

### 12.4 LiveKit 起了，但别的机器还是连不上

这通常是地址问题，不是服务没启动：

- 本地开发命令默认只绑定 `127.0.0.1`
- `.env` 默认 `LIVEKIT_PUBLIC_URL` 为空，更偏向本机访问
- 如果需要给局域网其他机器或 HTTPS 页面使用，要显式设置 `LIVEKIT_PUBLIC_URL`

### 12.5 Agent 点连接或执行后报 bridge unavailable

优先检查：

- `MEETING_AGENT_BRIDGE_MODE` 是否为 `http`
- `MEETING_AGENT_BRIDGE_URL` 是否指向 `http://127.0.0.1:8787`
- `curl http://127.0.0.1:8787/health?agent_type=codex` 是否返回 `ok: true`
- `codex login status` 是否成功

### 12.6 需要一个可分享的公网演示地址

仓库已有脚本：

- `scripts/start_pinggy_meeting.sh`

它适合演示，不是正式生产部署方案。

## 13. 相关专题文档

本页不重复展开这些专题，只给入口：

- HTTPS 本地联调
  - `HTTPS_TESTING.md`
- LiveKit SSL 启动说明
  - `LIVEKIT_SSL_STARTUP.md`
- STT worker 运行时说明
  - `services/stt_worker/README.md`
- 虚拟 agent 当前实现状态
  - `docs/virtual-agent-meeting-current-status.md`
