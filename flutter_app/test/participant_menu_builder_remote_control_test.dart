import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/participant_menu/participant_menu_builder.dart';

ParticipantMenuBuilderInput _input({
  bool isSelf = false,
  bool isModerator = false,
  bool hasPrivateMeetingApiScope = false,
  bool isRealtimeBot = false,
  bool remoteControlAvailable = true,
  bool remoteControlActive = false,
  bool remoteControlRequestPending = false,
}) {
  return ParticipantMenuBuilderInput(
    isSelf: isSelf,
    isModerator: isModerator,
    hasPrivateMeetingApiScope: hasPrivateMeetingApiScope,
    userId: 1,
    isRealtimeBot: isRealtimeBot,
    roleKey: 'participant',
    micEnabled: true,
    cameraEnabled: true,
    mutedByHost: false,
    videoBlockedByHost: false,
    allowSelfUnmute: true,
    allowMemberVideo: true,
    allowChat: true,
    allowScreenShare: true,
    micRequestPending: false,
    videoRequestPending: false,
    screenShareRequestPending: false,
    isScreenSharing: false,
    remoteControlAvailable: remoteControlAvailable,
    remoteControlActive: remoteControlActive,
    remoteControlRequestPending: remoteControlRequestPending,
  );
}

void main() {
  test('non-moderator can still request remote control for a participant', () {
    final specs = buildParticipantMenuSpecs(_input());
    final values = specs
        .where((item) => item.kind == ParticipantMenuEntryKind.action)
        .map((item) => item.value)
        .toList(growable: false);

    expect(values, contains('request_remote_control'));
  });

  test('active remote control exposes stop action', () {
    final specs = buildParticipantMenuSpecs(
      _input(remoteControlActive: true),
    );
    final values = specs
        .where((item) => item.kind == ParticipantMenuEntryKind.action)
        .map((item) => item.value)
        .toList(growable: false);

    expect(values, contains('stop_remote_control'));
    expect(values, isNot(contains('request_remote_control')));
  });

  test('realtime bot does not expose remote control actions', () {
    final specs = buildParticipantMenuSpecs(_input(isRealtimeBot: true));
    final values = specs
        .where((item) => item.kind == ParticipantMenuEntryKind.action)
        .map((item) => item.value)
        .toList(growable: false);

    expect(values, isNot(contains('request_remote_control')));
    expect(values, isNot(contains('stop_remote_control')));
  });
}
