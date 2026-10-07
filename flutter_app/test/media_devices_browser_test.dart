@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;

@JS('Object.defineProperty')
external JSObject defineProperty(
    JSObject target, JSString name, JSObject descriptor);

void main() {
  JSAny? original;
  setUp(() {
    original = web.window.navigator.getProperty<JSAny?>('mediaDevices'.toJS);
    defineProperty(web.window.navigator, 'mediaDevices'.toJS,
        {'value': null, 'configurable': true}.jsify() as JSObject);
  });
  tearDown(() {
    defineProperty(web.window.navigator, 'mediaDevices'.toJS,
        {'value': original, 'configurable': true}.jsify() as JSObject);
  });

  test('missing mediaDevices does not crash device listener registration', () {
    expect(() => rtc.navigator.mediaDevices.ondevicechange = (_) {},
        returnsNormally);
    expect(() => rtc.navigator.mediaDevices.ondevicechange = null,
        returnsNormally);
  });

  test('missing mediaDevices enumerates an empty list', () async {
    expect(await rtc.navigator.mediaDevices.enumerateDevices(), isEmpty);
  });

  test('LiveKit room can initialize without capture devices API', () async {
    final room = lk.Room();
    expect(await lk.Hardware.instance.audioInputs(), isEmpty);
    await room.dispose();
  });

  test('capture remains unavailable instead of bypassing browser restrictions',
      () async {
    await expectLater(rtc.navigator.mediaDevices.getUserMedia({'audio': true}),
        throwsA(anything));
    await expectLater(
        rtc.navigator.mediaDevices.getDisplayMedia({'video': true}),
        throwsA(anything));
  });
}
