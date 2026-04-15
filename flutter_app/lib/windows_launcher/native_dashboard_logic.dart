String defaultDesktopMeetingTitle({
  required String defaultDisplayName,
  required String username,
}) {
  final displayName = defaultDisplayName.trim();
  final user = username.trim();
  final resolved =
      displayName.isNotEmpty ? displayName : (user.isNotEmpty ? user : '用户');
  return '$resolved预定的会议';
}

String resolveDesktopJoinProfileField({
  required String cachedValue,
  required String latestValue,
}) {
  final latest = latestValue.trim();
  if (latest.isNotEmpty) {
    return latest;
  }
  return cachedValue.trim();
}

Map<String, dynamic> buildDesktopMeetingPayload({
  required String title,
  required String description,
  required String scheduledStart,
  required String meetingRecurrence,
  required String meetingTimezone,
  required String duration,
  required String maxParticipants,
  required String password,
  required bool waitingRoom,
  required bool allowGuestLinkJoin,
  required bool allowRecording,
  required bool allowScreenShare,
  required bool allowChat,
  required bool allowSelfUnmute,
  required bool allowMemberVideo,
  required bool muteOnEntry,
}) {
  final meetingTitle = title.trim();
  return <String, dynamic>{
    'title': meetingTitle,
    'description': description.trim().isEmpty ? null : description.trim(),
    'scheduled_start': _scheduledStartPayloadValue(scheduledStart),
    'meeting_recurrence':
        meetingRecurrence.trim().isEmpty ? 'once' : meetingRecurrence.trim(),
    'meeting_timezone': meetingTimezone.trim().isEmpty
        ? 'Asia/Shanghai'
        : meetingTimezone.trim(),
    'duration_minutes': int.tryParse(duration.trim()) ?? 30,
    'max_participants': int.tryParse(maxParticipants.trim()) ?? 100,
    'meeting_password': password.trim().isEmpty ? null : password.trim(),
    'waiting_room_enabled': waitingRoom,
    'allow_guest_link_join': allowGuestLinkJoin,
    'allow_recording': allowRecording,
    'allow_screen_share': allowScreenShare,
    'allow_chat': allowChat,
    'allow_self_unmute': allowSelfUnmute,
    'allow_member_video': allowMemberVideo,
    'mute_on_entry': muteOnEntry,
  };
}

Map<String, dynamic> buildDesktopMeetingUpdatePayload({
  required String title,
  required String description,
  required String scheduledStart,
  required String meetingRecurrence,
  required String meetingTimezone,
  required String duration,
  required String maxParticipants,
  required String password,
  required bool clearPassword,
  required bool waitingRoom,
  required bool allowGuestLinkJoin,
  required bool allowRecording,
  required bool allowScreenShare,
  required bool allowChat,
  required bool allowSelfUnmute,
  required bool allowMemberVideo,
  required bool muteOnEntry,
}) {
  final payload = buildDesktopMeetingPayload(
    title: title,
    description: description,
    scheduledStart: scheduledStart,
    meetingRecurrence: meetingRecurrence,
    meetingTimezone: meetingTimezone,
    duration: duration,
    maxParticipants: maxParticipants,
    password: password,
    waitingRoom: waitingRoom,
    allowGuestLinkJoin: allowGuestLinkJoin,
    allowRecording: allowRecording,
    allowScreenShare: allowScreenShare,
    allowChat: allowChat,
    allowSelfUnmute: allowSelfUnmute,
    allowMemberVideo: allowMemberVideo,
    muteOnEntry: muteOnEntry,
  );
  if (clearPassword) {
    payload['meeting_password'] = '';
  } else if ((payload['meeting_password'] ?? '').toString().trim().isEmpty) {
    payload.remove('meeting_password');
  }
  return payload;
}

String buildDesktopMeetingShareUrl({
  required Uri baseUri,
  required String shareUrl,
  required String shareCode,
}) {
  final fromApi = shareUrl.trim();
  if (fromApi.isNotEmpty) {
    final parsed = Uri.tryParse(fromApi);
    if (parsed != null) {
      if (parsed.hasScheme) {
        return fromApi;
      }
      if (fromApi.startsWith('/')) {
        return baseUri.resolve(fromApi).toString();
      }
    }
  }
  final code = shareCode.trim();
  if (code.isNotEmpty) {
    return baseUri.resolve('/m/$code').toString();
  }
  return '';
}

String buildDesktopMeetingShareText({
  required String title,
  required String roomName,
  required String shareUrl,
  required String meetingPasswordForShare,
  required bool hasPassword,
}) {
  final lines = <String>[
    '会议：${title.trim()}',
    '会议号：${roomName.trim()}',
  ];
  final link = shareUrl.trim();
  if (link.isNotEmpty) {
    lines.add('分享链接：$link');
  }
  final password = meetingPasswordForShare.trim();
  if (password.isNotEmpty) {
    lines.add('会议密码：$password');
  } else if (hasPassword) {
    lines.add('会议已设置密码，请联系主持人获取');
  }
  return lines.join('\n');
}

String buildDesktopMeetingShareLinkCopyText({
  required String shareUrl,
  required String meetingPasswordForShare,
}) {
  final link = shareUrl.trim();
  final password = meetingPasswordForShare.trim();
  if (link.isEmpty) {
    return '';
  }
  if (password.isEmpty) {
    return link;
  }
  return '$link\n会议密码：$password';
}

String formatDesktopDateTimeForInput(DateTime value) {
  return '${value.year}-${_twoDigits(value.month)}-${_twoDigits(value.day)} '
      '${_twoDigits(value.hour)}:${_twoDigits(value.minute)}';
}

DateTime? parseDesktopDateTimeInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return null;
  }
  final direct = DateTime.tryParse(text);
  if (direct != null) {
    return direct.toLocal();
  }
  final normalized = text.replaceAll('/', '-');
  final match = RegExp(
    r'^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{1,2})$',
  ).firstMatch(normalized);
  if (match == null) {
    return null;
  }
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4)!);
  final minute = int.tryParse(match.group(5)!);
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null) {
    return null;
  }
  final parsed = DateTime(year, month, day, hour, minute);
  if (parsed.year != year ||
      parsed.month != month ||
      parsed.day != day ||
      parsed.hour != hour ||
      parsed.minute != minute) {
    return null;
  }
  return parsed;
}

String? _scheduledStartPayloadValue(String raw) {
  final parsed = parseDesktopDateTimeInput(raw);
  if (parsed == null) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return parsed.toIso8601String();
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
