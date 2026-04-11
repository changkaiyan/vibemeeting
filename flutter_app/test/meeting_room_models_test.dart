import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/models.dart';
import 'package:smart_meeting_app/meeting_room/realtime_bot_protocol.dart';

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

  test('MeetingRealtimeBotConfig prefers provider-specific fields with legacy fallback', () {
    final config = MeetingRealtimeBotConfig.fromMeetingJson(<String, dynamic>{
      'realtime_bot_provider': 'volcengine',
      'realtime_bot_openai_model': 'gpt-realtime-mini',
      'realtime_bot_openai_voice': 'verse',
      'realtime_bot_model': 'legacy-model',
      'realtime_bot_voice': 'legacy-voice',
      'realtime_bot_volc_model': '',
      'realtime_bot_volc_voice': '',
    });

    expect(config.provider, 'volcengine');
    expect(config.openaiModel, 'gpt-realtime-mini');
    expect(config.openaiVoice, 'verse');
    expect(config.volcModel, 'legacy-model');
    expect(config.volcVoice, 'legacy-voice');
  });

  test('MeetingRealtimeBotControlsDraft builds provider-specific save payload', () {
    final openaiPayload = MeetingRealtimeBotControlsDraft(
      provider: 'openai',
      enabled: true,
      muted: false,
      displayName: 'AI 助手',
      baseUrl: 'https://api.openai.com',
      openaiModel: 'gpt-realtime',
      openaiVoice: 'marin',
      volcModel: '',
      volcVoice: '',
      volcWsUrl: '',
      volcAppId: '',
      volcResourceId: '',
      volcUid: '',
      apiKeyAlreadySet: false,
      volcAccessKeyAlreadySet: false,
    ).buildSavePayload(apiKey: 'sk-test');

    expect(openaiPayload['realtime_bot_openai_model'], 'gpt-realtime');
    expect(openaiPayload['realtime_bot_openai_voice'], 'marin');
    expect(openaiPayload.containsKey('realtime_bot_model'), isFalse);
    expect(openaiPayload['realtime_bot_api_key'], 'sk-test');

    final volcPayload = MeetingRealtimeBotControlsDraft(
      provider: 'volcengine',
      enabled: true,
      muted: true,
      displayName: '火山助手',
      baseUrl: '',
      openaiModel: '',
      openaiVoice: '',
      volcModel: '',
      volcVoice: 'zh_female',
      volcWsUrl: 'wss://openspeech.bytedance.com/api/v3/realtime/dialogue',
      volcAppId: 'app-id',
      volcResourceId: 'volc.speech.dialog',
      volcUid: 'uid-1',
      apiKeyAlreadySet: false,
      volcAccessKeyAlreadySet: false,
    ).buildSavePayload(volcAccessKey: 'ak-test');

    expect(volcPayload['realtime_bot_volc_model'], '2.2.0.0');
    expect(volcPayload['realtime_bot_volc_voice'], 'zh_female');
    expect(volcPayload['realtime_bot_volc_access_key'], 'ak-test');
  });

  test('parseRealtimeBotIngressMessage normalizes websocket protocol events', () {
    final asr = parseRealtimeBotIngressMessage(
      '{"type":"asr","text":"你好","is_interim":false}',
    )!;
    expect(asr.kind, RealtimeBotIngressMessageKind.asrFinal);
    expect(asr.previewText, '你好');

    final result = parseRealtimeBotIngressMessage(<String, dynamic>{
      'type': 'result',
      'recognized_text': '测试识别',
      'preview_text': '测试回复',
      'message': <String, dynamic>{'id': 1},
    })!;
    expect(result.kind, RealtimeBotIngressMessageKind.result);
    expect(result.recognizedText, '测试识别');
    expect(result.previewText, '测试回复');
    expect(result.message, isA<Map<String, dynamic>>());
  });

  test('meetingAiRealtimeAudioWsPath converts api path to websocket path', () {
    expect(
      meetingAiRealtimeAudioWsPath('/api/meetings/7/ai-controls/realtime-audio'),
      '/ws/meetings/7/ai-controls/realtime-audio',
    );
  });
}
