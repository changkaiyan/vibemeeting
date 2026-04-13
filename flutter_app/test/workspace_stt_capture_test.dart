import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_capture.dart';

void main() {
  group('preferredWorkspaceSttMimeType', () {
    test('prefers audio/webm when supported', () {
      final mimeType = preferredWorkspaceSttMimeType(
        isTypeSupported: (candidate) => candidate == 'audio/webm',
      );

      expect(mimeType, 'audio/webm');
    });

    test('falls back to empty mime type when no preferred type is supported',
        () {
      final mimeType = preferredWorkspaceSttMimeType(
        isTypeSupported: (_) => false,
      );

      expect(mimeType, '');
    });
  });

  group('resolveWorkspaceSttSpeaker', () {
    test('uses participant identity when present', () {
      final speaker = resolveWorkspaceSttSpeaker('alice-1');

      expect(speaker.name, 'alice-1');
      expect(speaker.identity, 'alice-1');
    });

    test('falls back to generic self identity', () {
      final speaker = resolveWorkspaceSttSpeaker('   ');

      expect(speaker.name, 'Me');
      expect(speaker.identity, 'me');
    });
  });

  group('planWorkspaceSttStopAction', () {
    test('closes socket immediately when immediate stop is requested', () {
      final plan = planWorkspaceSttStopAction(
        socketReadyState: workspaceSttSocketOpenState,
        immediate: true,
      );

      expect(plan.shouldCloseSocket, isTrue);
      expect(plan.shouldSendStopMessage, isFalse);
    });

    test('sends stop message for open websocket during graceful stop', () {
      final plan = planWorkspaceSttStopAction(
        socketReadyState: workspaceSttSocketOpenState,
        immediate: false,
      );

      expect(plan.shouldCloseSocket, isFalse);
      expect(plan.shouldSendStopMessage, isTrue);
    });

    test('clears resources when socket is already closed', () {
      final plan = planWorkspaceSttStopAction(
        socketReadyState: workspaceSttSocketClosedState,
        immediate: false,
      );

      expect(plan.shouldCloseSocket, isFalse);
      expect(plan.shouldSendStopMessage, isFalse);
      expect(plan.shouldClearResources, isTrue);
    });
  });
}
