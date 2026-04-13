const int workspaceSttSocketOpenState = 1;
const int workspaceSttSocketClosedState = 3;

class WorkspaceSttSpeaker {
  const WorkspaceSttSpeaker({
    required this.name,
    required this.identity,
  });

  final String name;
  final String identity;
}

class WorkspaceSttStopActionPlan {
  const WorkspaceSttStopActionPlan({
    required this.shouldSendStopMessage,
    required this.shouldCloseSocket,
    required this.shouldClearResources,
  });

  final bool shouldSendStopMessage;
  final bool shouldCloseSocket;
  final bool shouldClearResources;
}

String preferredWorkspaceSttMimeType({
  required bool Function(String candidate) isTypeSupported,
}) {
  return isTypeSupported('audio/webm') ? 'audio/webm' : '';
}

WorkspaceSttSpeaker resolveWorkspaceSttSpeaker(String participantIdentity) {
  final normalized = participantIdentity.trim();
  if (normalized.isNotEmpty) {
    return WorkspaceSttSpeaker(
      name: normalized,
      identity: normalized,
    );
  }
  return const WorkspaceSttSpeaker(
    name: 'Me',
    identity: 'me',
  );
}

WorkspaceSttStopActionPlan planWorkspaceSttStopAction({
  required int? socketReadyState,
  required bool immediate,
}) {
  if (socketReadyState == workspaceSttSocketOpenState) {
    if (immediate) {
      return const WorkspaceSttStopActionPlan(
        shouldSendStopMessage: false,
        shouldCloseSocket: true,
        shouldClearResources: false,
      );
    }
    return const WorkspaceSttStopActionPlan(
      shouldSendStopMessage: true,
      shouldCloseSocket: false,
      shouldClearResources: false,
    );
  }
  return const WorkspaceSttStopActionPlan(
    shouldSendStopMessage: false,
    shouldCloseSocket: false,
    shouldClearResources: true,
  );
}
