# v0.1.1 网络参数验证

新增 `--host`、`--public-url`、`--livekit-url`、`--livekit-public-url`、`--livekit-node-ip`、`--turn-host`、`--allowed-hosts` 和 `--csrf-trusted-origins`。pip 与源码启动入口均支持，配置按数据目录保存。

## 自动化验证

先添加失败测试，再实现参数转发、地址校验、配置持久化和 Compose 端口绑定。

```bash
python -m unittest discover -s scripts/tests -p 'test_*.py'
python manage.py test conference.test_bootstrap_admin conference.test_web_assets conference.tests.MeetingRecordingTests --verbosity 0
python scripts/release_audit.py
python -m build --no-isolation
python -m twine check --strict dist/vibemeeting-0.1.1-py3-none-any.whl dist/vibemeeting-0.1.1.tar.gz
```

结果：脚本与实际分发文件测试 57 项通过，后端与录制回归 31 项通过；当前源码隐私扫描无发现，wheel 与 sdist 检查通过。

覆盖参数转发、配置重用、端口变化、具体接口地址、非法地址拒绝且保留原配置、两种 Compose 的监听接口，以及分发文件完整性和运行数据排除。

## Windows 实际启动

将 v0.1.1 wheel 安装到独立虚拟环境，从仓库外启动独立数据目录：

```bash
vibemeeting --data-dir ./network-smoke-data --host 0.0.0.0 --port 39000 --livekit-port 38880 --rtc-tcp-port 38881 --rtc-udp-port 38882 --turn-port 33479 --public-url http://localhost:39000
```

验证结果：Web 实际监听 `0.0.0.0:39000`；健康检查与登录页返回 HTTP 200；四个 Docker 媒体端口均绑定 `0.0.0.0`；LiveKit、Redis、TURN、Egress 就绪。Ctrl+C 仅停止该实例的服务，数据保留。

本轮未验证跨机器摄像头/麦克风、公网 NAT、真实域名证书或外部 LiveKit 集群。地址参数不会自动配置 HTTPS/WSS 代理、防火墙和路由器，部署者仍需按自身网络完成这些设置。

## 正式 PyPI 安装

v0.1.1 已由 [GitHub Actions](https://github.com/changkaiyan/vibemeeting/actions/runs/37642839941) 上传至 [PyPI](https://pypi.org/project/vibemeeting/0.1.1/)。从仓库外执行以下命令，确认版本号、参数帮助和独立配置初始化成功：

```bash
python -m pip --isolated install --upgrade --no-cache-dir --timeout 120 --index-url https://pypi.org/simple vibemeeting==0.1.1
vibemeeting --version
vibemeeting --help
vibemeeting --prepare-only --data-dir ./pypi-011-official-data --host 0.0.0.0 --public-url https://meeting.example.com --livekit-public-url wss://rtc.example.com --livekit-node-ip 192.0.2.10 --turn-host turn.example.com
```
