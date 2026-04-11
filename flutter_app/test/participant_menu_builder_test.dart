import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/participant_menu/participant_menu_builder.dart';

ParticipantMenuBuilderInput _input({
  bool isSelf = false,
  bool isModerator = true,
  bool hasPrivateMeetingApiScope = true,
  int? userId = 1,
  bool isRealtimeBot = false,
  String roleKey = 'participant',
  bool micEnabled = true,
  bool cameraEnabled = true,
  bool mutedByHost = false,
  bool videoBlockedByHost = false,
  bool allowSelfUnmute = true,
  bool allowMemberVideo = true,
  bool allowChat = true,
  bool allowScreenShare = true,
  bool micRequestPending = false,
  bool videoRequestPending = false,
  bool screenShareRequestPending = false,
  bool isScreenSharing = false,
}) {
  return ParticipantMenuBuilderInput(
    isSelf: isSelf,
    isModerator: isModerator,
    hasPrivateMeetingApiScope: hasPrivateMeetingApiScope,
    userId: userId,
    isRealtimeBot: isRealtimeBot,
    roleKey: roleKey,
    micEnabled: micEnabled,
    cameraEnabled: cameraEnabled,
    mutedByHost: mutedByHost,
    videoBlockedByHost: videoBlockedByHost,
    allowSelfUnmute: allowSelfUnmute,
    allowMemberVideo: allowMemberVideo,
    allowChat: allowChat,
    allowScreenShare: allowScreenShare,
    micRequestPending: micRequestPending,
    videoRequestPending: videoRequestPending,
    screenShareRequestPending: screenShareRequestPending,
    isScreenSharing: isScreenSharing,
  );
}

void main() {
  test('self menu includes pending request actions with disabled state', () {
    final specs = buildParticipantMenuSpecs(
      _input(
        isSelf: true,
        allowSelfUnmute: false,
        allowMemberVideo: false,
        allowScreenShare: false,
        micRequestPending: true,
        videoRequestPending: false,
        screenShareRequestPending: true,
      ),
    );

    expect(specs.first.kind, ParticipantMenuEntryKind.section);
    expect(specs.first.title, '我的控制');
    expect(
      specs.where((spec) => spec.value == 'rename_self').single.title,
      '修改本次显示名',
    );

    final mic = specs.where((spec) => spec.value == 'request_mic').single;
    expect(mic.title, '开麦申请已提交');
    expect(mic.enabled, isFalse);

    final video = specs.where((spec) => spec.value == 'request_video').single;
    expect(video.title, '申请开视频');
    expect(video.enabled, isTrue);

    final share = specs.where((spec) => spec.value == 'request_share').single;
    expect(share.title, '屏幕共享申请已提交');
    expect(share.enabled, isFalse);
  });

  test('moderator menu for realtime bot exposes ai controls only', () {
    final specs = buildParticipantMenuSpecs(
      _input(
        isRealtimeBot: true,
        userId: null,
        roleKey: 'ai',
        mutedByHost: true,
      ),
    );

    expect(specs.map((spec) => spec.title), contains('AI 控制'));
    expect(
      specs.where((spec) => spec.value == 'unmute').single.title,
      '允许 AI 发言',
    );
    expect(specs.where((spec) => spec.value == 'ai_control'), hasLength(1));
    expect(
      specs.where((spec) => spec.kind == ParticipantMenuEntryKind.action),
      hasLength(2),
    );
  });

  test('moderator menu for guest disables chat permission toggle', () {
    final specs = buildParticipantMenuSpecs(
      _input(
        userId: null,
        roleKey: 'participant',
        allowChat: false,
      ),
    );

    final chat =
        specs.where((spec) => spec.value == 'chat_permission_allow').single;
    expect(chat.enabled, isFalse);
    expect(chat.subtitle, '访客聊天权限跟随会议设置');
    expect(specs.where((spec) => spec.value == 'remove_guest'), hasLength(1));
    expect(specs.where((spec) => spec.value == 'remove'), isEmpty);
  });

  test('non-host member menu includes role management and removal actions', () {
    final specs = buildParticipantMenuSpecs(
      _input(
        roleKey: 'cohost',
        userId: 42,
        allowSelfUnmute: false,
        micRequestPending: true,
      ),
    );

    expect(
        specs.where((spec) => spec.value == 'set_participant'), hasLength(1));
    expect(
      specs.where((spec) => spec.value == 'mic_permission_allow').length,
      greaterThanOrEqualTo(1),
    );
    expect(specs.where((spec) => spec.value == 'remove_ban'), hasLength(1));
  });
}
