import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/join_capture_policy.dart';

void main() {
  test('available capture keeps requested devices enabled regardless of URL',
      () {
    final plan = JoinCapturePolicy(
        mediaDevicesAvailable: true,
        microphoneRequested: true,
        cameraRequested: true);
    expect(plan.microphoneEnabled, isTrue);
    expect(plan.cameraEnabled, isTrue);
    expect(plan.warning, isNull);
  });
  test('missing capture does not require permission requests to join', () {
    final plan = JoinCapturePolicy(
        mediaDevicesAvailable: false,
        microphoneRequested: true,
        cameraRequested: true);
    expect(plan.microphoneEnabled, isFalse);
    expect(plan.cameraEnabled, isFalse);
    expect(plan.warning, contains('浏览器'));
  });
  test('available capture preserves the users muted choices', () {
    final plan = JoinCapturePolicy(
        mediaDevicesAvailable: true,
        microphoneRequested: false,
        cameraRequested: false);
    expect(plan.microphoneEnabled, isFalse);
    expect(plan.cameraEnabled, isFalse);
    expect(plan.warning, isNull);
  });
}
