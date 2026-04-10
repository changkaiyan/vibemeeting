import '../../core/json_parsing.dart';

class BillingPlanItem {
  BillingPlanItem({
    required this.id,
    required this.name,
    required this.description,
    required this.maxActiveRooms,
    required this.maxRoomParticipants,
    required this.maxRoomUsedSeconds,
    required this.maxCurrentRoomUsedSeconds,
    required this.maxRecordingStorageBytes,
    required this.maxMeetingCount,
    required this.updatedAt,
  });

  final int id;
  final String name;
  final String description;
  final int maxActiveRooms;
  final int maxRoomParticipants;
  final int maxRoomUsedSeconds;
  final int maxCurrentRoomUsedSeconds;
  final int maxRecordingStorageBytes;
  final int maxMeetingCount;
  final String updatedAt;

  factory BillingPlanItem.fromJson(Map<String, dynamic> json) {
    return BillingPlanItem(
      id: JsonParsing.asInt(json['id'], 0),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      maxActiveRooms: JsonParsing.asInt(json['max_active_rooms'], 0),
      maxRoomParticipants:
          JsonParsing.asInt(json['max_room_participants'], 0),
      maxRoomUsedSeconds: JsonParsing.asInt(json['max_room_used_seconds'], 0),
      maxCurrentRoomUsedSeconds:
          JsonParsing.asInt(json['max_current_room_used_seconds'], 0),
      maxRecordingStorageBytes:
          JsonParsing.asInt(json['max_recording_storage_bytes'], 0),
      maxMeetingCount: JsonParsing.asInt(json['max_meeting_count'], 0),
      updatedAt: (json['updated_at'] ?? '').toString(),
    );
  }
}

class BillingUserItem {
  BillingUserItem({
    required this.userId,
    required this.username,
    required this.email,
    required this.isSuperuser,
    required this.planId,
    required this.planName,
    required this.usage,
    required this.limits,
    required this.exceededKeys,
  });

  final int userId;
  final String username;
  final String email;
  final bool isSuperuser;
  final int? planId;
  final String? planName;
  final Map<String, int> usage;
  final Map<String, int?> limits;
  final List<String> exceededKeys;

  static Map<String, int> _toIntMap(dynamic value) {
    if (value is! Map) return const <String, int>{};
    final result = <String, int>{};
    for (final entry in value.entries) {
      result[entry.key.toString()] = JsonParsing.asInt(entry.value, 0);
    }
    return result;
  }

  static Map<String, int?> _toNullableIntMap(dynamic value) {
    if (value is! Map) return const <String, int?>{};
    final result = <String, int?>{};
    for (final entry in value.entries) {
      if (entry.value == null) {
        result[entry.key.toString()] = null;
      } else {
        result[entry.key.toString()] = JsonParsing.asInt(entry.value, 0);
      }
    }
    return result;
  }

  factory BillingUserItem.fromJson(Map<String, dynamic> json) {
    final exceededRaw = json['exceeded_keys'];
    final exceeded = <String>[];
    if (exceededRaw is List) {
      for (final item in exceededRaw) {
        exceeded.add(item.toString());
      }
    }
    final planIdRaw = json['plan_id'];
    int? planId;
    if (planIdRaw != null) {
      planId = JsonParsing.asInt(planIdRaw, 0);
    }
    return BillingUserItem(
      userId: JsonParsing.asInt(json['user_id'], 0),
      username: (json['username'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      isSuperuser: JsonParsing.asBool(json['is_superuser'], false),
      planId: planId,
      planName: json['plan_name']?.toString(),
      usage: _toIntMap(json['usage']),
      limits: _toNullableIntMap(json['limits']),
      exceededKeys: exceeded,
    );
  }
}

class BillingAuthOptionsItem {
  BillingAuthOptionsItem({
    required this.allowTechcloudOauthLogin,
    required this.allowLocalRegister,
    required this.allowLocalLogin,
    required this.techcloudOauthConfigured,
    required this.effectiveTechcloudOauthLogin,
    required this.updatedByUsername,
    required this.updatedAt,
  });

  final bool allowTechcloudOauthLogin;
  final bool allowLocalRegister;
  final bool allowLocalLogin;
  final bool techcloudOauthConfigured;
  final bool effectiveTechcloudOauthLogin;
  final String updatedByUsername;
  final String updatedAt;

  BillingAuthOptionsItem copyWith({
    bool? allowTechcloudOauthLogin,
    bool? allowLocalRegister,
    bool? allowLocalLogin,
    bool? techcloudOauthConfigured,
    bool? effectiveTechcloudOauthLogin,
    String? updatedByUsername,
    String? updatedAt,
  }) {
    return BillingAuthOptionsItem(
      allowTechcloudOauthLogin:
          allowTechcloudOauthLogin ?? this.allowTechcloudOauthLogin,
      allowLocalRegister: allowLocalRegister ?? this.allowLocalRegister,
      allowLocalLogin: allowLocalLogin ?? this.allowLocalLogin,
      techcloudOauthConfigured:
          techcloudOauthConfigured ?? this.techcloudOauthConfigured,
      effectiveTechcloudOauthLogin:
          effectiveTechcloudOauthLogin ?? this.effectiveTechcloudOauthLogin,
      updatedByUsername: updatedByUsername ?? this.updatedByUsername,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toUpdatePayload() {
    return <String, dynamic>{
      'allow_techcloud_oauth_login': allowTechcloudOauthLogin,
      'allow_local_register': allowLocalRegister,
      'allow_local_login': allowLocalLogin,
    };
  }

  factory BillingAuthOptionsItem.fromJson(Map<String, dynamic> json) {
    return BillingAuthOptionsItem(
      allowTechcloudOauthLogin:
          JsonParsing.asBool(json['allow_techcloud_oauth_login'], true),
      allowLocalRegister:
          JsonParsing.asBool(json['allow_local_register'], true),
      allowLocalLogin: JsonParsing.asBool(json['allow_local_login'], true),
      techcloudOauthConfigured:
          JsonParsing.asBool(json['techcloud_oauth_configured'], false),
      effectiveTechcloudOauthLogin:
          JsonParsing.asBool(json['effective_techcloud_oauth_login'], false),
      updatedByUsername: (json['updated_by_username'] ?? '').toString(),
      updatedAt: (json['updated_at'] ?? '').toString(),
    );
  }
}
