# 一键安装运行（含会议录制）

启动脚本同样支持 `--host`、`--public-url`、`--livekit-url`、`--livekit-public-url`、`--livekit-node-ip`、`--turn-host`、`--allowed-hosts` 和 `--csrf-trusted-origins`。参数说明与远程部署示例见 [地址配置](./pip-install.md#v011监听地址与远程访问)。

如果希望通过 Python 包安装并直接执行 `vibemeeting`，请阅读 [pip 安装指南](./pip-install.md)。包方式内置网页编译产物，无需克隆仓库或安装 Flutter；音视频与录制仍使用 Docker。

下载或克隆完整仓库后，在仓库根目录执行。默认用于当前电脑的浏览器，支持摄像头、麦克风、共享屏幕和会议录制。AI 模型、语音转写及外部 Agent 不属于基础启动依赖，需要时按相应专题文档配置；启动脚本不会安装已废弃的原生客户端。

## Docker 方式（推荐）

安装并启动 Docker Desktop，选择 Linux 容器；Linux 可使用 Docker Engine。需要 Compose v2.20+。不需要在宿主机安装 Python、Flutter、Git SDK 或 LiveKit。

Windows 双击 `run-docker.cmd`，或在 PowerShell 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-docker.ps1
```

Linux / macOS：

```bash
bash run-docker.sh
```

脚本初始化独立配置、从源码构建 Flutter 网页和 Python 镜像、迁移数据库、创建初始管理员，然后启动并检查 Web、Redis、Egress，并启动本机 TURN 媒体中继。LiveKit 连接同一个 Redis，录制回调已指向 Web 服务。

成功后打开 <http://127.0.0.1:8080/accounts/login>。用户名 `admin`；初始随机密码保存在 `.runtime/docker.env` 的 `DJANGO_SUPERUSER_PASSWORD`。修改账号密码后重复启动不会重置密码，因此配置文件中的值只代表初始密码。

停止和查看日志：

```powershell
.\run-docker.ps1 --stop
.\run-docker.ps1 --logs
```

```bash
bash run-docker.sh --stop
bash run-docker.sh --logs
```

停止时不会删除数据库卷、Redis 卷或录像。再次运行原启动命令即可启动并检查服务；源码改变会触发 Docker 构建缓存更新。

## 本地方式

需要 Python 3.10+（Linux 包括 `venv` 模块）、Git、Docker 与 Compose。Flutter 自动安装到项目内，或复用 `tools/flutter`、PATH 中已有 SDK。建议使用 Flutter 3.41.6，与 Docker 构建保持一致。LiveKit、Redis、TURN、Egress 自动拉取官方容器镜像，无需另行安装。

Windows 双击 `run-local.cmd`，或执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-local.ps1
```

Linux / macOS：

```bash
bash run-local.sh
```

脚本创建 `.runtime/venv`、安装 Python 依赖、构建并发布网页、迁移独立数据库和创建初始管理员。Django 与网页构建在本机运行，LiveKit、Redis、TURN 和 Egress 通过 Docker 运行并共享媒体网络。Windows 录制依赖容器；官方 Egress 镜像同时提供 Chrome、音视频编码与合成依赖。

成功后打开 <http://127.0.0.1:8000/accounts/login>。用户名 `admin`，初始密码查看 `.runtime/local.env`。本地窗口保持运行，按 **Ctrl+C** 停止本次启动的本地应用进程及音视频、录制容器，不会停止其他程序。

重复启动会根据源文件和依赖清单判断是否需要重新安装或构建；可通过 `--rebuild` 强制重建网页。失败后可修复原因并重跑。日志在 `.runtime/logs/`。

## 会议录制

两种模式默认均启动 **Redis + LiveKit Egress**，无需另外运行录制命令。进入会议后，由有权限的主持人点击录制开始/停止；启动服务不会自动录下所有会议。

- 录像保存在宿主机 `.runtime/recordings/`，Web 与 Egress 共享同一目录。
- 初始化时自动配置 Django 的录像存储路径；管理员已配置过的路径不会被覆盖。
- 如果以后手动更改存储根目录，需要同时修改 Egress 挂载目录与 `LIVEKIT_EGRESS_OUTPUT_ROOT`，否则录制结果无法被网页读取。
- Egress 官方镜像使用 `SYS_ADMIN` 能力启动录制浏览器，Compose 已配置。
- 建议为 Docker 分配至少 4 CPU、4 GB 内存用于录制；镜像和 Flutter SDK 首次下载需要较多磁盘空间。资源建议及运行要求见 [LiveKit 官方 Egress 文档](https://docs.livekit.io/transport/self-hosting/egress/)。

两种模式均让 Egress 与 LiveKit 共享网络命名空间，避免录制浏览器把 `127.0.0.1` 误认为其他容器。本地模式通过 `host.docker.internal` 将录制回调发送给本机 Django；不依赖宿主机网卡 IP 自动检测。两种模式同时启动带随机密码认证的 Coturn，通过本机 TCP 端口中继媒体，兼容 Windows Docker 的 UDP 转发限制。中继仅发布到 127.0.0.1，不向外网开放。

## 配置、数据与端口

根目录 `.env`、现有 `smart_meeting.db` 和已有开发环境不会被安装器覆盖。安装器的配置分别在 `.runtime/local.env` 和 `.runtime/docker.env`，包含随机密钥和管理员初始密码；整个 `.runtime/` 已忽略，不应提交或分享。

| 内容 | Docker | 本地 |
| --- | --- | --- |
| Web 端口 | 8080 | 8000 |
| LiveKit 信令端口 | 7880 | 7880 |
| LiveKit RTC TCP / UDP | 7881 / 7882 | 7881 / 7882 |
| TURN TCP 媒体中继 | 3478 | 3478 |
| Redis | 仅容器网络 | 仅容器网络 |
| 数据库 | Compose `meeting-data` 卷 | `.runtime/data/smart_meeting.db` |
| 录像 | `.runtime/recordings/` | `.runtime/recordings/` |

端口冲突时脚本会报错，不会结束占用端口的程序。自定义端口示例（两种脚本支持相同端口参数）：

```powershell
.\run-docker.ps1 --port 18080 --livekit-port 17880 --rtc-tcp-port 17881 --rtc-udp-port 17882 --turn-port 13478
.\run-local.ps1 --port 18000 --livekit-port 27880 --rtc-tcp-port 27881 --rtc-udp-port 27882 --turn-port 23478
```

```bash
bash run-docker.sh --port 18080 --livekit-port 17880 --rtc-tcp-port 17881 --rtc-udp-port 17882 --turn-port 13478
bash run-local.sh --port 18000 --livekit-port 27880 --rtc-tcp-port 27881 --rtc-udp-port 27882 --turn-port 23478
```

后续不传参数会复用之前保存的端口。两种模式共用网页构建产物与录像文件夹，各自有独立数据库；一般选择一种模式运行。

安装器生成变量的完整说明同步在 `.env.example`：`INSTALL_*` 为端口、节点 IP 和宿主机挂载参数；`DJANGO_SUPERUSER_*` 用于首次管理员创建；`RECORDING_STORAGE_ROOT` 为 Django 可见的录像存储路径。`SECRET_KEY`、LiveKit 密钥与 `TURN_PASSWORD` 自动随机生成；`INSTALL_TURN_PORT` 为本机中继 TCP 端口。

## 局域网与公网

Docker 发布端口和 Windows 本地 Web 均仅绑定 `127.0.0.1`，用于当前电脑的浏览器。Linux/macOS 本地 Web 监听 `0.0.0.0`，以接收 Docker 网关的录制回调；容器发布端口仍只绑定本机，Web 的允许主机名包含 localhost 与容器回调地址。用户浏览器仍使用上面的本机 URL。

本机浏览器的 `http://127.0.0.1` 可使用麦克风；从另一台设备访问时应配置 HTTPS/WSS、可信证书、正确的 LiveKit 媒体 IP 与防火墙。请按 [HTTPS 指南](./https-testing.md)、[LiveKit SSL 指南](./livekit-ssl-startup.md) 和 [部署说明](./deployment.md) 配置，不能直接把默认本机 URL 分享给他人。

Docker 构建只发送允许列表中的源码，排除 `.env`、数据库、密钥、录像、日志、SDK 和构建缓存。正式公网运行时还需按部署指南配置域名、可信证书、备份和进程资源。

## 验证命令

安装器与配置回归测试：

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s scripts/tests -p "test_*.py"
.\.venv\Scripts\python.exe manage.py test conference.test_bootstrap_admin conference.test_web_assets conference.tests.MeetingRecordingTests --verbosity 0
```

Windows 已实测 Docker 和本地模式的安装/启动、管理员登录、浏览器合成音频发布、录制开始/停止及 MP4 文件生成，并验证停止后数据库和录像保留。Linux/macOS Shell 入口已做语法检查，尚未在相应系统实机验证。
