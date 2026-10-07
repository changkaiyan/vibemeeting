# Flutter App (Web)

该目录是会议控制台的 Flutter Web 源码。当前仅维护浏览器客户端，适用于桌面和手机浏览器。原生安装包和远程桌面控制已废弃。

当前主要结构：

- `lib/app/`
  - 应用壳、入口分发、路由解析
- `lib/core/`
  - 跨 feature 共享的基础能力
- `lib/features/dashboard/`
  - 会议控制台主页
- `lib/features/billing/`
  - 超级管理员计费与登录策略页面
- `lib/meeting_room/`
  - 会议房间页及其子模块

## 前置条件

- 已安装 Flutter SDK（建议 3.24+）

## 运行

```bash
cd flutter_app
flutter pub get
flutter run -d chrome
```

当前前端默认通过 `Uri.base.resolve(...)` 访问与页面同源的 Django API，
入口代码已不再维护单独的 `baseUrl` 常量。

会议室顶部默认使用紧凑工具栏。点击右侧箭头可展开或收起会议号、参会统计和状态信息；分享、音视频设置、更多操作与录制指示始终可用。手机端的舞台、成员和聊天标签使用单行布局，以增加舞台可用高度。

如果你联调本地 Django，请确保页面本身就是从 Django 提供的地址打开。

## 与 Django 集成（可选）

如果要将 Flutter 构建产物接入 Django：

```bash
cd flutter_app
flutter pub get
flutter build web
```

然后将 `build/web` 内容同步到 `../artifacts/flutter_app_web/`：

```bash
rsync -av --delete build/web/ ../artifacts/flutter_app_web/
```

注意：

- `flutter_app/` 是源码目录
- `artifacts/flutter_app_web/` 是生成产物目录
- 不要手改 `artifacts/flutter_app_web/` 下的文件
- Flutter package 名为 `smart_meeting_app`
