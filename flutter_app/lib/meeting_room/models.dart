import 'package:livekit_client/livekit_client.dart' as lk;

class MeetingApiException implements Exception {
  const MeetingApiException({
    required this.statusCode,
    required this.detail,
    required this.payload,
  });

  final int statusCode;
  final String detail;
  final Map<String, dynamic>? payload;

  @override
  String toString() => 'ApiException($statusCode): $detail';
}

enum CameraResolutionPreset {
  p720,
  p1080,
  p1440,
  p2160,
}

enum ScreenShareResolutionPreset {
  p720,
  p1080,
  p1440,
  p2160,
}

enum RemoteShareViewMode {
  stretch,
  original,
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderUserId,
    required this.senderUsername,
    required this.senderDisplayName,
    required this.isRealtimeBot,
    required this.audioMimeType,
    required this.audioBase64,
    required this.content,
    required this.createdAt,
  });

  final int id;
  final int senderUserId;
  final String senderUsername;
  final String senderDisplayName;
  final bool isRealtimeBot;
  final String audioMimeType;
  final String audioBase64;
  final String content;
  final DateTime? createdAt;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final senderUsername = (json['sender_username'] ?? '-').toString();
    final senderDisplayName =
        (json['sender_display_name'] ?? senderUsername).toString();
    return ChatMessage(
      id: _MeetingModelParsing.asInt(json['id'], 0),
      senderUserId: _MeetingModelParsing.asInt(json['sender_user_id'], 0),
      senderUsername: senderUsername,
      senderDisplayName: senderDisplayName,
      isRealtimeBot:
          _MeetingModelParsing.asBool(json['is_realtime_bot'], false),
      audioMimeType: (json['audio_mime_type'] ?? '').toString(),
      audioBase64: (json['audio_base64'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      createdAt: _MeetingModelParsing.asDateTime(json['created_at']),
    );
  }
}

class WorkspaceAgentSession {
  const WorkspaceAgentSession({
    required this.agentType,
    required this.displayName,
    required this.presenceStatus,
    required this.currentTaskTitle,
    required this.latestShortReply,
    required this.bridgeOnline,
  });

  final String agentType;
  final String displayName;
  final String presenceStatus;
  final String currentTaskTitle;
  final String latestShortReply;
  final bool bridgeOnline;

  factory WorkspaceAgentSession.fromJson(Map<String, dynamic> json) {
    return WorkspaceAgentSession(
      agentType: (json['agent_type'] ?? '').toString().trim(),
      displayName: (json['display_name'] ?? '').toString().trim(),
      presenceStatus: (json['presence_status'] ?? 'offline').toString().trim(),
      currentTaskTitle: (json['current_task_title'] ?? '').toString(),
      latestShortReply: (json['latest_short_reply'] ?? '').toString(),
      bridgeOnline: _MeetingModelParsing.asBool(json['bridge_online'], false),
    );
  }
}

class WorkspaceContextSnapshot {
  const WorkspaceContextSnapshot({
    required this.topicLabel,
    required this.summaryText,
    required this.decisions,
    required this.todos,
  });

  final String topicLabel;
  final String summaryText;
  final List<String> decisions;
  final List<String> todos;

  factory WorkspaceContextSnapshot.fromJson(Map<String, dynamic> json) {
    return WorkspaceContextSnapshot(
      topicLabel: (json['topic_label'] ?? '').toString().trim(),
      summaryText: (json['summary_text'] ?? '').toString(),
      decisions: _MeetingModelParsing.asStringList(json['decisions']),
      todos: _MeetingModelParsing.asStringList(json['todos']),
    );
  }
}

class WorkspaceTranscriptChunk {
  const WorkspaceTranscriptChunk({
    required this.id,
    required this.speakerName,
    required this.speakerIdentity,
    required this.source,
    required this.text,
    required this.isFinal,
    required this.sequenceNo,
  });

  final int id;
  final String speakerName;
  final String speakerIdentity;
  final String source;
  final String text;
  final bool isFinal;
  final int sequenceNo;

  factory WorkspaceTranscriptChunk.fromJson(Map<String, dynamic> json) {
    return WorkspaceTranscriptChunk(
      id: _MeetingModelParsing.asInt(json['id'], 0),
      speakerName: (json['speaker_name'] ?? '').toString(),
      speakerIdentity: (json['speaker_identity'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      text: (json['text'] ?? '').toString(),
      isFinal: _MeetingModelParsing.asBool(json['is_final'], true),
      sequenceNo: _MeetingModelParsing.asInt(json['sequence_no'], 0),
    );
  }
}

class WorkspaceArtifact {
  const WorkspaceArtifact({
    required this.id,
    required this.artifactType,
    required this.title,
    required this.content,
  });

  final int id;
  final String artifactType;
  final String title;
  final String content;

  factory WorkspaceArtifact.fromJson(Map<String, dynamic> json) {
    return WorkspaceArtifact(
      id: _MeetingModelParsing.asInt(json['id'], 0),
      artifactType: (json['artifact_type'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
    );
  }
}

class ParticipantTileData {
  const ParticipantTileData({
    required this.identity,
    required this.displayName,
    required this.avatarUrl,
    required this.isLocal,
    required this.isSpeaking,
    required this.audioLevel,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.videoTrack,
    required this.isScreenShare,
  });

  final String identity;
  final String displayName;
  final String avatarUrl;
  final bool isLocal;
  final bool isSpeaking;
  final double audioLevel;
  final bool micEnabled;
  final bool cameraEnabled;
  final lk.VideoTrack? videoTrack;
  final bool isScreenShare;
}

class PreferredVideoSelection {
  const PreferredVideoSelection({
    required this.track,
    required this.isScreenShare,
  });

  final lk.VideoTrack? track;
  final bool isScreenShare;
}

class RequestPendingFlags {
  const RequestPendingFlags({
    required this.micPending,
    required this.videoPending,
    required this.screenSharePending,
  });

  final bool micPending;
  final bool videoPending;
  final bool screenSharePending;
}

class ParticipantRowData {
  const ParticipantRowData({
    required this.identity,
    required this.userId,
    required this.isRealtimeBot,
    required this.displayName,
    required this.avatarUrl,
    required this.role,
    required this.roleKey,
    required this.isSpeaking,
    required this.audioLevel,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.mutedByHost,
    required this.videoBlockedByHost,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.allowChat,
    required this.allowScreenShare,
    required this.micRequestPending,
    required this.videoRequestPending,
    required this.screenShareRequestPending,
    required this.isScreenSharing,
  });

  final String identity;
  final int? userId;
  final bool isRealtimeBot;
  final String displayName;
  final String avatarUrl;
  final String role;
  final String roleKey;
  final bool isSpeaking;
  final double audioLevel;
  final bool micEnabled;
  final bool cameraEnabled;
  final bool mutedByHost;
  final bool videoBlockedByHost;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool allowChat;
  final bool allowScreenShare;
  final bool micRequestPending;
  final bool videoRequestPending;
  final bool screenShareRequestPending;
  final bool isScreenSharing;
}

class MeetingMemberProfile {
  const MeetingMemberProfile({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.displayNameVersion,
    required this.avatarUrl,
    required this.role,
    required this.mutedByHost,
    required this.videoBlockedByHost,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.allowChat,
    required this.allowScreenShare,
    required this.micRequestPending,
    required this.videoRequestPending,
  });

  final int userId;
  final String username;
  final String displayName;
  final int displayNameVersion;
  final String avatarUrl;
  final String role;
  final bool mutedByHost;
  final bool videoBlockedByHost;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool allowChat;
  final bool allowScreenShare;
  final bool micRequestPending;
  final bool videoRequestPending;

  factory MeetingMemberProfile.fromJson(Map<String, dynamic> json) {
    return MeetingMemberProfile(
      userId: _MeetingModelParsing.asInt(json['user_id'], 0),
      username: (json['username'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['username'] ?? '').toString(),
      displayNameVersion:
          _MeetingModelParsing.asInt(json['display_name_version'], 1),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      role: (json['role'] ?? 'participant').toString(),
      mutedByHost: _MeetingModelParsing.asBool(json['muted_by_host'], false),
      videoBlockedByHost:
          _MeetingModelParsing.asBool(json['video_blocked_by_host'], false),
      allowSelfUnmute:
          _MeetingModelParsing.asBool(json['allow_self_unmute'], true),
      allowMemberVideo:
          _MeetingModelParsing.asBool(json['allow_member_video'], true),
      allowChat: _MeetingModelParsing.asBool(json['allow_chat'], true),
      allowScreenShare:
          _MeetingModelParsing.asBool(json['allow_screen_share'], true),
      micRequestPending:
          _MeetingModelParsing.asBool(json['mic_request_pending'], false),
      videoRequestPending:
          _MeetingModelParsing.asBool(json['video_request_pending'], false),
    );
  }
}

class JoinTokenPayload {
  const JoinTokenPayload({
    required this.meetingId,
    required this.meetingRef,
    required this.roomName,
    required this.livekitUrl,
    required this.token,
    required this.waitingRoomEnabled,
    required this.maxParticipants,
    required this.actualStartedAt,
    required this.muteOnEntry,
    required this.allowGuestLinkJoin,
    required this.allowRecording,
    required this.allowScreenShare,
    required this.allowChat,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.canPublish,
  });

  final int meetingId;
  final String meetingRef;
  final String roomName;
  final String livekitUrl;
  final String token;
  final bool waitingRoomEnabled;
  final int maxParticipants;
  final DateTime? actualStartedAt;
  final bool muteOnEntry;
  final bool allowGuestLinkJoin;
  final bool allowRecording;
  final bool allowScreenShare;
  final bool allowChat;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool canPublish;

  JoinTokenPayload copyWith({
    int? meetingId,
    String? meetingRef,
    String? roomName,
    String? livekitUrl,
    String? token,
    bool? waitingRoomEnabled,
    int? maxParticipants,
    DateTime? actualStartedAt,
    bool? muteOnEntry,
    bool? allowGuestLinkJoin,
    bool? allowRecording,
    bool? allowScreenShare,
    bool? allowChat,
    bool? allowSelfUnmute,
    bool? allowMemberVideo,
    bool? canPublish,
  }) {
    return JoinTokenPayload(
      meetingId: meetingId ?? this.meetingId,
      meetingRef: meetingRef ?? this.meetingRef,
      roomName: roomName ?? this.roomName,
      livekitUrl: livekitUrl ?? this.livekitUrl,
      token: token ?? this.token,
      waitingRoomEnabled: waitingRoomEnabled ?? this.waitingRoomEnabled,
      maxParticipants: maxParticipants ?? this.maxParticipants,
      actualStartedAt: actualStartedAt ?? this.actualStartedAt,
      muteOnEntry: muteOnEntry ?? this.muteOnEntry,
      allowGuestLinkJoin: allowGuestLinkJoin ?? this.allowGuestLinkJoin,
      allowRecording: allowRecording ?? this.allowRecording,
      allowScreenShare: allowScreenShare ?? this.allowScreenShare,
      allowChat: allowChat ?? this.allowChat,
      allowSelfUnmute: allowSelfUnmute ?? this.allowSelfUnmute,
      allowMemberVideo: allowMemberVideo ?? this.allowMemberVideo,
      canPublish: canPublish ?? this.canPublish,
    );
  }

  factory JoinTokenPayload.fromJson(Map<String, dynamic> json) {
    return JoinTokenPayload(
      meetingId: _MeetingModelParsing.asInt(json['meeting_id'], 0),
      meetingRef: (json['meeting_ref'] ?? '').toString().trim(),
      roomName: (json['room_name'] ?? '').toString(),
      livekitUrl: (json['livekit_url'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      waitingRoomEnabled:
          _MeetingModelParsing.asBool(json['waiting_room_enabled'], false),
      maxParticipants:
          _MeetingModelParsing.asInt(json['max_participants'], 100),
      actualStartedAt:
          _MeetingModelParsing.asDateTime(json['actual_started_at']),
      muteOnEntry: _MeetingModelParsing.asBool(json['mute_on_entry'], false),
      allowGuestLinkJoin:
          _MeetingModelParsing.asBool(json['allow_guest_link_join'], true),
      allowRecording:
          _MeetingModelParsing.asBool(json['allow_recording'], true),
      allowScreenShare:
          _MeetingModelParsing.asBool(json['allow_screen_share'], true),
      allowChat: _MeetingModelParsing.asBool(json['allow_chat'], true),
      allowSelfUnmute:
          _MeetingModelParsing.asBool(json['allow_self_unmute'], true),
      allowMemberVideo:
          _MeetingModelParsing.asBool(json['allow_member_video'], true),
      canPublish: _MeetingModelParsing.asBool(json['can_publish'], true),
    );
  }
}

class WaitingRoomEntry {
  const WaitingRoomEntry({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  final int userId;
  final String username;
  final String displayName;

  factory WaitingRoomEntry.fromJson(Map<String, dynamic> json) {
    return WaitingRoomEntry(
      userId: _MeetingModelParsing.asInt(json['user_id'], 0),
      username: (json['username'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['username'] ?? '').toString(),
    );
  }
}

class _MeetingModelParsing {
  static int asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static bool asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  static DateTime? asDateTime(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toLocal();
  }

  static List<String> asStringList(dynamic value) {
    if (value is! List) return const <String>[];
    return value.map((item) => item.toString()).toList();
  }
}
