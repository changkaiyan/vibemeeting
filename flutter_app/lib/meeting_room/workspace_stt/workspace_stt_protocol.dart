import 'dart:convert';

enum WorkspaceSttMessageKind {
  sessionStarted,
  partialTranscript,
  finalTranscript,
  error,
  unknown,
}

class WorkspaceSttInboundMessage {
  const WorkspaceSttInboundMessage({
    required this.kind,
    required this.rawType,
    this.text = '',
    this.detail = '',
    this.payload = const <String, dynamic>{},
  });

  final WorkspaceSttMessageKind kind;
  final String rawType;
  final String text;
  final String detail;
  final Map<String, dynamic> payload;
}

String buildWorkspaceSttWebsocketUrl({
  required Uri origin,
  required String websocketPath,
  required String token,
}) {
  final scheme = origin.scheme == 'https' ? 'wss' : 'ws';
  final host = origin.host;
  final port = origin.hasPort ? ':${origin.port}' : '';
  final encodedToken = Uri.encodeComponent(token);
  return '$scheme://$host$port$websocketPath?token=$encodedToken';
}

Map<String, dynamic> workspaceSttStartMessage({
  required String speakerName,
  required String speakerIdentity,
}) {
  return <String, dynamic>{
    'type': 'start',
    'speaker_name': speakerName,
    'speaker_identity': speakerIdentity,
  };
}

Map<String, dynamic> workspaceSttAudioChunkMessage({
  required String mimeType,
  required String dataBase64,
}) {
  return <String, dynamic>{
    'type': 'audio_chunk',
    'mime_type': mimeType,
    'data_base64': dataBase64,
  };
}

Map<String, dynamic> workspaceSttStopMessage() {
  return const <String, dynamic>{'type': 'stop'};
}

WorkspaceSttInboundMessage? parseWorkspaceSttInboundMessage(Object? raw) {
  Map<String, dynamic> payload;
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      payload = decoded;
    } catch (_) {
      return null;
    }
  } else if (raw is Map<String, dynamic>) {
    payload = raw;
  } else {
    return null;
  }

  final rawType = (payload['type'] ?? '').toString().trim();
  final text = (payload['text'] ?? '').toString();
  final detail = (payload['detail'] ?? '').toString();
  switch (rawType) {
    case 'session_started':
      return WorkspaceSttInboundMessage(
        kind: WorkspaceSttMessageKind.sessionStarted,
        rawType: rawType,
        text: text,
        detail: detail,
        payload: payload,
      );
    case 'partial_transcript':
      return WorkspaceSttInboundMessage(
        kind: WorkspaceSttMessageKind.partialTranscript,
        rawType: rawType,
        text: text,
        detail: detail,
        payload: payload,
      );
    case 'final_transcript':
      return WorkspaceSttInboundMessage(
        kind: WorkspaceSttMessageKind.finalTranscript,
        rawType: rawType,
        text: text,
        detail: detail,
        payload: payload,
      );
    case 'error':
      return WorkspaceSttInboundMessage(
        kind: WorkspaceSttMessageKind.error,
        rawType: rawType,
        text: text,
        detail: detail,
        payload: payload,
      );
    default:
      return WorkspaceSttInboundMessage(
        kind: WorkspaceSttMessageKind.unknown,
        rawType: rawType,
        text: text,
        detail: detail,
        payload: payload,
      );
  }
}
