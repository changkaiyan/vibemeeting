import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_pcm.dart';

void main() {
  group('workspaceSttPcmChunkByteSize', () {
    test('computes 200ms chunk size for 16k mono pcm16', () {
      expect(
        workspaceSttPcmChunkByteSize(
          sampleRate: workspaceSttTargetSampleRate,
          frameMs: 200,
        ),
        6400,
      );
    });
  });

  group('downsampleWorkspaceSttFloat32', () {
    test('returns identical samples when source and target rates match', () {
      final input = Float32List.fromList(const [0.1, -0.2, 0.3]);

      final output = downsampleWorkspaceSttFloat32(
        input,
        sourceRate: 16000,
        targetRate: 16000,
      );

      expect(output, hasLength(3));
      expect(output[0], closeTo(0.1, 1e-6));
      expect(output[1], closeTo(-0.2, 1e-6));
      expect(output[2], closeTo(0.3, 1e-6));
    });

    test('averages source windows during downsampling', () {
      final input = Float32List.fromList(const [0, 3, 6, 9, 12, 15]);

      final output = downsampleWorkspaceSttFloat32(
        input,
        sourceRate: 48000,
        targetRate: 16000,
      );

      expect(output, hasLength(2));
      expect(output[0], closeTo(3, 1e-6));
      expect(output[1], closeTo(12, 1e-6));
    });
  });

  group('workspaceSttFloat32ToPcm16Bytes', () {
    test('encodes and clamps float samples to little-endian pcm16', () {
      final bytes = workspaceSttFloat32ToPcm16Bytes(
        Float32List.fromList(const [-1.5, -0.5, 0.0, 0.5, 1.5]),
      );
      final data = ByteData.sublistView(bytes);

      expect(data.getInt16(0, Endian.little), -32767);
      expect(data.getInt16(2, Endian.little), -16384);
      expect(data.getInt16(4, Endian.little), 0);
      expect(data.getInt16(6, Endian.little), 16384);
      expect(data.getInt16(8, Endian.little), 32767);
    });
  });

  group('flushWorkspaceSttPcmChunks', () {
    test('emits complete chunks and preserves remainder', () {
      final captureBytes = List<int>.generate(6400 * 2 + 100, (i) => i % 255);
      final sentChunks = <Uint8List>[];

      final sentCount = flushWorkspaceSttPcmChunks(
        captureBytes,
        chunkBytes: 6400,
        sendChunk: (chunk) {
          sentChunks.add(chunk);
          return true;
        },
      );

      expect(sentCount, 2);
      expect(sentChunks, hasLength(2));
      expect(sentChunks[0], hasLength(6400));
      expect(sentChunks[1], hasLength(6400));
      expect(captureBytes, hasLength(100));
    });

    test('keeps pending data when send fails', () {
      final captureBytes = List<int>.generate(6400 * 2, (i) => i % 255);
      var attempts = 0;

      final sentCount = flushWorkspaceSttPcmChunks(
        captureBytes,
        chunkBytes: 6400,
        sendChunk: (chunk) {
          attempts += 1;
          return attempts < 2;
        },
      );

      expect(sentCount, 1);
      expect(captureBytes, hasLength(6400));
    });
  });
}
