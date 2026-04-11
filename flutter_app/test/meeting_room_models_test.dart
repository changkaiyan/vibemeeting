import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/models.dart';

void main() {
  test('ChatMessage normalizes sender and timestamp fields', () {
    final message = ChatMessage.fromJson(<String, dynamic>{
      'id': '42',
      'sender_user_id': '7',
      'sender_username': 'alice',
      'sender_display_name': '',
      'is_realtime_bot': '1',
      'audio_mime_type': 'audio/wav',
      'audio_base64': 'ZmFrZQ==',
      'content': 'hello',
      'created_at': '2026-04-11T00:00:00Z',
    });

    expect(message.id, 42);
    expect(message.senderUserId, 7);
    expect(message.senderUsername, 'alice');
    expect(message.senderDisplayName, '');
    expect(message.isRealtimeBot, isTrue);
    expect(message.createdAt, isNotNull);
  });

  test('WorkspaceContextSnapshot keeps topic summary and lists', () {
    final snapshot = WorkspaceContextSnapshot.fromJson(<String, dynamic>{
      'topic_label': 'API migration',
      'summary_text': 'need land v2 before launch',
      'decisions': <String>['keep REST'],
      'todos': <String>['write tests', 'update docs'],
    });

    expect(snapshot.topicLabel, 'API migration');
    expect(snapshot.summaryText, 'need land v2 before launch');
    expect(snapshot.decisions, <String>['keep REST']);
    expect(snapshot.todos, <String>['write tests', 'update docs']);
  });

  test('JoinTokenPayload parses booleans ints and date values', () {
    final payload = JoinTokenPayload.fromJson(<String, dynamic>{
      'meeting_id': '9',
      'meeting_ref': 'm-001',
      'room_name': 'demo-room',
      'livekit_url': 'wss://livekit.example.com',
      'token': 'jwt',
      'waiting_room_enabled': 'true',
      'max_participants': '88',
      'actual_started_at': '2026-04-11T01:02:03Z',
      'mute_on_entry': 1,
      'allow_guest_link_join': 0,
      'allow_recording': true,
      'allow_screen_share': true,
      'allow_chat': false,
      'allow_self_unmute': true,
      'allow_member_video': false,
      'can_publish': '1',
    });

    expect(payload.meetingId, 9);
    expect(payload.meetingRef, 'm-001');
    expect(payload.waitingRoomEnabled, isTrue);
    expect(payload.maxParticipants, 88);
    expect(payload.actualStartedAt, isNotNull);
    expect(payload.muteOnEntry, isTrue);
    expect(payload.allowGuestLinkJoin, isFalse);
    expect(payload.canPublish, isTrue);
  });
}
