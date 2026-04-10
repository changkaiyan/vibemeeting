import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_dashboard/meeting_room/stt_debug.dart';

void main() {
  group('workspaceSttReadyStateLabel', () {
    test('maps websocket ready states', () {
      expect(workspaceSttReadyStateLabel(0), 'connecting');
      expect(workspaceSttReadyStateLabel(1), 'open');
      expect(workspaceSttReadyStateLabel(2), 'closing');
      expect(workspaceSttReadyStateLabel(3), 'closed');
    });

    test('falls back for unknown states', () {
      expect(workspaceSttReadyStateLabel(null), 'not-created');
      expect(workspaceSttReadyStateLabel(9), 'not-created');
    });
  });

  group('workspaceSttErrorLabel', () {
    test('normalizes empty error text', () {
      expect(workspaceSttErrorLabel(null), '-');
      expect(workspaceSttErrorLabel(''), '-');
      expect(workspaceSttErrorLabel('   '), '-');
    });

    test('preserves non-empty error text', () {
      expect(workspaceSttErrorLabel('permission denied'), 'permission denied');
    });
  });
}
