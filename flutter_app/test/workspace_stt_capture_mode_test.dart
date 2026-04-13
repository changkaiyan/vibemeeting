import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_capture_mode.dart';

void main() {
  group('resolveWorkspaceSttCaptureMode', () {
    test('defaults to mediaRecorder when no preference is provided', () {
      expect(
        resolveWorkspaceSttCaptureMode(
          preferredValue: null,
          pcmSupported: true,
        ),
        WorkspaceSttCaptureMode.mediaRecorderWebm,
      );
    });

    test('uses pcmWorklet when requested and supported', () {
      expect(
        resolveWorkspaceSttCaptureMode(
          preferredValue: 'pcm',
          pcmSupported: true,
        ),
        WorkspaceSttCaptureMode.pcmWorklet,
      );
    });

    test('falls back to mediaRecorder when pcm is requested but unsupported',
        () {
      expect(
        resolveWorkspaceSttCaptureMode(
          preferredValue: 'pcm',
          pcmSupported: false,
        ),
        WorkspaceSttCaptureMode.mediaRecorderWebm,
      );
    });

    test('accepts explicit webm preference', () {
      expect(
        resolveWorkspaceSttCaptureMode(
          preferredValue: 'webm',
          pcmSupported: true,
        ),
        WorkspaceSttCaptureMode.mediaRecorderWebm,
      );
    });
  });

  group('workspaceSttCaptureModeLabel', () {
    test('returns stable labels', () {
      expect(
        workspaceSttCaptureModeLabel(WorkspaceSttCaptureMode.mediaRecorderWebm),
        'webm',
      );
      expect(
        workspaceSttCaptureModeLabel(WorkspaceSttCaptureMode.pcmWorklet),
        'pcm',
      );
    });
  });

  group('nextWorkspaceSttCaptureModeFallback', () {
    test('falls back from pcm to webm after pcm startup failure', () {
      expect(
        nextWorkspaceSttCaptureModeFallback(
          attemptedMode: WorkspaceSttCaptureMode.pcmWorklet,
        ),
        WorkspaceSttCaptureMode.mediaRecorderWebm,
      );
    });

    test('does not retry with another mode after webm failure', () {
      expect(
        nextWorkspaceSttCaptureModeFallback(
          attemptedMode: WorkspaceSttCaptureMode.mediaRecorderWebm,
        ),
        isNull,
      );
    });
  });
}
