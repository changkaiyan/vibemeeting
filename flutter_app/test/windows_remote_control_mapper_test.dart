import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/windows_launcher/windows_remote_control_mapper.dart';

void main() {
  group('windowsVirtualKeyFromHidUsage', () {
    test('maps latin letters', () {
      expect(windowsVirtualKeyFromHidUsage(0x70004), 0x41);
      expect(windowsVirtualKeyFromHidUsage(0x7001D), 0x5A);
    });

    test('maps function and navigation keys', () {
      expect(windowsVirtualKeyFromHidUsage(0x7003E), 0x74); // F5
      expect(windowsVirtualKeyFromHidUsage(0x70052), 0x26); // Arrow up
      expect(windowsVirtualKeyFromHidUsage(0x7004C), 0x2E); // Delete
    });

    test('returns null for unknown usage', () {
      expect(windowsVirtualKeyFromHidUsage(0x79999), isNull);
    });
  });

  group('normalized pointer helpers', () {
    test('clamps unit coordinates', () {
      expect(clampRemoteControlUnit(-0.2), 0);
      expect(clampRemoteControlUnit(0.5), 0.5);
      expect(clampRemoteControlUnit(3), 1);
    });

    test('maps normalized coordinate to screen point', () {
      final p1 = mapNormalizedToScreenPoint(
        x: 0,
        y: 0,
        screenWidth: 1920,
        screenHeight: 1080,
      );
      final p2 = mapNormalizedToScreenPoint(
        x: 1,
        y: 1,
        screenWidth: 1920,
        screenHeight: 1080,
      );
      expect(p1, (x: 0, y: 0));
      expect(p2, (x: 1919, y: 1079));
    });
  });
}
