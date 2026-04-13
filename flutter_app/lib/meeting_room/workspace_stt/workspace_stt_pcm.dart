import 'dart:math' as math;
import 'dart:typed_data';

const int workspaceSttTargetSampleRate = 16000;

int workspaceSttPcmChunkByteSize({
  required int sampleRate,
  required int frameMs,
  int channels = 1,
  int bytesPerSample = 2,
}) {
  final safeRate = sampleRate <= 0 ? workspaceSttTargetSampleRate : sampleRate;
  final safeFrameMs = frameMs <= 0 ? 200 : frameMs;
  final safeChannels = channels <= 0 ? 1 : channels;
  final safeBytesPerSample = bytesPerSample <= 0 ? 2 : bytesPerSample;
  final samplesPerChunk = (safeRate * safeFrameMs / 1000).round();
  return samplesPerChunk * safeChannels * safeBytesPerSample;
}

Float32List downsampleWorkspaceSttFloat32(
  Float32List input, {
  required int sourceRate,
  required int targetRate,
}) {
  if (input.isEmpty) return Float32List(0);
  final srcRate = sourceRate <= 0 ? workspaceSttTargetSampleRate : sourceRate;
  final dstRate = targetRate <= 0 ? workspaceSttTargetSampleRate : targetRate;
  if (srcRate == dstRate) {
    return Float32List.fromList(input);
  }
  final ratio = srcRate / dstRate;
  final outputLength = (input.length / ratio).floor();
  if (outputLength <= 0) return Float32List(0);
  final output = Float32List(outputLength);
  var sourceOffset = 0.0;
  for (var i = 0; i < outputLength; i++) {
    final nextOffset = sourceOffset + ratio;
    final start = sourceOffset.floor();
    final end = math.min(nextOffset.floor(), input.length);
    if (end <= start) {
      output[i] = input[math.min(start, input.length - 1)];
    } else {
      double sum = 0.0;
      var count = 0;
      for (var j = start; j < end; j++) {
        sum += input[j];
        count += 1;
      }
      output[i] = count <= 0 ? 0.0 : sum / count;
    }
    sourceOffset = nextOffset;
  }
  return output;
}

Uint8List workspaceSttFloat32ToPcm16Bytes(Float32List input) {
  final output = Uint8List(input.length * 2);
  final data = ByteData.view(output.buffer);
  for (var i = 0; i < input.length; i++) {
    final clamped = input[i].clamp(-1.0, 1.0);
    final sample = (clamped * 32767.0).round();
    data.setInt16(i * 2, sample, Endian.little);
  }
  return output;
}

int flushWorkspaceSttPcmChunks(
  List<int> captureBytes, {
  required int chunkBytes,
  required bool Function(Uint8List chunk) sendChunk,
}) {
  var sentCount = 0;
  while (captureBytes.length >= chunkBytes) {
    final chunk = Uint8List.fromList(captureBytes.sublist(0, chunkBytes));
    final ok = sendChunk(chunk);
    if (!ok) {
      return sentCount;
    }
    captureBytes.removeRange(0, chunkBytes);
    sentCount += 1;
  }
  return sentCount;
}
