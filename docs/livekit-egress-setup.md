# LiveKit Egress 录制部署说明

## 现象
调用：
- `/api/meetings/<id>/recordings/egress/start`
- `/api/my/meetings/<meeting_ref>/recordings/egress/start`

返回：
- `twirperror no response from server status=503`
- 或 `egress not connected (redis required)`

## 根因
LiveKit egress 录制不是 `livekit-server` 单进程功能，必须同时具备：
1. Redis
2. livekit-server（连接到 Redis）
3. livekit-egress（连接到同一个 Redis，并指向同一个 LiveKit）

当前仅启动了 `livekit-server`，未连接 Redis，且没有 `livekit-egress` 进程，因此会报 503/500。
```docker run -d --name redis -p 6379:6379 redis```
## 最小要求
1. 启动 Redis（示例：`127.0.0.1:6379`）。
2. 用 Redis 参数启动 LiveKit Server：
   - `livekit-server.exe --bind 0.0.0.0 --port 7880 --keys "devkey: secret" --redis-host 127.0.0.1:6379 --node-ip 192.168.1.157`
   - node-ip必须为宿主机可达ip，根因是 egress 内部浏览器被喂了 url=ws://127.0.0.1:7880。
127.0.0.1 在容器里指向容器自己，不是宿主机 livekit-server，所以会立即断开。
3. 启动 livekit-egress（配置需包含）：
   - `api_key: devkey`
   - `api_secret: secret`
   - `ws_url: ws://127.0.0.1:7880`
   - `redis.address: 127.0.0.1:6379`
   - ```docker run --rm `
  -e EGRESS_CONFIG_FILE=/out/config.yaml `
  -v "${HOME}/egress-test:/out" `
-v 'D:\2026综合事务\tmp_recording:/recordings' `
  livekit/egress``` (把Windows外层系统盘映射到Egress内层盘)
## 验证
在 Django 项目根目录执行：

```powershell
.\.venv\Scripts\python.exe manage.py shell -c "from conference.services.livekit_service import LiveKitService; print(LiveKitService().list_egress())"
```

如果不再出现 `egress not connected` / `no response from server`，说明 egress 链路已打通。

