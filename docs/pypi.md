# VibeMeeting · 开源在线会议

可自行部署的网页会议系统，支持音视频、屏幕共享、文字聊天、主持人控制与 MP4 会议录制。基于 Django、Flutter Web 和 LiveKit，采用标准 Apache-2.0 许可证。

## 安装与运行

v0.1.2 改进会议控制台和计费管理布局：设置入口集中在顶部，通过弹窗配置；小窗口下列表保持可用高度，页面可以上下滚动。

需要 Python 3.10–3.13 和已启动的 Docker（Linux 容器、Compose v2.20+）。安装包已包含编译后的网页，无需另装 Flutter 或 Git。

```bash
pip install vibemeeting
vibemeeting
```

浏览器打开 `http://127.0.0.1:8000`。管理员用户名 `admin`，随机初始密码查看用户主目录下 `.vibemeeting/.runtime/local.env` 的 `DJANGO_SUPERUSER_PASSWORD`。默认数据目录为 `~/.vibemeeting`，可通过 `--data-dir` 指定。

```bash
vibemeeting --help
vibemeeting --version
vibemeeting --port 18000 --data-dir ./meeting-data
vibemeeting info --data-dir ./meeting-data
```

v0.1.1 支持指定监听和媒体地址：

```bash
vibemeeting --host 0.0.0.0 --port 8000
```

远程会议可进一步指定 `--public-url https://meeting.example.com`、`--livekit-public-url wss://rtc.example.com` 和 `--livekit-node-ip <服务器可达IPv4>`；`--livekit-url` 用于后端 API 地址，`--turn-host` 用于 TURN 地址。地址设置会持久保存。HTTPS/WSS 代理、证书与媒体网络需在部署环境配置。

主程序前台运行，按 Ctrl+C 停止本次创建的音视频和录制服务；账号、数据库、录像会保留。首次启动会下载官方 LiveKit、Redis、TURN 和 Egress 镜像。会议录制服务一起启动，具体会议由主持人开始和停止录制。

默认地址仅供当前电脑浏览器使用。跨设备访问需要配置 HTTPS/WSS 和媒体网络。可选语音转写与 Agent 服务需要另外配置。

0.1.3 修复浏览器缺少媒体采集接口时的会议初始化崩溃。HTTP 下按实际浏览器能力运行：接口可用时正常采集，接口缺失时跳过采集并继续尝试入会；浏览器本身的音视频权限限制仍然适用。

0.1.4 修复远程部署的媒体连接：指定非回环 `--livekit-node-ip` 时，关闭 LiveKit 回环候选并让 TURN 自动选择容器中继接口，避免信令成功但媒体连接反复失败。本机回环部署保持原有行为。

详细文档、开发源码、使用限制和反馈入口见 [GitHub 仓库](https://github.com/changkaiyan/vibemeeting)。
