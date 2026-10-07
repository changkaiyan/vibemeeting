// Standalone browser regression entrypoint, independent of flutter test's runner.
import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;
import 'media_devices_probe.dart' show defineProperty;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  defineProperty(web.window.navigator, 'mediaDevices'.toJS,
      {'value': null, 'configurable': true}.jsify() as JSObject);
  final results = <String, String>{};
  try {
    final room = lk.Room();
    if ((await lk.Hardware.instance.audioInputs()).isNotEmpty) {
      throw StateError('Expected no capture devices');
    }
    await room.dispose();
    results['LiveKit Room initialization without mediaDevices'] = 'PASS';
  } catch (error) {
    results['LiveKit Room initialization without mediaDevices'] =
        'FAIL: $error';
  }
  final output = web.document.createElement('pre')
    ..textContent = const JsonEncoder.withIndent('  ').convert(results);
  web.document.body!.appendChild(output);
}
