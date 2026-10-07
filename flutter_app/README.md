# 智能会议网页客户端

此目录只维护 Flutter Web 客户端，桌面和手机均通过浏览器访问。

## 开发

```bash
flutter pub get
flutter run -d chrome
```

## 测试与构建

```bash
flutter test
flutter build web
```

构建后将 `build/web/` 同步到项目根目录的 `artifacts/flutter_app_web/`，
再运行 `python manage.py collectstatic --noinput`。

前端请求同源 Django API。完整说明见 [Flutter Web 文档](../docs/run/flutter-app.md)。
