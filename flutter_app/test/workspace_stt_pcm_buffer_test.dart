import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_pcm.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_pcm_buffer.dart';

void main() {
  group('WorkspaceSttPcmBuffer', () {
    test('emits one fixed-size pcm chunk for a full 200ms frame', () {
      final buffer = WorkspaceSttPcmBuffer(frameMs: 200);
      final emitted = <Uint8List>[];
      final input = Float32List.fromList(List<double>.filled(9600, 0.5));

      final sent = buffer.pushFloat32Samples(
        input,
        sourceRate: 48000,
        onChunk: emitted.add,
      );

      expect(sent, 1);
      expect(emitted, hasLength(1));
      expect(emitted.first.length, 6400);
      expect(buffer.pendingByteCount, 0);
    });

    test('keeps remainder until enough audio is accumulated', () {
      final buffer = WorkspaceSttPcmBuffer(frameMs: 200);
      final emitted = <Uint8List>[];

      final sentFirst = buffer.pushFloat32Samples(
        Float32List.fromList(List<double>.filled(4800, 0.25)),
        sourceRate: 48000,
        onChunk: emitted.add,
      );
      final sentSecond = buffer.pushFloat32Samples(
        Float32List.fromList(List<double>.filled(4800, 0.25)),
        sourceRate: 48000,
        onChunk: emitted.add,
      );

      expect(sentFirst, 0);
      expect(sentSecond, 1);
      expect(emitted, hasLength(1));
      expect(emitted.first.length, 6400);
      expect(buffer.pendingByteCount, 0);
    });

    test('reset clears buffered bytes', () {
      final buffer = WorkspaceSttPcmBuffer(frameMs: 200);

      buffer.pushFloat32Samples(
        Float32List.fromList(List<double>.filled(4800, 0.1)),
        sourceRate: 48000,
        onChunk: (_) {},
      );
      expect(buffer.pendingByteCount, greaterThan(0));

      buffer.reset();

      expect(buffer.pendingByteCount, 0);
    });

    test('uses configured chunk size helper', () {
      final buffer = WorkspaceSttPcmBuffer(frameMs: 320);

      expect(
        buffer.chunkBytes,
        workspaceSttPcmChunkByteSize(
          sampleRate: workspaceSttTargetSampleRate,
          frameMs: 320,
        ),
      );
    });
  });
}
