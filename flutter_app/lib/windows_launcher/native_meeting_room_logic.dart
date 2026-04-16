String meetingRoleLabelZh(String role) {
  switch (role.trim().toLowerCase()) {
    case 'host':
      return '\u4e3b\u6301\u4eba';
    case 'cohost':
      return '\u8054\u5e2d\u4e3b\u6301';
    case 'participant':
      return '\u53c2\u4f1a\u6210\u5458';
    default:
      return '\u6210\u5458';
  }
}

bool canRaiseHandForRole(String role) {
  final normalized = role.trim().toLowerCase();
  return normalized != 'host' && normalized != 'cohost';
}

bool isModeratorRole(String role) {
  final normalized = role.trim().toLowerCase();
  return normalized == 'host' || normalized == 'cohost';
}

String normalizedRaiseHandRequestType(String raw) {
  final normalized = raw.trim().toLowerCase();
  if (normalized == 'video') {
    return 'video';
  }
  return 'mic';
}

bool shouldUseDesktopSourcePicker({
  required bool isWeb,
  required String platform,
}) {
  if (isWeb) return false;
  final normalized = platform.trim().toLowerCase();
  return normalized == 'windows' ||
      normalized == 'linux' ||
      normalized == 'macos';
}

bool shouldUseSystemWindowFullscreen({
  required bool isWeb,
  required String platform,
}) {
  if (isWeb) return false;
  return platform.trim().toLowerCase() == 'windows';
}

bool shouldUseSystemWindowFullscreenForTile({
  required bool isWeb,
  required String platform,
  required bool isRemoteControlTileActive,
}) {
  if (isRemoteControlTileActive) {
    return false;
  }
  return shouldUseSystemWindowFullscreen(isWeb: isWeb, platform: platform);
}

bool isScreenShareSourceNotFoundError(Object error) {
  final normalized = error.toString().trim().toLowerCase();
  return normalized.contains('source not found');
}

bool isJoinWithoutMediaTrackError(Object error) {
  final normalized = error.toString().trim().toLowerCase();
  return normalized.contains('failed to create stream') &&
      normalized.contains('at least 1 video or audio track should exist');
}

String mapScreenShareErrorToStatus(Object error) {
  final text = error.toString().trim();
  final normalized = text.toLowerCase();
  if (normalized.contains('aborterror') ||
      normalized.contains('cancel') ||
      normalized.contains('canceled') ||
      normalized.contains('cancelled') ||
      normalized.contains('dismiss')) {
    return '\u5df2\u53d6\u6d88\u5c4f\u5e55\u5171\u4eab\u9009\u62e9';
  }
  if (normalized.contains('notallowederror') ||
      normalized.contains('permission')) {
    return '\u5c4f\u5e55\u5171\u4eab\u5931\u8d25\uff1a'
        '\u8bf7\u68c0\u67e5\u7cfb\u7edf\u5c4f\u5e55\u5f55\u5236\u6743\u9650'
        '\uff08\u5e76\u786e\u8ba4\u5df2\u5141\u8bb8\u672c\u5e94\u7528\uff09';
  }
  if (isScreenShareSourceNotFoundError(error)) {
    return '\u5c4f\u5e55\u5171\u4eab\u5931\u8d25\uff1a'
        '\u5171\u4eab\u6e90\u5931\u6548\uff0c\u8bf7\u91cd\u65b0\u9009\u62e9\u540e\u91cd\u8bd5';
  }
  return '\u5c4f\u5e55\u5171\u4eab\u5207\u6362\u5931\u8d25\uff1a$text';
}

List<Map<String, dynamic>> sortMembersForDisplay(
  List<Map<String, dynamic>> members,
) {
  final copy = List<Map<String, dynamic>>.from(members);

  int roleWeight(String role) {
    switch (role.trim().toLowerCase()) {
      case 'host':
        return 0;
      case 'cohost':
        return 1;
      default:
        return 2;
    }
  }

  copy.sort((a, b) {
    final roleA = roleWeight((a['role'] ?? '').toString());
    final roleB = roleWeight((b['role'] ?? '').toString());
    if (roleA != roleB) {
      return roleA.compareTo(roleB);
    }
    final nameA = (a['display_name'] ?? a['username'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final nameB = (b['display_name'] ?? b['username'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return nameA.compareTo(nameB);
  });
  return copy;
}

String buildNativeMeetingShareText({
  required String meetingTitle,
  required String roomName,
  required String meetingRef,
  required String shareUrl,
}) {
  final title = meetingTitle.trim().isEmpty
      ? '\u672a\u547d\u540d\u4f1a\u8bae'
      : meetingTitle.trim();
  final room = roomName.trim().isEmpty ? '-' : roomName.trim();
  final ref = meetingRef.trim();
  final url = shareUrl.trim();
  final lines = <String>[
    '\u4f1a\u8bae\uff1a$title',
    '\u4f1a\u8bae\u53f7\uff1a$room',
  ];
  if (ref.isNotEmpty) {
    lines.add('\u4f1a\u8bae\u6807\u8bc6\uff1a$ref');
  }
  if (url.isNotEmpty) {
    lines.add('\u5206\u4eab\u94fe\u63a5\uff1a$url');
  }
  lines.add(
      '\u8bf7\u5728\u5ba2\u6237\u7aef\u8f93\u5165\u4f1a\u8bae\u53f7\u52a0\u5165\u4f1a\u8bae\u3002');
  return lines.join('\n');
}

int stageGridColumnsForWidth(double width) {
  if (width >= 1100) return 3;
  if (width >= 700) return 2;
  return 1;
}

bool shouldShowTileZoomControls({
  required bool hasVideoTrack,
  required bool isSpotlight,
  required bool isFullscreen,
}) {
  return hasVideoTrack && (isSpotlight || isFullscreen);
}

String micButtonLabelZh({required bool micEnabled}) {
  return micEnabled ? '\u9759\u97f3' : '\u53d6\u6d88\u9759\u97f3';
}

String cameraButtonLabelZh({required bool cameraEnabled}) {
  return cameraEnabled
      ? '\u5173\u95ed\u6444\u50cf\u5934'
      : '\u5f00\u542f\u6444\u50cf\u5934';
}

String screenShareButtonLabelZh({
  required bool canShareScreen,
  required bool screenShareEnabled,
}) {
  if (!canShareScreen) {
    return '\u5171\u4eab\u5df2\u7981\u7528';
  }
  return screenShareEnabled
      ? '\u505c\u6b62\u5171\u4eab'
      : '\u5171\u4eab\u5c4f\u5e55';
}

bool canToggleMicButton({
  required bool connected,
  required bool micEnabled,
  required bool canSelfUnmute,
}) {
  return connected && (micEnabled || canSelfUnmute);
}

bool canToggleCameraButton({
  required bool connected,
  required bool cameraEnabled,
  required bool canOpenVideo,
}) {
  return connected && (cameraEnabled || canOpenVideo);
}

bool shouldStartRemoteControlScreenShare({
  required bool screenShareEnabled,
  required bool canScreenShare,
}) {
  return !screenShareEnabled && canScreenShare;
}

bool shouldSendRemoteHoverPointerMoves({
  required bool isWeb,
  required String platform,
}) {
  if (isWeb) return false;
  final normalized = platform.trim().toLowerCase();
  return normalized == 'windows' ||
      normalized == 'linux' ||
      normalized == 'macos';
}

bool shouldForceReliableRemotePointerMove(int moveSequence) {
  if (moveSequence <= 0) return true;
  return moveSequence % 5 == 0;
}

bool shouldIncludeWindowSourcesInDesktopPicker({
  required bool forRemoteControlAutoStart,
}) {
  return !forRemoteControlAutoStart;
}

bool shouldSendRemotePointerReliably({
  required String event,
  required int moveSequence,
}) {
  final normalized = event.trim().toLowerCase();
  if (normalized == 'down' || normalized == 'up') {
    return true;
  }
  if (normalized == 'move') {
    return shouldForceReliableRemotePointerMove(moveSequence);
  }
  return false;
}

bool shouldStopAutoStartedRemoteControlScreenShare({
  required bool autoStartedByRemoteControl,
  required bool sessionWasBeingControlled,
}) {
  return autoStartedByRemoteControl && sessionWasBeingControlled;
}

String remoteControlScreenShareRequiredStatusZh() {
  return '\u8fdc\u7a0b\u63a7\u5236\u9700\u5148\u5f00\u542f\u5c4f\u5e55\u5171\u4eab';
}

String remoteControlTargetScreenNotReadyStatusZh() {
  return '\u8fdc\u7a0b\u753b\u9762\u6682\u672a\u5c31\u7eea\uff0c'
      '\u8bf7\u5bf9\u65b9\u91cd\u65b0\u5171\u4eab\u5c4f\u5e55\u540e\u91cd\u8bd5';
}
