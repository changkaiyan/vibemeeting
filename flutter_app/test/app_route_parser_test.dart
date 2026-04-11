import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/routing/app_route_parser.dart';

void main() {
  group('resolveAppRoute', () {
    test('resolves personal meeting ref route', () {
      final route = resolveAppRoute(
        Uri.parse('https://example.com/my/meetings/demo-room?autojoin=1'),
      );

      expect(route.kind, AppRouteKind.meetingRoom);
      expect(route.meetingRef, 'demo-room');
      expect(route.autoJoin, isTrue);
    });

    test('resolves numeric meeting id route', () {
      final route = resolveAppRoute(
        Uri.parse('https://example.com/meetings/42'),
      );

      expect(route.kind, AppRouteKind.meetingRoom);
      expect(route.meetingId, 42);
      expect(route.autoJoin, isFalse);
    });

    test('resolves share code route with default auto join', () {
      final route = resolveAppRoute(
        Uri.parse('https://example.com/m/share-code'),
      );

      expect(route.kind, AppRouteKind.meetingRoom);
      expect(route.shareCode, 'share-code');
      expect(route.autoJoin, isTrue);
    });

    test('resolves billing route', () {
      final route = resolveAppRoute(
        Uri.parse('https://example.com/billing'),
      );

      expect(route.kind, AppRouteKind.billingAdmin);
    });

    test('falls back to dashboard route', () {
      final route = resolveAppRoute(
        Uri.parse('https://example.com/unknown/path'),
      );

      expect(route.kind, AppRouteKind.dashboard);
    });
  });
}
