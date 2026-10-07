# VibeMeeting · 智能会议

可自行部署的网页会议系统，支持音视频、屏幕共享、文字聊天、主持人控制与 MP4 会议录制。基于 Django、Flutter Web 和 LiveKit，采用标准 Apache-2.0 许可证。

## 安装与运行

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

主程序前台运行，按 Ctrl+C 停止本次创建的音视频和录制服务；账号、数据库、录像会保留。首次启动会下载官方 LiveKit、Redis、TURN 和 Egress 镜像。会议录制服务一起启动，具体会议由主持人开始和停止录制。

默认地址仅供当前电脑浏览器使用。跨设备访问需要配置 HTTPS/WSS 和媒体网络。可选语音转写与 Agent 服务需要另外配置。

详细文档、开发源码、使用限制和反馈入口见 [GitHub 仓库](https://github.com/changkaiyan/vibemeeting)。
