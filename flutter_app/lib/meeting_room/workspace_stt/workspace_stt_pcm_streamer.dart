import 'dart:convert';
import 'dart:typed_data';

import 'workspace_stt_pcm.dart';
import 'workspace_stt_pcm_buffer.dart';
import 'workspace_stt_protocol.dart';

class WorkspaceSttPcmStreamer {
  WorkspaceSttPcmStreamer({
    this.targetRate = workspaceSttTargetSampleRate,
    this.frameMs = 200,
  }) : _buffer = WorkspaceSttPcmBuffer(
          targetRate: targetRate,
          frameMs: frameMs,
        );

  final int targetRate;
  final int frameMs;
  final WorkspaceSttPcmBuffer _buffer;

  String get mimeType => 'audio/pcm;rate=$targetRate';
  int get pendingByteCount => _buffer.pendingByteCount;

  int pushFloat32Samples(
    Float32List input, {
    required int sourceRate,
    required void Function(Map<String, dynamic> message) onMessage,
  }) {
    return _buffer.pushFloat32Samples(
      input,
      sourceRate: sourceRate,
      onChunk: (chunk) {
        onMessage(
          workspaceSttAudioChunkMessage(
            mimeType: mimeType,
            dataBase64: base64Encode(chunk),
          ),
        );
      },
    );
  }

  void reset() {
    _buffer.reset();
  }
}
