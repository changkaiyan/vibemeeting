# 远程媒体连接修复

远程部署虽然信令及鉴权成功，但 LiveKit 始终无法建立 ICE 连接，后续重连出现 `could not restart participant`。TURN 使用固定回环中继时同时出现 `udp send: Invalid argument`。

修复包含两部分：非回环 node_ip 下让 coturn 使用默认中继接口选择；关闭 LiveKit enable_loopback_candidate，避免将回环接口候选映射成外部地址。本机回环部署保留原行为。没有新增环境变量或暴露额外端口。

TDD：先为两种安装模式添加远程和回环配置回归测试，两次分别确认旧配置失败，再修改生成逻辑。

验证：

- `python -m unittest scripts.tests.test_launcher scripts.tests.test_compose_config`：19 项通过。
- `python -m unittest discover -s scripts/tests`：60 项通过。
- Linux Docker 实际验证：备份配置后重启媒体服务，TURN 不再出现 UDP Invalid argument；LiveKit 记录 participant active 和选中的 ICE 候选。
- HTTP 浏览器实际验证：关闭本地采集入会，页面显示“网络：优秀 · 已加入会议”。本次未验证真实麦克风采集或新录制任务。

配置修复随 0.1.4 安装包分发，升级并重新启动会按保存的网络参数重新生成配置。
