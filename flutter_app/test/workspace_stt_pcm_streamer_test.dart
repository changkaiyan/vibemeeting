import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_pcm.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_pcm_streamer.dart';

void main() {
  group('WorkspaceSttPcmStreamer', () {
    test(
        'emits websocket-ready audio_chunk payloads once a full frame is ready',
        () {
      final streamer = WorkspaceSttPcmStreamer(frameMs: 200);
      final payloads = <Map<String, dynamic>>[];

      final sent = streamer.pushFloat32Samples(
        Float32List.fromList(List<double>.filled(9600, 0.5)),
        sourceRate: 48000,
        onMessage: payloads.add,
      );

      expect(sent, 1);
      expect(payloads, hasLength(1));
      expect(payloads.first['type'], 'audio_chunk');
      expect(payloads.first['mime_type'], 'audio/pcm;rate=16000');

      final encoded = payloads.first['data_base64'] as String;
      final bytes = base64Decode(encoded);
      expect(bytes, hasLength(6400));
      expect(streamer.pendingByteCount, 0);
    });

    test('keeps remainder when partial frame is pushed', () {
      final streamer = WorkspaceSttPcmStreamer(frameMs: 200);

      final sent = streamer.pushFloat32Samples(
        Float32List.fromList(List<double>.filled(4800, 0.25)),
        sourceRate: 48000,
        onMessage: (_) {},
      );

      expect(sent, 0);
      expect(streamer.pendingByteCount, greaterThan(0));
    });

    test('reset clears buffered pcm bytes', () {
      final streamer = WorkspaceSttPcmStreamer(frameMs: 200);
      streamer.pushFloat32Samples(
        Float32List.fromList(List<double>.filled(4800, 0.25)),
        sourceRate: 48000,
        onMessage: (_) {},
      );

      streamer.reset();

      expect(streamer.pendingByteCount, 0);
    });

    test('uses target sample rate helper for mime construction', () {
      final streamer = WorkspaceSttPcmStreamer();

      expect(streamer.mimeType, 'audio/pcm;rate=$workspaceSttTargetSampleRate');
    });
  });
}
