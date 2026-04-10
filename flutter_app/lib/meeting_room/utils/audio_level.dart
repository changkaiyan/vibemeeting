import 'dart:math' as math;

double computeNormalizedMicTestLevel(List<int> byteSamples) {
  if (byteSamples.isEmpty) {
    return 0;
  }
  var sum = 0.0;
  for (final sample in byteSamples) {
    final centered = (sample - 128) / 128;
    sum += centered * centered;
  }
  final rms = sum / byteSamples.length;
  final normalized = (rms == 0 ? 0.0 : math.sqrt(rms) * 6).clamp(0.0, 1.0);
  return normalized;
}
