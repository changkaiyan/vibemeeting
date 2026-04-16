import 'dart:convert';

const String remoteControlDataTopic = 'meeting.remote_control.v1';

enum RemoteControlMessageKind {
  request,
  response,
  stop,
  pointer,
  wheel,
  key,
}

class RemoteControlMessage {
  const RemoteControlMessage({
    required this.kind,
    required this.requestId,
    required this.controllerIdentity,
    required this.targetIdentity,
    this.approved,
    this.reason,
    this.pointerEvent,
    this.x,
    this.y,
    this.button,
    this.deltaX,
    this.deltaY,
    this.phase,
    this.hidUsage,
    this.keyLabel,
  });

  final RemoteControlMessageKind kind;
  final String requestId;
  final String controllerIdentity;
  final String targetIdentity;
  final bool? approved;
  final String? reason;
  final String? pointerEvent;
  final double? x;
  final double? y;
  final String? button;
  final int? deltaX;
  final int? deltaY;
  final String? phase;
  final int? hidUsage;
  final String? keyLabel;
}

Map<String, dynamic> buildRemoteControlRequestMessage({
  required String requestId,
  required String controllerIdentity,
  required String targetIdentity,
}) {
  return <String, dynamic>{
    'type': 'request',
    'request_id': requestId,
    'controller_identity': controllerIdentity,
    'target_identity': targetIdentity,
  };
}

Map<String, dynamic> buildRemoteControlResponseMessage({
  required String requestId,
  required String controllerIdentity,
  required String targetIdentity,
  required bool approved,
  String reason = '',
}) {
  return <String, dynamic>{
    'type': 'response',
    'request_id': requestId,
    'controller_identity': controllerIdentity,
    'target_identity': targetIdentity,
    'approved': approved,
    if (reason.trim().isNotEmpty) 'reason': reason.trim(),
  };
}

Map<String, dynamic> buildRemoteControlStopMessage({
  required String requestId,
  required String controllerIdentity,
  required String targetIdentity,
  String reason = '',
}) {
  return <String, dynamic>{
    'type': 'stop',
    'request_id': requestId,
    'controller_identity': controllerIdentity,
    'target_identity': targetIdentity,
    if (reason.trim().isNotEmpty) 'reason': reason.trim(),
  };
}

Map<String, dynamic> buildRemoteControlPointerMessage({
  required String requestId,
  required String controllerIdentity,
  required String targetIdentity,
  required String event,
  required double x,
  required double y,
  String button = '',
}) {
  return <String, dynamic>{
    'type': 'pointer',
    'request_id': requestId,
    'controller_identity': controllerIdentity,
    'target_identity': targetIdentity,
    'event': event,
    'x': x,
    'y': y,
    if (button.trim().isNotEmpty) 'button': button.trim(),
  };
}

Map<String, dynamic> buildRemoteControlWheelMessage({
  required String requestId,
  required String controllerIdentity,
  required String targetIdentity,
  required int deltaX,
  required int deltaY,
}) {
  return <String, dynamic>{
    'type': 'wheel',
    'request_id': requestId,
    'controller_identity': controllerIdentity,
    'target_identity': targetIdentity,
    'delta_x': deltaX,
    'delta_y': deltaY,
  };
}

Map<String, dynamic> buildRemoteControlKeyMessage({
  required String requestId,
  required String controllerIdentity,
  required String targetIdentity,
  required String phase,
  required int hidUsage,
  String keyLabel = '',
}) {
  return <String, dynamic>{
    'type': 'key',
    'request_id': requestId,
    'controller_identity': controllerIdentity,
    'target_identity': targetIdentity,
    'phase': phase,
    'hid_usage': hidUsage,
    if (keyLabel.trim().isNotEmpty) 'key_label': keyLabel.trim(),
  };
}

RemoteControlMessage? parseRemoteControlMessage(Object? raw) {
  Map<String, dynamic>? map;
  if (raw is String) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        map = parsed;
      } else if (parsed is Map) {
        map = parsed.cast<String, dynamic>();
      }
    } catch (_) {
      return null;
    }
  } else if (raw is Map<String, dynamic>) {
    map = raw;
  } else if (raw is Map) {
    map = raw.cast<String, dynamic>();
  }
  if (map == null) return null;

  final type = (map['type'] ?? '').toString().trim().toLowerCase();
  final requestId = (map['request_id'] ?? '').toString().trim();
  final controllerIdentity =
      (map['controller_identity'] ?? '').toString().trim();
  final targetIdentity = (map['target_identity'] ?? '').toString().trim();
  if (requestId.isEmpty ||
      controllerIdentity.isEmpty ||
      targetIdentity.isEmpty) {
    return null;
  }

  switch (type) {
    case 'request':
      return RemoteControlMessage(
        kind: RemoteControlMessageKind.request,
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
      );
    case 'response':
      final approved = map['approved'];
      if (approved is! bool) return null;
      return RemoteControlMessage(
        kind: RemoteControlMessageKind.response,
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        approved: approved,
        reason: (map['reason'] ?? '').toString().trim(),
      );
    case 'stop':
      return RemoteControlMessage(
        kind: RemoteControlMessageKind.stop,
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        reason: (map['reason'] ?? '').toString().trim(),
      );
    case 'pointer':
      final event = (map['event'] ?? '').toString().trim().toLowerCase();
      final x = _doubleFromJson(map['x']);
      final y = _doubleFromJson(map['y']);
      if (event.isEmpty || x == null || y == null) return null;
      return RemoteControlMessage(
        kind: RemoteControlMessageKind.pointer,
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        pointerEvent: event,
        x: x,
        y: y,
        button: (map['button'] ?? '').toString().trim().toLowerCase(),
      );
    case 'wheel':
      final dx = _intFromJson(map['delta_x']);
      final dy = _intFromJson(map['delta_y']);
      if (dx == null || dy == null) return null;
      return RemoteControlMessage(
        kind: RemoteControlMessageKind.wheel,
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        deltaX: dx,
        deltaY: dy,
      );
    case 'key':
      final phase = (map['phase'] ?? '').toString().trim().toLowerCase();
      final hidUsage = _intFromJson(map['hid_usage']);
      if (phase.isEmpty || hidUsage == null) return null;
      return RemoteControlMessage(
        kind: RemoteControlMessageKind.key,
        requestId: requestId,
        controllerIdentity: controllerIdentity,
        targetIdentity: targetIdentity,
        phase: phase,
        hidUsage: hidUsage,
        keyLabel: (map['key_label'] ?? '').toString(),
      );
    default:
      return null;
  }
}

bool shouldSendRemoteControlReliably(RemoteControlMessageKind kind) {
  return kind != RemoteControlMessageKind.pointer &&
      kind != RemoteControlMessageKind.wheel;
}

double? _doubleFromJson(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw == null) return null;
  return double.tryParse(raw.toString());
}

int? _intFromJson(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.round();
  if (raw == null) return null;
  return int.tryParse(raw.toString());
}
