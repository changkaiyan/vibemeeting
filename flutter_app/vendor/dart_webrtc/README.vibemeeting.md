# VibeMeeting compatibility patch

Source: dart_webrtc 1.8.1 from pub.dev, upstream https://github.com/flutter-webrtc/dart-webrtc.
The upstream MIT license is retained in LICENSE. Only lib/, pubspec.yaml and the license are vendored.

Changes in lib/src/mediadevices_impl.dart:

- A missing navigator.mediaDevices returns an empty device list.
- Registering or reading the optional device-change listener is safe when that API is missing.
- Clearing a listener actually removes it.

This allows LiveKit Hardware/Room initialization without local capture support. It does not add a browser API, grant permissions, or enable capture that the browser prohibits. Existing mediaDevices implementations continue to be used unchanged.

Browser regression: test/media_devices_browser_test.dart. A standalone assertion page is also provided in test_support/media_devices_probe.dart for environments where Flutter's browser test harness cannot start.
