import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:dart_webrtc/dart_webrtc.dart' as rtc;
import 'package:web/web.dart' as web;

@JS('Object.defineProperty')
external JSObject defineProperty(
    JSObject target, JSString name, JSObject descriptor);

Future<void> main() async {
  final original =
      web.window.navigator.getProperty<JSAny?>('mediaDevices'.toJS);
  final results = <String, String>{};
  Future<void> check(String name, Future<void> Function() action) async {
    try {
      await action();
      results[name] = 'PASS';
    } catch (error) {
      results[name] = 'FAIL: $error';
    }
  }

  defineProperty(web.window.navigator, 'mediaDevices'.toJS,
      {'value': null, 'configurable': true}.jsify() as JSObject);
  await check('missing API listener', () async {
    rtc.navigator.mediaDevices.ondevicechange = (_) {};
    rtc.navigator.mediaDevices.ondevicechange = null;
  });
  await check('missing API enumeration', () async {
    if ((await rtc.navigator.mediaDevices.enumerateDevices()).isNotEmpty)
      throw StateError('Expected empty devices');
  });
  await check('missing API capture still rejected', () async {
    try {
      await rtc.navigator.mediaDevices.getUserMedia({'audio': true});
    } catch (_) {
      return;
    }
    throw StateError('Capture unexpectedly succeeded');
  });
  defineProperty(web.window.navigator, 'mediaDevices'.toJS,
      {'value': original, 'configurable': true}.jsify() as JSObject);
  await check('available API listener remains active', () async {
    rtc.navigator.mediaDevices.ondevicechange = (_) {};
    if (web.window.navigator.mediaDevices.ondevicechange.isUndefinedOrNull)
      throw StateError('Missing listener');
    rtc.navigator.mediaDevices.ondevicechange = null;
  });
  web.document.body!.textContent =
      const JsonEncoder.withIndent('  ').convert(results);
}
