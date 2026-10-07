# LiveKit SSL 启动手册（本项目）

适用目录：`<PROJECT_ROOT>`
适用 LiveKit：`livekit_1.10.1_windows_amd64\livekit-server.exe`

## 架构说明

当前方案是三段式：

1. LiveKit 原生服务（内部）：`ws://127.0.0.1:7880`
2. 本地 TLS 反向代理（对外）：`wss://<LAN_IP>:7443`
3. Django HTTPS：`https://<LAN_IP>:8443`

说明：`livekit-server 1.10.1` 不支持直接配置 `tls:` 作为信令口 HTTPS，因此用 `livekit_tls_proxy.py` 做 TLS 终止。

## 一次性准备

### 1. 生成证书（包含局域网 IP）

```powershell
.\.venv\Scripts\python manage.py gendevcert --hosts "localhost,127.0.0.1,::1,<LAN_IP>" --force
```

### 2. 准备 `.env`

项目根目录创建或更新 `.env`：

```dotenv
SECRET_KEY=replace-with-your-secret
DEBUG=1
ALLOWED_HOSTS=127.0.0.1,localhost,<LAN_IP>
TIME_ZONE=Asia/Shanghai
ACCESS_TOKEN_EXPIRE_MINUTES=480
DATABASE_URL=sqlite:///./smart_meeting.db

HTTPS_TEST=1
CSRF_TRUSTED_ORIGINS=https://localhost:8443,https://127.0.0.1:8443,https://<LAN_IP>:8443
HTTPS_CERT_FILE=.certs/localhost.crt
HTTPS_KEY_FILE=.certs/localhost.key

LIVEKIT_URL=ws://127.0.0.1:7880
LIVEKIT_PUBLIC_URL=wss://<LAN_IP>:7443
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret
LIVEKIT_MEET_URL=https://meet.livekit.io
```

## 启动步骤（每次开机后）

建议开 3 个 PowerShell 窗口，工作目录都切到项目根目录。

7443,8443运行ssl协议，8000,7880运行https/ws协议
### 窗口 A：启动 LiveKit

```powershell
.\livekit_1.10.1_windows_amd64\livekit-server.exe --bind 0.0.0.0 --port 7880 --keys "devkey: secret"
```

### 窗口 B：启动 TLS 代理（wss）

```powershell
.\.venv\Scripts\python .\livekit_tls_proxy.py --listen-host 0.0.0.0 --listen-port 7443 --upstream http://127.0.0.1:7880 --cert-file .certs/localhost.crt --key-file .certs/localhost.key
```

### 窗口 C：启动 Django HTTPS

```powershell
.\.venv\Scripts\python manage.py runsslserver 0.0.0.0:8443 --noreload --nothreading
```

## 快速验证

### 1. 端口监听检查

```powershell
netstat -ano | Select-String ":7880|:7443|:8443"
```

### 2. 接口返回的 LiveKit 地址应为 `wss://`

```powershell
curl.exe -k -s -X POST "https://127.0.0.1:8443/api/public/meetings/share/<你的share_code>/join-token" -H "Content-Type: application/json" -d "{}"
```

返回 JSON 中应看到：

```text
"livekit_url":"wss://<LAN_IP>:7443"
```

## 停止服务

```powershell
Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -like "*livekit-server.exe*" -or
  $_.CommandLine -like "*livekit_tls_proxy.py*" -or
  $_.CommandLine -like "*manage.py runsslserver*"
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

## 常见问题

1. 会议页出现 Mixed Content（`ws://` 被拦截）
   - 先看 `join-token` 返回是否是 `wss://...`
   - 确认 `.env` 里 `LIVEKIT_PUBLIC_URL` 是 `wss://<LAN_IP>:7443`
   - 重启 Django 服务让 `.env` 生效

2. 浏览器提示证书不受信任
   - 自签证书属于开发环境正常现象
   - 每台访问会议页的客户端机器都需要导入同一个证书到受信任根
   - Windows（当前用户）命令：

```powershell
Import-Certificate -FilePath "<PROJECT_ROOT>\.certs\localhost.crt" -CertStoreLocation "Cert:\CurrentUser\Root"
```

   - 如果客户端不在这台服务器上，请先把 `localhost.crt` 拷贝到客户端，再执行上面命令
   - 导入后请完全关闭并重开浏览器（必要时重启浏览器进程）

3. `share_code` 变化导致 404
   - 使用当前会议最新分享链接中的 `share_code`，不要用旧值
