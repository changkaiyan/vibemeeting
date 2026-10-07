# pip 安装、运行与发布

## 用户安装

需要 Python 3.10–3.13 和已启动的 Docker，Docker 使用 Linux 容器并提供 Compose v2.20+。安装包已经包含 Django 应用、模板、静态资源和 Flutter Web 编译产物，无需 Git 或 Flutter SDK。

`vibemeeting 0.1.0` 已发布到 [PyPI](https://pypi.org/project/vibemeeting/0.1.0/)，使用：

```bash
pip install vibemeeting
vibemeeting
```

建议在独立 Python 虚拟环境中安装，避免与其他应用的依赖冲突。也可以安装已经下载的分发文件：

```bash
pip install ./dist/vibemeeting-0.1.0-py3-none-any.whl
vibemeeting
```

如果操作系统找不到命令，使用同一个 Python 的模块入口：

```bash
python -m vibemeeting
```

启动时自动初始化配置、随机管理员口令、数据库和录像目录，再启动 Django 与 LiveKit、Redis、TURN、Egress。首次运行会拉取官方 Docker 镜像。主程序前台运行，按 Ctrl+C 停止本次创建的服务。

默认访问 `http://127.0.0.1:8000/accounts/login`，用户名 `admin`，初始密码查看下面的数据目录中的 `.runtime/local.env`。账号密码修改后不会被后续启动重置。

## 命令与持久化

### v0.1.1：监听地址与远程访问

升级后，Windows / Linux / macOS 均可指定 IPv4 监听地址：

```bash
pip install --upgrade vibemeeting
vibemeeting --host 0.0.0.0 --port 8000
```

`0.0.0.0` 是监听地址，浏览器应访问服务器的实际 IP 或域名。该选项同时控制配套 Docker 媒体端口的宿主机监听接口。

已配置 HTTPS / WSS 反向代理的团队部署示例：

```bash
vibemeeting --host 0.0.0.0 --port 8000 \
  --public-url https://meeting.example.com \
  --livekit-url ws://127.0.0.1:7880 \
  --livekit-public-url wss://rtc.example.com \
  --livekit-node-ip 192.0.2.10 \
  --turn-host turn.example.com
```

PowerShell 可将上面的命令写在一行。域名和 `192.0.2.10` 均为示例，请替换成部署环境中可达的地址。

| 参数 | 用途 |
| --- | --- |
| `--host` | Web 与配套媒体端口的监听 IPv4 地址，支持 `0.0.0.0` |
| `--public-url` | 用户访问网页的 HTTP/HTTPS origin，自动加入 Host 与 CSRF 配置 |
| `--livekit-url` | Django 后端调用 LiveKit API 的 WS/WSS 地址 |
| `--livekit-public-url` | 浏览器连接 LiveKit 的 WS/WSS 地址；HTTPS 页面应使用 WSS |
| `--livekit-node-ip` | 配套 LiveKit 公告给客户端的可达 IPv4 地址，不能为 `0.0.0.0` |
| `--turn-host` | 配套 TURN 的可达域名或 IPv4 地址；默认使用媒体 IP |
| `--allowed-hosts` | 额外允许的主机名，以逗号分隔 |
| `--csrf-trusted-origins` | 额外信任的 HTTP/HTTPS origin，以逗号分隔 |

参数保存在当前数据目录，后续直接执行 `vibemeeting` 会复用，再次传入可更新。`--prepare-only` 可先验证并生成配置。已有账号、密钥和录像保留。

这些参数不会自动申请证书、创建反向代理或配置路由器。网页 HTTPS 代理指向 Web 端口，WSS 代理指向 LiveKit 信令端口；媒体 TCP/UDP 与 TURN TCP 端口还需按实际网络放行。远程浏览器的摄像头、麦克风和屏幕共享需要可信 HTTPS。详见 [HTTPS 指南](./https-testing.md)。

默认仍启动配套 LiveKit、Redis、TURN 和 Egress。`--livekit-url` 只修改后端 API 目标，不会切换为外部媒体服务模式；若指向独立 LiveKit，需自行匹配该服务的 API 凭据、Redis/Egress 和回调配置。常规安装请保留本机后端地址，只设置浏览器公开地址和媒体 IP。

```bash
vibemeeting --help
vibemeeting --version
vibemeeting info
vibemeeting --prepare-only
vibemeeting --port 18000 --livekit-port 17880 --rtc-tcp-port 17881 --rtc-udp-port 17882 --turn-port 13478
vibemeeting --data-dir ./meeting-data
```

`vibemeeting` 等同于 `vibemeeting run`。`info` 只显示访问地址、管理员名和口令文件位置，不显示密码。`--prepare-only` 初始化文件与随机凭据，不启动 Docker 或 Web 服务。

默认目录是用户主目录下的 `.vibemeeting`；可通过 `--data-dir` 修改。再次启动或查看信息时，必须使用同一个目录。

| 目录内容 | 用途 |
| --- | --- |
| `.runtime/local.env` | 私密配置及管理员初始密码 |
| `.runtime/data/smart_meeting.db` | 数据库 |
| `.runtime/recordings/` | MP4 录像 |
| `.runtime/logs/` | Web 日志 |
| 其他应用文件 | 由 Python 包管理的应用代码与网页 |

每个数据目录有独立的 Docker Compose 项目名和进程锁，避免重复启动或误停其他数据目录的容器；同时运行多个实例还需为它们指定不同端口。首次运行拒绝覆盖非空、非 VibeMeeting 管理的目录。

升级前停止正在运行的实例，备份 `.runtime/`，然后执行：

```bash
pip install --upgrade vibemeeting
vibemeeting
```

新包替换其管理的应用文件并迁移数据库，保留配置、账号、日志与录像。不要直接修改数据目录中的受管理源码；定制开发请使用源码仓库。卸载 Python 包不会自动删除用户数据目录。

默认面向当前电脑浏览器，跨设备访问仍需按 [HTTPS 指南](./https-testing.md) 和 [部署说明](./deployment.md) 配置媒体网络。

## 维护者构建

从完整源码构建需要 Python、Git 和 Flutter（可复用项目 SDK，也可由构建器自动安装）。先执行隐私扫描和测试，再构建：

```bash
python -m unittest discover -s scripts/tests -p "test_*.py"
python scripts/release_audit.py
python -m pip install -r requirements.txt -r requirements-dev.txt
python -m build
python -m twine check --strict dist/vibemeeting-0.1.0-py3-none-any.whl dist/vibemeeting-0.1.0.tar.gz
```

构建器仅从允许的应用源码和网页资源生成包，不读取 `.env`、`.runtime/`、数据库、录像、证书或日志。网页源文件发生变化时重新构建 Flutter；wheel 和 sdist 均带有文件校验清单。sdist 内已经包含预编译网页，从该 sdist 构建 wheel 无需 Flutter 或原始仓库。

Python 版本范围与当前固定的 Django 5.2.2 一致。Python 3.14 支持需要先升级并验证 Django 和其他依赖；Django 直到 5.2.8 才加入 Python 3.14 支持，见 [官方发布说明](https://docs.djangoproject.com/en/5.2/releases/5.2.8/)。

## PyPI 发布

当前包名 `vibemeeting`，版本 `0.1.0`。仓库使用 [GitHub Actions 工作流](../../.github/workflows/publish-pypi.yml) 和 [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/)，通过 OIDC 身份发布，无需保存 PyPI Token。

首次发布前，在 PyPI 账号的 Publishing 页面添加 pending publisher；已有项目则在该项目的 Publishing 页面添加：

| 字段 | 值 |
| --- | --- |
| PyPI Project Name | `vibemeeting` |
| Owner | `changkaiyan` |
| Repository name | `vibemeeting` |
| Workflow name | `publish-pypi.yml` |
| Environment name | `pypi` |

GitHub 仓库创建 `pypi` environment，仅允许 `v*` 标签部署。工作流文件名与环境名必须和 PyPI 设置一致；pending publisher 不预留包名，首次成功上传后才创建项目。见 [PyPI 首次项目发布说明](https://docs.pypi.org/trusted-publishers/creating-a-project-through-oidc/)。

在 GitHub Actions 手动执行该工作流，保持 `publish=false`，可验证构建而不上传。正式发布时：

1. 确认 `pyproject.toml` 与 `vibemeeting/__init__.py` 版本一致。
2. 将审查后的源码提交至仓库，创建对应版本标签，例如 `v0.1.0`。
3. 基于该标签发布 GitHub Release，自动触发构建、隐私扫描、测试、分发文件检查和安装验证。
4. 检查通过后，独立发布任务获得 OIDC 权限，上传 wheel、sdist 与来源证明；随后自动从正式 PyPI 安装指定版本并检查入口。

标签必须与包版本完全匹配，分支和不一致的版本不能上传。发布权限只授予发布任务，构建任务不持有该权限。PyPI 的已发布版本文件不可原地覆盖；修复后应增加版本号。实际从正式索引安装通过后，再将 README 的发布状态改为已发布。
