import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_dashboard/meeting_room/audio_level.dart';

void main() {
  group('computeNormalizedMicTestLevel', () {
    test('returns zero for empty samples', () {
      expect(computeNormalizedMicTestLevel(const []), 0);
    });

    test('returns zero for silence', () {
      expect(
        computeNormalizedMicTestLevel(List<int>.filled(8, 128)),
        0,
      );
    });

    test('returns positive level for non-silent samples', () {
      final level = computeNormalizedMicTestLevel(
        const [128, 148, 108, 140, 116, 150, 106, 128],
      );
      expect(level, greaterThan(0));
      expect(level, lessThanOrEqualTo(1));
    });
  });
}
