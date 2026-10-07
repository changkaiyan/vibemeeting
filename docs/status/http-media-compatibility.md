# HTTP 媒体接口兼容验证

修复的是浏览器缺少 `navigator.mediaDevices` 时，WebRTC 设备监听注册及枚举抛错、阻止 LiveKit Room 初始化的问题。判断依据是实际接口能力，不是 HTTP/HTTPS 协议。接口可用时保留用户的麦克风、摄像头选择；缺少接口时跳过采集权限请求并继续尝试连接。

## 回归验证

- `flutter test --reporter compact`：118 项通过（浏览器专用测试不在 VM 中运行）。
- `python -m unittest discover -s scripts/tests`：59 项通过，包含 vendor 改动失效构建缓存与 Docker 本地依赖测试。
- `dart compile js test_support/media_devices_probe.dart -o <输出目录>/probe.js`：在 HTTP 浏览器页面执行，缺失接口监听、空设备列表、采集继续拒绝、正常接口监听四项断言全部通过。
- `flutter build web --release --no-pub --no-wasm-dry-run --target test_support/room_initialization_probe.dart --output <绝对输出目录>`：HTTP 浏览器页面验证 LiveKit Room 初始化、设备枚举和释放通过。

浏览器测试入口为 `flutter test --platform chrome test/media_devices_browser_test.dart`。本机 Flutter 浏览器测试运行器停在加载阶段（已有最小测试也如此），因此本次使用上述独立编译的浏览器断言入口完成 SDK 验证。

本次未完成真实跨设备、LiveKit 信令及媒体网络的端到端验证。初始化兼容不代表所有浏览器均允许非安全来源音视频；采集权限及可用性仍由浏览器决定，不伪造媒体接口或绕过权限。真实部署仍需确保 LiveKit 地址及网络可达。

补丁基于 dart_webrtc 1.8.1，源码及 MIT 声明位于 `flutter_app/vendor/dart_webrtc`。升级上游时需重新运行浏览器断言；上游解决同类问题后可移除路径覆盖。
