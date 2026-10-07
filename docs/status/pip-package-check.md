# pip 安装包验证

包名：`vibemeeting`；版本：`0.1.0`；Python：3.10–3.13；许可证：Apache-2.0。

`0.1.0` 已通过 GitHub Trusted Publishing 正式上传到 [PyPI](https://pypi.org/project/vibemeeting/0.1.0/)。[发布工作流](https://github.com/changkaiyan/vibemeeting/actions/runs/37633662371) 的构建、OIDC 上传、正式索引安装验证全部成功；GitHub 仓库按维护者要求保持私有。

## 实际执行的自动化检查

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s scripts/tests -p "test_*.py"
.\.venv\Scripts\python.exe scripts/release_audit.py
.\.runtime\package-build-venv\Scripts\python.exe -m build --no-isolation --outdir dist
.\.runtime\package-build-venv\Scripts\python.exe -m twine check --strict dist/vibemeeting-0.1.0-py3-none-any.whl dist/vibemeeting-0.1.0.tar.gz
```

51 项脚本测试通过，包括 9 项包启动 / 构建测试、3 项实际分发文件测试、3 项发布工作流测试和 1 项可选 STT 依赖隔离测试。wheel 和 sdist 均通过 Twine 严格检查；正常构建流程从 sdist 生成 wheel，确认预编译网页可以随源码分发安装。

在仅安装 wheel 声明依赖的干净环境执行：

```powershell
.\.runtime\pip-smoke-venv\Scripts\python.exe manage.py test conference.test_bootstrap_admin conference.test_web_assets conference.tests.MeetingRecordingTests --verbosity 0
.\.runtime\actionlint\actionlint.exe -shellcheck='' .github/workflows/publish-pypi.yml
```

31 项后端测试通过；工作流通过 actionlint 1.7.12 语法检查。录制测试不再在导入阶段加载可选 STT worker；语音识别的真实 worker 测试仍需安装该服务自己的依赖。GitHub `pypi` 环境仅允许 `v*` 标签部署，PyPI Trusted Publisher 已完成首次上传。

实际录像回看发现 Egress 时长单位为纳秒（[LiveKit API](https://docs.livekit.io/reference/other/egress/api/)），已补充失败回归后转换为秒，并通过 `0023` 数据迁移修复旧 Egress 录像时长，保留手动上传录像的秒数。

版权署名覆盖登录 / 注册页、控制台页脚和会议分享弹窗。先执行新增测试确认失败，再实现界面；完整 Flutter 测试 111 项通过，覆盖统一品牌名称、Logo 与版权页脚：

```powershell
cd flutter_app
..\tools\flutter\bin\flutter.bat test
..\tools\flutter\bin\flutter.bat test test/app_entry_test.dart test/copyright_notice_test.dart
```

组件测试覆盖窄屏、两倍文字缩放和深浅主题，并确认会议页面不会因版权页脚缩小舞台。

网页入口缓存版本的 3 项回归测试也通过：

```bash
node --test scripts/tests/flutter_bootstrap.test.cjs
```

## 正式 PyPI 安装复测

使用全新的 Windows 虚拟环境，仅从正式索引安装，不复用本地 wheel 或 pip 缓存：

```bash
python -m pip --isolated install --disable-pip-version-check --no-cache-dir --progress-bar off --timeout 120 --retries 3 --index-url https://pypi.org/simple vibemeeting==0.1.0
```

首次下载遇到网络读取超时，延长超时后的重试成功。随后切换到仓库外目录，使用此环境的入口执行以下命令，全部返回成功：

```bash
vibemeeting --version
vibemeeting --prepare-only --data-dir <TEST_DATA_DIR>
vibemeeting info --data-dir <TEST_DATA_DIR>
```

版本输出为 `vibemeeting 0.1.0`。GitHub 发布工作流也在独立 Linux 环境中完成正式 PyPI 安装和初始化。完整 GitHub 仓库继续保持私有；发布包不包含其 Git 历史。

## 干净环境安装与实际运行

```powershell
.\.venv\Scripts\python.exe -m venv .runtime/pip-smoke-venv
.\.runtime\pip-smoke-venv\Scripts\python.exe -m pip install --disable-pip-version-check --progress-bar off .\dist\vibemeeting-0.1.0-py3-none-any.whl
```

之后切换到仓库外的临时目录，使用该虚拟环境中的 `vibemeeting` 可执行入口，指定独立数据目录运行：

```bash
vibemeeting --version
vibemeeting --prepare-only --data-dir <TEST_DATA_DIR> --port 38000 --livekit-port 37880 --rtc-tcp-port 37891 --rtc-udp-port 37882 --turn-port 33478
vibemeeting info --data-dir <TEST_DATA_DIR>
vibemeeting --data-dir <TEST_DATA_DIR>
```

上面的数据目录为脱敏占位符，实际使用项目内被忽略的独立测试目录。实际安装后的入口完成了：

- 加载包内应用与编译好的网页，不安装 Flutter / Git，也不创建第二个 Python 虚拟环境。
- 数据库迁移、随机管理员和录像路径初始化。
- `/healthz`、Flutter 主脚本加载、管理员 API 登录、创建会议及获取参会 Token。
- Windows 无头 Chrome 发布合成音频，媒体连接成功。
- 通过 Django 会议接口启动 / 停止 Egress，生成 MP4（实测 112470 字节）。
- 使用已登录用户的鉴权请求下载录像，文件与磁盘内容一致。
- 同数据目录的并发启动被拒绝。
- Ctrl+C 停止本次 Web 与媒体、录制服务，保留数据库、配置与录像。

测试没有访问真实麦克风、摄像头或个人参会数据。Linux 的构建、包入口及正式 PyPI 安装初始化已由发布工作流验证。Linux/macOS 的媒体运行尚未实机验收。
