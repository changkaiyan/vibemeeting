import 'workspace_stt_protocol.dart';

class WorkspaceSttInboundEffect {
  const WorkspaceSttInboundEffect({
    this.debugLastAction,
    this.partialText,
    this.statusMessage,
    this.shouldReloadWorkspace = false,
    this.shouldCloseSocket = false,
    this.isNoop = false,
  });

  final String? debugLastAction;
  final String? partialText;
  final String? statusMessage;
  final bool shouldReloadWorkspace;
  final bool shouldCloseSocket;
  final bool isNoop;
}

class WorkspaceSttController {
  const WorkspaceSttController();

  WorkspaceSttInboundEffect handleInboundMessage(
    WorkspaceSttInboundMessage message, {
    required bool stopping,
  }) {
    switch (message.kind) {
      case WorkspaceSttMessageKind.sessionStarted:
        return const WorkspaceSttInboundEffect(
          debugLastAction: 'ws-session-started',
          statusMessage: '实时字幕会话已启动',
        );
      case WorkspaceSttMessageKind.partialTranscript:
        return WorkspaceSttInboundEffect(
          debugLastAction: 'ws-partial',
          partialText: message.text,
        );
      case WorkspaceSttMessageKind.finalTranscript:
        return WorkspaceSttInboundEffect(
          debugLastAction: 'ws-final',
          partialText: '',
          shouldReloadWorkspace: true,
          shouldCloseSocket: stopping,
        );
      case WorkspaceSttMessageKind.error:
        return WorkspaceSttInboundEffect(
          debugLastAction: 'ws-error-message',
          statusMessage:
              message.detail.isNotEmpty ? message.detail : 'Realtime STT error',
        );
      case WorkspaceSttMessageKind.unknown:
        return const WorkspaceSttInboundEffect(isNoop: true);
    }
  }
}
