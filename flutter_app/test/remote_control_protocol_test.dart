import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/remote_control_protocol.dart';

void main() {
  group('remote control protocol outbound messages', () {
    test('builds request payload with identities and request id', () {
      final payload = buildRemoteControlRequestMessage(
        requestId: 'req-1',
        controllerIdentity: 'controller-a',
        targetIdentity: 'target-b',
      );

      expect(payload['type'], 'request');
      expect(payload['request_id'], 'req-1');
      expect(payload['controller_identity'], 'controller-a');
      expect(payload['target_identity'], 'target-b');
    });

    test('builds key payload with phase and hid usage', () {
      final payload = buildRemoteControlKeyMessage(
        requestId: 'req-2',
        controllerIdentity: 'controller-a',
        targetIdentity: 'target-b',
        phase: 'down',
        hidUsage: 0x70004,
        keyLabel: 'a',
      );

      expect(payload['type'], 'key');
      expect(payload['phase'], 'down');
      expect(payload['hid_usage'], 0x70004);
      expect(payload['key_label'], 'a');
    });
  });

  group('remote control protocol parser', () {
    test('parses json string payload', () {
      final raw = jsonEncode(
        buildRemoteControlPointerMessage(
          requestId: 'req-3',
          controllerIdentity: 'controller-a',
          targetIdentity: 'target-b',
          event: 'move',
          x: 0.3,
          y: 0.7,
        ),
      );
      final parsed = parseRemoteControlMessage(raw);

      expect(parsed, isNotNull);
      expect(parsed!.kind, RemoteControlMessageKind.pointer);
      expect(parsed.requestId, 'req-3');
      expect(parsed.pointerEvent, 'move');
      expect(parsed.x, closeTo(0.3, 0.0001));
      expect(parsed.y, closeTo(0.7, 0.0001));
    });

    test('returns null for unsupported type', () {
      expect(
        parseRemoteControlMessage(
          <String, dynamic>{
            'type': 'unsupported',
            'request_id': 'r',
            'controller_identity': 'a',
            'target_identity': 'b',
          },
        ),
        isNull,
      );
    });

    test('returns null when required identities are missing', () {
      expect(
        parseRemoteControlMessage(
          <String, dynamic>{
            'type': 'request',
            'request_id': 'r',
            'controller_identity': '',
            'target_identity': 'b',
          },
        ),
        isNull,
      );
    });
  });

  group('remote control channel policy', () {
    test('pointer and wheel are lossy, others are reliable', () {
      expect(
        shouldSendRemoteControlReliably(RemoteControlMessageKind.pointer),
        isFalse,
      );
      expect(
        shouldSendRemoteControlReliably(RemoteControlMessageKind.wheel),
        isFalse,
      );
      expect(
        shouldSendRemoteControlReliably(RemoteControlMessageKind.key),
        isTrue,
      );
      expect(
        shouldSendRemoteControlReliably(RemoteControlMessageKind.request),
        isTrue,
      );
    });
  });
}
