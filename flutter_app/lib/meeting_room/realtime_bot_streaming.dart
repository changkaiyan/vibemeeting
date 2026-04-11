import 'dart:typed_data';

int flushRealtimeBotStreamChunks(
  List<int> captureBytes, {
  required int chunkBytes,
  required bool Function(Uint8List chunk) sendChunk,
  bool force = false,
  int minFinalChunkBytes = 320,
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
  if (!force) {
    return sentCount;
  }
  final remain = captureBytes.length - (captureBytes.length % 2);
  if (remain < minFinalChunkBytes) {
    captureBytes.clear();
    return sentCount;
  }
  final chunk = Uint8List.fromList(captureBytes.sublist(0, remain));
  final ok = sendChunk(chunk);
  if (ok) {
    captureBytes.removeRange(0, remain);
    sentCount += 1;
  }
  return sentCount;
}

bool shouldEndRealtimeBotSpeechTurn({
  required int elapsedMs,
  required int silenceMs,
  required int minSpeechMs,
  required int silenceThresholdMs,
  required int maxSpeechMs,
}) {
  return elapsedMs >= maxSpeechMs ||
      (elapsedMs >= minSpeechMs && silenceMs >= silenceThresholdMs);
}

bool shouldRestartRealtimeBotCapture({
  required DateTime now,
  required DateTime? boundAt,
  required DateTime? lastProcessAt,
  int stallMs = 8000,
}) {
  final baseline = lastProcessAt ?? boundAt;
  if (baseline == null) {
    return false;
  }
  return now.difference(baseline).inMilliseconds > stallMs;
}
