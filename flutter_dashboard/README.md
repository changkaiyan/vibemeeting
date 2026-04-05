# Flutter Dashboard (Web)

该目录是会议控制台的 Flutter Web 重构骨架。

## 前置条件

- 已安装 Flutter SDK（建议 3.24+）

## 运行

```bash
cd flutter_dashboard
flutter pub get
flutter run -d chrome
```

默认 API 地址写在 `lib/main.dart`：

`baseUrl = http://127.0.0.1:8000`

如需联调远程环境，请修改该常量。

## 与 Django 集成（可选）

如果要将 Flutter 构建产物接入 Django，请在仓库根目录执行：

```bash
./scripts/build_flutter_dashboard.sh
```

脚本会把 `build/web` 同步到 `artifacts/flutter_dashboard_web/`。

注意：

- `flutter_dashboard/` 是源码目录
- `artifacts/flutter_dashboard_web/` 是生成产物目录
- 不要手改 `artifacts/flutter_dashboard_web/` 下的文件
