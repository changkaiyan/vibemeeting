# Build Artifacts

`artifacts/` is reserved for generated outputs that are needed locally at runtime but should not be treated as hand-edited source code.

Current usage:

- `artifacts/flutter_app_web/`
  - Flutter Web build output consumed by Django static serving
  - Generated from the source project in [`flutter_app/`](../flutter_app)

Do not edit files under `artifacts/flutter_app_web/` manually.
Regenerate them from the Flutter source project with:

```bash
cd flutter_app
flutter pub get
flutter build web
```

Then copy the contents of `flutter_app/build/web/` into `artifacts/flutter_app_web/`.
