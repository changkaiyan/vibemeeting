# Flutter Windows Launcher

This project includes a Windows-only Flutter launcher entry:

- `flutter_app/lib/main_windows.dart`

The Windows app uses native Flutter pages for:

- login
- meeting list
- meeting join flow
- in-app meeting room (LiveKit)

The existing Web pages remain in the project for browser access and are not
required by the Windows client runtime.

## Build

From repository root:

```powershell
.\scripts\build_flutter_windows.ps1 -Mode Debug
```

Or directly:

```powershell
cd flutter_app
puro flutter build windows --debug --target lib/main_windows.dart
```

Output executable:

- `flutter_app\build\windows\x64\runner\Debug\smart_meeting_app.exe`

## Release Build Note

In some Windows environments, `release` build fails when the project path
contains non-ASCII characters (for example Chinese folder names), with:

- `Unable to read file ... app.dill`

This repository includes an automatic workaround in
`scripts/build_flutter_windows.ps1`: when `-Mode Release` is used under a
non-ASCII path, it temporarily maps the project to `X:` via `subst` and then
builds from the mapped path.

Use:

```powershell
.\scripts\build_flutter_windows.ps1 -Mode Release
```

Manual equivalent:

```powershell
subst X: D:\2026综合事务\智能会议
cd X:\flutter_app
puro flutter build windows --release --target lib/main_windows.dart
subst X: /d
```
