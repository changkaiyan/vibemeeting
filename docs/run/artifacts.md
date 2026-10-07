# Build Artifacts

`artifacts/` is reserved for generated outputs that are needed locally at runtime but should not be treated as hand-edited source code.

Current usage:

- `artifacts/flutter_app_web/`
  - Flutter Web build output consumed by Django static serving
  - Generated from the source project in [`flutter_app/`](../../flutter_app)

Django uses only `artifacts/flutter_app_web/` for the Flutter Web bundle.
The retired `flutter_dashboard/` project residues and the old
`app/static/flutter_app/` bundle have been removed. If the current bundle is
missing, rebuild and copy it as described below; there is no fallback bundle.
Keep the handwritten assets directly under `app/static/` and the collected
deployment files under `staticfiles/`.

Do not edit files under `artifacts/flutter_app_web/` manually.
Regenerate them from the Flutter source project with:

```bash
cd flutter_app
flutter pub get
flutter build web
```

Then copy the contents of `flutter_app/build/web/` into `artifacts/flutter_app_web/`.
