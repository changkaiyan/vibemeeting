import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/windows_launcher/native_join_target.dart';

void main() {
  group('resolveDesktopJoinTarget', () {
    test('parses share path', () {
      final target = resolveDesktopJoinTarget('/m/demo-share?autojoin=1');
      expect(target.shareCode, 'demo-share');
      expect(target.meetingRef, isNull);
      expect(target.roomName, isNull);
    });

    test('parses private meeting ref path', () {
      final target = resolveDesktopJoinTarget('/my/meetings/ref-01?autojoin=1');
      expect(target.meetingRef, 'ref-01');
      expect(target.shareCode, isNull);
      expect(target.roomName, isNull);
    });

    test('parses absolute meeting url', () {
      final target =
          resolveDesktopJoinTarget('https://meeting.example.com/m/s-001');
      expect(target.shareCode, 's-001');
      expect(target.meetingRef, isNull);
    });

    test('keeps plain input as fallback for ref/share/room', () {
      final target = resolveDesktopJoinTarget('room-7788');
      expect(target.meetingRef, 'room-7788');
      expect(target.shareCode, 'room-7788');
      expect(target.roomName, 'room-7788');
    });
  });
}
