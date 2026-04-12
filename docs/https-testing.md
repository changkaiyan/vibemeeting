# HTTPS 启动

## 1. 安装依赖

```bash
uv venv --python 3.10 .venv
uv pip install -r requirements.txt --python .venv
uv pip install -r services/stt_worker/requirements.txt --python .venv
```

## 2. 生成证书

只在本机 `localhost` 测试：

```bash
uv run --python .venv/bin/python manage.py gendevcert --hosts "localhost,127.0.0.1" --force
```

如果要让同内网其他机器访问，把服务端 IP 也加进去：

```bash
uv run --python .venv/bin/python manage.py gendevcert --hosts "localhost,127.0.0.1,10.208.128.244" --force
```

证书输出到：

- `.certs/localhost.crt`
- `.certs/localhost.key`

## 3. 配置 `.env`

```dotenv
HTTPS_TEST=1
ALLOWED_HOSTS=127.0.0.1,localhost,10.208.128.244
CSRF_TRUSTED_ORIGINS=https://localhost:8443,https://127.0.0.1:8443,https://10.208.128.244:8443
LIVEKIT_URL=ws://127.0.0.1:7880
LIVEKIT_PUBLIC_URL=wss://10.208.128.244:7443
MEETING_REALTIME_STT_WORKER_URL=ws://127.0.0.1:8765/ws/realtime-transcribe
MEETING_AGENT_BRIDGE_MODE=http
MEETING_AGENT_BRIDGE_URL=http://127.0.0.1:8787
```

## 4. 启动服务

终端 1：

```bash
livekit-server --dev --bind 0.0.0.0 --port 7880 --keys "devkey: secret"
```

终端 2：

```bash
uv run --python .venv/bin/python livekit_tls_proxy.py \
  --listen-host 0.0.0.0 \
  --listen-port 7443 \
  --upstream http://127.0.0.1:7880 \
  --cert-file .certs/localhost.crt \
  --key-file .certs/localhost.key
```

终端 3：

```bash
STT_WORKER_HOST=0.0.0.0 \
STT_WORKER_PORT=8765 \
STT_WORKER_PROVIDER=faster_whisper \
STT_WORKER_MODEL_SIZE=tiny \
STT_WORKER_COMPUTE_TYPE=int8 \
STT_WORKER_LANGUAGE=zh \
STT_WORKER_LOCAL_FILES_ONLY=0 \
uv run --python .venv/bin/python -m services.stt_worker.stt_worker.server
```

终端 4：

```bash
MEETING_AGENT_BRIDGE_HOST=127.0.0.1 \
MEETING_AGENT_BRIDGE_PORT=8787 \
MEETING_AGENT_BRIDGE_WORKSPACE_ROOT="$(pwd)" \
MEETING_AGENT_BRIDGE_CODEX_BIN=codex \
uv run --python .venv/bin/python -m services.meeting_agent_bridge.server
```

终端 5：

```bash
uv run --python .venv/bin/python -m uvicorn smart_meeting.asgi:application \
  --host 0.0.0.0 \
  --port 8443 \
  --ssl-certfile .certs/localhost.crt \
  --ssl-keyfile .certs/localhost.key
```

## 5. 访问地址

- 本机：`https://127.0.0.1:8443`
- 内网其他机器：`https://10.208.128.244:8443`
