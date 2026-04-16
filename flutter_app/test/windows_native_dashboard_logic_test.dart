import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/windows_launcher/native_dashboard_logic.dart';

void main() {
  group('defaultDesktopMeetingTitle', () {
    test('prefers display name', () {
      expect(
        defaultDesktopMeetingTitle(
          defaultDisplayName: 'Alice',
          username: 'alice_u',
        ),
        'Alice预定的会议',
      );
    });

    test('falls back to username', () {
      expect(
        defaultDesktopMeetingTitle(
          defaultDisplayName: '   ',
          username: 'alice_u',
        ),
        'alice_u预定的会议',
      );
    });
  });

  group('buildDesktopMeetingPayload', () {
    test('normalizes nullable and numeric fields', () {
      final payload = buildDesktopMeetingPayload(
        title: '  Team Sync  ',
        description: '   ',
        scheduledStart: '2026-05-01 10:15',
        meetingRecurrence: '',
        meetingTimezone: '',
        duration: 'xx',
        maxParticipants: '',
        password: '  ',
        waitingRoom: true,
        allowGuestLinkJoin: false,
        allowRecording: true,
        allowScreenShare: true,
        allowChat: true,
        allowSelfUnmute: false,
        allowMemberVideo: true,
        muteOnEntry: true,
      );

      expect(payload['title'], 'Team Sync');
      expect(payload['description'], isNull);
      expect(payload['meeting_recurrence'], 'once');
      expect(payload['meeting_timezone'], 'Asia/Shanghai');
      expect(payload['duration_minutes'], 30);
      expect(payload['max_participants'], 100);
      expect(payload['meeting_password'], isNull);
      expect(payload['waiting_room_enabled'], isTrue);
      expect(payload['allow_guest_link_join'], isFalse);
      expect(payload['allow_self_unmute'], isFalse);
      expect(payload['mute_on_entry'], isTrue);
      expect((payload['scheduled_start'] as String?)?.contains('T'), isTrue);
    });
  });

  group('buildDesktopMeetingUpdatePayload', () {
    test('removes empty password by default', () {
      final payload = buildDesktopMeetingUpdatePayload(
        title: 'Demo',
        description: '',
        scheduledStart: '',
        meetingRecurrence: 'once',
        meetingTimezone: 'Asia/Shanghai',
        duration: '45',
        maxParticipants: '50',
        password: '  ',
        clearPassword: false,
        waitingRoom: false,
        allowGuestLinkJoin: true,
        allowRecording: true,
        allowScreenShare: true,
        allowChat: true,
        allowSelfUnmute: true,
        allowMemberVideo: true,
        muteOnEntry: false,
      );

      expect(payload.containsKey('meeting_password'), isFalse);
    });

    test('forces clear password when requested', () {
      final payload = buildDesktopMeetingUpdatePayload(
        title: 'Demo',
        description: '',
        scheduledStart: '',
        meetingRecurrence: 'once',
        meetingTimezone: 'Asia/Shanghai',
        duration: '45',
        maxParticipants: '50',
        password: '  ',
        clearPassword: true,
        waitingRoom: false,
        allowGuestLinkJoin: true,
        allowRecording: true,
        allowScreenShare: true,
        allowChat: true,
        allowSelfUnmute: true,
        allowMemberVideo: true,
        muteOnEntry: false,
      );

      expect(payload['meeting_password'], '');
    });
  });

  group('buildDesktopMeetingShareText', () {
    test('includes password line when password exists', () {
      final text = buildDesktopMeetingShareText(
        title: 'Weekly Sync',
        roomName: 'room-1',
        shareUrl: 'https://example.com/m/abc',
        meetingPasswordForShare: '1234',
        hasPassword: true,
      );

      expect(text, contains('会议：Weekly Sync'));
      expect(text, contains('会议号：room-1'));
      expect(text, contains('分享链接：https://example.com/m/abc'));
      expect(text, contains('会议密码：1234'));
    });
  });

  group('resolveDesktopJoinProfileField', () {
    test('prefers latest non-empty value', () {
      expect(
        resolveDesktopJoinProfileField(
          cachedValue: '旧显示名',
          latestValue: '新显示名',
        ),
        '新显示名',
      );
    });

    test('falls back to cached value when latest is empty', () {
      expect(
        resolveDesktopJoinProfileField(
          cachedValue: '旧显示名',
          latestValue: '   ',
        ),
        '旧显示名',
      );
    });
  });
}
