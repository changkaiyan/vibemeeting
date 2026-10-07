# Development Guide

本文档说明如何在本机完成当前仓库的开发环境初始化、服务启动和联调验证。

生产部署、HTTPS / SSL、反向代理和外部可访问地址等主题，见文末相关文档。

## 1. 最短可用启动路径

下面这套流程的目标是：

- 本地启动所有必要服务
- 打开页面
- 创建会议
- 进入会议
- 验证会议工作区
- 打通 STT 和 agent 输出链路

开始前先确认以下工具可用：

- `flutter --version`
- `livekit-server --version`
- `codex login status`

### 1.0 先选启动模式

当前开发有两套模式，不要混用：

### A. HTTP 本机开发模式

适用场景：

- 你只在当前机器本机浏览器里调试
- 你不需要跨机器访问
- 你不需要解决浏览器对内网 `http://<ip>` 的麦克风安全限制

关键端口：

- Django: `http://127.0.0.1:8000`
- LiveKit: `ws://127.0.0.1:7880`

配置特点：

- `.env` 里 `HTTPS_TEST=0`
- `.env` 里 `LIVEKIT_PUBLIC_URL=` 保持为空
- Django 会把本地 `LIVEKIT_URL` 自动改写给浏览器使用

### B. HTTPS / 内网联调模式

适用场景：

- 你要从另一台内网机器访问
- 你要测试浏览器麦克风
- 你要验证 HTTPS 页面下的完整会议体验

关键端口：

- Django: `https://<LAN_IP>:8443`
- LiveKit 对浏览器暴露地址: `wss://<LAN_IP>:7443`
- LiveKit 内部服务端地址: `ws://127.0.0.1:7880`

配置特点：

- `.env` 里 `HTTPS_TEST=1`
- `.env` 里 `LIVEKIT_PUBLIC_URL=wss://<LAN_IP>:7443`
- `.env` 里 `ALLOWED_HOSTS` 和 `CSRF_TRUSTED_ORIGINS` 必须包含 `<LAN_IP>`

最重要的一条：

- `7880` 是 LiveKit 内部服务端口，不是 HTTPS 页面里给浏览器直连的端口
- HTTPS 模式下浏览器应该连 `7443`，不是 `7880`

### 1.1 一次性初始化

```bash
uv venv .venv
uv pip install -r requirements.txt --python .venv
uv pip install -r services/stt_worker/requirements.txt --python .venv
cp .env.example .env
uv run --python .venv/bin/python manage.py migrate

cd flutter_app
flutter pub get
flutter build web
mkdir -p ../artifacts/flutter_app_web
rsync -av --delete build/web/ ../artifacts/flutter_app_web/
cd ..
```

### 1.2 每次开发启动

### 1.2.1 HTTP 本机开发模式

这套模式只用于本机开发。

推荐 `.env` 关键项：

```dotenv
HTTPS_TEST=0
LIVEKIT_URL=ws://localhost:7880
LIVEKIT_PUBLIC_URL=
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe
MEETING_AGENT_BRIDGE_MODE=http
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787
```

使用 4 个终端分别执行以下命令。

终端 1：

```bash
cd /path/to/vibemeeting
livekit-server --dev --bind 127.0.0.1 --port 7880 --keys "devkey: secret"
```

终端 2：

```bash
cd /path/to/vibemeeting
STT_WORKER_PROVIDER=faster_whisper \
STT_WORKER_MODEL_SIZE=tiny \
STT_WORKER_COMPUTE_TYPE=int8 \
STT_WORKER_LANGUAGE=zh \
STT_WORKER_LOCAL_FILES_ONLY=0 \
uv run --python .venv/bin/python -m services.stt_worker.stt_worker.server
```

终端 3：

```bash
cd /path/to/vibemeeting
MEETING_AGENT_BRIDGE_HOST=127.0.0.1 \
MEETING_AGENT_BRIDGE_PORT=8787 \
MEETING_AGENT_BRIDGE_WORKSPACE_ROOT="$(pwd)" \
MEETING_AGENT_BRIDGE_CODEX_BIN=codex \
uv run --python .venv/bin/python -m services.meeting_agent_bridge.server
```

终端 4：

```bash
cd /path/to/vibemeeting
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe \
MEETING_AGENT_BRIDGE_MODE=http \
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787 \
uv run --python .venv/bin/python -m uvicorn smart_meeting.asgi:application --host 127.0.0.1 --port 8000
```

### 1.2.2 HTTPS / 内网联调模式

这套模式用于“另一台机器通过内网 IP 打开页面”和“浏览器麦克风联调”。

推荐 `.env` 关键项：

```dotenv
HTTPS_TEST=1
ALLOWED_HOSTS=127.0.0.1,localhost,<LAN_IP>
CSRF_TRUSTED_ORIGINS=https://localhost:8443,https://127.0.0.1:8443,https://<LAN_IP>:8443
LIVEKIT_URL=ws://localhost:7880
LIVEKIT_PUBLIC_URL=wss://<LAN_IP>:7443
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe
MEETING_AGENT_BRIDGE_MODE=http
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787
```

直接按 [https-testing.md](./https-testing.md) 启动。

### 1.3 功能验证

1. 本机 HTTP 模式打开 `http://127.0.0.1:8000`
2. 内网 HTTPS 模式打开 `https://<LAN_IP>:8443`
   其中 `<LAN_IP>` 请替换为运行 HTTPS 服务那台机器的实际内网 IP
3. 首次访问自签名证书页面时，先手动信任证书
4. 注册或登录
5. 创建一个会议
6. 进入会议页，确认能看到 `会议工作区`
7. 在工作区点击 `开始`
8. 说几句话后点击 `停止`
9. 确认 `Live Transcript` 中出现转录文本
10. 确认 `Current Context` 中出现上下文
11. 点击 `Alice / Codex` 的 `总结`
12. 确认 `Outputs` 中出现结果

如果你是从另一台内网机器访问 HTTPS 页面，且浏览器仍然拒绝麦克风：

1. 确认证书 SAN 包含该服务端 IP
2. 把 `.certs/localhost.crt` 导入访问机器的受信任根证书
3. 重新打开浏览器

如果你能打开会议页，但点“入会”后始终进不去房间，优先检查：

1. 当前页面是不是 `https://<LAN_IP>:8443`
2. `.env` 里 `LIVEKIT_PUBLIC_URL` 是不是 `wss://<LAN_IP>:7443`
3. 不要把 HTTPS 页面错误地配成去连 `wss://<LAN_IP>:7880`

## 2. 先理解当前开发形态

当前本地开发涉及 4 个进程层：

- Django 主应用
  - 页面、API、数据库、鉴权、会议业务
- Flutter Web 会议页
  - 当前真实会议室 UI
- STT worker
  - 会议实时字幕 WebSocket 服务
- LiveKit
  - 实时音视频房间与 join token

当前有 3 个关键事实必须先记住：

- 当前真实会议页不是 `app/templates/meeting_room.html`
- 当前真实会议页来自 Flutter Web 构建产物
- Django 读取的是 `artifacts/flutter_app_web/`

所以如果你修改了 `flutter_app/lib/`，必须重新执行：

```bash
cd flutter_app
flutter build web
mkdir -p ../artifacts/flutter_app_web
rsync -av --delete build/web/ ../artifacts/flutter_app_web/
```

只改 Flutter 源码但不 build + rsync，Django 页面不会更新。

## 3. 推荐本地联调方案

当前推荐的完整联调方案是：

- Python 环境用 `uv`
- Django 用 ASGI 启动
- STT 默认走真实 `faster-whisper`
- Agent 默认走本地 HTTP bridge
- Flutter 页面通过 `flutter build web` 后挂到 Django
- 需要浏览器麦克风 / 内网跨机器访问时，优先使用 `HTTPS + WSS`

不再推荐把本地开发默认建立在 `mock` STT 或 `disabled` bridge 之上。

## 4. 先决条件

在仓库根目录执行命令。

### 4.1 必备工具

- `uv`
- Python `3.10+`

检查方式：

```bash
uv --version
uv python list
```

### 4.2 做真实会议页开发时额外需要

- Flutter SDK
- Chrome

检查方式：

```bash
flutter --version
```

### 4.3 做完整会议联调时额外需要

- `livekit-server`
- 本机可用的 `codex` CLI

检查方式：

```bash
livekit-server --version
codex login status
```

如果你的网络环境需要代理，请按你自己的机器环境设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 后再安装依赖或首次下载模型。本文档不写任何机器绑定的代理地址或端口。

## 5. 初始化环境

### 5.1 Python 环境

```bash
uv venv .venv
uv pip install -r requirements.txt --python .venv
uv pip install -r services/stt_worker/requirements.txt --python .venv
cp .env.example .env
```

说明：

- 仓库当前使用 `requirements.txt`，不是 `pyproject.toml`
- `.env.example` 已经按当前本地联调方案提供默认值
- `.venv` 已存在时，`uv venv` 会复用该目录
- 当前 pin 的依赖按包元数据支持 `Python >=3.10`
- 因此不要求必须使用 `3.10`；机器上如果已有 `3.11` / `3.12`，也可以直接用
- 当前这台开发机实际验证过的是 `3.10`

### 5.2 数据库

```bash
uv run --python .venv/bin/python manage.py migrate
uv run --python .venv/bin/python manage.py check
```

如果需要后台账号：

```bash
uv run --python .venv/bin/python manage.py createsuperuser
```

## 6. `.env` 默认本地配置

以 `.env.example` 为基础，当前本地开发默认对齐下面这套链路：

```dotenv
LIVEKIT_URL=ws://localhost:7880
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret

MEETING_STT_PROVIDER=faster_whisper
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe

MEETING_AGENT_BRIDGE_MODE=http
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787

STT_WORKER_PROVIDER=faster_whisper
STT_WORKER_MODEL_SIZE=tiny
STT_WORKER_COMPUTE_TYPE=int8
STT_WORKER_LANGUAGE=zh
STT_WORKER_LOCAL_FILES_ONLY=0

MEETING_AGENT_BRIDGE_HOST=127.0.0.1
MEETING_AGENT_BRIDGE_PORT=8787
MEETING_AGENT_BRIDGE_WORKSPACE_ROOT=.
MEETING_AGENT_BRIDGE_CODEX_BIN=codex
MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX=0
```

如果你切到 HTTPS / 内网联调模式，建议覆盖为：

```dotenv
ALLOWED_HOSTS=127.0.0.1,localhost,<LAN_IP>
HTTPS_TEST=1
CSRF_TRUSTED_ORIGINS=https://localhost:8443,https://127.0.0.1:8443,https://<LAN_IP>:8443
LIVEKIT_PUBLIC_URL=wss://<LAN_IP>:7443
```

补充说明：

- 这里的 `<LAN_IP>` 必须替换成运行 Django HTTPS 服务那台机器的真实内网 IP，比如 `<LAN_IP>`
- 如果你能打开 `https://127.0.0.1:8443/`，但打开 `https://<LAN_IP>:8443/` 出现 `DisallowedHost`，通常就是 `.env` 里的 `ALLOWED_HOSTS` 或 `CSRF_TRUSTED_ORIGINS` 漏了这个 IP
- 改完 `.env` 之后要重启 Django 相关进程，再重新访问
- 如果你能打开 HTTPS 页面，但点“入会”后进不去会议，通常是 `LIVEKIT_PUBLIC_URL` 没配成 `wss://<LAN_IP>:7443`

重点说明：

- `MEETING_REALTIME_STT_WORKER_URL` 是 Django 服务端桥接到 STT worker 的地址，不是浏览器直接连接的地址
- `MEETING_AGENT_BRIDGE_MODE=http` 表示会议工作区里的 agent 默认走本地 bridge
- `STT_WORKER_PROVIDER=faster_whisper` 表示本地默认不是 mock
- `MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX=0` 表示当前默认只保证 `codex` 可用
- HTTP 本机模式下 `LIVEKIT_PUBLIC_URL` 应为空；HTTPS / 内网模式下应显式写成 `wss://<LAN_IP>:7443`

## 7. 启动顺序

推荐严格按这个顺序启动。

### 7.1 构建 Flutter Web 产物

```bash
cd flutter_app
flutter pub get
flutter build web
mkdir -p ../artifacts/flutter_app_web
rsync -av --delete build/web/ ../artifacts/flutter_app_web/
cd ..
```

### 7.2 启动 LiveKit

```bash
livekit-server --dev --bind 127.0.0.1 --port 7880 --keys "devkey: secret"
```

### 7.3 启动 STT worker

```bash
STT_WORKER_PROVIDER=faster_whisper \
STT_WORKER_MODEL_SIZE=tiny \
STT_WORKER_COMPUTE_TYPE=int8 \
STT_WORKER_LANGUAGE=zh \
STT_WORKER_LOCAL_FILES_ONLY=0 \
uv run --python .venv/bin/python -m services.stt_worker.stt_worker.server
```

### 7.4 启动 meeting agent bridge

```bash
MEETING_AGENT_BRIDGE_HOST=127.0.0.1 \
MEETING_AGENT_BRIDGE_PORT=8787 \
MEETING_AGENT_BRIDGE_WORKSPACE_ROOT="$(pwd)" \
MEETING_AGENT_BRIDGE_CODEX_BIN=codex \
uv run --python .venv/bin/python -m services.meeting_agent_bridge.server
```

如果你明确要让 `claude` 也临时复用 `codex`，再额外加：

```bash
MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX=1
```

### 7.5 启动 Django

本地完整会议联调时，推荐使用 ASGI。

```bash
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe \
MEETING_AGENT_BRIDGE_MODE=http \
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787 \
uv run --python .venv/bin/python -m uvicorn smart_meeting.asgi:application --host 127.0.0.1 --port 8000
```

说明：

- 会议页实时字幕链路依赖 WebSocket
- 当前完整会议链路以 ASGI 方式联调更稳定
- 如果只做普通 Django 页面或 API 开发，仍可单独使用 `runserver`

## 8. 最小验证

### 8.1 Django

```bash
curl -fsS http://127.0.0.1:8000/healthz
curl -I -s http://127.0.0.1:8000/
```

预期：

- `/healthz` 返回 `{"status":"ok"}` 或等价健康响应
- 首页返回 `HTTP 200`

### 8.2 STT worker

```bash
uv run --python .venv/bin/python - <<'PY'
import asyncio, websockets
async def main():
    async with websockets.connect('ws://127.0.0.1:8765/ws/realtime-transcribe') as ws:
        print('stt_ws_ok')
asyncio.run(main())
PY
```

### 8.3 Agent bridge

```bash
curl -fsS 'http://127.0.0.1:8787/health?agent_type=codex'
```

预期返回包含：

- `ok: true`

### 8.4 Flutter 页面

打开真实会议页，例如：

- `/my/meetings/<meeting_ref>`

进入会议后，应该能看到：

- `会议聊天`
- `会议工作区`

在工作区中，应该能看到：

- `实时字幕`
- `My Agents`
- `Current Context`
- `Live Transcript`
- `Outputs`

## 9. 当前本地链路的实际行为

### 9.1 实时字幕

当前行为是：

- 点击 `开始` 后，浏览器建立到 Django 的 STT WebSocket
- Django 再转发到本地 STT worker
- 点击 `停止` 后，会生成本轮 final transcript
- final transcript 会进入 `Live Transcript`
- final transcript 会自动进入 `Current Context`

当前更接近“final transcript 优先”：

- `faster-whisper` 目前主要稳定产出 final transcript
- partial 区域不是稳定逐字字幕，不应按逐字实时字幕预期理解

### 9.2 Agent

当前行为是：

- 工作区里的 `Alice / Codex` 默认走本地 HTTP bridge
- bridge 默认通过 `codex exec` 执行真实 action
- 成功后结果会进入 `Outputs`

当前默认不保证 `Bob / Claude` 可用：

- 如需临时复用 `codex` runner，显式设置 `MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX=1`

## 10. 常见问题

### 10.1 Flutter 改了但页面没变

优先检查：

- 你改的是不是 `flutter_app/lib/`
- 有没有重新执行 `flutter build web`
- 有没有把 `build/web/` 同步到 `artifacts/flutter_app_web/`
- 浏览器是否还缓存着旧的 `main.dart.js`

### 10.2 进入会议后看不到工作区

优先检查：

- 你打开的是不是新版 Flutter 产物对应的真实会议页
- 是否已经执行过 `flutter build web` + `rsync`
- 是否走的是已登录成员入口，而不是能力受限的访客入口

### 10.3 点“开始实时字幕”没反应

优先检查：

- `MEETING_REALTIME_STT_WORKER_URL` 是否配置正确
- STT worker 是否真的监听在 `127.0.0.1:8765`
- Django 是否按 ASGI 方式启动

### 10.4 点 agent 后报 bridge unavailable

优先检查：

- `MEETING_AGENT_BRIDGE_MODE` 是否为 `http`
- `MEETING_AGENT_BRIDGE_URL` 是否为 `http://127.0.0.1:8787`
- `curl 'http://127.0.0.1:8787/health?agent_type=codex'` 是否返回 `ok: true`
- `codex login status` 是否成功

### 10.5 `migrate` 提示 conflicting migrations

优先确认当前代码包含：

- `conference/migrations/0020_merge_20260410_1422.py`

如果你切到旧提交上执行迁移，可能会遇到并行叶子迁移冲突。

### 10.6 HTTPS 页面能打开，但无法进入会议

优先检查：

- 当前访问地址是不是 `https://<LAN_IP>:8443`
- `.env` 里的 `HTTPS_TEST` 是否为 `1`
- `.env` 里的 `LIVEKIT_PUBLIC_URL` 是否为 `wss://<LAN_IP>:7443`
- `7443` 的 TLS 代理是否真的已经启动
- 不要让浏览器去连 `7880`

## 11. 相关文档

- 部署边界说明：`docs/run/deployment.md`
- HTTPS 本地联调：`docs/run/https-testing.md`
- LiveKit SSL：`docs/run/livekit-ssl-startup.md`
- STT worker 运行时说明：`docs/run/stt-worker.md`
- 虚拟 agent 方案与状态：`docs/design/virtual-agent-meeting-design.md`、`docs/status/virtual-agent-meeting-current-status.md`
