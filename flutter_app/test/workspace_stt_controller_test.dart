import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_controller.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_protocol.dart';

void main() {
  group('WorkspaceSttController.handleInboundMessage', () {
    test('marks session started and sets user-facing status', () {
      final effect = const WorkspaceSttController().handleInboundMessage(
        const WorkspaceSttInboundMessage(
          kind: WorkspaceSttMessageKind.sessionStarted,
          rawType: 'session_started',
        ),
        stopping: false,
      );

      expect(effect.debugLastAction, 'ws-session-started');
      expect(effect.statusMessage, '实时字幕会话已启动');
      expect(effect.partialText, isNull);
      expect(effect.shouldReloadWorkspace, isFalse);
      expect(effect.shouldCloseSocket, isFalse);
    });

    test('updates partial text on partial transcript', () {
      final effect = const WorkspaceSttController().handleInboundMessage(
        const WorkspaceSttInboundMessage(
          kind: WorkspaceSttMessageKind.partialTranscript,
          rawType: 'partial_transcript',
          text: '正在讨论 API 拆分',
        ),
        stopping: false,
      );

      expect(effect.debugLastAction, 'ws-partial');
      expect(effect.partialText, '正在讨论 API 拆分');
      expect(effect.statusMessage, isNull);
      expect(effect.shouldReloadWorkspace, isFalse);
    });

    test('clears partial text and reloads workspace on final transcript', () {
      final effect = const WorkspaceSttController().handleInboundMessage(
        const WorkspaceSttInboundMessage(
          kind: WorkspaceSttMessageKind.finalTranscript,
          rawType: 'final_transcript',
          text: '最终字幕',
        ),
        stopping: false,
      );

      expect(effect.debugLastAction, 'ws-final');
      expect(effect.partialText, '');
      expect(effect.shouldReloadWorkspace, isTrue);
      expect(effect.shouldCloseSocket, isFalse);
    });

    test('requests socket close after final transcript when stopping', () {
      final effect = const WorkspaceSttController().handleInboundMessage(
        const WorkspaceSttInboundMessage(
          kind: WorkspaceSttMessageKind.finalTranscript,
          rawType: 'final_transcript',
          text: '最终字幕',
        ),
        stopping: true,
      );

      expect(effect.shouldReloadWorkspace, isTrue);
      expect(effect.shouldCloseSocket, isTrue);
    });

    test('surfaces worker error detail', () {
      final effect = const WorkspaceSttController().handleInboundMessage(
        const WorkspaceSttInboundMessage(
          kind: WorkspaceSttMessageKind.error,
          rawType: 'error',
          detail: 'worker unavailable',
        ),
        stopping: false,
      );

      expect(effect.debugLastAction, 'ws-error-message');
      expect(effect.statusMessage, 'worker unavailable');
      expect(effect.shouldReloadWorkspace, isFalse);
    });

    test('ignores unknown message types', () {
      final effect = const WorkspaceSttController().handleInboundMessage(
        const WorkspaceSttInboundMessage(
          kind: WorkspaceSttMessageKind.unknown,
          rawType: 'noop',
        ),
        stopping: false,
      );

      expect(effect.isNoop, isTrue);
    });
  });
}
