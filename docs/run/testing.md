# 流程测试与验证范围

## 本机验收

使用虚构姓名、测试会议和合成音频，避免把真实参会者数据放入问题记录、截图或测试产物。完整操作顺序见 [README 流程测试](../../README.md#流程测试)。

安装后应验证：服务就绪、管理员登录、创建会议、入会、音视频、屏幕共享、聊天、主持人权限、录制开始和停止，以及重启后的账号和录像持久化。

多人及商业使用遵循标准 Apache-2.0，无需另行取得作者授权；默认安装面向当前电脑，跨设备需要另行配置 HTTPS/WSS、媒体 IP、可信证书与防火墙。

## 自动化命令

在项目根目录、已安装依赖的 Python 环境执行：

```bash
python -m unittest discover -s scripts/tests -p "test_*.py"
python manage.py test conference.test_bootstrap_admin conference.test_web_assets conference.tests.MeetingRecordingTests --verbosity 0
python scripts/release_audit.py
```

pip 安装包还需构建并检查真实分发文件，详见 [pip 安装与发布](./pip-install.md)；构建后同一脚本测试命令会额外校验 wheel / sdist 的入口、依赖、许可证、应用资源校验清单和私密文件排除。

Flutter Web 回归：

```bash
cd flutter_app
flutter pub get
flutter test
```

测试覆盖安装器配置隔离、随机凭据、重复启动、端口冲突、失败清理、构建缓存、Docker 服务及挂载关系、管理员初始化、网页资源、录制状态与权限，以及发布扫描和源码导出。扫描器测试使用构造的敏感样本，不含真实个人数据。

## 已执行的集成验证

在 Windows 上已实际运行 Docker 与本地两个安装入口，验证管理员登录、Flutter 网页资源加载、浏览器发布合成音频、Egress 开始和停止录制、MP4 文件头和大小，以及停止后的数据库、账号与录像保留。媒体链路包含本机 TCP TURN 中继。

这轮集成验证使用合成音频，不等同于完成真实摄像头、屏幕共享、多方会议、移动端、弱网或公网部署验收。上述场景仍应按部署环境测试。Linux/macOS Shell 入口已通过语法检查，尚未在对应系统实机运行。

测试产物、测试口令和本机日志不随源码发布。
