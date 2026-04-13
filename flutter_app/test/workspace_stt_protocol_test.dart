import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_protocol.dart';

void main() {
  group('buildWorkspaceSttWebsocketUrl', () {
    test('uses wss for https origin with explicit port', () {
      final url = buildWorkspaceSttWebsocketUrl(
        origin: Uri.parse('https://meeting.example.com:8443/app'),
        websocketPath: '/ws/meetings/7/stt',
        token: 'abc 123',
      );

      expect(
        url,
        'wss://meeting.example.com:8443/ws/meetings/7/stt?token=abc%20123',
      );
    });

    test('uses ws for http origin without port suffix', () {
      final url = buildWorkspaceSttWebsocketUrl(
        origin: Uri.parse('http://127.0.0.1/room'),
        websocketPath: '/ws/meetings/8/stt',
        token: 'jwt',
      );

      expect(url, 'ws://127.0.0.1/ws/meetings/8/stt?token=jwt');
    });
  });

  group('workspace stt outbound messages', () {
    test('builds start payload with speaker info', () {
      expect(
        workspaceSttStartMessage(
          speakerName: 'Alice',
          speakerIdentity: 'alice-1',
        ),
        <String, dynamic>{
          'type': 'start',
          'speaker_name': 'Alice',
          'speaker_identity': 'alice-1',
        },
      );
    });

    test('builds audio chunk payload', () {
      expect(
        workspaceSttAudioChunkMessage(
          mimeType: 'audio/webm',
          dataBase64: 'YWJj',
        ),
        <String, dynamic>{
          'type': 'audio_chunk',
          'mime_type': 'audio/webm',
          'data_base64': 'YWJj',
        },
      );
    });

    test('builds stop payload', () {
      expect(workspaceSttStopMessage(), <String, dynamic>{'type': 'stop'});
    });
  });

  group('parseWorkspaceSttInboundMessage', () {
    test('parses partial transcript event', () {
      final parsed = parseWorkspaceSttInboundMessage(
        '{"type":"partial_transcript","text":"hello"}',
      );

      expect(parsed, isNotNull);
      expect(parsed!.kind, WorkspaceSttMessageKind.partialTranscript);
      expect(parsed.text, 'hello');
      expect(parsed.detail, '');
    });

    test('parses error event from map payload', () {
      final parsed = parseWorkspaceSttInboundMessage(
        <String, dynamic>{'type': 'error', 'detail': 'worker unavailable'},
      );

      expect(parsed, isNotNull);
      expect(parsed!.kind, WorkspaceSttMessageKind.error);
      expect(parsed.detail, 'worker unavailable');
    });

    test('returns unknown for unsupported payload type', () {
      final parsed = parseWorkspaceSttInboundMessage(
        <String, dynamic>{'type': 'unexpected', 'foo': 'bar'},
      );

      expect(parsed, isNotNull);
      expect(parsed!.kind, WorkspaceSttMessageKind.unknown);
      expect(parsed.rawType, 'unexpected');
    });

    test('returns null for invalid json string', () {
      expect(parseWorkspaceSttInboundMessage('{bad-json'), isNull);
    });
  });
}
