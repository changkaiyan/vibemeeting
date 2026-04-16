# Flutter App (Web)

该目录是会议控制台的 Flutter Web 源码。

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

## Native Android APK Build

From repository root:

```powershell
.\scripts\build_flutter_android.ps1 -Mode Release -AndroidSdkPath "D:\Android\Sdk"
```

Debug build:

```powershell
.\scripts\build_flutter_android.ps1 -Mode Debug -AndroidSdkPath "D:\Android\Sdk"
```

Dry run (print commands only):

```powershell
.\scripts\build_flutter_android.ps1 -Mode Release -AndroidSdkPath "D:\Android\Sdk" -DryRun
```

Output APK:

- Release: `flutter_app\build\app\outputs\flutter-apk\app-release.apk`
- Debug: `flutter_app\build\app\outputs\flutter-apk\app-debug.apk`

Note: if `flutter_app\android` is missing, the script auto-runs `puro flutter create --platforms=android .` before building.
Note: Android native build targets `lib/main_windows.dart`.
Note: when project path contains non-ASCII chars on Windows, the script auto-uses `subst X:` during build.
