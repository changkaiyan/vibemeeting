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

## Remote Desktop Control

The native meeting room supports remote desktop control over LiveKit data
channel. Controllers can be either:

- Web meeting page participant
- Native Windows participant

The target participant must use the native Windows client.

### Approval And Visibility Rule

To avoid "blind control", the target side now enforces a visibility-first
flow:

1. Controller sends `request_remote_control` from member menu.
2. Target receives a confirmation dialog.
3. If target clicks allow, target must complete screen-share source selection
   first.
4. Only after screen share is active does target send approved response.
5. Controller auto-focuses target tile and uses target screen stream as the
   primary remote-control view.

If source selection is canceled, permission denied, or source is unavailable,
the request is rejected with `target_screen_share_unavailable`.

### Session Controls

- Controller can stop session from tile overlay (`结束控制`).
- Target can stop session from top action (`结束被控`).
- Either side can terminate, and both clients clear remote-control state.

### Current Constraints

- Web target is not supported (`web_target_unsupported`).
- If target is in another active control session, new request is rejected
  (`target_busy`).
- Remote control requires data publish permission and both participants online.
- Keyboard/mouse injection is implemented in native Windows client.
- Detailed cross-client behavior doc:
  - `docs/run/remote-desktop-control.md`

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
