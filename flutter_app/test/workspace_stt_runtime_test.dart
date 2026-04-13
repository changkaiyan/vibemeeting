import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_controller.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_runtime.dart';

void main() {
  group('WorkspaceSttRuntimeState', () {
    test('start tap increments counter and sets action', () {
      final state = WorkspaceSttRuntimeState.initial().afterStartTap();

      expect(state.debugStartTapCount, 1);
      expect(state.debugLastAction, 'tap-start');
      expect(state.debugState, 'start-tapped');
    });

    test('stop tap increments counter and preserves current debug state', () {
      final state = WorkspaceSttRuntimeState.initial()
          .copyWith(debugState: 'recording')
          .afterStopTap();

      expect(state.debugStopTapCount, 1);
      expect(state.debugLastAction, 'tap-stop');
      expect(state.debugState, 'recording');
    });

    test('resources cleared resets runtime fields to idle baseline', () {
      final state = WorkspaceSttRuntimeState.initial()
          .copyWith(
            active: true,
            stopping: true,
            partialText: 'partial',
            debugState: 'recording',
            debugMimeType: 'audio/webm',
            debugBlobEventCount: 3,
            debugLastBlobSize: 1200,
            debugLastError: 'boom',
            debugWsState: 'open',
            debugAudioTrackCount: 1,
          )
          .cleared();

      expect(state.active, isFalse);
      expect(state.stopping, isFalse);
      expect(state.partialText, '');
      expect(state.debugState, 'idle');
      expect(state.debugMimeType, '');
      expect(state.debugBlobEventCount, 0);
      expect(state.debugLastBlobSize, 0);
      expect(state.debugLastError, '');
      expect(state.debugWsState, 'not-created');
      expect(state.debugAudioTrackCount, 0);
      expect(state.debugLastAction, 'resources-cleared');
    });

    test('applying inbound effect updates partial text and action', () {
      final effect = const WorkspaceSttInboundEffect(
        debugLastAction: 'ws-partial',
        partialText: 'hello',
      );
      final state =
          WorkspaceSttRuntimeState.initial().applyInboundEffect(effect);

      expect(state.partialText, 'hello');
      expect(state.debugLastAction, 'ws-partial');
    });

    test('start failure records contextual debug state', () {
      final state = WorkspaceSttRuntimeState.initial()
          .copyWith(
            debugState: 'gum-request',
          )
          .withStartFailure(
            errorText: 'permission denied',
            wsState: 'closed',
            audioTrackCount: 0,
          );

      expect(state.debugState, 'failed:gum-request');
      expect(state.debugLastError, 'permission denied');
      expect(state.debugWsState, 'closed');
      expect(state.debugLastAction, 'start-failed');
    });

    test('entering recorder created resets blob counters and mime info', () {
      final state = WorkspaceSttRuntimeState.initial()
          .copyWith(
            debugBlobEventCount: 5,
            debugLastBlobSize: 999,
            debugLastError: 'old',
          )
          .enteredRecorderCreated(
            mimeType: 'audio/webm',
            wsState: 'open',
          );

      expect(state.debugState, 'recorder-created');
      expect(state.debugMimeType, 'audio/webm');
      expect(state.debugBlobEventCount, 0);
      expect(state.debugLastBlobSize, 0);
      expect(state.debugLastError, '');
      expect(state.debugWsState, 'open');
      expect(state.debugLastAction, 'recorder-created');
    });

    test('recording started marks runtime active', () {
      final state = WorkspaceSttRuntimeState.initial().enteredRecording(
        wsState: 'open',
      );

      expect(state.active, isTrue);
      expect(state.stopping, isFalse);
      expect(state.debugState, 'recording');
      expect(state.debugWsState, 'open');
      expect(state.debugLastAction, 'recorder-started');
    });

    test('blob event updates counters and mime type', () {
      final state = WorkspaceSttRuntimeState.initial()
          .copyWith(debugBlobEventCount: 2, debugMimeType: 'audio/webm')
          .observedBlobEvent(
            blobSize: 320,
            wsState: 'open',
            blobMimeType: 'audio/pcm',
          );

      expect(state.debugState, 'dataavailable');
      expect(state.debugBlobEventCount, 3);
      expect(state.debugLastBlobSize, 320);
      expect(state.debugWsState, 'open');
      expect(state.debugMimeType, 'audio/pcm');
      expect(state.debugLastAction, 'blob-event');
    });

    test('entering stopping updates stop state and action', () {
      final state = WorkspaceSttRuntimeState.initial().enteredStopping(
        wsState: 'closing',
      );

      expect(state.stopping, isTrue);
      expect(state.debugState, 'stopping');
      expect(state.debugWsState, 'closing');
      expect(state.debugLastAction, 'stop-entered');
    });
  });
}
