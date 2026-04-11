part of 'page.dart';

class _ApiException implements Exception {
  final int statusCode;
  final String detail;
  final Map<String, dynamic>? payload;

  const _ApiException({
    required this.statusCode,
    required this.detail,
    required this.payload,
  });

  @override
  String toString() => 'ApiException($statusCode): $detail';
}

enum _CameraResolutionPreset {
  p720,
  p1080,
  p1440,
  p2160,
}

enum _ScreenShareResolutionPreset {
  p720,
  p1080,
  p1440,
  p2160,
}

enum _RemoteShareViewMode {
  stretch,
  original,
}

class _ChatMessage {
  final int id;
  final int senderUserId;
  final String senderUsername;
  final String senderDisplayName;
  final bool isRealtimeBot;
  final String audioMimeType;
  final String audioBase64;
  final String content;
  final DateTime? createdAt;

  const _ChatMessage({
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

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toLocal();
  }

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  factory _ChatMessage.fromJson(Map<String, dynamic> json) {
    final senderUsername = (json['sender_username'] ?? '-').toString();
    final senderDisplayName =
        (json['sender_display_name'] ?? senderUsername).toString();
    return _ChatMessage(
      id: _asInt(json['id'], 0),
      senderUserId: _asInt(json['sender_user_id'], 0),
      senderUsername: senderUsername,
      senderDisplayName: senderDisplayName,
      isRealtimeBot: _asBool(json['is_realtime_bot'], false),
      audioMimeType: (json['audio_mime_type'] ?? '').toString(),
      audioBase64: (json['audio_base64'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      createdAt: _asDateTime(json['created_at']),
    );
  }
}

class _WorkspaceAgentSession {
  final String agentType;
  final String displayName;
  final String presenceStatus;
  final String currentTaskTitle;
  final String latestShortReply;
  final bool bridgeOnline;

  const _WorkspaceAgentSession({
    required this.agentType,
    required this.displayName,
    required this.presenceStatus,
    required this.currentTaskTitle,
    required this.latestShortReply,
    required this.bridgeOnline,
  });

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  factory _WorkspaceAgentSession.fromJson(Map<String, dynamic> json) {
    return _WorkspaceAgentSession(
      agentType: (json['agent_type'] ?? '').toString().trim(),
      displayName: (json['display_name'] ?? '').toString().trim(),
      presenceStatus: (json['presence_status'] ?? 'offline').toString().trim(),
      currentTaskTitle: (json['current_task_title'] ?? '').toString(),
      latestShortReply: (json['latest_short_reply'] ?? '').toString(),
      bridgeOnline: _asBool(json['bridge_online'], false),
    );
  }
}

class _WorkspaceContextSnapshot {
  final String topicLabel;
  final String summaryText;
  final List<String> decisions;
  final List<String> todos;

  const _WorkspaceContextSnapshot({
    required this.topicLabel,
    required this.summaryText,
    required this.decisions,
    required this.todos,
  });

  static List<String> _asStringList(dynamic value) {
    if (value is! List) return const <String>[];
    return value.map((item) => item.toString()).toList();
  }

  factory _WorkspaceContextSnapshot.fromJson(Map<String, dynamic> json) {
    return _WorkspaceContextSnapshot(
      topicLabel: (json['topic_label'] ?? '').toString().trim(),
      summaryText: (json['summary_text'] ?? '').toString(),
      decisions: _asStringList(json['decisions']),
      todos: _asStringList(json['todos']),
    );
  }
}

class _WorkspaceTranscriptChunk {
  final int id;
  final String speakerName;
  final String speakerIdentity;
  final String source;
  final String text;
  final bool isFinal;
  final int sequenceNo;

  const _WorkspaceTranscriptChunk({
    required this.id,
    required this.speakerName,
    required this.speakerIdentity,
    required this.source,
    required this.text,
    required this.isFinal,
    required this.sequenceNo,
  });

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  factory _WorkspaceTranscriptChunk.fromJson(Map<String, dynamic> json) {
    return _WorkspaceTranscriptChunk(
      id: _asInt(json['id'], 0),
      speakerName: (json['speaker_name'] ?? '').toString(),
      speakerIdentity: (json['speaker_identity'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      text: (json['text'] ?? '').toString(),
      isFinal: _asBool(json['is_final'], true),
      sequenceNo: _asInt(json['sequence_no'], 0),
    );
  }
}

class _WorkspaceArtifact {
  final int id;
  final String artifactType;
  final String title;
  final String content;

  const _WorkspaceArtifact({
    required this.id,
    required this.artifactType,
    required this.title,
    required this.content,
  });

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  factory _WorkspaceArtifact.fromJson(Map<String, dynamic> json) {
    return _WorkspaceArtifact(
      id: _asInt(json['id'], 0),
      artifactType: (json['artifact_type'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
    );
  }
}

class _ParticipantTileData {
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

  const _ParticipantTileData({
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
}

class _PreferredVideoSelection {
  final lk.VideoTrack? track;
  final bool isScreenShare;

  const _PreferredVideoSelection({
    required this.track,
    required this.isScreenShare,
  });
}

class _RequestPendingFlags {
  final bool micPending;
  final bool videoPending;
  final bool screenSharePending;

  const _RequestPendingFlags({
    required this.micPending,
    required this.videoPending,
    required this.screenSharePending,
  });
}

class _ParticipantRowData {
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

  const _ParticipantRowData({
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
}

class _MeetingMemberProfile {
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

  const _MeetingMemberProfile({
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

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  factory _MeetingMemberProfile.fromJson(Map<String, dynamic> json) {
    return _MeetingMemberProfile(
      userId: _asInt(json['user_id'], 0),
      username: (json['username'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['username'] ?? '').toString(),
      displayNameVersion: _asInt(json['display_name_version'], 1),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      role: (json['role'] ?? 'participant').toString(),
      mutedByHost: _asBool(json['muted_by_host'], false),
      videoBlockedByHost: _asBool(json['video_blocked_by_host'], false),
      allowSelfUnmute: _asBool(json['allow_self_unmute'], true),
      allowMemberVideo: _asBool(json['allow_member_video'], true),
      allowChat: _asBool(json['allow_chat'], true),
      allowScreenShare: _asBool(json['allow_screen_share'], true),
      micRequestPending: _asBool(json['mic_request_pending'], false),
      videoRequestPending: _asBool(json['video_request_pending'], false),
    );
  }
}

class _JoinTokenPayload {
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

  const _JoinTokenPayload({
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

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toLocal();
  }

  factory _JoinTokenPayload.fromJson(Map<String, dynamic> json) {
    return _JoinTokenPayload(
      meetingId: _asInt(json['meeting_id'], 0),
      meetingRef: (json['meeting_ref'] ?? '').toString().trim(),
      roomName: (json['room_name'] ?? '').toString(),
      livekitUrl: (json['livekit_url'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      waitingRoomEnabled: _asBool(json['waiting_room_enabled'], false),
      maxParticipants: _asInt(json['max_participants'], 100),
      actualStartedAt: _asDateTime(json['actual_started_at']),
      muteOnEntry: _asBool(json['mute_on_entry'], false),
      allowGuestLinkJoin: _asBool(json['allow_guest_link_join'], true),
      allowRecording: _asBool(json['allow_recording'], true),
      allowScreenShare: _asBool(json['allow_screen_share'], true),
      allowChat: _asBool(json['allow_chat'], true),
      allowSelfUnmute: _asBool(json['allow_self_unmute'], true),
      allowMemberVideo: _asBool(json['allow_member_video'], true),
      canPublish: _asBool(json['can_publish'], true),
    );
  }
}

class _WaitingRoomEntry {
  final int userId;
  final String username;
  final String displayName;

  const _WaitingRoomEntry({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  factory _WaitingRoomEntry.fromJson(Map<String, dynamic> json) {
    return _WaitingRoomEntry(
      userId: _asInt(json['user_id'], 0),
      username: (json['username'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['username'] ?? '').toString(),
    );
  }
}
