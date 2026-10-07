# 控制台与计费管理布局验证

会议控制台和计费管理原先把资料、录制存储或登录设置放在固定高度列表上方，小窗口中列表被挤压，外层又无法滚动。

现在设置入口集中在页面顶部，点击打开可滚动弹窗。会议、套餐和用户列表保留可用高度；较窄页面纵向排列，整页和列表均可滚动。关闭设置后保留列表位置，保存或刷新会同步更新弹窗内容。会议控制台标题栏和快捷操作文案也作了精简。

## 自动化

在 `flutter_app` 目录执行：

```bash
flutter test test/dashboard_content_test.dart
flutter test
flutter analyze lib/app/widgets/scrollable_panels.dart lib/features/dashboard/page.dart lib/features/billing/page.dart
flutter build web --no-pub --no-wasm-dry-run
```

先添加失败测试，再修改布局。最终 4 项布局回归和全部 115 项 Flutter 测试通过；Web 编译通过。测试覆盖短窗口、窄窗口、顶部入口可见、列表滚动、弹窗底部可达、关闭后列表位置保持及弹窗数据刷新。相关页面静态分析仍有既有废弃 API、未使用声明等提示，无编译错误。

使用独立数据库、虚构管理员及 12 个虚构会议/套餐进行浏览器检查，覆盖桌面低高度和手机宽度；没有读取或修改真实会议、账号、计费策略和登录开关。

## PyPI 发布

修复已随 [v0.1.2](https://pypi.org/project/vibemeeting/0.1.2/) 发布。[发布工作流](https://github.com/changkaiyan/vibemeeting/actions/runs/37647801170) 的构建、上传和正式源安装验证全部通过。本机从官方索引升级、版本检查及独立数据目录初始化成功：

```bash
python -m pip --isolated install --upgrade --no-cache-dir --timeout 120 --index-url https://pypi.org/simple vibemeeting==0.1.2
vibemeeting --version
vibemeeting --prepare-only --data-dir ./pypi-012-official-data --host 0.0.0.0 --public-url https://meeting.example.com --livekit-public-url wss://rtc.example.com
```

用户升级后应使用原数据目录和启动参数重启服务，并刷新浏览器以加载新版网页。
