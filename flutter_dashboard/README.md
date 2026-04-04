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

如果要将 Flutter 构建产物接入 Django：

```bash
flutter build web
```

然后将 `build/web` 内容部署到 Django 静态资源目录并配置路由。

