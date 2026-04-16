import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class NativeWindowFullscreenController {
  int _windowHandle = 0;
  int _windowStyle = 0;
  int _windowExStyle = 0;
  _SavedWindowPlacement? _savedPlacement;

  bool get isSystemFullscreenActive => _windowHandle != 0;

  bool enterSystemFullscreen() {
    final hwnd = _resolveCurrentWindowHandle();
    if (hwnd == 0) return false;
    if (_windowHandle == hwnd) return true;
    if (_windowHandle != 0) {
      exitSystemFullscreen();
    }

    final placement = calloc<WINDOWPLACEMENT>();
    final monitorInfo = calloc<MONITORINFO>();
    try {
      placement.ref.length = sizeOf<WINDOWPLACEMENT>();
      if (GetWindowPlacement(hwnd, placement) == 0) return false;
      final monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (monitor == 0) return false;
      monitorInfo.ref.cbSize = sizeOf<MONITORINFO>();
      if (GetMonitorInfo(monitor, monitorInfo) == 0) return false;

      _windowHandle = hwnd;
      _windowStyle = GetWindowLongPtr(hwnd, GWL_STYLE);
      _windowExStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
      _savedPlacement = _SavedWindowPlacement.fromNative(placement.ref);

      final monitorRect = monitorInfo.ref.rcMonitor;
      final nextStyle = _windowStyle &
          ~(WS_CAPTION |
              WS_THICKFRAME |
              WS_MINIMIZE |
              WS_MAXIMIZE |
              WS_SYSMENU);
      final nextExStyle = _windowExStyle &
          ~(WS_EX_DLGMODALFRAME |
              WS_EX_WINDOWEDGE |
              WS_EX_CLIENTEDGE |
              WS_EX_STATICEDGE);

      SetWindowLongPtr(hwnd, GWL_STYLE, nextStyle);
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, nextExStyle);
      SetWindowPos(
        hwnd,
        HWND_TOP,
        monitorRect.left,
        monitorRect.top,
        monitorRect.right - monitorRect.left,
        monitorRect.bottom - monitorRect.top,
        SWP_FRAMECHANGED,
      );
      ShowWindow(hwnd, SW_SHOWMAXIMIZED);
      return true;
    } finally {
      free(monitorInfo);
      free(placement);
    }
  }

  bool exitSystemFullscreen() {
    final hwnd = _windowHandle;
    final savedPlacement = _savedPlacement;
    if (hwnd == 0 || savedPlacement == null) return false;

    final placement = calloc<WINDOWPLACEMENT>();
    try {
      SetWindowLongPtr(hwnd, GWL_STYLE, _windowStyle);
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, _windowExStyle);

      placement.ref
        ..length = sizeOf<WINDOWPLACEMENT>()
        ..flags = savedPlacement.flags
        ..showCmd = savedPlacement.showCmd
        ..ptMinPosition.x = savedPlacement.ptMinPositionX
        ..ptMinPosition.y = savedPlacement.ptMinPositionY
        ..ptMaxPosition.x = savedPlacement.ptMaxPositionX
        ..ptMaxPosition.y = savedPlacement.ptMaxPositionY
        ..rcNormalPosition.left = savedPlacement.left
        ..rcNormalPosition.top = savedPlacement.top
        ..rcNormalPosition.right = savedPlacement.right
        ..rcNormalPosition.bottom = savedPlacement.bottom;
      SetWindowPlacement(hwnd, placement);
      SetWindowPos(
        hwnd,
        0,
        0,
        0,
        0,
        0,
        SWP_NOMOVE |
            SWP_NOSIZE |
            SWP_NOZORDER |
            SWP_NOOWNERZORDER |
            SWP_FRAMECHANGED,
      );
      ShowWindow(hwnd, SW_SHOWNORMAL);
      return true;
    } finally {
      _windowHandle = 0;
      _windowStyle = 0;
      _windowExStyle = 0;
      _savedPlacement = null;
      free(placement);
    }
  }

  int _resolveCurrentWindowHandle() {
    var hwnd = GetForegroundWindow();
    if (hwnd == 0) {
      hwnd = GetActiveWindow();
    }
    if (hwnd == 0) return 0;
    final processIdPtr = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, processIdPtr);
      if (processIdPtr.value != GetCurrentProcessId()) {
        return 0;
      }
      return hwnd;
    } finally {
      free(processIdPtr);
    }
  }
}

class _SavedWindowPlacement {
  const _SavedWindowPlacement({
    required this.flags,
    required this.showCmd,
    required this.ptMinPositionX,
    required this.ptMinPositionY,
    required this.ptMaxPositionX,
    required this.ptMaxPositionY,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int flags;
  final int showCmd;
  final int ptMinPositionX;
  final int ptMinPositionY;
  final int ptMaxPositionX;
  final int ptMaxPositionY;
  final int left;
  final int top;
  final int right;
  final int bottom;

  factory _SavedWindowPlacement.fromNative(WINDOWPLACEMENT placement) {
    return _SavedWindowPlacement(
      flags: placement.flags,
      showCmd: placement.showCmd,
      ptMinPositionX: placement.ptMinPosition.x,
      ptMinPositionY: placement.ptMinPosition.y,
      ptMaxPositionX: placement.ptMaxPosition.x,
      ptMaxPositionY: placement.ptMaxPosition.y,
      left: placement.rcNormalPosition.left,
      top: placement.rcNormalPosition.top,
      right: placement.rcNormalPosition.right,
      bottom: placement.rcNormalPosition.bottom,
    );
  }
}
