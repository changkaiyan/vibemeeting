import 'dart:typed_data';

import 'workspace_stt_pcm.dart';

class WorkspaceSttPcmBuffer {
  WorkspaceSttPcmBuffer({
    this.targetRate = workspaceSttTargetSampleRate,
    this.frameMs = 200,
  }) : chunkBytes = workspaceSttPcmChunkByteSize(
          sampleRate: targetRate,
          frameMs: frameMs,
        );

  final int targetRate;
  final int frameMs;
  final int chunkBytes;
  final List<int> _captureBytes = <int>[];

  int get pendingByteCount => _captureBytes.length;

  int pushFloat32Samples(
    Float32List input, {
    required int sourceRate,
    required void Function(Uint8List chunk) onChunk,
  }) {
    final downsampled = downsampleWorkspaceSttFloat32(
      input,
      sourceRate: sourceRate,
      targetRate: targetRate,
    );
    final pcmBytes = workspaceSttFloat32ToPcm16Bytes(downsampled);
    _captureBytes.addAll(pcmBytes);
    return flushWorkspaceSttPcmChunks(
      _captureBytes,
      chunkBytes: chunkBytes,
      sendChunk: (chunk) {
        onChunk(chunk);
        return true;
      },
    );
  }

  void reset() {
    _captureBytes.clear();
  }
}
