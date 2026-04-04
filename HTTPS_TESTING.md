# HTTPS 本地测试

这个项目已支持通过 Django 管理命令进行本地 HTTPS 调试。

## 1. 安装依赖

```powershell
pip install -r requirements.txt
```

## 2. 生成本地证书

```powershell
python manage.py gendevcert
```

默认会生成：

- `.certs/localhost.crt`
- `.certs/localhost.key`

如果你需要给局域网 IP 也签发证书，可指定 `--hosts`：

```powershell
python manage.py gendevcert --hosts "localhost,127.0.0.1,192.168.1.10"
```

## 3. 启动 HTTPS 开发服务

```powershell
python manage.py runsslserver 0.0.0.0:8443
```

默认读取证书路径：

- `HTTPS_CERT_FILE`（默认 `.certs/localhost.crt`）
- `HTTPS_KEY_FILE`（默认 `.certs/localhost.key`）

也可命令行覆盖：

```powershell
python manage.py runsslserver 0.0.0.0:8443 --cert-file .certs/localhost.crt --key-file .certs/localhost.key
```

## 4. 可选环境变量

在 `.env` 中可以开启 HTTPS Cookie 行为：

```dotenv
HTTPS_TEST=1
CSRF_TRUSTED_ORIGINS=https://localhost:8443,https://127.0.0.1:8443
```

## 5. LiveKit 跨网络访问

如果后端和客户端不在同一网络，建议区分：

- `LIVEKIT_URL`：后端管理 LiveKit 用（可写内网地址）
- `LIVEKIT_PUBLIC_URL`：返回给浏览器/移动端连接 LiveKit 用（应写真实可访问地址）

示例：

```dotenv
LIVEKIT_URL=http://livekit.internal:7880
LIVEKIT_PUBLIC_URL=wss://rtc.example.com:7880
```

说明：当会议页面本身是 `https://` 时，系统会把返回给客户端的 `ws://` 自动升级为 `wss://`，避免浏览器 Mixed Content 拦截。

## 注意

- 自签名证书在浏览器会出现“不受信任”提示，属于本地测试的正常现象。
- 该方案仅用于开发/测试，不可直接用于生产环境。
