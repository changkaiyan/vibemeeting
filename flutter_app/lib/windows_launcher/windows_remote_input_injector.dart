import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:smart_meeting_app/meeting_room/remote_control_protocol.dart';
import 'package:smart_meeting_app/windows_launcher/windows_remote_control_mapper.dart';
import 'package:win32/win32.dart';

class WindowsRemoteInputInjector {
  const WindowsRemoteInputInjector();

  void apply(RemoteControlMessage message) {
    switch (message.kind) {
      case RemoteControlMessageKind.pointer:
        _applyPointer(message);
        return;
      case RemoteControlMessageKind.wheel:
        _applyWheel(message);
        return;
      case RemoteControlMessageKind.key:
        _applyKey(message);
        return;
      case RemoteControlMessageKind.request:
      case RemoteControlMessageKind.response:
      case RemoteControlMessageKind.stop:
        return;
    }
  }

  void _applyPointer(RemoteControlMessage message) {
    final x = message.x;
    final y = message.y;
    if (x == null || y == null) return;
    final screenWidth = GetSystemMetrics(SM_CXSCREEN);
    final screenHeight = GetSystemMetrics(SM_CYSCREEN);
    final point = mapNormalizedToScreenPoint(
      x: x,
      y: y,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
    );
    SetCursorPos(point.x, point.y);

    final event = (message.pointerEvent ?? '').trim().toLowerCase();
    if (event == 'down') {
      _sendMouseInput(_mouseButtonDownFlag(message.button), mouseData: 0);
    } else if (event == 'up') {
      _sendMouseInput(_mouseButtonUpFlag(message.button), mouseData: 0);
    }
  }

  void _applyWheel(RemoteControlMessage message) {
    final dx = message.deltaX ?? 0;
    final dy = message.deltaY ?? 0;
    if (dy != 0) {
      _sendMouseInput(MOUSEEVENTF_WHEEL, mouseData: -dy);
    }
    if (dx != 0) {
      _sendMouseInput(MOUSEEVENTF_HWHEEL, mouseData: dx);
    }
  }

  void _applyKey(RemoteControlMessage message) {
    final hidUsage = message.hidUsage;
    if (hidUsage == null) return;
    final virtualKey = windowsVirtualKeyFromHidUsage(hidUsage);
    if (virtualKey == null) return;
    final phase = (message.phase ?? '').trim().toLowerCase();
    final flags = phase == 'up' ? KEYEVENTF_KEYUP : 0;
    _sendKeyboardInput(virtualKey, flags: flags);
  }

  void _sendMouseInput(int flags, {required int mouseData}) {
    final input = calloc<INPUT>();
    try {
      input.ref
        ..type = INPUT_MOUSE
        ..mi.dwFlags = flags
        ..mi.mouseData = mouseData;
      SendInput(1, input, sizeOf<INPUT>());
    } finally {
      free(input);
    }
  }

  void _sendKeyboardInput(int virtualKey, {required int flags}) {
    final input = calloc<INPUT>();
    try {
      input.ref
        ..type = INPUT_KEYBOARD
        ..ki.wVk = virtualKey
        ..ki.dwFlags = flags;
      SendInput(1, input, sizeOf<INPUT>());
    } finally {
      free(input);
    }
  }

  int _mouseButtonDownFlag(String? button) {
    switch ((button ?? '').trim().toLowerCase()) {
      case 'right':
        return MOUSEEVENTF_RIGHTDOWN;
      case 'middle':
        return MOUSEEVENTF_MIDDLEDOWN;
      default:
        return MOUSEEVENTF_LEFTDOWN;
    }
  }

  int _mouseButtonUpFlag(String? button) {
    switch ((button ?? '').trim().toLowerCase()) {
      case 'right':
        return MOUSEEVENTF_RIGHTUP;
      case 'middle':
        return MOUSEEVENTF_MIDDLEUP;
      default:
        return MOUSEEVENTF_LEFTUP;
    }
  }
}
