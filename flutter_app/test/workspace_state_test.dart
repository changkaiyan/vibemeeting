import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace/workspace_state.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_runtime.dart';

void main() {
  group('MeetingWorkspaceState', () {
    test('starts with empty workspace collections and fresh STT runtime', () {
      final state = MeetingWorkspaceState();

      expect(state.loading, isFalse);
      expect(state.ready, isFalse);
      expect(state.agentSessions, isEmpty);
      expect(state.context, isNull);
      expect(state.transcripts, isEmpty);
      expect(state.artifacts, isEmpty);
      expect(state.sttRuntime, WorkspaceSttRuntimeState.initial());
      expect(state.sttSession.hasLiveResources, isFalse);
      expect(state.timer, isNull);
    });

    test('resetSttRuntime clears session handles and restores idle runtime', () {
      final state = MeetingWorkspaceState();
      state.sttSession.captureController = Object();
      state.sttSession.pendingAudioChunkSends = 3;
      state.sttRuntime = state.sttRuntime.copyWith(
        active: true,
        partialText: 'partial',
        debugState: 'recording',
      );

      state.resetSttRuntime();

      expect(state.sttSession.hasLiveResources, isFalse);
      expect(state.sttSession.pendingAudioChunkSends, 0);
      expect(state.sttRuntime.active, isFalse);
      expect(state.sttRuntime.partialText, '');
      expect(state.sttRuntime.debugState, 'idle');
    });
  });
}
