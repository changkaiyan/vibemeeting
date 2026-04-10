# STT Worker

这是一个仓内独立的语音转文字运行时子项目，用来承载重音频 / 重模型依赖。

目标职责：

- 接收实时音频流
- 做分段与 VAD
- 调用 `faster-whisper`
- 输出 partial / final transcript

它不负责：

- Django 认证与会议业务逻辑
- transcript 持久化
- context / artifact / agent orchestration

这些职责仍由主 Django 工程负责。

## 当前状态

当前已经具备独立运行的最小 WebSocket 服务：

- provider 抽象已建立
- `mock` provider 已可用
- `faster-whisper` provider 位置已预留
- 对外 WebSocket 协议已落地：`/ws/realtime-transcribe`
- worker 侧已有 session / server 单测

当前协议：

- client -> worker
  - `start`
  - `audio_chunk`
  - `stop`
- worker -> client
  - `session_started`
  - `partial_transcript`
  - `final_transcript`
  - `error`

启动方式：

```bash
python -m services.stt_worker.stt_worker.server
```

真实 Whisper 路线示例：

```bash
STT_WORKER_PROVIDER=faster_whisper \
STT_WORKER_MODEL_SIZE=tiny \
STT_WORKER_COMPUTE_TYPE=int8 \
python -m services.stt_worker.stt_worker.server
```

如果首次下载模型遇到网络问题，优先尝试代理：

```bash
export ALL_PROXY=socks5://127.0.0.1:10808
export HTTPS_PROXY=socks5://127.0.0.1:10808
export HTTP_PROXY=socks5://127.0.0.1:10808
```

可选环境变量：

- `STT_WORKER_HOST`
- `STT_WORKER_PORT`
- `STT_WORKER_PROVIDER`
- `STT_WORKER_MODEL_SIZE`
- `STT_WORKER_COMPUTE_TYPE`
- `STT_WORKER_LANGUAGE`

下一步再接：

1. VAD 分段
2. `faster-whisper` 真正转写
3. Django gateway 与 worker 的真实联调
4. 前端从 `MediaRecorder/webm` 逐步切到更适合低延迟 STT 的 PCM / AudioWorklet

## 建议目录

```text
services/stt_worker/
  requirements.txt
  README.md
  stt_worker/
    config.py
    schemas.py
    server.py
    providers/
    pipeline/
  tests/
```
