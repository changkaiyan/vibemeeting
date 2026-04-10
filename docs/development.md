# Development Guide

这份文档是仓库当前的本地开发主入口，覆盖：

- `uv` 管理的 Python 环境初始化
- Django 主应用本地启动
- 数据库迁移
- STT worker 本地联调
- LiveKit / HTTPS / 外网演示相关边界

本页尽量只保留“开发时真正要做的事情”。更细的专题文档继续保留，但不再重复一整套启动步骤。

## 1. 当前开发形态

本仓库本地开发可以拆成三层：

- Django 主应用
  - 用户、会议、页面、API、数据库
- STT worker
  - 实时语音转写 WebSocket 服务
- LiveKit
  - 真实音视频房间与 token 使用场景

因此本地开发也分三种强度：

- 最小开发
  - 只起 Django，验证页面、API、后台和数据模型
- 转写联调
  - 起 Django + STT worker，验证实时 transcript 链路
- 完整会议联调
  - 起 Django + STT worker + LiveKit，验证完整音视频会议能力

## 2. 先决条件

- 已安装 `uv`
- 本机可用 Python `3.10.x`
- 在仓库根目录执行命令

检查方式：

```bash
uv --version
uv python list
```

当前已验证通过的组合：

- `uv 0.9.24`
- `Python 3.10.19`

## 3. 初始化本地 Python 环境

仓库当前没有 `pyproject.toml` 或 `uv.lock`，所以开发环境直接基于 `requirements.txt` 构建。

```bash
uv venv --python 3.10.19 .venv
uv pip install --python .venv/bin/python -r requirements.txt
cp .env.example .env
```

说明：

- `.env` 默认使用 SQLite，本地最小启动不依赖额外数据库服务
- 如果 `.venv` 已存在，`uv venv` 会复用该目录
- 若要彻底重建环境，删掉 `.venv` 后重新执行即可

## 4. 数据库迁移

```bash
uv run --python .venv/bin/python manage.py migrate
```

可选检查：

```bash
uv run --python .venv/bin/python manage.py check
```

如果你要登录后台，再补一个管理员账号：

```bash
uv run --python .venv/bin/python manage.py createsuperuser
```

说明：

- 当前仓库需要 [conference/migrations/0020_merge_20260410_1422.py](/Users/zhaoyilun/workspace/vibemeeting/conference/migrations/0020_merge_20260410_1422.py) 来收敛 `conference` 的并行叶子迁移
- 如果你在旧提交上执行 `migrate`，可能会遇到 `Conflicting migrations detected`

## 5. 启动 Django 主应用

```bash
uv run --python .venv/bin/python manage.py runserver 127.0.0.1:8000 --noreload
```

验证服务：

```bash
curl -fsS http://127.0.0.1:8000/healthz
curl -I -s http://127.0.0.1:8000/
```

预期结果：

- `/healthz` 返回 `{"status": "ok"}`
- 首页返回 `HTTP/1.1 200 OK`

到这里，最小本地开发环境就算完成。

## 6. 关键环境变量

### 6.1 Django 最小开发

这些变量足够支撑最小本地启动：

- `SECRET_KEY`
- `DEBUG`
- `ALLOWED_HOSTS`
- `DATABASE_URL`
- `TIME_ZONE`

### 6.2 LiveKit 相关

这些变量用于真实会议音视频能力：

- `LIVEKIT_URL`
- `LIVEKIT_PUBLIC_URL`
- `LIVEKIT_API_KEY`
- `LIVEKIT_API_SECRET`
- `LIVEKIT_MEET_URL`
- `LIVEKIT_EGRESS_OUTPUT_ROOT`

### 6.3 STT / Agent 相关

这些变量用于实时转写和 agent bridge 联调：

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

说明：

- `MEETING_REALTIME_STT_WORKER_URL` 控制实时会议 WebSocket 转写链路
- `MEETING_STT_PROVIDER` 当前主要影响上传音频转写，明确支持 `mock`
- `.env.example` 已经覆盖这些模板值

## 7. 可选：启动 STT worker

如果你只做普通页面和 API 开发，可以跳过。

如果你要联调实时 transcript，先安装 worker 依赖：

```bash
uv pip install --python .venv/bin/python -r services/stt_worker/requirements.txt
```

### 7.1 mock 模式

这是本地最推荐的联调方式，不依赖模型下载：

```bash
uv run --python .venv/bin/python -m services.stt_worker.stt_worker.server
```

默认监听：

- `ws://127.0.0.1:8765/ws/realtime-transcribe`

### 7.2 Django 连接本地 worker

在 `.env` 中设置：

```dotenv
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe
```

改完后重启 Django。

### 7.3 最小握手验证

```bash
./.venv/bin/python -c 'import asyncio, json, websockets
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

## 8. 可选：faster-whisper 模式

如果你要验证真实模型路径：

```bash
STT_WORKER_PROVIDER=faster_whisper \
STT_WORKER_MODEL_SIZE=tiny \
STT_WORKER_COMPUTE_TYPE=int8 \
uv run --python .venv/bin/python -m services.stt_worker.stt_worker.server
```

首次模型下载可能需要代理，参考 [services/stt_worker/README.md](/Users/zhaoyilun/workspace/vibemeeting/services/stt_worker/README.md)。

## 9. 开发边界和专题文档

本页不重复展开这些专题，只给入口：

- HTTPS 本地联调
  - [HTTPS_TESTING.md](/Users/zhaoyilun/workspace/vibemeeting/HTTPS_TESTING.md)
- LiveKit SSL 启动说明
  - [LIVEKIT_SSL_STARTUP.md](/Users/zhaoyilun/workspace/vibemeeting/LIVEKIT_SSL_STARTUP.md)
- STT worker 运行时说明
  - [services/stt_worker/README.md](/Users/zhaoyilun/workspace/vibemeeting/services/stt_worker/README.md)
- 虚拟 agent 当前实现状态
  - [docs/virtual-agent-meeting-current-status.md](/Users/zhaoyilun/workspace/vibemeeting/docs/virtual-agent-meeting-current-status.md)

## 10. 常见问题

### 10.1 `migrate` 提示 conflicting migrations

说明当前代码缺少 merge migration，检查是否包含：

- [conference/migrations/0020_merge_20260410_1422.py](/Users/zhaoyilun/workspace/vibemeeting/conference/migrations/0020_merge_20260410_1422.py)

### 10.2 Django 能启动，但会议相关能力不完整

通常是依赖层没补齐：

- 实时音视频依赖 LiveKit
- 实时转写依赖 STT worker
- agent 动作依赖 `MEETING_AGENT_BRIDGE_*`

### 10.3 需要一个可分享的公网演示地址

仓库已有脚本：

- [scripts/start_pinggy_meeting.sh](/Users/zhaoyilun/workspace/vibemeeting/scripts/start_pinggy_meeting.sh)

它适合演示，不是正式生产部署方案。
