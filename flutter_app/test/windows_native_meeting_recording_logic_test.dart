import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/windows_launcher/native_meeting_recording_logic.dart';

void main() {
  group('DesktopMeetingRecordingState.fromPayload', () {
    test('parses active payload fields', () {
      final state = DesktopMeetingRecordingState.fromPayload(
        <String, dynamic>{
          'active': true,
          'started_at': '2026-04-15T12:30:00Z',
          'egress_id': 'eg_123',
          'status': 'running',
          'error': '',
          'file_name': '',
        },
      );

      expect(state.active, isTrue);
      expect(state.startedAt, isNotNull);
      expect(state.egressId, 'eg_123');
      expect(state.statusKey, 'running');
    });
  });

  group('describeRecordingStatus', () {
    test('shows active label when recording in progress', () {
      final text = describeRecordingStatus(
        state: const DesktopMeetingRecordingState(active: true),
        uploading: false,
      );
      expect(text, '正在录制中');
    });

    test('shows complete file when finished', () {
      final text = describeRecordingStatus(
        state: const DesktopMeetingRecordingState(
          active: false,
          statusKey: 'complete',
          fileName: 'meeting_001.mp4',
        ),
        uploading: false,
      );
      expect(text, '录制完成：meeting_001.mp4');
    });

    test('shows error message on failure', () {
      final text = describeRecordingStatus(
        state: const DesktopMeetingRecordingState(
          active: false,
          statusKey: 'failed',
          errorText: 'egress unavailable',
        ),
        uploading: false,
      );
      expect(text, '录制失败：egress unavailable');
    });
  });
}
