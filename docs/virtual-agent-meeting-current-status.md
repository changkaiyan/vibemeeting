# Virtual Agent Meeting 当前实现状态

## 文档目的

这份文档对照 [virtual-agent-meeting-design.md](/home/zhaoyilun/vibemeeting/docs/virtual-agent-meeting-design.md) 和 [virtual-agent-meeting-overview.mmd](/home/zhaoyilun/vibemeeting/docs/diagrams/virtual-agent-meeting-overview.mmd)，说明当前代码库里**已经实现**了什么、**还没有实现**什么，以及当前系统的**部署方式**和**测试方法**。

这不是目标方案文档，而是当前代码状态文档。

## 一句话结论

当前系统已经从“只有 meeting_context workspace MVP”推进到了“会议页 + transcript/context/artifact 工作区 + agent bridge + 独立 STT worker 骨架 + Django realtime gateway”这一阶段。

但它还不是完整的 `virtual agent in meeting`：

- 已有：会议页、工作区、手动 transcript、实时字幕 WebSocket 通路、独立 `stt_worker`、真实 `faster-whisper` worker 转写验证、agent action API、artifact 落库
- 未有：Agent 作为真正 LiveKit 虚拟参会者入会、Agent 语音实时发言、Notebook Provider、Agent Dashboard 独立应用、真实流式 partial transcript、VAD、稳定的本地 Codex/Claude 长驻执行链路

## 对照设计方案的当前状态

### 1. Meeting UI

设计目标：

- 会议主舞台
- transcript 面板
- agent panels
- context 面板
- outputs 面板

当前状态：

- 已实现会议页模板 [meeting_room.html](/home/zhaoyilun/vibemeeting/app/templates/meeting_room.html)
- 已实现会议页前端逻辑 [meeting-room.js](/home/zhaoyilun/vibemeeting/app/static/meeting-room.js)
- 已有：
  - Join / Leave
  - 打开 LiveKit Meet UI
  - Participants 列表
  - My Agents 面板
  - Current Context 面板
  - Live Transcript 面板
  - Outputs 面板
  - `Start Live Captions`
  - transcript 选中后发送给 Alice / Bob

结论：

- UI 主体已存在
- 交互入口已足够支撑 MVP 验证
- 还没有“Agent 像真实参会者一样出现在舞台并发声”的体验

### 2. LiveKit Meeting Runtime

设计目标：

- 人类参会者 + 虚拟 agent 同处一个房间
- Agent 作为虚拟参会者存在

当前状态：

- 会议房间和媒体加入逻辑已存在于前端 [meeting-room.js](/home/zhaoyilun/vibemeeting/app/static/meeting-room.js)
- Django 提供 join token
- 前端可加入 LiveKit 房间、发布麦克风/摄像头/屏幕共享
- 当前没有实现“Agent 虚拟参会者”加入 LiveKit 房间

结论：

- 人类会议运行时可用
- 虚拟 agent presence 未落地

### 3. Transcript Timeline Store

设计目标：

- 持续接收 transcript chunk
- 形成会议时间线

当前状态：

- transcript API 已存在，路由在 [meeting_context.py](/home/zhaoyilun/vibemeeting/conference/routes/meeting_context.py)
- 目前支持：
  - `GET /api/meetings/{meeting_id}/transcripts`
  - 手动 transcript 写入
  - STT upload 写入
  - realtime STT final chunk 写入
- 当前 `MeetingTranscriptChunk` 已作为会议时间线核心存储对象使用

结论：

- transcript timeline 已存在
- 其来源目前仍较有限，主要是手动写入和 worker 驱动的 final transcript

### 4. Realtime Transcription

设计目标：

- 会议音频持续转写
- partial / final transcript

当前状态：

- Django WebSocket gateway 已存在：[realtime.py](/home/zhaoyilun/vibemeeting/conference/speech_to_text/realtime.py)
- WebSocket 路径：
  - `/ws/meetings/{meeting_id}/stt`
- 前端已能：
  - 采集本地音频
  - 通过 `MediaRecorder` 切块
  - 发送 `start / audio_chunk / stop`
- 独立 STT worker 已存在：[server.py](/home/zhaoyilun/vibemeeting/services/stt_worker/stt_worker/server.py)
- worker WebSocket 路径：
  - `/ws/realtime-transcribe`
- 当前 worker 支持两种 provider：
  - `mock`
  - `faster_whisper`
- 当前真实验证已完成：
  - `faster-whisper tiny` 在本机 CPU 上可完成中文音频转写
- 当前 partial transcript 仍是缓冲状态文本，不是真正增量识别
- 当前没有接 VAD

结论：

- “浏览器音频 -> Django gateway -> STT worker -> final transcript 入库”已成立
- “稳定、低延迟、真实流式字幕”还没有成立

### 5. Meeting Context Engine

设计目标：

- 从 transcript 窗口构建 summary / decisions / todos
- 形成当前上下文快照

当前状态：

- 当前上下文核心逻辑位于 [services.py](/home/zhaoyilun/vibemeeting/conference/meeting_context/services.py)
- 已能基于 transcript 构建当前 context snapshot
- 当前 context 已被 UI 展示在 Current Context 面板
- 当前 context 也已经被 agent action API 复用

结论：

- context engine 已有 MVP
- 还没有拆成设计稿中的多个清晰子模块
- 还没有 notebook memory 回灌

### 6. Agent Orchestrator / Bridge

设计目标：

- 连接本地 Codex / Claude
- 基于会议上下文分派任务

当前状态：

- agent bridge 客户端模块已存在：[client.py](/home/zhaoyilun/vibemeeting/conference/meeting_agent_bridge/client.py)
- 相关配置已存在于 [settings.py](/home/zhaoyilun/vibemeeting/smart_meeting/settings.py)
  - `MEETING_AGENT_BRIDGE_MODE`
  - `MEETING_AGENT_BRIDGE_URL`
  - `MEETING_AGENT_BRIDGE_TIMEOUT_SECONDS`
- meeting workspace API 已存在：
  - `POST /api/meetings/{meeting_id}/agents`
  - `POST /api/meetings/{meeting_id}/agent-actions`
  - `GET /api/meetings/{meeting_id}/artifacts`
- bridge 语义已经收紧：
  - 默认 `disabled`
  - 显式 `mock`
  - 或 `http`
- 未配置 bridge 时，不再伪装成功

结论：

- “上下文驱动 agent action”已经成立
- “本地 Codex / Claude 稳定在线参会”还没有成立

### 7. Agent Dashboard / Notebook Provider

设计目标：

- 每个 agent 有独立 dashboard
- agent 可接外部 notebook / notion / obsidian

当前状态：

- 未实现
- 目前只有会议页侧栏里的 `My Agents` 面板
- 还没有 notebook provider 对接

结论：

- 这部分目前仍停留在设计层

## 当前系统架构

### 代码结构

- 会议主应用：
  - [conference/](/home/zhaoyilun/vibemeeting/conference)
- meeting workspace：
  - [conference/meeting_context/](/home/zhaoyilun/vibemeeting/conference/meeting_context)
- STT HTTP + realtime gateway：
  - [conference/speech_to_text/](/home/zhaoyilun/vibemeeting/conference/speech_to_text)
- agent bridge：
  - [conference/meeting_agent_bridge/](/home/zhaoyilun/vibemeeting/conference/meeting_agent_bridge)
- 独立 STT worker：
  - [services/stt_worker/](/home/zhaoyilun/vibemeeting/services/stt_worker)
- 会议页前端：
  - [meeting_room.html](/home/zhaoyilun/vibemeeting/app/templates/meeting_room.html)
  - [meeting-room.js](/home/zhaoyilun/vibemeeting/app/static/meeting-room.js)

### 当前运行时数据流

```text
Browser Meeting UI
  -> LiveKit 房间
  -> /ws/meetings/{id}/stt
      -> Django auth / meeting access check
      -> WorkerRealtimeBridge
      -> ws://STT_WORKER_HOST:PORT/ws/realtime-transcribe
          -> stt_worker provider
          -> final transcript
      -> MeetingTranscriptChunk 落库
      -> build_current_context
      -> 前端刷新 transcript/context/artifacts

Browser Workspace Action
  -> /api/meetings/{id}/agent-actions
      -> meeting_context services
      -> meeting_agent_bridge client
      -> mock/http bridge
      -> MeetingArtifact 落库
```

## 当前部署方式

本仓库的本地开发部署说明已经统一收敛到：

- [docs/development.md](/Users/zhaoyilun/workspace/vibemeeting/docs/development.md)

这里不再重复完整的启动步骤，只保留和当前虚拟 agent / realtime STT 场景直接相关的说明。

当前完整会议链路依赖：

- Django 主应用
- STT worker
- LiveKit server
- 可选 agent bridge service

如果你只是要把仓库在本地跑起来，按 `docs/development.md` 先完成 Django 最小启动即可。

如果你要验证当前这份文档描述的实时 transcript / context / artifact 链路，再额外补：

- `MEETING_REALTIME_STT_WORKER_URL`
- `MEETING_AGENT_BRIDGE_MODE`
- `MEETING_AGENT_BRIDGE_URL`
- `STT_WORKER_*`

真实 `faster-whisper` 模型下载和代理细节，继续参考：

- [services/stt_worker/README.md](/Users/zhaoyilun/workspace/vibemeeting/services/stt_worker/README.md)

## 当前测试方法

## 1. 自动化测试

### 1.1 Django 侧会议工作区与 STT 相关测试

```bash
.venv/bin/python manage.py test \
  conference.tests.MeetingRealtimeSpeechToTextTests \
  conference.tests.MeetingSpeechToTextApiTests \
  conference.tests.MeetingAgentBridgeApiTests \
  conference.tests.MeetingContextWorkspaceApiTests
```

覆盖内容：

- 未配置 worker 时 websocket 返回 error
- Django realtime gateway 转发 worker
- final transcript 入库
- upload STT API
- agent bridge 行为
- context workspace 基本行为

### 1.2 worker 侧测试

```bash
.venv/bin/python -m unittest \
  services.stt_worker.tests.test_stream_session \
  services.stt_worker.tests.test_server
```

覆盖内容：

- provider 工厂
- mock session
- faster-whisper provider finalize 路径
- worker WebSocket 协议

## 2. 手工验证

### 2.1 worker 真实转写 smoke test

可以先生成一段测试音频：

```bash
.venv/bin/edge-tts \
  --text '你好，这是一个用于测试语音转文字的音频。' \
  --write-media .runlogs/stt/sample.mp3
```

然后直接调用 provider：

```bash
timeout 30 .venv/bin/python - <<'PY'
from services.stt_worker.stt_worker.providers.faster_whisper_provider import FasterWhisperRealtimeProvider
from pathlib import Path

p = Path('.runlogs/stt/sample.mp3')
provider = FasterWhisperRealtimeProvider(
    model_size='tiny',
    compute_type='int8',
    language='zh',
    speaker_name='Tester',
)
provider.push_chunk(p.read_bytes())
result = provider.finalize()
print(result.text)
PY
```

### 2.2 worker WebSocket smoke test

先起 worker：

```bash
STT_WORKER_PROVIDER=faster_whisper \
STT_WORKER_MODEL_SIZE=tiny \
STT_WORKER_PORT=8877 \
.venv/bin/python -m services.stt_worker.stt_worker.server
```

再用客户端走一遍：

```bash
.venv/bin/python - <<'PY'
import asyncio
import base64
import json
from pathlib import Path
import websockets

async def main():
    audio = Path('.runlogs/stt/sample.mp3').read_bytes()
    async with websockets.connect('ws://127.0.0.1:8877/ws/realtime-transcribe') as ws:
        await ws.send(json.dumps({'type': 'start', 'speaker_name': 'Tester', 'speaker_identity': 'tester-1'}))
        print(await ws.recv())
        await ws.send(json.dumps({'type': 'audio_chunk', 'mime_type': 'audio/mpeg', 'data_base64': base64.b64encode(audio).decode('ascii')}))
        print(await ws.recv())
        await ws.send(json.dumps({'type': 'stop'}))
        print(await ws.recv())

asyncio.run(main())
PY
```

### 2.3 会议页 smoke test

前提：

- LiveKit 可用
- Django 已启动
- worker 已启动
- `MEETING_REALTIME_STT_WORKER_URL` 已配置

步骤：

1. 打开会议页
2. 点击 `Join`
3. 点击 `Start Live Captions`
4. 对着麦克风说话
5. 观察：
   - websocket 不报错
   - transcript 面板出现 partial / final 更新
   - Current Context 自动刷新
   - 可继续把选中的 transcript 发送给 Alice / Bob

## 当前已验证结论

截至当前代码和本地验证结果，以下结论成立：

- 独立 `stt_worker` 已经不再是 placeholder
- `faster-whisper` 已在本机 CPU 上完成真实中文转写验证
- `Django realtime gateway -> worker -> final transcript 入库` 这一链路在测试和手工 smoke test 上都已成立
- `meeting_context workspace` 与 `agent-actions` 已能消费 transcript/context

## 当前未完成项

对照目标方案，当前仍缺少以下关键能力：

- Agent 作为真实 LiveKit 虚拟参会者出现
- Agent 通过语音实时发言
- 真正流式 partial transcript
- VAD 分段
- Notebook Provider
- 独立 Agent Dashboard
- 稳定的本地 Codex / Claude 长驻 worker 执行体系
- 生产级部署方式和运维脚本

## 建议下一步

如果继续沿设计方案推进，当前最合理的顺序是：

1. 把会议页 realtime STT 真接到 `faster-whisper` worker 默认运行模式
2. 把前端从 `MediaRecorder/webm` 逐步切到更适合实时 STT 的 PCM / AudioWorklet
3. 接入 VAD 和更真实的 partial transcript
4. 再做 Agent 虚拟参会者与语音交互
