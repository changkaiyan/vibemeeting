import '../../core/json_parsing.dart';

class MeetingItem {
  MeetingItem({
    required this.meetingRef,
    required this.title,
    required this.roomName,
    required this.shareCode,
    required this.shareUrl,
    required this.meetingPasswordForShare,
    required this.description,
    required this.scheduledStart,
    required this.meetingRecurrence,
    required this.meetingTimezone,
    required this.durationMinutes,
    required this.maxParticipants,
    required this.hasPassword,
    required this.waitingRoomEnabled,
    required this.allowGuestLinkJoin,
    required this.allowRecording,
    required this.allowScreenShare,
    required this.allowChat,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.muteOnEntry,
    required this.canEdit,
    required this.canDelete,
    required this.canDebugToken,
  });

  final String meetingRef;
  final String title;
  final String roomName;
  final String shareCode;
  final String shareUrl;
  final String meetingPasswordForShare;
  final String? description;
  final String? scheduledStart;
  final String meetingRecurrence;
  final String meetingTimezone;
  final int durationMinutes;
  final int maxParticipants;
  final bool hasPassword;
  final bool waitingRoomEnabled;
  final bool allowGuestLinkJoin;
  final bool allowRecording;
  final bool allowScreenShare;
  final bool allowChat;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool muteOnEntry;
  final bool canEdit;
  final bool canDelete;
  final bool canDebugToken;

  factory MeetingItem.fromJson(Map<String, dynamic> json) {
    return MeetingItem(
      meetingRef: (json['meeting_ref'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      roomName: (json['room_name'] ?? '').toString(),
      shareCode: (json['share_code'] ?? '').toString(),
      shareUrl: (json['share_url'] ?? '').toString(),
      meetingPasswordForShare:
          (json['meeting_password_for_share'] ?? '').toString(),
      description: json['description']?.toString(),
      scheduledStart: json['scheduled_start']?.toString(),
      meetingRecurrence: (json['meeting_recurrence'] ?? 'once').toString(),
      meetingTimezone: (json['meeting_timezone'] ?? 'Asia/Shanghai').toString(),
      durationMinutes: JsonParsing.asInt(json['duration_minutes'], 30),
      maxParticipants: JsonParsing.asInt(json['max_participants'], 100),
      hasPassword: JsonParsing.asBool(json['has_password'], false),
      waitingRoomEnabled:
          JsonParsing.asBool(json['waiting_room_enabled'], false),
      allowGuestLinkJoin:
          JsonParsing.asBool(json['allow_guest_link_join'], true),
      allowRecording: JsonParsing.asBool(json['allow_recording'], true),
      allowScreenShare: JsonParsing.asBool(json['allow_screen_share'], true),
      allowChat: JsonParsing.asBool(json['allow_chat'], true),
      allowSelfUnmute: JsonParsing.asBool(json['allow_self_unmute'], true),
      allowMemberVideo: JsonParsing.asBool(json['allow_member_video'], true),
      muteOnEntry: JsonParsing.asBool(json['mute_on_entry'], false),
      canEdit: JsonParsing.asBool(json['can_edit'], false),
      canDelete: JsonParsing.asBool(json['can_delete'], false),
      canDebugToken: JsonParsing.asBool(json['can_debug_token'], false),
    );
  }
}

class UserProfileData {
  UserProfileData({
    required this.username,
    required this.email,
    required this.avatarUrl,
    required this.defaultDisplayName,
    required this.isAdmin,
  });

  final String username;
  final String email;
  final String avatarUrl;
  final String defaultDisplayName;
  final bool isAdmin;

  factory UserProfileData.fromJson(Map<String, dynamic> json) {
    final username = (json['username'] ?? '').toString();
    final displayName = (json['default_display_name'] ?? '').toString().trim();
    return UserProfileData(
      username: username,
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      defaultDisplayName: displayName.isEmpty ? username : displayName,
      isAdmin: JsonParsing.asBool(json['is_admin'], false),
    );
  }
}

class RecordingItem {
  RecordingItem({
    required this.id,
    required this.meetingId,
    required this.meetingDisplayId,
    required this.meetingRef,
    required this.meetingDeleted,
    required this.meetingTitle,
    required this.meetingRoomName,
    required this.ownerUserId,
    required this.ownerUsername,
    required this.ownerDisplayName,
    required this.recordedByDisplayName,
    required this.fileName,
    required this.storageRoot,
    required this.relativePath,
    required this.storedFilePath,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.createdAt,
    required this.downloadPath,
  });

  final int id;
  final int meetingId;
  final int meetingDisplayId;
  final String meetingRef;
  final bool meetingDeleted;
  final String meetingTitle;
  final String meetingRoomName;
  final int ownerUserId;
  final String ownerUsername;
  final String ownerDisplayName;
  final String recordedByDisplayName;
  final String fileName;
  final String storageRoot;
  final String relativePath;
  final String storedFilePath;
  final String mimeType;
  final int sizeBytes;
  final int? durationSeconds;
  final String createdAt;
  final String downloadPath;

  factory RecordingItem.fromJson(Map<String, dynamic> json) {
    final rawDuration = json['duration_seconds'];
    int? duration;
    if (rawDuration is int) {
      duration = rawDuration;
    } else if (rawDuration is num) {
      duration = rawDuration.toInt();
    } else if (rawDuration is String) {
      duration = int.tryParse(rawDuration.trim());
    }
    return RecordingItem(
      id: JsonParsing.asInt(json['id'], 0),
      meetingId: JsonParsing.asInt(json['meeting_id'], 0),
      meetingDisplayId: JsonParsing.asInt(
        json['meeting_display_id'],
        JsonParsing.asInt(json['meeting_id'], 0),
      ),
      meetingRef: (json['meeting_ref'] ?? '').toString(),
      meetingDeleted: JsonParsing.asBool(json['meeting_deleted'], false),
      meetingTitle: (json['meeting_title'] ?? '').toString(),
      meetingRoomName: (json['meeting_room_name'] ?? '').toString(),
      ownerUserId: JsonParsing.asInt(json['owner_user_id'], 0),
      ownerUsername: (json['owner_username'] ?? '').toString(),
      ownerDisplayName: (json['owner_display_name'] ?? '').toString(),
      recordedByDisplayName:
          (json['recorded_by_display_name'] ?? '').toString(),
      fileName: (json['file_name'] ?? '').toString(),
      storageRoot: (json['storage_root'] ?? '').toString(),
      relativePath: (json['relative_path'] ?? '').toString(),
      storedFilePath: (json['stored_file_path'] ?? '').toString(),
      mimeType: (json['mime_type'] ?? '').toString(),
      sizeBytes: JsonParsing.asInt(json['size_bytes'], 0),
      durationSeconds: duration,
      createdAt: (json['created_at'] ?? '').toString(),
      downloadPath: (json['download_path'] ?? '').toString(),
    );
  }
}
